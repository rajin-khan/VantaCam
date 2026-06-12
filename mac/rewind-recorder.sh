#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

STREAM_NAME="${STREAM_NAME:-mac-cam}"
REWIND_ENABLED="${REWIND_ENABLED:-false}"
REWIND_MINUTES="${REWIND_MINUTES:-30}"
REWIND_SEGMENT_SECONDS="${REWIND_SEGMENT_SECONDS:-6}"
REWIND_DIR="${REWIND_DIR:-${HOME}/Library/Application Support/VantaCam/rewind}"
REWIND_SOURCE_URL="${REWIND_SOURCE_URL:-rtsp://127.0.0.1:8554/${STREAM_NAME}}"
REWIND_LOG_FILE="${REWIND_LOG_FILE:-${HOME}/Library/Application Support/VantaCam/logs/rewind.log}"
FFMPEG_BIN="${FFMPEG_BIN:-${HOME}/.vantacam/bin/ffmpeg}"

die() {
  echo "error: $*" >&2
  exit 1
}

enabled() {
  case "$(printf '%s' "${REWIND_ENABLED}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

validate() {
  [[ "${STREAM_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] ||
    die "STREAM_NAME must be 1-64 chars of letters, numbers, underscore, or dash"
  [[ "${REWIND_MINUTES}" =~ ^[0-9]+$ ]] && (( REWIND_MINUTES >= 1 && REWIND_MINUTES <= 240 )) ||
    die "REWIND_MINUTES must be 1-240"
  [[ "${REWIND_SEGMENT_SECONDS}" =~ ^[0-9]+$ ]] && (( REWIND_SEGMENT_SECONDS >= 2 && REWIND_SEGMENT_SECONDS <= 30 )) ||
    die "REWIND_SEGMENT_SECONDS must be 2-30"
  [[ -x "${FFMPEG_BIN}" ]] || die "ffmpeg not found: ${FFMPEG_BIN}"
}

segment_count() {
  local count=$(( (REWIND_MINUTES * 60 + REWIND_SEGMENT_SECONDS - 1) / REWIND_SEGMENT_SECONDS ))
  (( count >= 1 )) || count=1
  printf '%s\n' "${count}"
}

clear_buffer() {
  mkdir -p "${REWIND_DIR}"
  find "${REWIND_DIR}" -mindepth 1 -maxdepth 1 -type f \( -name 'index.m3u8' -o -name 'segment_*.ts' \) -delete
}

run_recorder() {
  validate
  enabled || die "REWIND_ENABLED is not true"
  clear_buffer

  mkdir -p "$(dirname "${REWIND_LOG_FILE}")"
  {
    printf '\n[%s] starting rewind recorder\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'source=%s dir=%s minutes=%s segment_seconds=%s list_size=%s\n' \
      "${REWIND_SOURCE_URL}" "${REWIND_DIR}" "${REWIND_MINUTES}" "${REWIND_SEGMENT_SECONDS}" "$(segment_count)"
  } >>"${REWIND_LOG_FILE}"

  exec "${FFMPEG_BIN}" \
    -hide_banner \
    -nostdin \
    -loglevel warning \
    -rtsp_transport tcp \
    -i "${REWIND_SOURCE_URL}" \
    -an \
    -c:v copy \
    -f hls \
    -hls_time "${REWIND_SEGMENT_SECONDS}" \
    -hls_list_size "$(segment_count)" \
    -hls_delete_threshold 2 \
    -hls_flags delete_segments+program_date_time \
    -hls_segment_filename "${REWIND_DIR}/segment_%05d.ts" \
    "${REWIND_DIR}/index.m3u8" >>"${REWIND_LOG_FILE}" 2>&1
}

case "${1:-run}" in
  run) run_recorder ;;
  clear) validate; clear_buffer ;;
  *) die "usage: $0 [run|clear]" ;;
esac
