#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${APP_DIR:-${HOME}/Library/Application Support/VantaCam}"
BIN_DIR="${APP_DIR}/bin"
RUN_BIN_DIR="${RUN_BIN_DIR:-${HOME}/.vantacam/bin}"
CONFIG_DIR="${APP_DIR}/config"
LOG_DIR="${APP_DIR}/logs"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
MEDIAMTX_VERSION="${MEDIAMTX_VERSION:-v1.19.0}"
STREAM_NAME="${STREAM_NAME:-mac-$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | cut -c 1-24)}"
CAMERA_DEVICE="${CAMERA_DEVICE:-auto}"
VIDEO_SIZE="${VIDEO_SIZE:-1280x720}"
FRAMERATE="${FRAMERATE:-30}"
PIXEL_FORMAT="${PIXEL_FORMAT:-nv12}"
BITRATE="${BITRATE:-1200k}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-8}"
ALLOW_SCREEN_CAPTURE="${ALLOW_SCREEN_CAPTURE:-false}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-3200}"
APP_PASSWORD="${APP_PASSWORD:-}"
CONTROL_PASSWORD="${CONTROL_PASSWORD:-}"
PUBLIC_STREAM_HOST="${PUBLIC_STREAM_HOST:-}"
PUBLIC_WEBRTC_URL="${PUBLIC_WEBRTC_URL:-}"
CORS_ORIGIN="${CORS_ORIGIN:-}"
COOKIE_SECURE="${COOKIE_SECURE:-false}"
COOKIE_SAMESITE="${COOKIE_SAMESITE:-Lax}"
START_READY_TIMEOUT_SECONDS="${START_READY_TIMEOUT_SECONDS:-20}"
REWIND_ENABLED="${REWIND_ENABLED:-true}"
REWIND_MINUTES="${REWIND_MINUTES:-30}"
REWIND_SEGMENT_SECONDS="${REWIND_SEGMENT_SECONDS:-6}"
REWIND_MAX_MB="${REWIND_MAX_MB:-512}"
REWIND_DIR="${REWIND_DIR:-${APP_DIR}/rewind}"
REWIND_TOKEN_SECONDS="${REWIND_TOKEN_SECONDS:-900}"
TAILSCALE_BIN="${TAILSCALE_BIN:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
START_SERVICES="yes"
SELECTED_CAMERA_INPUT=""

usage() {
  cat <<EOF
Usage: $0 [options]

Installs VantaCam as a macOS camera host using MediaMTX, ffmpeg, and a small
Python dashboard/control API. It does not modify the Raspberry Pi implementation.

Options:
  --list-cameras              Download ffmpeg if needed and print AVFoundation cameras.
  --probe-cameras             Test listed cameras and report which can produce frames.
  --camera DEVICE             AVFoundation device, usually auto, 0, 1, or a camera name.
  --stream-name NAME          Private stream path. Defaults to a random mac-* path.
  --video-size WxH            Default: ${VIDEO_SIZE}
  --framerate FPS             Default: ${FRAMERATE}
  --pixel-format FORMAT       AVFoundation input pixel format. Default: ${PIXEL_FORMAT}
  --probe-timeout SECONDS     Per-camera probe timeout. Default: ${PROBE_TIMEOUT}
  --allow-screen-capture      Let --camera auto choose AVFoundation screen capture.
  --bitrate RATE              Default: ${BITRATE}
  --host HOST                 Dashboard bind host. Default: ${HOST}
  --port PORT                 Dashboard port. Default: ${PORT}
  --public-host HOST          Hostname/IP browsers should use for WebRTC URL.
  --public-webrtc-url URL     Exact WebRTC URL browsers should load.
  --cors-origin ORIGINS       Comma-separated browser origins allowed to call the API.
  --cookie-secure BOOL        true when serving through HTTPS. Default: ${COOKIE_SECURE}
  --cookie-samesite VALUE     Lax or None. Use None for Vercel fleet mode.
  --start-ready-timeout SEC   Wait this long for WebRTC path readiness. Default: ${START_READY_TIMEOUT_SECONDS}
  --app-password PASSWORD     Dashboard login password. Generated when omitted.
  --control-password PASSWORD Stream on/off password. Generated when omitted.
  --rewind-enabled BOOL       Enable bounded rewind buffer. Default: ${REWIND_ENABLED}
  --rewind-minutes MINUTES    Rolling buffer duration. Default: ${REWIND_MINUTES}
  --rewind-max-mb MB          Intended storage cap. Default: ${REWIND_MAX_MB}
  --no-start                  Install files but do not start dashboard.
  -h, --help                  Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list-cameras) LIST_CAMERAS="yes"; shift ;;
    --probe-cameras) PROBE_CAMERAS="yes"; shift ;;
    --camera) CAMERA_DEVICE="$2"; shift 2 ;;
    --stream-name) STREAM_NAME="$2"; shift 2 ;;
    --video-size) VIDEO_SIZE="$2"; shift 2 ;;
    --framerate) FRAMERATE="$2"; shift 2 ;;
    --pixel-format) PIXEL_FORMAT="$2"; shift 2 ;;
    --probe-timeout) PROBE_TIMEOUT="$2"; shift 2 ;;
    --allow-screen-capture) ALLOW_SCREEN_CAPTURE="true"; shift ;;
    --bitrate) BITRATE="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --public-host) PUBLIC_STREAM_HOST="$2"; shift 2 ;;
    --public-webrtc-url) PUBLIC_WEBRTC_URL="$2"; shift 2 ;;
    --cors-origin) CORS_ORIGIN="$2"; shift 2 ;;
    --cookie-secure) COOKIE_SECURE="$2"; shift 2 ;;
    --cookie-samesite) COOKIE_SAMESITE="$2"; shift 2 ;;
    --start-ready-timeout) START_READY_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --app-password) APP_PASSWORD="$2"; shift 2 ;;
    --control-password) CONTROL_PASSWORD="$2"; shift 2 ;;
    --rewind-enabled) REWIND_ENABLED="$2"; shift 2 ;;
    --rewind-minutes) REWIND_MINUTES="$2"; shift 2 ;;
    --rewind-max-mb) REWIND_MAX_MB="$2"; shift 2 ;;
    --no-start) START_SERVICES="no"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

