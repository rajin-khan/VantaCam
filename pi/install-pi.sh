#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAMERA_ENV_FILE="${CAMERA_ENV_FILE:-${SCRIPT_DIR}/../camera.env}"
if [[ -f "${CAMERA_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CAMERA_ENV_FILE}"
fi

STREAM_NAME="${STREAM_NAME:-cam}"
VIDEO_DEVICE="${VIDEO_DEVICE:-auto}"
VIDEO_SIZE="${VIDEO_SIZE:-1280x720}"
FRAMERATE="${FRAMERATE:-30}"
BITRATE="${BITRATE:-1200k}"
INPUT_FORMAT="${INPUT_FORMAT:-}"
STREAM_BIND_IP="${STREAM_BIND_IP:-auto}"
WEBRTC_HTTP_BIND_IP="${WEBRTC_HTTP_BIND_IP:-}"
MEDIAMTX_VERSION="${MEDIAMTX_VERSION:-v1.19.0}"

die() {
  echo "error: $*" >&2
  exit 1
}

validate_ipv4() {
  local octets
  IFS=. read -r -a octets <<<"$1"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  local octet
  for octet in "${octets[@]}"; do
    [[ "${octet}" =~ ^[0-9]{1,3}$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

validate_inputs() {
  [[ "${STREAM_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] ||
    die "STREAM_NAME must be 1-64 chars of letters, numbers, underscore, or dash, starting with a letter or number"
  [[ "${VIDEO_DEVICE}" == "auto" || "${VIDEO_DEVICE}" =~ ^/dev/video[0-9]+$ || "${VIDEO_DEVICE}" =~ ^/dev/v4l/by-(id|path)/[A-Za-z0-9._:+,@=-]+$ ]] ||
    die "VIDEO_DEVICE must be auto, /dev/video0, or a stable /dev/v4l/by-id/... path"
  [[ "${VIDEO_SIZE}" =~ ^[0-9]{2,5}x[0-9]{2,5}$ ]] ||
    die "VIDEO_SIZE must look like 1280x720"
  [[ "${FRAMERATE}" =~ ^[0-9]+$ ]] && (( FRAMERATE >= 1 && FRAMERATE <= 60 )) ||
    die "FRAMERATE must be an integer from 1 to 60"
  [[ "${BITRATE}" =~ ^[1-9][0-9]{1,5}k$ ]] ||
    die "BITRATE must look like 1200k"
  case "${INPUT_FORMAT}" in
    ""|mjpeg|yuyv422) ;;
    *) die "INPUT_FORMAT must be empty, mjpeg, or yuyv422" ;;
  esac
  case "${STREAM_BIND_IP}" in
    auto) ;;
    *) validate_ipv4 "${STREAM_BIND_IP}" || die "STREAM_BIND_IP must be auto or an IPv4 address" ;;
  esac
  if [[ -n "${WEBRTC_HTTP_BIND_IP}" ]]; then
    validate_ipv4 "${WEBRTC_HTTP_BIND_IP}" || die "WEBRTC_HTTP_BIND_IP must be an IPv4 address"
  fi
}

resolve_video_device() {
  if [[ "${VIDEO_DEVICE}" != "auto" ]]; then
    [[ -e "${VIDEO_DEVICE}" ]] || die "VIDEO_DEVICE does not exist: ${VIDEO_DEVICE}"
    return
  fi

  local candidate
  candidate="$(find /dev/v4l/by-id -maxdepth 1 -type l -name '*-video-index0' 2>/dev/null | sort | head -n 1 || true)"
  if [[ -n "${candidate}" ]]; then
    VIDEO_DEVICE="${candidate}"
    return
  fi

  candidate="$(find /dev/video* -maxdepth 0 -type c 2>/dev/null | sort -V | head -n 1 || true)"
  if [[ -n "${candidate}" ]]; then
    VIDEO_DEVICE="${candidate}"
    echo "warning: using ${VIDEO_DEVICE}; prefer a stable /dev/v4l/by-id/... camera path when available" >&2
    return
  fi

  die "no camera device found; plug in the USB camera and rerun"
}

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This installer is meant to run on Raspberry Pi OS or another Linux host." >&2
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo: sudo ./install-pi.sh" >&2
  exit 1
fi

validate_inputs
resolve_video_device

case "$(uname -m)" in
  aarch64|arm64)
    MEDIAMTX_ASSET="linux_arm64"
    MEDIAMTX_SHA256="1e6c150e60af9663d9dff4eb749c9c9b5eee7059bb1d9462dc42e045bc722aab"
    ;;
  armv7l)
    MEDIAMTX_ASSET="linux_armv7"
    MEDIAMTX_SHA256="60ea874b069e83d4de9c69e9e43094e6bf45385ee4583ce580db24b5621e905d"
    ;;
  x86_64|amd64)
    MEDIAMTX_ASSET="linux_amd64"
    MEDIAMTX_SHA256="ee900a73d78919a44f995e04d65588f1cea10ddb43ebf1c740f2c6c4fa0c29b0"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

