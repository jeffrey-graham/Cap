#!/usr/bin/env bash
# Usage: linux.sh <cap-gpui> <ffmpeg lib dir> <out-dir>
# Real-app probes for contributor PRs: Studio project name, generated zoom
# amount, export progress ring video, and PipeWire system audio routing.
set -uo pipefail
if [[ -z ${PROBE_BUS:-} ]]; then
  exec env PROBE_BUS=1 dbus-run-session -- bash "$0" "$@"
fi
bin=$1 libs=$2 out=$3
mkdir -p "$out" && : >"$out/result.txt"
result() { printf '%s=%s\n' "$1" "$2" | tee -a "$out/result.txt"; }
unset WAYLAND_DISPLAY
export DISPLAY=:79 XDG_SESSION_TYPE=x11
Xvfb "$DISPLAY" -screen 0 1920x1080x24 >/dev/null 2>&1 &
sleep 1
xmessage -geometry 480x270+700+300 -title "Window to record" "A window to record" >/dev/null 2>&1 &

launch() {
  local name=$1; shift
  local profile=$out/$name
  mkdir -p "$profile/recordings" "$profile/logs"
  [[ -f "$profile/store" ]] || printf '%s' '{"general_settings":{"hasCompletedStartup":true,"hasCompletedOnboarding":true,"enableNotifications":false,"enableTelemetry":false,"recordingCountdown":0},"recording_start_safety":{"confirmBeforeRecordingWithoutMicrophone":false}}' >"$profile/store"
  env LD_LIBRARY_PATH="$libs" CAP_GPUI_APP_DATA_DIR="$profile" CAP_GPUI_RECORDINGS_DIR="${RECDIR:-$profile/recordings}" \
    CAP_GPUI_LOG_DIR="$profile/logs" CAP_GPUI_NO_TRAY=1 RUST_LOG=info "$@" \
    "$bin" >>"$profile/cap.log" 2>&1 &
  echo $! >"$profile/pid"
}
wait_log() {
  for _ in $(seq $(($3 * 4))); do
    grep -aq -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.25
  done
  return 1
}
finish() {
  local pid; pid=$(cat "$out/$1/pid")
  kill "$pid" 2>/dev/null
  for _ in $(seq 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
  kill -9 "$pid" 2>/dev/null
}

# 1. Studio project name (#3896): a Studio window recording with the default
# project name template.
launch name CAP_GPUI_AUTO_NO_MIC=1 CAP_GPUI_AUTO_RECORD=studio:5 CAP_GPUI_AUTO_OVERLAY=window \
  CAP_GPUI_AUTO_WINDOW="Window to record"
wait_log "$out/name/cap.log" "recording started" 30 && result name_started yes || result name_started no
sleep 2
project=$(find "$out/name/recordings" -maxdepth 1 -name "*.cap" | head -1)
if [[ -n $project ]]; then
  result name_in_progress_pretty_name "\"$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pretty_name"])' "$project/recording-meta.json" 2>/dev/null)\""
fi
wait_log "$out/name/cap.log" "recording finished" 30 && result name_finished yes || result name_finished no
sleep 4
finish name
project=$(find "$out/name/recordings" -maxdepth 1 -name "*.cap" | head -1)
result name_folder "\"$(basename "${project%.cap}")\""
pretty=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pretty_name"])' "$project/recording-meta.json" 2>/dev/null)
result name_pretty_name "\"$pretty\""
result name_matches_folder "$([[ -n $pretty && $pretty == "$(basename "${project%.cap}")" ]] && echo yes || echo no)"

# 2. Generated zoom amount (#3898): the same project, with clicks added to its
# cursor data, opened in the editor and Generate pressed through the harness.
python3 - "$project" <<'PY' | tee -a "$out/actions.log"
import json, os, sys
project = sys.argv[1]
meta_path = os.path.join(project, "recording-meta.json")
meta = json.load(open(meta_path))
segments = meta.get("segments") or [meta.get("segment")]
seg = segments[0]
cursor_rel = seg.get("cursor") or "content/segments/segment-0/cursor.json"
seg["cursor"] = cursor_rel
json.dump(meta, open(meta_path, "w"), indent=2)
path = os.path.join(project, cursor_rel)
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    data = json.load(open(path))
except Exception:
    data = {"clicks": [], "moves": []}
data.setdefault("moves", [])
for t, x, y in [(900, 0.3, 0.3), (1000, 0.31, 0.31), (2900, 0.6, 0.6), (3000, 0.61, 0.6)]:
    data["moves"].append({"active_modifiers": [], "cursor_id": "0", "time_ms": t, "x": x, "y": y})