hash_password() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

random_secret() {
  python3 -c 'import secrets; print(secrets.token_urlsafe(32)[:32])'
}

download_ffmpeg() {
  if [[ -x "${BIN_DIR}/ffmpeg" ]]; then
    ensure_runtime_links
    return
  fi
  mkdir -p "${BIN_DIR}"
  local zip_path="${APP_DIR}/ffmpeg.zip"
  echo "Downloading ffmpeg static build..."
  curl -fL "https://evermeet.cx/ffmpeg/getrelease/zip" -o "${zip_path}"
  ditto -x -k "${zip_path}" "${BIN_DIR}"
  chmod +x "${BIN_DIR}/ffmpeg"
  ensure_runtime_links
}

download_mediamtx() {
  if [[ -x "${BIN_DIR}/mediamtx" ]]; then
    return
  fi
  mkdir -p "${BIN_DIR}"
  local tar_path="${APP_DIR}/mediamtx.tar.gz"
  echo "Downloading MediaMTX ${MEDIAMTX_VERSION}..."
  curl -fL "https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_darwin_amd64.tar.gz" -o "${tar_path}"
  tar -xzf "${tar_path}" -C "${BIN_DIR}" mediamtx
  chmod +x "${BIN_DIR}/mediamtx"
}

tailscale_ip() {
  if [[ -x "${TAILSCALE_BIN}" ]]; then
    "${TAILSCALE_BIN}" ip -4 2>/dev/null | head -n 1 || true
  fi
}

ensure_runtime_links() {
  mkdir -p "${RUN_BIN_DIR}"
  ln -sf "${BIN_DIR}/ffmpeg" "${RUN_BIN_DIR}/ffmpeg"
}

shell_quote() {
  printf '%q' "$1"
}

camera_input() {
  if [[ -n "${SELECTED_CAMERA_INPUT}" ]]; then
    printf '%s' "${SELECTED_CAMERA_INPUT}"
    return
  fi
  if [[ "${CAMERA_DEVICE}" == "auto" ]]; then
    select_camera_input
  elif [[ "${CAMERA_DEVICE}" == *":none" || "${CAMERA_DEVICE}" == *":0" ]]; then
    printf '%s' "${CAMERA_DEVICE}"
  else
    printf '%s:none' "${CAMERA_DEVICE}"
  fi
}

camera_devices_json() {
  { "${BIN_DIR}/ffmpeg" -hide_banner -f avfoundation -list_devices true -i "" 2>&1 || true; } | python3 -c '
import json
import re
import sys

devices = []
in_video = False
for line in sys.stdin:
    if "AVFoundation video devices:" in line:
        in_video = True
        continue
    if "AVFoundation audio devices:" in line:
        in_video = False
    if not in_video:
        continue
    match = re.search(r"\]\s+\[(\d+)\]\s+(.+)$", line.strip())
    if match:
        devices.append({"index": match.group(1), "name": match.group(2)})
print(json.dumps(devices))
'
}

