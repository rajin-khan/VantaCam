#!/usr/bin/env bash
set -euo pipefail

DASHBOARD_TARGET="${DASHBOARD_TARGET:-http://127.0.0.1:3200}"
WEBRTC_TARGET="${WEBRTC_TARGET:-http://127.0.0.1:8889}"
TAILSCALE_BIN="${TAILSCALE_BIN:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"

if [[ ! -x "${TAILSCALE_BIN}" ]]; then
  if command -v tailscale >/dev/null 2>&1; then
    TAILSCALE_BIN="$(command -v tailscale)"
  else
    echo "error: Tailscale CLI not found" >&2
    exit 1
  fi
fi

echo "Serving Mac dashboard over private tailnet HTTPS on port 443..."
"${TAILSCALE_BIN}" serve --bg --yes --https=443 "${DASHBOARD_TARGET}"

echo "Serving Mac WebRTC page over private tailnet HTTPS on port 8443..."
"${TAILSCALE_BIN}" serve --bg --yes --https=8443 "${WEBRTC_TARGET}"

echo
"${TAILSCALE_BIN}" serve status
