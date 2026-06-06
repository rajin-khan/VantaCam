#!/usr/bin/env bash
set -euo pipefail

DASHBOARD_TARGET="${DASHBOARD_TARGET:-127.0.0.1:3100}"
WEBRTC_TARGET="${WEBRTC_TARGET:-127.0.0.1:8889}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo: sudo ./enable-tailscale-serve.sh" >&2
  exit 1
fi

if ! command -v tailscale >/dev/null 2>&1; then
  echo "error: tailscale is not installed" >&2
  exit 1
fi

echo "Serving dashboard over tailnet HTTPS on port 443..."
tailscale serve --bg --yes --https=443 "${DASHBOARD_TARGET}"

echo "Serving MediaMTX WebRTC page over tailnet HTTPS on port 8443..."
tailscale serve --bg --yes --https=8443 "${WEBRTC_TARGET}"

echo
tailscale serve status