probe_camera_input() {
  local input="$1"
  python3 - "$BIN_DIR/ffmpeg" "$input" "$PIXEL_FORMAT" "$FRAMERATE" "$VIDEO_SIZE" "$PROBE_TIMEOUT" <<'PY'
import subprocess
import sys

ffmpeg, camera_input, pixel_format, framerate, video_size, timeout = sys.argv[1:]
command = [
    ffmpeg,
    "-hide_banner",
    "-loglevel",
    "error",
    "-f",
    "avfoundation",
    "-pixel_format",
    pixel_format,
    "-framerate",
    framerate,
    "-video_size",
    video_size,
    "-i",
    camera_input,
    "-frames:v",
    "1",
    "-an",
    "-f",
    "null",
    "-",
]
try:
    result = subprocess.run(command, capture_output=True, text=True, timeout=float(timeout))
except subprocess.TimeoutExpired as error:
    sys.stderr.write((error.stderr or "").strip())
    sys.exit(124)
sys.stderr.write((result.stderr or "").strip())
sys.exit(result.returncode)
PY
}

probe_cameras() {
  mkdir -p "${LOG_DIR}"
  local devices_json
  devices_json="$(camera_devices_json)"
  python3 - "$devices_json" "$ALLOW_SCREEN_CAPTURE" <<'PY' | while IFS=$'\t' read -r index name; do
import json
import sys

devices = json.loads(sys.argv[1])
allow_screen = sys.argv[2].lower() == "true"
for device in devices:
    name = device["name"]
    if not allow_screen and "capture screen" in name.lower():
        continue
    print(f"{device['index']}\t{name}")
PY
    local input="${index}:none"
    printf 'Probing [%s] %s ... ' "$index" "$name"
    if probe_camera_input "$input" >/dev/null 2>"${LOG_DIR}/probe-${index}.log"; then
      printf 'ok\n'
    else
      local code=$?
      printf 'failed'
      if [[ -s "${LOG_DIR}/probe-${index}.log" ]]; then
        printf ' (%s)' "$(tr '\n' ' ' <"${LOG_DIR}/probe-${index}.log" | cut -c 1-140)"
      else
        printf ' (exit %s)' "$code"
      fi
      printf '\n'
    fi
  done
}

select_camera_input() {
  mkdir -p "${LOG_DIR}"
  local devices_json
  devices_json="$(camera_devices_json)"
  local selected
  selected="$(python3 - "$devices_json" "$ALLOW_SCREEN_CAPTURE" <<'PY'
import json
import sys

devices = json.loads(sys.argv[1])
allow_screen = sys.argv[2].lower() == "true"
for device in devices:
    name = device["name"]
    if not allow_screen and "capture screen" in name.lower():
        continue
    print(f"{device['index']}:none")
PY
  )"

  while IFS= read -r input; do
    [[ -z "$input" ]] && continue
    local index="${input%%:*}"
    if probe_camera_input "$input" >/dev/null 2>"${LOG_DIR}/probe-${index}.log"; then
      printf '%s' "$input"
      return 0
    fi
  done <<<"${selected}"

  echo "error: no AVFoundation camera produced frames with ${VIDEO_SIZE} ${FRAMERATE}fps ${PIXEL_FORMAT}" >&2
  echo "Try opening the MacBook lid, attaching a USB webcam, or running:" >&2
  echo "  $0 --probe-cameras --video-size 640x480 --framerate 15 --pixel-format uyvy422" >&2
  exit 1
}

write_mediamtx_config() {
  mkdir -p "${CONFIG_DIR}" "${LOG_DIR}"
  local input
  input="$(camera_input)"
  write_camera_runner "${input}"
  cat >"${CONFIG_DIR}/mediamtx.yml" <<EOF
logLevel: info

api: yes
apiAddress: 127.0.0.1:9997

rtsp: yes
rtspAddress: 127.0.0.1:8554

rtmp: no

hls: yes
hlsAddress: 127.0.0.1:8888

webrtc: yes
webrtcAddress: 0.0.0.0:8889
webrtcLocalUDPAddress: 0.0.0.0:8189
webrtcLocalTCPAddress: 0.0.0.0:8189

srt: no
moq: no

paths:
  ${STREAM_NAME}: {}
EOF
}

