#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${APP_DIR:-${HOME}/Library/Application Support/VantaCam}"
CERT_DIR="${CERT_DIR:-${APP_DIR}/certs}"
LOG_DIR="${LOG_DIR:-${APP_DIR}/logs}"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
TAILSCALE_BIN="${TAILSCALE_BIN:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
DOMAIN="${DOMAIN:-}"
LISTEN_HOST="${LISTEN_HOST:-}"
DASHBOARD_PORT="${DASHBOARD_PORT:-9443}"
WEBRTC_PORT="${WEBRTC_PORT:-9444}"
DASHBOARD_TARGET="${DASHBOARD_TARGET:-http://127.0.0.1:3200}"
WEBRTC_TARGET="${WEBRTC_TARGET:-http://127.0.0.1:8889}"

if [[ ! -x "${TAILSCALE_BIN}" ]]; then
  if command -v tailscale >/dev/null 2>&1; then
    TAILSCALE_BIN="$(command -v tailscale)"
  else
    echo "error: Tailscale CLI not found" >&2
    exit 1
  fi
fi

tailscale_json() {
  "${TAILSCALE_BIN}" status --json
}

if [[ -z "${DOMAIN}" ]]; then
  DOMAIN="$(tailscale_json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
fi

if [[ -z "${LISTEN_HOST}" ]]; then
  LISTEN_HOST="$(tailscale_json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["TailscaleIPs"][0])')"
fi

mkdir -p "${CERT_DIR}" "${LOG_DIR}" "${LAUNCH_AGENTS_DIR}"
CERT_FILE="${CERT_DIR}/${DOMAIN}.crt"
KEY_FILE="${CERT_DIR}/${DOMAIN}.key"

echo "Issuing or refreshing Tailscale certificate for ${DOMAIN}..."
"${TAILSCALE_BIN}" cert --cert-file "${CERT_FILE}" --key-file "${KEY_FILE}" "${DOMAIN}"

write_agent() {
  local label="$1"
  local port="$2"
  local target="$3"
  local plist="${LAUNCH_AGENTS_DIR}/${label}.plist"

  cat >"${plist}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>${PROJECT_DIR}/mac/vantacam_https_proxy.py</string>
    <string>--listen-host</string>
    <string>${LISTEN_HOST}</string>
    <string>--listen-port</string>
    <string>${port}</string>
    <string>--target</string>
    <string>${target}</string>
    <string>--cert-file</string>
    <string>${CERT_FILE}</string>
    <string>--key-file</string>
    <string>${KEY_FILE}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/${label}.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/${label}.err.log</string>
</dict>
</plist>
EOF

  local domain_ref="gui/$(id -u)"
  launchctl bootout "${domain_ref}/${label}" 2>/dev/null || true
  launchctl bootstrap "${domain_ref}" "${plist}"
  launchctl kickstart -k "${domain_ref}/${label}"
}

write_agent "com.vantacam.https-dashboard" "${DASHBOARD_PORT}" "${DASHBOARD_TARGET}"
write_agent "com.vantacam.https-webrtc" "${WEBRTC_PORT}" "${WEBRTC_TARGET}"

cat <<EOF

VantaCam HTTPS proxy is running on private tailnet ports:

Dashboard: https://${DOMAIN}:${DASHBOARD_PORT}/
WebRTC:    https://${DOMAIN}:${WEBRTC_PORT}/

Use this WebRTC URL in fleet config:
https://${DOMAIN}:${WEBRTC_PORT}/YOUR-STREAM-PATH/
EOF
