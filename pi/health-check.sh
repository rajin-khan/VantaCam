#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAMERA_ENV_FILE="${CAMERA_ENV_FILE:-${SCRIPT_DIR}/../camera.env}"
if [[ -f "${CAMERA_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CAMERA_ENV_FILE}"
fi
WEB_ENV_FILE="${WEB_ENV_FILE:-${SCRIPT_DIR}/../web/.env}"
if [[ -f "${WEB_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${WEB_ENV_FILE}"
fi

STREAM_NAME="${STREAM_NAME:-cam}"
VIDEO_DEVICE="${VIDEO_DEVICE:-auto}"
DASHBOARD_HOST="${DASHBOARD_HEALTH_HOST:-${HOST:-127.0.0.1}}"
if [[ "${DASHBOARD_HOST}" == "0.0.0.0" ]]; then
  DASHBOARD_HOST="127.0.0.1"
fi
DASHBOARD_URL="${DASHBOARD_URL:-http://${DASHBOARD_HOST}:${PORT:-3100}/api/session}"
REPAIR="no"
FAILURES=0

detect_webrtc_url() {
  if [[ -n "${PUBLIC_WEBRTC_URL:-}" ]]; then
    printf '%s\n' "${PUBLIC_WEBRTC_URL}"
    return
  fi

  local address
  address="$(awk -F': ' '/^webrtcAddress:/ {print $2; exit}' /etc/mediamtx/mediamtx.yml 2>/dev/null || true)"
  if [[ -n "${address}" ]]; then
    printf 'http://%s/%s/\n' "${address}" "${STREAM_NAME}"
    return
  fi

  printf 'http://127.0.0.1:8889/%s/\n' "${STREAM_NAME}"
}

WEBRTC_URL="${WEBRTC_URL:-$(detect_webrtc_url)}"

usage() {
  cat <<EOF
Usage: $0 [--repair]

Checks the Pi camera stack:
  - camera device exists
  - tailscaled is active
  - dashboard service is active when installed/enabled
  - MediaMTX is active when enabled
  - dashboard and WebRTC endpoints respond when expected

Options:
  --repair  Start enabled services that are not active.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repair)
      REPAIR="yes"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

ok() {
  printf 'ok: %s\n' "$*"
}

warn() {
  printf 'warn: %s\n' "$*" >&2
}

fail() {
  printf 'fail: %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

resolve_video_device() {
  if [[ "${VIDEO_DEVICE}" != "auto" ]]; then
    printf '%s\n' "${VIDEO_DEVICE}"
    return
  fi

  local candidate
  candidate="$(find /dev/v4l/by-id -maxdepth 1 -type l -name '*-video-index0' 2>/dev/null | sort | head -n 1 || true)"
  if [[ -n "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return
  fi

  find /dev/video* -maxdepth 0 -type c 2>/dev/null | sort -V | head -n 1 || true
}

service_exists() {
  systemctl list-unit-files "$1" >/dev/null 2>&1
}

service_enabled() {
  systemctl is-enabled "$1" >/dev/null 2>&1
}

service_active() {
  systemctl is-active "$1" >/dev/null 2>&1
}

repair_service_if_enabled() {
  local service="$1"
  if [[ "${REPAIR}" == "yes" ]] && service_enabled "${service}" && ! service_active "${service}"; then
    warn "${service} is enabled but not active; attempting start"
    sudo systemctl start "${service}" || true
    sleep 1
  fi
}

check_http() {
  local label="$1"
  local url="$2"
  if curl -fsS --max-time 6 "${url}" >/dev/null 2>&1; then
    ok "${label} responded"
  else
    fail "${label} did not respond at ${url}"
  fi
}

echo "VantaCam health check"
echo "repair mode: ${REPAIR}"

RESOLVED_VIDEO_DEVICE="$(resolve_video_device)"
if [[ -n "${RESOLVED_VIDEO_DEVICE}" && -e "${RESOLVED_VIDEO_DEVICE}" ]]; then
  ok "camera device exists: ${RESOLVED_VIDEO_DEVICE}"
else
  fail "camera device is missing; configured VIDEO_DEVICE=${VIDEO_DEVICE}"
fi

if service_exists tailscaled.service; then
  repair_service_if_enabled tailscaled.service
  if service_active tailscaled.service; then
    ok "tailscaled is active"
  else
    fail "tailscaled is not active"
  fi
else
  warn "tailscaled.service is not installed"
fi

if service_exists camera-dashboard.service; then
  repair_service_if_enabled camera-dashboard.service
  if service_active camera-dashboard.service; then
    ok "camera-dashboard is active"
    check_http "dashboard API" "${DASHBOARD_URL}"
  elif service_enabled camera-dashboard.service; then
    fail "camera-dashboard is enabled but not active"
  else
    warn "camera-dashboard is installed but disabled"
  fi
else
  warn "camera-dashboard.service is not installed"
fi

if service_exists mediamtx.service; then
  repair_service_if_enabled mediamtx.service
  if service_active mediamtx.service; then
    ok "mediamtx is active"
    check_http "MediaMTX WebRTC page" "${WEBRTC_URL}"
  elif service_enabled mediamtx.service; then
    fail "mediamtx is enabled but not active"
  else
    ok "mediamtx is disabled; stream is intentionally off"
  fi
else
  fail "mediamtx.service is not installed"
fi

if [[ "${FAILURES}" -eq 0 ]]; then
  ok "health check passed"
else
  fail "health check found ${FAILURES} issue(s)"
fi

exit "${FAILURES}"