write_camera_runner() {
  mkdir -p "${RUN_BIN_DIR}" "${LOG_DIR}"
  local input_q log_q framerate_q video_size_q pixel_format_q bitrate_q
  input_q="$(shell_quote "$1")"
  log_q="$(shell_quote "${LOG_DIR}/ffmpeg.log")"
  framerate_q="$(shell_quote "${FRAMERATE}")"
  video_size_q="$(shell_quote "${VIDEO_SIZE}")"
  pixel_format_q="$(shell_quote "${PIXEL_FORMAT}")"
  bitrate_q="$(shell_quote "${BITRATE}")"

  cat >"${RUN_BIN_DIR}/run-camera" <<EOF
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE=${log_q}
FFMPEG_BIN="\$(dirname "\$0")/ffmpeg"
CAMERA_INPUT=${input_q}
FRAMERATE=${framerate_q}
VIDEO_SIZE=${video_size_q}
PIXEL_FORMAT=${pixel_format_q}
BITRATE=${bitrate_q}
RTSP_TARGET="rtsp://127.0.0.1:8554/${STREAM_NAME}"

{
  printf '\\n[%s] starting camera runner\\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'camera=%s size=%s fps=%s pixel=%s bitrate=%s target=%s\\n' "\$CAMERA_INPUT" "\$VIDEO_SIZE" "\$FRAMERATE" "\$PIXEL_FORMAT" "\$BITRATE" "\$RTSP_TARGET"
} >>"\$LOG_FILE"

while true; do
  "\$FFMPEG_BIN" \\
    -hide_banner \\
    -loglevel info \\
    -stats \\
    -f avfoundation \\
    -pixel_format "\$PIXEL_FORMAT" \\
    -framerate "\$FRAMERATE" \\
    -video_size "\$VIDEO_SIZE" \\
    -i "\$CAMERA_INPUT" \\
    -an \\
    -c:v libx264 \\
    -pix_fmt yuv420p \\
    -preset ultrafast \\
    -tune zerolatency \\
    -b:v "\$BITRATE" \\
    -rtsp_transport tcp \\
    -f rtsp "\$RTSP_TARGET" >>"\$LOG_FILE" 2>&1
  code="\$?"
  printf '[%s] ffmpeg exited with code %s; retrying in 2s\\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "\$code" >>"\$LOG_FILE"
  sleep 2
done
EOF
  chmod +x "${RUN_BIN_DIR}/run-camera"
}

write_env() {
  mkdir -p "${SCRIPT_DIR}"
  if [[ -z "${APP_PASSWORD}" ]]; then
    APP_PASSWORD="$(random_secret)"
  fi
  if [[ -z "${CONTROL_PASSWORD}" ]]; then
    CONTROL_PASSWORD="$(random_secret)"
  fi
  if [[ -z "${PUBLIC_STREAM_HOST}" ]]; then
    PUBLIC_STREAM_HOST="$(tailscale_ip)"
    PUBLIC_STREAM_HOST="${PUBLIC_STREAM_HOST:-$(hostname).local}"
  fi
  if [[ -z "${PUBLIC_WEBRTC_URL}" ]]; then
    PUBLIC_WEBRTC_URL="http://${PUBLIC_STREAM_HOST}:8889/${STREAM_NAME}/"
  fi
  local session_secret
  session_secret="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  cat >"${SCRIPT_DIR}/.env" <<EOF
HOST=${HOST}
PORT=${PORT}
STREAM_NAME=${STREAM_NAME}
PUBLIC_STREAM_HOST=${PUBLIC_STREAM_HOST}
PUBLIC_WEBRTC_URL=${PUBLIC_WEBRTC_URL}
CORS_ORIGIN=${CORS_ORIGIN}
APP_PASSWORD_SHA256=$(hash_password "${APP_PASSWORD}")
CONTROL_PASSWORD_SHA256=$(hash_password "${CONTROL_PASSWORD}")
SESSION_SECRET=${session_secret}
COOKIE_SECURE=${COOKIE_SECURE}
COOKIE_SAMESITE=${COOKIE_SAMESITE}
START_READY_TIMEOUT_SECONDS=${START_READY_TIMEOUT_SECONDS}
REWIND_ENABLED=${REWIND_ENABLED}
REWIND_MINUTES=${REWIND_MINUTES}
REWIND_SEGMENT_SECONDS=${REWIND_SEGMENT_SECONDS}
REWIND_MAX_MB=${REWIND_MAX_MB}
REWIND_DIR=${REWIND_DIR}
REWIND_SOURCE_URL=rtsp://127.0.0.1:8554/${STREAM_NAME}
REWIND_TOKEN_SECONDS=${REWIND_TOKEN_SECONDS}
MEDIAMTX_LABEL=com.vantacam.mediamtx
MEDIAMTX_PLIST=${LAUNCH_AGENTS_DIR}/com.vantacam.mediamtx.plist
CAMERA_LABEL=com.vantacam.camera
CAMERA_PLIST=${LAUNCH_AGENTS_DIR}/com.vantacam.camera.plist
REWIND_LABEL=com.vantacam.rewind
REWIND_PLIST=${LAUNCH_AGENTS_DIR}/com.vantacam.rewind.plist
PUBLIC_DIR=${PROJECT_DIR}/web/public
EOF
}

