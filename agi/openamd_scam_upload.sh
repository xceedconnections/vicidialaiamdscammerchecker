#!/bin/bash
# Upload MixMonitor WAV to AIAMD SCAM API (HTTP :2130 — not file sync).
# MixMonitor invokes with ^-separated args: script^wav^meta
set -euo pipefail

WAV="${1:-}"
META="${2:-}"
CONF="/etc/asterisk/openamd.conf"

log() { logger -t openamd_scam "$*" 2>/dev/null || echo "openamd_scam: $*" >&2; }

[[ -n "$WAV" && -f "$WAV" ]] || { log "missing wav: $WAV"; exit 0; }
if [[ -z "$META" ]]; then
  META="${WAV%.wav}.meta"
fi

KEY=""
URL=""
SSL_VERIFY=1
if [[ -r "$CONF" ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^OPENAMD_API_KEY=(.*)$ ]] && KEY="${BASH_REMATCH[1]}"
    [[ "$line" =~ ^OPENAMD_URL=(.*)$ ]] && URL="${BASH_REMATCH[1]}"
    [[ "$line" =~ ^OPENAMD_SSL_VERIFY=(.*)$ ]] && SSL_VERIFY="${BASH_REMATCH[1]}"
  done <"$CONF"
fi

CALLID="$(basename "$WAV" .wav)"
CALLER=""
CALLED=""
CAMP=""
AGENT=""
UPLOAD=""
if [[ -f "$META" ]]; then
  while IFS= read -r line; do
    case "$line" in
      callid=*) CALLID="${line#callid=}" ;;
      caller=*) CALLER="${line#caller=}" ;;
      called=*) CALLED="${line#called=}" ;;
      campaign=*) CAMP="${line#campaign=}" ;;
      agent=*) AGENT="${line#agent=}" ;;
      upload_url=*) UPLOAD="${line#upload_url=}" ;;
    esac
  done <"$META"
fi

if [[ -z "$UPLOAD" && -n "$URL" ]]; then
  UPLOAD="$(echo "$URL" | sed -E 's#/api/v1/analyze/?$#/api/v1/scam/recording#')"
fi
[[ -n "$UPLOAD" && -n "$KEY" ]] || { log "missing upload url or key"; rm -f "$WAV" "$META"; exit 0; }

CURL_OPTS=(-fsS --max-time 180)
if [[ "$SSL_VERIFY" =~ ^(0|false|no|off)$ ]]; then
  CURL_OPTS+=(-k)
fi

BYTES=$(stat -c%s "$WAV" 2>/dev/null || echo 0)
if [[ "$BYTES" -lt 2000 ]]; then
  log "wav too small (${BYTES}) — skip upload"
  rm -f "$WAV" "$META"
  exit 0
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
rm -f "$WAV" "$META"
exit 0
