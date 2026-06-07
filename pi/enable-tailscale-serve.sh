#!/usr/bin/env bash
set -euo pipefail

DASHBOARD_TARGET="${DASHBOARD_TARGET:-127.0.0.1:3100}"
WEBRTC_TARGET="${WEBRTC_TARGET:-127.0.0.1:8889}"

normalize_target() {
  local target="$1"

  if [[ "${target}" =~ ^https?:// ]]; then
    printf '%s\n' "${target}"
    return
  fi

  if [[ "${target}" =~ ^(127\.0\.0\.1|localhost)(:|/) ]]; then
    printf '%s\n' "${target}"
    return
  fi

  printf 'http://%s\n' "${target}"
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo: sudo ./enable-tailscale-serve.sh" >&2
  exit 1
fi

if ! command -v tailscale >/dev/null 2>&1; then
  echo "error: tailscale is not installed" >&2
  exit 1
fi

if [[ "${WEBRTC_TARGET}" == "127.0.0.1:8889" ]] && ! curl -fsS --max-time 2 "http://${WEBRTC_TARGET}/" >/dev/null 2>&1; then
  TAILSCALE_IP="$(tailscale ip -4 | head -n 1 || true)"

  if [[ -n "${TAILSCALE_IP}" ]] && curl -fsS --max-time 2 "http://${TAILSCALE_IP}:8889/" >/dev/null 2>&1; then
    WEBRTC_TARGET="http://${TAILSCALE_IP}:8889"
    echo "Detected MediaMTX WebRTC on ${WEBRTC_TARGET}"
  fi
fi

DASHBOARD_TARGET="$(normalize_target "${DASHBOARD_TARGET}")"
WEBRTC_TARGET="$(normalize_target "${WEBRTC_TARGET}")"

echo "Serving dashboard over tailnet HTTPS on port 443..."
tailscale serve --bg --yes --https=443 "${DASHBOARD_TARGET}"

echo "Serving MediaMTX WebRTC page over tailnet HTTPS on port 8443..."
tailscale serve --bg --yes --https=8443 "${WEBRTC_TARGET}"

echo
tailscale serve status
