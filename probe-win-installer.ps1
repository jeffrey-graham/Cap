$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$work = Join-Path $env:RUNNER_TEMP "instprobe"
$out = Join-Path $env:RUNNER_TEMP "instprobe-out"
New-Item -ItemType Directory -Force $work, $out | Out-Null
$repo = $env:GITHUB_WORKSPACE
$gpui = Join-Path $repo "apps\desktop-gpui"
$release = Join-Path $work "Cap_0.6.2_x64-setup.exe"
$installDir = Join-Path $env:LOCALAPPDATA "Cap"

function Shot($name) {
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Location, [Drawing.Point]::Empty, $b.Size)
  $bmp.Save((Join-Path $out "$name.png"))
  $g.Dispose(); $bmp.Dispose()
}

function Start-Mcp($label) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = Join-Path $installDir "cap-cli.exe"
  $psi.Arguments = "mcp serve"
  $psi.WorkingDirectory = $env:USERPROFILE
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.EnvironmentVariables["CAP_AGENT_TOKEN"] = "cap_cli_probe"
  $psi.EnvironmentVariables["CAP_SERVER_URL"] = "http://127.0.0.1:9"
  $p = [System.Diagnostics.Process]::Start($psi)
  $init = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
  $p.StandardInput.WriteLine($init)
  $p.StandardInput.Flush()
  $task = $p.StandardOutput.ReadLineAsync()
  if (-not $task.Wait(30000)) { throw "[$label] no MCP initialize response" }
  $line = $task.Result
  if ($null -eq $line) {
    $p.WaitForExit(5000) | Out-Null
    throw "[$label] mcp server exited ($($p.ExitCode)): $($p.StandardError.ReadToEnd())"
  }
  Write-Host "[$label] mcp pid $($p.Id) initialize -> $($line.Substring(0, [Math]::Min(200, $line.Length)))"
  Start-Sleep -Seconds 1
  $mods = (Get-Process -Id $p.Id).Modules | Where-Object { $_.ModuleName -like "avcodec*" } | ForEach-Object { $_.FileName }
  Write-Host "[$label] mcp pid $($p.Id) loaded: $($mods -join ', ')"
  return $p
}

function Install-Baseline {
  Get-Process Cap, cap-cli -ErrorAction SilentlyContinue | Stop-Process -Force
  $p = Start-Process -FilePath $release -ArgumentList "/S" -PassThru
  if (-not $p.WaitForExit(300000)) { throw "baseline install hung" }
  Write-Host "baseline install exit $($p.ExitCode)"
  Get-Process Cap -ErrorAction SilentlyContinue | Stop-Process -Force
}

function Run-Update($label, $installer, $marked, $record = $false) {
  Install-Baseline
  $before = (Get-FileHash (Join-Path $installDir "avcodec-61.dll")).Hash
  $mcp = Start-Mcp "$label before"
  $cli = Join-Path $installDir "cap-cli.exe"
  $worker = $null
  if ($record) {
    $targets = & $cli targets --json 2>&1 | Out-String
    Write-Host "[$label] targets: $($targets.Substring(0, [Math]::Min(600, $targets.Length)))"
    $screen = ([regex]::Match($targets, '"id"\s*:\s*"?([^",}]+)"?')).Groups[1].Value
    $started = & $cli record start --screen $screen --detach --json 2>&1 | Out-String
    Write-Host "[$label] record start: $started"
    $workerPid = [int]([regex]::Match($started, '"pid"\s*:\s*(\d+)')).Groups[1].Value
    $recordingId = ([regex]::Match($started, '"recordingId"\s*:\s*"([^"]+)"')).Groups[1].Value
    Start-Sleep -Seconds 4
    $worker = Get-Process -Id $workerPid -ErrorAction SilentlyContinue
    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $workerPid").CommandLine
    Write-Host "[$label] recording worker pid $workerPid alive=$($null -ne $worker) cmd=$cmd"
  }
  $inst = Start-Process -FilePath $installer -ArgumentList "/P /R /UPDATE" -PassThru
  $finished = $inst.WaitForExit(120000)
  Shot $label
  if ($finished) {
    Write-Host "[$label] installer exit $($inst.ExitCode)"
  } else {
    $titles = Get-Process | Where-Object { $_.MainWindowTitle } | ForEach-Object { "$($_.ProcessName): $($_.MainWindowTitle)" }
    Write-Host "[$label] installer STILL RUNNING after 120s; windows: $($titles -join ' | ')"
    Stop-Process -Id $inst.Id -Force
  }
  $mcp.Refresh()
  Write-Host "[$label] old mcp server exited: $($mcp.HasExited)"
  if ($record) {
    $alive = $null -ne (Get-Process -Id $workerPid -ErrorAction SilentlyContinue)
    Write-Host "[$label] recording worker still running after installer: $alive"
    Get-Process | Where-Object { $_.Name -like "*setup*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    $stopped = & $cli record stop --id $recordingId --json 2>&1 | Out-String
    Write-Host "[$label] record stop: $stopped"
  }
  $after = (Get-FileHash (Join-Path $installDir "avcodec-61.dll")).Hash
  Write-Host "[$label] avcodec-61.dll before=$before after=$after marked=$marked replaced=$($after -eq $marked)"
  Get-Process Cap -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "[$label] relaunched Cap pid $($_.Id) $($_.Path)" }
  if (-not $mcp.HasExited) { Stop-Process -Id $mcp.Id -Force }
  Get-Process Cap -ErrorAction SilentlyContinue | Stop-Process -Force
  $again = Start-Mcp "$label after"
  Stop-Process -Id $again.Id -Force
}

