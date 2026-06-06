#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CAMERA_ENV_FILE="${CAMERA_ENV_FILE:-${PROJECT_DIR}/camera.env}"
if [[ -f "${CAMERA_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CAMERA_ENV_FILE}"
fi

PI_SSH_TARGET="${PI_SSH_TARGET:-camerauser@100.x.y.z}"
PI_TAILSCALE_IP="${PI_TAILSCALE_IP:-100.x.y.z}"
STREAM_NAME="${STREAM_NAME:-cam}"
CONTROL_PASSWORD_SHA256="${CONTROL_PASSWORD_SHA256:-}"
TAILSCALE_SERVE_DASHBOARD_URL="${TAILSCALE_SERVE_DASHBOARD_URL:-}"
TAILSCALE_SERVE_WEBRTC_URL="${TAILSCALE_SERVE_WEBRTC_URL:-}"
MODE="auto"

require_config() {
  [[ -n "${!1:-}" ]] || {
    echo "error: ${1} is not set. Copy camera.env.example to camera.env and fill it in." >&2
    exit 1
  }
}

usage() {
  cat <<EOF
Usage: $0 [--local|--remote] on|off|status|urls

Commands:
  on       Enable and start the camera stream.
  off      Stop and disable the camera stream.
  status   Show service state and listening stream ports.
  urls     Print the private Tailscale stream URLs.

Options:
  --local   Run against this machine. Use on the Raspberry Pi.
  --remote  Run against ${PI_SSH_TARGET}. Use from this Mac.

Environment overrides:
  PI_SSH_TARGET=${PI_SSH_TARGET}
  PI_TAILSCALE_IP=${PI_TAILSCALE_IP}
  STREAM_NAME=${STREAM_NAME}
EOF
}

hash_password() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    echo "error: shasum or sha256sum is required" >&2
    exit 1
  fi
}

require_control_password() {
  local entered
  printf 'Stream control password: '
  stty -echo
  read -r entered
  stty echo
  printf '\n'

  local entered_hash
  entered_hash="$(hash_password "${entered}")"
  if [[ "${entered_hash}" != "${CONTROL_PASSWORD_SHA256}" ]]; then
    echo "error: incorrect stream control password" >&2
    exit 1
  fi
}

is_pi_host() {
  command -v systemctl >/dev/null 2>&1 || return 1
  [[ -f /etc/systemd/system/mediamtx.service ]] || return 1
  command -v tailscale >/dev/null 2>&1 || return 1
  tailscale ip -4 2>/dev/null | grep -qx "${PI_TAILSCALE_IP}"
}

local_status() {
  printf 'service active: '
  systemctl is-active mediamtx 2>/dev/null || true
  printf 'service enabled: '
  systemctl is-enabled mediamtx 2>/dev/null || true
  printf '\nlistening stream ports:\n'
  ss -lntup 2>/dev/null | grep -E '(:8888|:8889|:8189)' || echo 'no browser stream ports are listening'
}

local_on() {
  sudo systemctl enable --now mediamtx
  sleep 1
  local_status
  urls
}

local_off() {
  sudo systemctl disable --now mediamtx
  sleep 1
  local_status
}

remote_run() {
  ssh -t "${PI_SSH_TARGET}" "$1"
}

remote_status() {
  remote_run "printf 'service active: '; systemctl is-active mediamtx 2>/dev/null || true; printf 'service enabled: '; systemctl is-enabled mediamtx 2>/dev/null || true; printf '\\nlistening stream ports:\\n'; ss -lntup 2>/dev/null | grep -E '(:8888|:8889|:8189)' || echo 'no browser stream ports are listening'"
}

remote_on() {
  remote_run "sudo systemctl enable --now mediamtx && sleep 1 && printf 'service active: ' && systemctl is-active mediamtx && printf 'service enabled: ' && systemctl is-enabled mediamtx"
  urls
}

remote_off() {
  remote_run "sudo systemctl disable --now mediamtx && sleep 1 && printf 'service active: ' && (systemctl is-active mediamtx || true) && printf 'service enabled: ' && (systemctl is-enabled mediamtx || true)"
}

urls() {
  cat <<EOF
Dashboard:     http://${PI_TAILSCALE_IP}:3100/
Direct WebRTC: http://${PI_TAILSCALE_IP}:8889/${STREAM_NAME}/
Direct HLS:    http://${PI_TAILSCALE_IP}:8888/${STREAM_NAME}/index.m3u8
EOF
  if [[ -n "${TAILSCALE_SERVE_DASHBOARD_URL}" || -n "${TAILSCALE_SERVE_WEBRTC_URL}" ]]; then
    printf '\nTailscale Serve HTTPS:\n'
    [[ -n "${TAILSCALE_SERVE_DASHBOARD_URL}" ]] && printf 'Dashboard:     %s\n' "${TAILSCALE_SERVE_DASHBOARD_URL}"
    [[ -n "${TAILSCALE_SERVE_WEBRTC_URL}" ]] && printf 'WebRTC:        %s\n' "${TAILSCALE_SERVE_WEBRTC_URL}"
  fi
}

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
      MODE="local"
      shift
      ;;
    --remote)
      MODE="remote"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

if [[ ${#args[@]} -ne 1 ]]; then
  usage
  exit 1
fi

command="${args[0]}"
case "${command}" in
  on|off|status|urls) ;;
  *)
    usage
    exit 1
    ;;
esac

if [[ "${command}" == "on" || "${command}" == "off" ]]; then
  require_config CONTROL_PASSWORD_SHA256
  require_control_password
fi

if [[ "${command}" == "urls" ]]; then
  urls
  exit 0
fi

if [[ "${MODE}" == "auto" ]]; then
  if is_pi_host; then
    MODE="local"
  else
    MODE="remote"
  fi
fi

case "${MODE}:${command}" in
  local:on) local_on ;;
  local:off) local_off ;;
  local:status) local_status ;;
  remote:on) remote_on ;;
  remote:off) remote_off ;;
  remote:status) remote_status ;;
esac