echo "Installing OS packages..."
apt-get update
apt-get install -y ca-certificates coreutils curl ffmpeg tar v4l-utils

DOWNLOAD_FILE="mediamtx_${MEDIAMTX_VERSION}_${MEDIAMTX_ASSET}.tar.gz"
DOWNLOAD_URL="https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/${DOWNLOAD_FILE}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "Downloading MediaMTX ${MEDIAMTX_VERSION} for ${MEDIAMTX_ASSET}..."
curl -fL "${DOWNLOAD_URL}" -o "${TMP_DIR}/mediamtx.tar.gz"
printf '%s  %s\n' "${MEDIAMTX_SHA256}" "${TMP_DIR}/mediamtx.tar.gz" | sha256sum --check
tar -xzf "${TMP_DIR}/mediamtx.tar.gz" -C "${TMP_DIR}"
install -m 0755 "${TMP_DIR}/mediamtx" /usr/local/bin/mediamtx

if ! id mediamtx >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin mediamtx
fi
usermod -aG video mediamtx

mkdir -p /etc/mediamtx

INPUT_FORMAT_ARG=""
if [[ -n "${INPUT_FORMAT}" ]]; then
  INPUT_FORMAT_ARG="-input_format ${INPUT_FORMAT}"
fi

TAILSCALE_IP=""
if command -v tailscale >/dev/null 2>&1; then
  TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
fi

if [[ "${STREAM_BIND_IP}" == "auto" ]]; then
  [[ -n "${TAILSCALE_IP}" ]] || die "Tailscale IPv4 address not found; connect Tailscale or set STREAM_BIND_IP explicitly"
  STREAM_BIND_IP="${TAILSCALE_IP}"
fi

if [[ -z "${WEBRTC_HTTP_BIND_IP}" ]]; then
  WEBRTC_HTTP_BIND_IP="${STREAM_BIND_IP}"
fi

WEBRTC_ADDITIONAL_HOSTS="[]"
if [[ -n "${STREAM_BIND_IP}" ]]; then
  WEBRTC_ADDITIONAL_HOSTS="[${STREAM_BIND_IP}]"
fi

echo "Writing /etc/mediamtx/mediamtx.yml..."
cat >/etc/mediamtx/mediamtx.yml <<EOF
logLevel: info

api: yes
apiAddress: 127.0.0.1:9997

rtsp: yes
rtspAddress: 127.0.0.1:8554

rtmp: no

hls: yes
hlsAddress: 127.0.0.1:8888

webrtc: yes
webrtcAddress: ${WEBRTC_HTTP_BIND_IP}:8889
webrtcLocalUDPAddress: ${STREAM_BIND_IP}:8189
webrtcLocalTCPAddress: ${STREAM_BIND_IP}:8189
webrtcAdditionalHosts: ${WEBRTC_ADDITIONAL_HOSTS}

srt: no
moq: no

paths:
  ${STREAM_NAME}:
    runOnInit: ffmpeg -hide_banner -loglevel warning -f v4l2 -framerate ${FRAMERATE} -video_size ${VIDEO_SIZE} ${INPUT_FORMAT_ARG} -i ${VIDEO_DEVICE} -an -c:v libx264 -pix_fmt yuv420p -preset ultrafast -tune zerolatency -b:v ${BITRATE} -f rtsp rtsp://127.0.0.1:\$RTSP_PORT/\$MTX_PATH
    runOnInitRestart: yes
EOF

echo "Writing systemd service..."
cat >/etc/systemd/system/mediamtx.service <<'EOF'
[Unit]
Description=MediaMTX USB camera stream
After=network-online.target
Wants=network-online.target

[Service]
User=mediamtx
Group=video
SupplementaryGroups=video
ExecStart=/usr/local/bin/mediamtx /etc/mediamtx/mediamtx.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mediamtx

echo
echo "MediaMTX is installed and running."
echo "Camera device: ${VIDEO_DEVICE}"
if [[ "${WEBRTC_HTTP_BIND_IP}" == "127.0.0.1" ]]; then
  echo "WebRTC page URL: http://127.0.0.1:8889/${STREAM_NAME}/ (intended for Tailscale Serve)"
else
  echo "Tailscale WebRTC URL: http://${WEBRTC_HTTP_BIND_IP}:8889/${STREAM_NAME}/"
fi
echo "Dashboard HLS URL: http://${STREAM_BIND_IP}:3100/stream/index.m3u8"
echo
echo "If the stream does not load, run: ./diagnose-pi.sh"