Invoke-WebRequest -Uri $env:RELEASE_URL -OutFile $release
Write-Host "release installer sha256 $((Get-FileHash $release).Hash)"

# Repack the shipped 0.6.2 payload through the real Tauri 2.8.4 NSIS template.
$payload = Join-Path $work "payload"
& 7z x -y "-o$payload" $release | Out-Null
Get-ChildItem $payload | Select-Object -First 60 | ForEach-Object { Write-Host "payload: $($_.Name)" }
$triple = "x86_64-pc-windows-msvc"
$rel = Join-Path $gpui "target\$triple\release"
New-Item -ItemType Directory -Force $rel, (Join-Path $gpui "binaries"), (Join-Path $repo "target\ffmpeg\bin") | Out-Null
Copy-Item (Join-Path $payload "Cap.exe") (Join-Path $rel "Cap.exe")
Copy-Item (Join-Path $payload "cap-cli.exe") (Join-Path $gpui "binaries\cap-cli-$triple.exe")
Copy-Item (Join-Path $payload "cap-muxer.exe") (Join-Path $gpui "binaries\cap-muxer-$triple.exe")
Copy-Item (Join-Path $payload "*.dll") (Join-Path $repo "target\ffmpeg\bin\")
# Overlay bytes make the repacked avcodec distinguishable from the installed one.
$dll = Join-Path $repo "target\ffmpeg\bin\avcodec-61.dll"
$fs = [System.IO.File]::Open($dll, "Append"); $fs.Write([byte[]](1..16), 0, 16); $fs.Close()
$marked = (Get-FileHash $dll).Hash
'{"bundle":{"resources":{"../../target/ffmpeg/bin/*.dll":"./"}}}' | Set-Content -Encoding ascii (Join-Path $gpui "tauri.windows.conf.json")
$noUpdater = Join-Path $work "no-updater.json"
'{"bundle":{"createUpdaterArtifacts":false}}' | Set-Content -Encoding ascii $noUpdater

$hooks = Join-Path $gpui "packaging\windows\installer-hooks.nsh"
$fixed = Get-Content -Raw $hooks
$mainHooks = Join-Path $repo "main-installer-hooks.nsh"
$variants = @(@{ name = "main"; hooks = (Get-Content -Raw $mainHooks) }, @{ name = "fixed"; hooks = $fixed })
$built = @{}
Push-Location $gpui
foreach ($v in $variants) {
  Set-Content -NoNewline -Path $hooks -Value $v.hooks
  & npx --yes @tauri-apps/cli@2.8.4 bundle --target $triple --bundles nsis --config $noUpdater
  if ($LASTEXITCODE -ne 0) { throw "bundle $($v.name) failed" }
  $setup = Get-ChildItem (Join-Path $rel "bundle\nsis\*-setup.exe") | Select-Object -First 1
  $dest = Join-Path $work "$($v.name)-setup.exe"
  Copy-Item $setup.FullName $dest -Force
  $built[$v.name] = $dest
}
Pop-Location

Run-Update "repack-main" $built["main"] $marked
Run-Update "repack-fixed" $built["fixed"] $marked
Run-Update "repack-fixed-recording" $built["fixed"] $marked $true