data["clicks"] = [
    {"active_modifiers": [], "cursor_num": 0, "cursor_id": "0", "time_ms": 1000.0, "down": True},
    {"active_modifiers": [], "cursor_num": 0, "cursor_id": "0", "time_ms": 1100.0, "down": False},
    {"active_modifiers": [], "cursor_num": 0, "cursor_id": "0", "time_ms": 3000.0, "down": True},
    {"active_modifiers": [], "cursor_num": 0, "cursor_id": "0", "time_ms": 3100.0, "down": False},
]
json.dump(data, open(path, "w"))
print("clicks written to", path)
PY
cp -a "$project/project-config.json" "$out/project-config.before.json" 2>/dev/null
launch zoom CAP_GPUI_AUTO_EDITOR="$project" CAP_GPUI_AUTO_GENERATE_ZOOM=1
sleep 20
finish zoom
cp -a "$project/project-config.json" "$out/project-config.after-zoom.json" 2>/dev/null
amounts=$(python3 -c '
import json,sys
c=json.load(open(sys.argv[1]))
z=(c.get("timeline") or {}).get("zoomSegments") or []
print(",".join(str(s.get("amount")) for s in z))' "$project/project-config.json" 2>/dev/null)
result zoom_amounts "${amounts:-none}"

# 3. Export progress ring (#3780): screen-record the export overlay.
ffmpeg -hide_banner -loglevel error -nostdin -y -f x11grab -framerate 30 -video_size 1920x1080 -i "$DISPLAY" \
  -t 40 -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$out/export-ring.mp4" &
grab=$!
launch ring CAP_GPUI_AUTO_EDITOR="$project" CAP_GPUI_AUTO_EXPORT="$out/export.mp4"
wait_log "$out/ring/cap.log" "editor export completed" 60 && result ring_export_logged yes || result ring_export_logged no
sleep 3
finish ring
kill -INT $grab 2>/dev/null; wait $grab 2>/dev/null
result ring_export_file "$([[ -s $out/export.mp4 ]] && echo yes || echo no)"

# 4. PipeWire system audio (#3514 / #3534): Ubuntu 24.04's PipeWire 1.0.5.
if [[ ${PROBE_AUDIO:-1} == 1 ]]; then
  export XDG_RUNTIME_DIR=$(mktemp -d); chmod 700 "$XDG_RUNTIME_DIR"
  pipewire >"$out/pipewire.log" 2>&1 &
  sleep 1
  wireplumber >"$out/wireplumber.log" 2>&1 &
  pipewire-pulse >"$out/pipewire-pulse.log" 2>&1 &
  for _ in $(seq 40); do pactl info >/dev/null 2>&1 && break; sleep 0.25; done
  pactl info | tee "$out/pactl-info.txt"
  pactl load-module module-null-sink sink_name=cap_tone
  pactl load-module module-remap-source master=cap_tone.monitor source_name=cap_mic
  sleep 1
  pactl set-default-sink cap_tone
  python3 - "$out/tone.wav" <<'PY'
import math, struct, sys, wave
rate = 48000
with wave.open(sys.argv[1], "wb") as tone:
    tone.setnchannels(2); tone.setsampwidth(2); tone.setframerate(rate)
    tone.writeframes(b"".join(struct.pack("<hh", s, s) for s in (int(12000 * math.sin(2 * math.pi * 440 * n / rate)) for n in range(rate * 30))))
PY
  (while paplay --device=cap_tone "$out/tone.wav"; do :; done) &
  player=$!
  for case in mic monitor; do
    if [[ $case == mic ]]; then pactl set-default-source cap_mic; else pactl set-default-source cap_tone.monitor; fi
    pactl list short sources >"$out/sources-$case.txt"
    launch "audio_$case" CAP_GPUI_AUTO_NO_MIC=1 CAP_GPUI_AUTO_SYSTEM_AUDIO=1 CAP_GPUI_AUTO_RECORD=studio:6 \
      CAP_GPUI_AUTO_OVERLAY=window CAP_GPUI_AUTO_WINDOW="Window to record"
    wait_log "$out/audio_$case/cap.log" "recording started" 30 && result "audio_${case}_started" yes || result "audio_${case}_started" no
    pactl -f json list source-outputs >"$out/source-outputs-$case.json" 2>&1
    wait_log "$out/audio_$case/cap.log" "recording finished" 30 && result "audio_${case}_finished" yes || result "audio_${case}_finished" no
    sleep 2
    finish "audio_$case"
    result "audio_${case}_route_errors" "$(grep -ac 'did not change' "$out/audio_$case/cap.log")"
    file=$(find "$out/audio_$case/recordings" -path "*segment-0/system_audio.m4a" 2>/dev/null | head -1)
    level=-91
    [[ -n $file ]] && level=$(ffmpeg -hide_banner -nostats -i "$file" -af volumedetect -f null - 2>&1 |
      sed -n 's/.*mean_volume: \(-\{0,1\}[0-9.]*\) dB.*/\1/p')
    result "audio_${case}_system_audio_db" "${level:--91}"
    result "audio_${case}_system_audio" "$(awk -v v="${level:--91}" 'BEGIN { print (v > -40 ? "yes" : "no") }')"
  done
  kill $player 2>/dev/null
fi
cat "$out/result.txt"
