#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAMERA_ENV_FILE="${CAMERA_ENV_FILE:-${SCRIPT_DIR}/../camera.env}"
if [[ -f "${CAMERA_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CAMERA_ENV_FILE}"
fi

STREAM_NAME="${STREAM_NAME:-cam}"
VIDEO_DEVICE="${VIDEO_DEVICE:-/dev/video0}"
REDACT="${REDACT:-yes}"

section() {
  printf '\n== %s ==\n' "$1"
}

redact_output() {
  if [[ "${REDACT}" == "no" ]]; then
    cat
  else
    sed -E \
      -e 's/[[:alnum:]_.+-]+@[[:alnum:]_.+-]+/<account>/g' \
      -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<ipv4>/g' \
      -e 's/fd7a:[0-9a-fA-F:]+/<tailscale-ipv6>/g' \
      -e 's/direct [^, ]+/direct <endpoint>/g'
  fi
}

run_optional() {
  if command -v "$1" >/dev/null 2>&1; then
    "$@" 2>&1 | redact_output || true
  else
    echo "$1 is not installed"
  fi
}

section "Host"
hostname 2>&1 | redact_output || true
uname -a 2>&1 | redact_output || true
cat /etc/os-release 2>/dev/null | redact_output || true

section "Camera Devices"
ls -l /dev/video* 2>/dev/null || echo "No /dev/video* devices found"
run_optional v4l2-ctl --list-devices

section "Camera Formats"
if [[ -e "${VIDEO_DEVICE}" ]]; then
  run_optional v4l2-ctl --device="${VIDEO_DEVICE}" --list-formats-ext
else
  echo "${VIDEO_DEVICE} does not exist"
fi

section "MediaMTX Binary"
if command -v mediamtx >/dev/null 2>&1; then
  mediamtx --version 2>&1 | redact_output || true
else
  echo "mediamtx is not installed"
fi

section "MediaMTX Service"
systemctl --no-pager status mediamtx 2>&1 | redact_output || true

section "Recent MediaMTX Logs"
journalctl -u mediamtx --no-pager -n 80 2>&1 | redact_output || true

section "Listening Ports"
run_optional ss -lntup

section "Local Endpoints"
ENDPOINT_HOST="127.0.0.1"
if command -v tailscale >/dev/null 2>&1; then
  ENDPOINT_HOST="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
  ENDPOINT_HOST="${ENDPOINT_HOST:-127.0.0.1}"
fi
curl -sS -D - "http://${ENDPOINT_HOST}:8889/${STREAM_NAME}/" -o /tmp/mediamtx-webrtc.html | sed -n '1,12p' | redact_output || true
wc -c /tmp/mediamtx-webrtc.html 2>/dev/null || true
curl -sSL -D - "http://${ENDPOINT_HOST}:8888/${STREAM_NAME}/index.m3u8" -o /tmp/mediamtx-hls.m3u8 | sed -n '1,16p' | redact_output || true
wc -c /tmp/mediamtx-hls.m3u8 2>/dev/null || true

section "Tailscale"
if command -v tailscale >/dev/null 2>&1; then
  tailscale status 2>&1 | redact_output || true
  tailscale ip -4 2>&1 | redact_output || true
else
  echo "tailscale is not installed"
fi
