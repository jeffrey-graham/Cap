param([string]$App, [string]$Out)
# Real-app probes on Windows: the main window after Settings / the editor
# closes (#3606, #3664) and the area outline during a recording (#3709, #3761).
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$results = Join-Path $Out "result.txt"
Set-Content -Path $results -Value ""
function Result($k, $v) { "$k=$v" | Tee-Object -FilePath $results -Append }

Add-Type -ReferencedAssemblies System.Drawing @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class W {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowDisplayAffinity(IntPtr h, out uint a);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  public static List<IntPtr> Of(uint pid) {
    var l = new List<IntPtr>();
    EnumWindows((h, _) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid) l.Add(h); return true; }, IntPtr.Zero);
    return l;
  }
  public static string Title(IntPtr h) { var s = new StringBuilder(256); GetWindowText(h, s, 256); return s.ToString(); }
  public static uint Owner(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
  public static IntPtr At(int x, int y) { var p = new POINT(); p.X = x; p.Y = y; return GetAncestor(WindowFromPoint(p), 2); }
}
"@
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

function Dump($proc, $label) {
  $lines = @()
  foreach ($h in [W]::Of([uint32]$proc.Id)) {
    $r = New-Object W+RECT; [W]::GetWindowRect($h, [ref]$r) | Out-Null
    $cloak = 0; [W]::DwmGetWindowAttribute($h, 14, [ref]$cloak, 4) | Out-Null
    $aff = 0; [W]::GetWindowDisplayAffinity($h, [ref]$aff) | Out-Null
    $ex = [W]::GetWindowLongPtr($h, -20).ToInt64()
    $lines += ("{0} title='{1}' visible={2} iconic={3} cloaked={4} exstyle=0x{5:x} affinity={6} rect={7},{8},{9},{10}" -f `
      $h, [W]::Title($h), [W]::IsWindowVisible($h), [W]::IsIconic($h), $cloak, $ex, $aff, $r.L, $r.T, $r.R, $r.B)
  }
  "--- $label" | Add-Content (Join-Path $Out "windows.log")
  $lines | Add-Content (Join-Path $Out "windows.log")
}
function Find($proc, $title) {
  foreach ($h in [W]::Of([uint32]$proc.Id)) { if ([W]::Title($h) -eq $title) { return $h } }
  return [IntPtr]::Zero
}
function Visible($proc, $title) {
  foreach ($h in [W]::Of([uint32]$proc.Id)) {
    if ([W]::Title($h) -eq $title -and [W]::IsWindowVisible($h) -and -not [W]::IsIconic($h)) { $c = 0; [W]::DwmGetWindowAttribute($h, 14, [ref]$c, 4) | Out-Null; if ($c -eq 0) { return "yes" } }
  }
  return "no"
}
function WaitLog($log, $pattern, $secs) {
  for ($i = 0; $i -lt $secs * 4; $i++) {
    if ((Test-Path $log) -and (Select-String -Path $log -Pattern $pattern -Quiet)) { return $true }
    Start-Sleep -Milliseconds 250
  }
  return $false
}
function Launch($name, $vars) {
  $profile = Join-Path $Out $name
  New-Item -ItemType Directory -Force -Path (Join-Path $profile "recordings"), (Join-Path $profile "logs") | Out-Null
  Set-Content -Path (Join-Path $profile "store") -NoNewline -Value '{"general_settings":{"hasCompletedOnboarding":true,"hasCompletedStartup":true,"enableNotifications":false,"enableTelemetry":false,"recordingCountdown":0},"recording_start_safety":{"confirmBeforeRecordingWithoutMicrophone":false}}'
  $env:CAP_GPUI_APP_DATA_DIR = $profile
  $env:CAP_GPUI_RECORDINGS_DIR = Join-Path $profile "recordings"
  $env:CAP_GPUI_LOG_DIR = Join-Path $profile "logs"
  $env:CAP_GPUI_AUTO_NO_MIC = "1"
  $env:RUST_LOG = "cap_gpui=info,cap_recording=info"
  foreach ($k in $vars.Keys) { Set-Item -Path "env:$k" -Value $vars[$k] }
  $p = Start-Process -FilePath $App -PassThru -RedirectStandardOutput (Join-Path $profile "cap.log") -RedirectStandardError (Join-Path $profile "cap.err.log")
  foreach ($k in $vars.Keys) { Remove-Item -Path "env:$k" -ErrorAction SilentlyContinue }
  return $p
}
function Stop($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Start-Sleep 2 }
function LogAfter($log, $first, $then) {
  $lines = Get-Content $log -ErrorAction SilentlyContinue
  $seen = $false
  foreach ($l in $lines) {
    if ($l -match $first) { $seen = $true; continue }
    if ($seen -and $l -match $then) { return "yes" }
  }
  return "no"
}

# 1. Close the main window with its close button (WM_CLOSE), open Settings
# from the tray, close Settings: the main window should stay closed.
$p = Launch "settings" @{ CAP_GPUI_AUTO_TRAY = "settings"; CAP_GPUI_AUTO_TRAY_DELAY = "12000" }
$log = Join-Path $Out "settings\cap.log"
for ($i = 0; $i -lt 60 -and (Visible $p "Cap") -ne "yes"; $i++) { Start-Sleep -Milliseconds 500 }
Result settings_main_shown_at_launch (Visible $p "Cap")
Start-Sleep 2
[W]::PostMessage((Find $p "Cap"), 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
Start-Sleep 2
Dump $p "settings: after closing main"
Result settings_main_visible_after_close (Visible $p "Cap")
WaitLog $log "settings window opened" 30 | Out-Null
Start-Sleep 3
Dump $p "settings: settings open"
Result settings_settings_visible (Visible $p "Cap Settings")
[W]::PostMessage((Find $p "Cap Settings"), 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
Start-Sleep 4
Dump $p "settings: after closing settings"
Result settings_closed_logged ([bool](Select-String -Path $log -Pattern "settings window closed" -Quiet))
Result settings_main_visible_after_settings_close (Visible $p "Cap")
Result settings_main_reshown_logged (LogAfter $log "settings window closed" "showing the main window")
Stop $p

# 2. Close the main window, start a Studio recording with the shortcut, stop it,
# let the editor open and close it: the main window should stay closed.
$p = Launch "editor" @{ CAP_GPUI_AUTO_HOTKEY = "startStudioRecording"; CAP_GPUI_AUTO_TRAY = "stop"; CAP_GPUI_AUTO_TRAY_DELAY = "14000"; CAP_GPUI_AUTO_EDITOR_CLOSE = "5" }
$log = Join-Path $Out "editor\cap.log"
for ($i = 0; $i -lt 300 -and (Visible $p "Cap") -ne "yes"; $i++) { Start-Sleep -Milliseconds 100 }
Result editor_main_shown_at_launch (Visible $p "Cap")
[W]::PostMessage((Find $p "Cap"), 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
Result editor_recording_started (WaitLog $log "recording started" 40)
Result editor_opened (WaitLog $log "editor instance ready|preparing editor shell created" 60)
Result editor_closed_logged (WaitLog $log "editor window closed" 40)
Start-Sleep 4
Dump $p "editor: after closing the editor"
Result editor_main_visible_after_editor_close (Visible $p "Cap")
Result editor_main_reshown_logged (LogAfter $log "editor window closed" "showing the main window")
Stop $p

# 3. Area recording: the outline stays, lets clicks through, and is drawn.
# CAP_PROBE_CAPTURE_VISIBLE keeps Cap's windows in desktop screenshots for
# this probe only (inert otherwise).
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$before = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
[System.Drawing.Graphics]::FromImage($before).CopyFromScreen(0, 0, 0, 0, $before.Size)
$before.Save((Join-Path $Out "area-before.png"))
$x = 160; $y = 140; $w = 480; $h = 270
$p = Launch "area" @{ CAP_GPUI_AUTO_RECORD = "studio:14"; CAP_GPUI_AUTO_OVERLAY = "area"; CAP_GPUI_AUTO_AREA = "$x,$y,$w,$h"; CAP_PROBE_CAPTURE_VISIBLE = "1" }
$log = Join-Path $Out "area\cap.log"
Result area_recording_started (WaitLog $log "recording started" 40)
Start-Sleep 4
Dump $p "area: recording"
$shot = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
[System.Drawing.Graphics]::FromImage($shot).CopyFromScreen(0, 0, 0, 0, $shot.Size)
$shot.Save((Join-Path $Out "area-recording.png"))
Result area_click_through_failed_logged ([bool](Select-String -Path $log -Pattern "click-through failed" -Quiet))
$overlay = "no"
foreach ($hw in [W]::Of([uint32]$p.Id)) {
  $r = New-Object W+RECT; [W]::GetWindowRect($hw, [ref]$r) | Out-Null
  if ([W]::IsWindowVisible($hw) -and ($r.R - $r.L) -ge $bounds.Width -and ($r.B - $r.T) -ge $bounds.Height - 80) { $overlay = "yes" }
}
Result area_overlay_window_visible $overlay
$hit = [W]::At($x + $w / 2, $y + $h / 2)
Result area_click_lands_on_cap ([W]::Owner($hit) -eq [uint32]$p.Id)
# Pixels that changed in a band around the area's edge.
$changed = 0; $total = 0
foreach ($i in 0..($w + 16)) {
  foreach ($py in @(($y - 6), ($y - 3), ($y + $h + 2), ($y + $h + 5))) {
    $px = $x - 8 + $i
    $total++
    if ($before.GetPixel($px, $py).ToArgb() -ne $shot.GetPixel($px, $py).ToArgb()) { $changed++ }
  }
}
Result area_edge_pixels_changed "$changed/$total"
Result area_recording_finished (WaitLog $log "recording finished" 40)
Stop $p
Get-Content $results