write_plists() {
  mkdir -p "${LAUNCH_AGENTS_DIR}" "${LOG_DIR}"
  cat >"${LAUNCH_AGENTS_DIR}/com.vantacam.mediamtx.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.vantacam.mediamtx</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BIN_DIR}/mediamtx</string>
    <string>${CONFIG_DIR}/mediamtx.yml</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/mediamtx.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/mediamtx.err.log</string>
</dict>
</plist>
EOF

  cat >"${LAUNCH_AGENTS_DIR}/com.vantacam.camera.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.vantacam.camera</string>
  <key>ProgramArguments</key>
  <array>
    <string>${RUN_BIN_DIR}/run-camera</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/camera.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/camera.err.log</string>
</dict>
</plist>
EOF

  cat >"${LAUNCH_AGENTS_DIR}/com.vantacam.host.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.vantacam.host</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>${SCRIPT_DIR}/vantacam_host.py</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${PROJECT_DIR}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/host.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/host.err.log</string>
</dict>
</plist>
EOF

  chmod +x "${PROJECT_DIR}/mac/rewind-recorder.sh"
  cat >"${LAUNCH_AGENTS_DIR}/com.vantacam.rewind.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.vantacam.rewind</string>
  <key>ProgramArguments</key>
  <array>
    <string>${PROJECT_DIR}/mac/rewind-recorder.sh</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key>
  <false/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/rewind.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/rewind.err.log</string>
</dict>
</plist>
EOF
}

reload_host() {
  local domain="gui/$(id -u)"
  launchctl bootout "${domain}/com.vantacam.host" >/dev/null 2>&1 || true
  launchctl bootstrap "${domain}" "${LAUNCH_AGENTS_DIR}/com.vantacam.host.plist"
  launchctl kickstart -k "${domain}/com.vantacam.host"
  launchctl disable "${domain}/com.vantacam.camera" >/dev/null 2>&1 || true
  launchctl bootout "${domain}/com.vantacam.camera" >/dev/null 2>&1 || true
  pkill -f "${RUN_BIN_DIR}/run-camera" >/dev/null 2>&1 || true
  pkill -f "${RUN_BIN_DIR}/ffmpeg" >/dev/null 2>&1 || true
  launchctl disable "${domain}/com.vantacam.rewind" >/dev/null 2>&1 || true
  launchctl bootout "${domain}/com.vantacam.rewind" >/dev/null 2>&1 || true
  launchctl disable "${domain}/com.vantacam.mediamtx" >/dev/null 2>&1 || true
  launchctl bootout "${domain}/com.vantacam.mediamtx" >/dev/null 2>&1 || true
}

download_ffmpeg

if [[ "${LIST_CAMERAS:-no}" == "yes" ]]; then
  "${BIN_DIR}/ffmpeg" -hide_banner -f avfoundation -list_devices true -i "" 2>&1 || true
  exit 0
fi

if [[ "${PROBE_CAMERAS:-no}" == "yes" ]]; then
  probe_cameras
  exit 0
fi

download_mediamtx
SELECTED_CAMERA_INPUT="$(camera_input)"
write_mediamtx_config
write_env
write_plists

if [[ "${START_SERVICES}" == "yes" ]]; then
  reload_host
fi

echo
echo "VantaCam Mac host installed."
echo "Dashboard: http://${PUBLIC_STREAM_HOST}:${PORT}/"
echo "WebRTC:    ${PUBLIC_WEBRTC_URL}"
echo
echo "Dashboard password:"
echo "${APP_PASSWORD}"
echo
echo "Stream control password:"
echo "${CONTROL_PASSWORD}"
echo
echo "Camera input: $(camera_input)"
echo "Pixel format: ${PIXEL_FORMAT}"
echo "Stream starts off. Use the dashboard Turn On button to start it."
