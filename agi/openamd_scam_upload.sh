#!/bin/bash
# Upload MixMonitor WAV to AIAMD SCAM API (HTTP :2130 — not file sync).
# Invoked by detached watchdog: openamd_scam_upload.sh <wav> <meta>
set -u

WAV="${1:-}"
META="${2:-}"
CONF="/etc/asterisk/openamd.conf"
LOCK=""

log() { logger -t openamd_scam "$*" 2>/dev/null || echo "openamd_scam: $*" >&2; }

finalize() {
  local note="${1:-upload_failed}"
  local status="${2:-ERROR}"
  [[ -n "${FINALIZE:-}" && -n "${KEY:-}" && -n "${CALLID:-}" ]] || return 0
  local opts=(-fsS --max-time 15)
  if [[ "${CURL_INSECURE:-0}" == "1" ]]; then
    opts+=(-k)
  fi
  curl "${opts[@]}" \
    -H "X-API-Key: ${KEY}" \
    -F "callid=${CALLID}" \
    -F "status=${status}" \
    -F "note=${note}" \
    -F "campaign=${CAMP:-}" \
    -F "caller=${CALLER:-}" \
    -F "called=${CALLED:-}" \
    -F "agent=${AGENT:-}" \
    "${FINALIZE}" >/dev/null 2>&1 || true
  log "finalize status=${status} note=${note} callid=${CALLID}"
}

cleanup() {
  rm -f "${WAV:-}" "${META:-}" "${WAV%.wav}.wav" 2>/dev/null || true
}

# MixMonitor sometimes writes path.wav or path (plus format). Accept either.
if [[ -z "$WAV" ]]; then
  log "missing wav arg"
  exit 0
fi
if [[ ! -f "$WAV" ]]; then
  if [[ -f "${WAV}.wav" ]]; then
    WAV="${WAV}.wav"
  elif [[ -f "${WAV%.wav}" ]]; then
    WAV="${WAV%.wav}"
  fi
fi
if [[ -z "$META" ]]; then
  META="${WAV%.wav}.meta"
  [[ -f "$META" ]] || META="/tmp/$(basename "${WAV%.wav}").meta"
fi

KEY=""
URL=""
SSL_VERIFY="auto"
CALLID="$(basename "$WAV" .wav)"
CALLID="${CALLID#openamd-scam-}"
CALLER=""
CALLED=""
CAMP=""
AGENT=""
UPLOAD=""
FINALIZE=""

if [[ -r "$CONF" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^OPENAMD_API_KEY=(.*)$ ]] && KEY="${BASH_REMATCH[1]}"
    [[ "$line" =~ ^OPENAMD_URL=(.*)$ ]] && URL="${BASH_REMATCH[1]}"
    [[ "$line" =~ ^OPENAMD_SSL_VERIFY=(.*)$ ]] && SSL_VERIFY="${BASH_REMATCH[1]}"
  done <"$CONF"
fi

if [[ -f "$META" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      callid=*) CALLID="${line#callid=}" ;;
      caller=*) CALLER="${line#caller=}" ;;
      called=*) CALLED="${line#called=}" ;;
      campaign=*) CAMP="${line#campaign=}" ;;
      agent=*) AGENT="${line#agent=}" ;;
      upload_url=*) UPLOAD="${line#upload_url=}" ;;
      finalize_url=*) FINALIZE="${line#finalize_url=}" ;;
    esac
  done <"$META"
fi

if [[ -z "$UPLOAD" && -n "$URL" ]]; then
  if [[ "$URL" =~ /api/v1/analyze/?$ ]]; then
    UPLOAD="$(echo "$URL" | sed -E 's#/api/v1/analyze/?$#/api/v1/scam/recording#')"
  else
    UPLOAD="${URL%/}/api/v1/scam/recording"
  fi
fi
if [[ -z "$FINALIZE" && -n "$URL" ]]; then
  if [[ "$URL" =~ /api/v1/analyze/?$ ]]; then
    FINALIZE="$(echo "$URL" | sed -E 's#/api/v1/analyze/?$#/api/v1/scam/finalize#')"
  else
    FINALIZE="${URL%/}/api/v1/scam/finalize"
  fi
fi

CURL_INSECURE=0
if [[ "$SSL_VERIFY" =~ ^(0|false|no|off)$ ]]; then
  CURL_INSECURE=1
elif [[ "$SSL_VERIFY" =~ ^(auto)?$ ]]; then
  if [[ "${UPLOAD}" =~ ^https?://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    CURL_INSECURE=1
  fi
fi

LOCK="/tmp/openamd-scam-upload-${CALLID}.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  log "upload already in progress callid=${CALLID}"
  exit 0
fi

if [[ ! -f "$WAV" ]]; then
  log "missing wav file: $WAV"
  finalize "missing_wav" "ERROR"
  cleanup
  exit 0
fi

if [[ -z "$UPLOAD" || -z "$KEY" ]]; then
  log "missing upload url or key"
  finalize "missing_upload_config" "ERROR"
  cleanup
  exit 0
fi

BYTES=$(stat -c%s "$WAV" 2>/dev/null || echo 0)
# WAV header alone is 44 bytes; require real audio
if [[ "$BYTES" -lt 1000 ]]; then
  log "wav too small (${BYTES}) — skip upload"
  finalize "wav_too_small_${BYTES}" "ERROR"
  cleanup
  exit 0
fi

CURL_OPTS=(-fsS --max-time 180)
if [[ "$CURL_INSECURE" == "1" ]]; then
  CURL_OPTS+=(-k)
fi

HTTP_CODE=$(curl "${CURL_OPTS[@]}" -o /tmp/openamd_scam_upload.json -w "%{http_code}" \
  -H "X-API-Key: ${KEY}" \
  -F "callid=${CALLID}" \
  -F "campaign=${CAMP}" \
  -F "caller=${CALLER}" \
  -F "called=${CALLED}" \
  -F "agent=${AGENT}" \
  -F "audio=@${WAV};type=audio/wav;filename=scam-${CALLID}.wav" \
  "${UPLOAD}" || true)

log "upload http=${HTTP_CODE} callid=${CALLID} bytes=${BYTES}"

if [[ "$HTTP_CODE" != "200" ]]; then
  finalize "upload_http_${HTTP_CODE}" "ERROR"
fi

cleanup
exit 0
