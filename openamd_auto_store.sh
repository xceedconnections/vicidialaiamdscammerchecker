#!/bin/bash
#
# Auto-apply OpenAMD Caller ID / Called Number STORE to ANY new VICIdial
# carrier prefixes after VICIdial rebuilds extensions-vicidial.conf.
#
# Idempotent — safe every minute via cron. Only reloads dialplan when
# new STORE lines were actually injected.
#
# Installed by vicibox_install.sh as:
#   /usr/local/sbin/openamd_auto_store.sh
#   /etc/cron.d/openamd-auto-store
#
set -u

LOCK="/var/lock/openamd_auto_store.lock"
VICI="/etc/asterisk/extensions-vicidial.conf"
SHARE="/usr/local/share/openamd"
INJECT="${SHARE}/inject_called_number.py"
LOG_TAG="openamd_auto_store"

log() { logger -t "$LOG_TAG" "$*" 2>/dev/null || echo "$LOG_TAG: $*" >&2; }

[[ "$(id -u)" -eq 0 ]] || exit 0
[[ -f "$VICI" ]] || exit 0
[[ -f "$INJECT" ]] || {
  # Fallback to clone paths if share copy missing
  for c in \
    /root/vicidialaiamdscammerchecker/inject_called_number.py \
    /root/vicidialaiamd/inject_called_number.py \
    /root/vicidialaiamdscammerchecker/inject_called_number.py
  do
    [[ -f "$c" ]] && INJECT="$c" && break
  done
}
[[ -f "$INJECT" ]] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Single-flight lock (flock optional on older boxes)
exec 9>"$LOCK" 2>/dev/null || exit 0
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || exit 0
fi

# Quick skip: every CALLERID(num) already followed by STORE nearby is rare to
# compute in bash — always run inject --quiet (writes only when needed).
OUT="$(python3 "$INJECT" --quiet /etc/asterisk/extensions-vicidial.conf /etc/asterisk/extensions.conf 2>&1 || true)"

if echo "$OUT" | grep -q 'Injected AstDB store on [1-9]'; then
  log "$OUT"
  /usr/sbin/asterisk -rx "dialplan reload" >/dev/null 2>&1 || true
  log "dialplan reloaded after new carrier prefix STORE inject"
elif echo "$OUT" | grep -q '^CHANGED$'; then
  /usr/sbin/asterisk -rx "dialplan reload" >/dev/null 2>&1 || true
  log "dialplan reloaded (dialplan file changed)"
fi

exit 0
