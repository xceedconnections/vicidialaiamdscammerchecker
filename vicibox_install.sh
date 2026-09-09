#!/bin/bash
#
# Install OpenAMD on ViciBox (AGI + extension 8399 + Caller ID / Called Number)
#
# Usage (first arg = AI AMD base — IP, domain, or full URL):
#   bash vicibox_install.sh http://aiamd.xceedconnections.com oam_xxxxxxxx
#   bash vicibox_install.sh https://aiamd.xceedconnections.com oam_xxxxxxxx
#   bash vicibox_install.sh 204.168.200.221 oam_xxxxxxxx
#   bash vicibox_install.sh aiamd.xceedconnections.com oam_xxxxxxxx
#
# What this does (one shot — no need to re-run helper scripts after):
#   1) Writes /etc/asterisk/openamd.conf (http/https + SSL verify for IP)
#   2) Installs openamd.agi (local-presence aware, http+https)
#   3) Runs restore_vicidial_dialplan.sh — cleans broken Dial B()/openamd-capture
#   4) Runs fix_caller_called.sh (fix_local_presence_metadata.sh) which:
#        - Installs exact extension 8399 + [openamd-detect]
#          HUMAN -> agent | MACHINE -> hangup | AIAMD down -> stock AMD 8369
#        - Stores Caller ID + Called Number at dial time into AstDB for
#          ANY VICIdial dial prefix (_8. _9. _87899. _94455. _94556. _6. etc.)
#          Lead comes from Dial() ${EXTEN:N} when present.
#   5) Does NOT modify Dial() destinations or add B(openamd-capture)
#
# After install: set VICIdial campaign AMD / routing extension to 8399
#

set -euo pipefail

AIAMD_RAW="${1:-${AIAMD_URL:-${AIAMD_IP:-}}}"
API_KEY="${2:-${OPENAMD_API_KEY:-}}"

if [[ -z "${AIAMD_RAW}" || -z "${API_KEY}" ]]; then
  echo "Usage: bash vicibox_install.sh <AI_AMD_BASE> API_KEY"
  echo ""
  echo "  AI_AMD_BASE can be any of:"
  echo "    http://aiamd.example.com"
  echo "    https://aiamd.example.com"
  echo "    aiamd.example.com          (defaults to http://)"
  echo "    204.168.200.221            (defaults to http://)"
  echo ""
  echo "Examples:"
  echo "  bash vicibox_install.sh https://aiamd.xceedconnections.com oam_abc123"
  echo "  bash vicibox_install.sh http://aiamd.xceedconnections.com oam_abc123"
  echo "  bash vicibox_install.sh 204.168.200.221 oam_abc123"
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

# Normalize AI AMD base -> BASE_URL, HOST, ANALYZE_URL, HEALTH_URL, SSL_VERIFY
normalize_aiamd_base() {
  local raw="$1"
  raw="$(echo "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's|/*$||')"

  local scheme="" rest="" hostport="" host=""
  if [[ "$raw" =~ ^[Hh][Tt][Tt][Pp][Ss]?:// ]]; then
    scheme="$(echo "$raw" | sed -E 's#^(https?)://.*#\1#' | tr '[:upper:]' '[:lower:]')"
    rest="$(echo "$raw" | sed -E 's#^https?://##I')"
  else
    scheme="http"
    rest="$raw"
  fi

  # Drop any path (/api/..., trailing junk)
  hostport="${rest%%/*}"
  hostport="${hostport%%\?*}"
  host="${hostport%%:*}"

  if [[ -z "$host" ]]; then
    echo "ERROR: could not parse AI AMD host from: $1" >&2
    exit 1
  fi

  BASE_URL="${scheme}://${hostport}"
  ANALYZE_URL="${BASE_URL}/api/v1/analyze"
  HEALTH_URL="${BASE_URL}/api/health"
  AIAMD_HOST="$host"
  AIAMD_HOSTPORT="$hostport"

  # Bare IP => skip TLS hostname verify (certs are almost never issued for IPs)
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SSL_VERIFY=0
  else
    SSL_VERIFY=1
  fi
}

normalize_aiamd_base "${AIAMD_RAW}"

# Optional: if chosen scheme fails health, try the other scheme once
probe_and_maybe_flip() {
  local curl_opts=(-fsS --max-time 8)
  if [[ "$SSL_VERIFY" == "0" ]]; then
    curl_opts+=(-k)
  fi
  if curl "${curl_opts[@]}" "${HEALTH_URL}" >/tmp/openamd_health.json 2>/dev/null; then
    return 0
  fi
  local alt_scheme other_health
  if [[ "${BASE_URL}" == https://* ]]; then
    alt_scheme="http"
  else
    alt_scheme="https"
  fi
  other_health="${alt_scheme}://${AIAMD_HOSTPORT}/api/health"
  echo "WARNING: ${HEALTH_URL} failed — trying ${other_health} ..."
  if curl -fsSk --max-time 8 "${other_health}" >/tmp/openamd_health.json 2>/dev/null; then
    scheme="$alt_scheme"
    BASE_URL="${alt_scheme}://${AIAMD_HOSTPORT}"
    ANALYZE_URL="${BASE_URL}/api/v1/analyze"
    HEALTH_URL="${BASE_URL}/api/health"
    echo "Using ${BASE_URL}"
    return 0
  fi
  return 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGI1="/usr/share/asterisk/agi-bin"
AGI2="/var/lib/asterisk/agi-bin"
CONF="/etc/asterisk/openamd.conf"
CUSTOM="/etc/asterisk/extensions-custom.conf"
VICI="/etc/asterisk/extensions-vicidial.conf"
EXT="/etc/asterisk/extensions.conf"

# Locate AGI next to this script (vicibox/agi/openamd.agi)
find_agi() {
  local c
  for c in \
    "${SCRIPT_DIR}/agi/openamd.agi" \
    "${SCRIPT_DIR}/../agi/openamd.agi" \
    "/root/vicibox/agi/openamd.agi" \
    "/root/vicidialaiamd/agi/openamd.agi" \
    "/root/AIAMD/vicibox/agi/openamd.agi" \
    "/root/AIAMD/agi/openamd.agi"
  do
    if [[ -f "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

AGI_SRC="$(find_agi)" || {
  echo "ERROR: openamd.agi not found."
  echo "Upload the vicibox/ folder (must include vicibox/agi/openamd.agi)."
  exit 1
}

echo "==========================================="
echo " OpenAMD ViciBox installer"
echo " Base : ${BASE_URL}"
echo " Host : ${AIAMD_HOSTPORT}"
echo " SSL verify: ${SSL_VERIFY}"
echo " AGI src: ${AGI_SRC}"
echo "==========================================="

probe_and_maybe_flip || echo "WARNING: health check failed for both http and https — install continues; fix firewall/DNS after."

# Locate helper scripts (must ship with this installer)
find_script() {
  local name="$1"
  local c
  for c in \
    "${SCRIPT_DIR}/${name}" \
    "${SCRIPT_DIR}/agi/${name}" \
    "${SCRIPT_DIR}/../agi/${name}" \
    "/root/vicidialaiamd/${name}" \
    "/root/vicidialaiamd/agi/${name}"
  do
    if [[ -f "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

RESTORE_SRC="$(find_script restore_vicidial_dialplan.sh)" || {
  echo "ERROR: restore_vicidial_dialplan.sh not found next to installer."
  exit 1
}
FIX_CALLER_SRC="$(find_script fix_caller_called.sh)" || {
  echo "ERROR: fix_caller_called.sh not found next to installer."
  exit 1
}
# Prefer wrapper; fall back to agi/fix_local_presence_metadata.sh
FIX_META_SRC=""
if [[ -f "${SCRIPT_DIR}/agi/fix_local_presence_metadata.sh" ]]; then
  FIX_META_SRC="${SCRIPT_DIR}/agi/fix_local_presence_metadata.sh"
elif [[ -f "${SCRIPT_DIR}/../agi/fix_local_presence_metadata.sh" ]]; then
  FIX_META_SRC="${SCRIPT_DIR}/../agi/fix_local_presence_metadata.sh"
fi

mkdir -p "${AGI1}" "${AGI2}"

echo "[1/6] Writing ${CONF}..."
cat >"${CONF}" <<EOF
# OpenAMD dialer config — generated by vicibox_install.sh
OPENAMD_URL=${ANALYZE_URL}
OPENAMD_API_KEY=${API_KEY}
OPENAMD_AI_IP=${AIAMD_HOSTPORT}
# 1 = verify TLS hostname (domains). 0 = allow IP / mismatched cert.
OPENAMD_SSL_VERIFY=${SSL_VERIFY}
EOF
chmod 640 "${CONF}"
sed -i 's/\r$//' "${CONF}"
echo "    OPENAMD_URL=${ANALYZE_URL}"
echo "    OPENAMD_SSL_VERIFY=${SSL_VERIFY}"

copy_agi() {
  local src="$1" dest="$2"
  [[ -n "$src" && -n "$dest" && -f "$src" ]] || return 0
  if [[ "$src" -ef "$dest" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cp -f "$src" "$dest"
}

echo "[2/6] Installing openamd.agi..."
copy_agi "${AGI_SRC}" "${AGI1}/openamd.agi"
copy_agi "${AGI_SRC}" "${AGI2}/openamd.agi"
chmod 755 "${AGI1}/openamd.agi" "${AGI2}/openamd.agi"
chown asterisk:asterisk "${AGI1}/openamd.agi" "${AGI2}/openamd.agi" 2>/dev/null || true
sed -i 's/\r$//' "${AGI1}/openamd.agi" "${AGI2}/openamd.agi"
# Keep a copy beside fix_local_presence_metadata.sh (skip if already the same file)
if [[ -n "${FIX_META_SRC}" ]]; then
  copy_agi "${AGI_SRC}" "$(dirname "${FIX_META_SRC}")/openamd.agi"
  sed -i 's/\r$//' "$(dirname "${FIX_META_SRC}")/openamd.agi"
fi
perl -c "${AGI1}/openamd.agi"

echo "[3/6] Installing Perl modules (best effort)..."
if command -v zypper >/dev/null 2>&1; then
  zypper --non-interactive install -y perl-libwww-perl perl-Asterisk-AGI 2>/dev/null || true
elif command -v apt-get >/dev/null 2>&1; then
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y libwww-perl 2>/dev/null || true
fi

# Backup before dialplan mutation
cp -a "${EXT}" "${EXT}.bak.openamd.$(date +%Y%m%d%H%M%S)"
touch "${CUSTOM}"
cp -a "${CUSTOM}" "${CUSTOM}.bak.openamd.$(date +%Y%m%d%H%M%S)"
[[ -f "${VICI}" ]] && cp -a "${VICI}" "${VICI}.bak.openamd.$(date +%Y%m%d%H%M%S)"

echo "[4/6] Restoring clean VICIdial dialplan (strip broken Dial B / openamd-capture)..."
sed -i 's/\r$//' "${RESTORE_SRC}"
# OPENAMD_FROM_INSTALL=1 skips the "set AMD to 8369" tip (we install 8399 next)
OPENAMD_FROM_INSTALL=1 bash "${RESTORE_SRC}"

echo "[5/6] Installing 8399 + Caller ID / Called Number (any campaign/carrier prefix)..."
# This is the same path as: bash fix_caller_called.sh
# -> agi/fix_local_presence_metadata.sh (AstDB STORE + openamd-detect + exact 8399)
sed -i 's/\r$//' "${FIX_CALLER_SRC}"
OPENAMD_FROM_INSTALL=1 bash "${FIX_CALLER_SRC}"

grep -q '^#include extensions-custom.conf' "${EXT}" \
  || echo '#include extensions-custom.conf' >>"${EXT}"

sed -i 's/\r$//' "${EXT}" "${CUSTOM}"
[[ -f "${VICI}" ]] && sed -i 's/\r$//' "${VICI}"

echo "[6/6] Final dialplan reload + verify..."
asterisk -rx "database deltree openamd" >/dev/null 2>&1 || true
asterisk -rx "dialplan reload"
sleep 1

if ! grep -q '^#include extensions-custom.conf' "${EXT}"; then
  echo "ERROR: ${EXT} does not include extensions-custom.conf (openamd-detect will not load)."
  exit 1
fi

echo ""
echo "=== extensions-custom include ==="
grep extensions-custom "${EXT}" || true
echo ""
echo "=== 8399 ==="
asterisk -rx "dialplan show 8399@default" | head -20 || true
echo ""
echo "=== openamd-detect ==="
asterisk -rx "dialplan show openamd-detect" | head -25 || true
echo ""
echo "=== outbound CID sample (STORE must appear between CALLERID and Dial) ==="
grep -n -A8 'Set(CALLERID(num)' "${VICI}" 2>/dev/null | head -40 || true
echo ""
echo "=== Dial safety (must be empty of broken Dial B wrappers) ==="
if grep -nE 'openamd-capture|B\(openamd-capture' /etc/asterisk/extensions*.conf 2>/dev/null; then
  echo "WARNING: openamd-capture still present in dialplan (should be removed)."
else
  echo "(clean)"
fi

# Hard-fail if 8399 or STORE did not land (so install is never "half done")
# Capture dialplan output first — do NOT pipe asterisk|grep under pipefail
# (asterisk often exits non-zero and falsely trips the check).
OAMD_DP="$(asterisk -rx "dialplan show openamd-detect" 2>/dev/null || true)"
if ! echo "$OAMD_DP" | grep -q "Context 'openamd-detect'"; then
  echo "ERROR: [openamd-detect] context not loaded — check #include extensions-custom.conf in ${EXT}"
  echo "Tip: grep extensions-custom ${EXT}"
  echo "     asterisk -rx \"dialplan show openamd-detect\" | head"
  exit 1
fi
OAMD_8399="$(asterisk -rx "dialplan show 8399@default" 2>/dev/null || true)"
if ! echo "$OAMD_8399" | grep -q 'openamd-detect'; then
  echo "ERROR: extension 8399 / openamd-detect missing after install."
  echo "---- dialplan show 8399@default (first 25 lines) ----"
  echo "$OAMD_8399" | head -25
  exit 1
fi
if [[ -f "${VICI}" ]] && ! grep -q 'DB(openamd/${CHANNEL(linkedid)}/outcid)' "${VICI}" \
  && ! grep -q 'DB(openamd/${CHANNEL(linkedid)}/outcid)' "${EXT}"; then
  echo "ERROR: Caller ID AstDB STORE not found in ${VICI} or ${EXT}."
  echo "Campaign/carrier prefixes will not send Caller ID to the AIAMD portal."
  exit 1
fi
if [[ -f "${VICI}" ]] && ! grep -q 'DB(openamd/${CHANNEL(linkedid)}/lead)' "${VICI}" \
  && ! grep -q 'DB(openamd/${CHANNEL(linkedid)}/lead)' "${EXT}"; then
  echo "ERROR: Called Number AstDB STORE not found in ${VICI} or ${EXT}."
  echo "Portal Called Number column will be empty for local-presence campaigns."
  exit 1
fi

echo ""
if curl -fsSk --max-time 8 "${HEALTH_URL}"; then
  echo ""
else
  echo "WARNING: cannot reach ${HEALTH_URL}"
fi

echo ""
echo "[auto-store] Installing watcher for new carrier prefixes..."
sed -i 's/\r$//' "${SCRIPT_DIR}/install_openamd_auto_store.sh" "${SCRIPT_DIR}/openamd_auto_store.sh" 2>/dev/null || true
bash "${SCRIPT_DIR}/install_openamd_auto_store.sh" || echo "WARNING: auto-store watcher install failed (manual fix_caller_called.sh still works)"

echo ""
echo "==========================================="
echo " ViciBox OpenAMD install complete"
echo "==========================================="
echo " Set VICIdial campaign AMD extension to: 8399"
echo " AGI : ${AGI1}/openamd.agi"
echo " URL : ${ANALYZE_URL}"
echo " Conf: ${CONF}"
echo ""
echo " Included in this install (no extra scripts needed):"
echo "   - restore_vicidial_dialplan.sh   (clean Dial / no openamd-capture)"
echo "   - fix_caller_called.sh           (Caller ID + Called Number -> portal)"
echo "   - fix_local_presence_metadata.sh (any dial prefix + exact 8399)"
echo "   - openamd_auto_store.sh          (auto-inject when NEW prefixes are added)"
echo ""
echo " Failover: if AIAMD is down / unreachable / errors,"
echo "           extension 8399 automatically uses stock AMD 8369"
echo ""
echo " Portal columns:"
echo "   Caller ID     = local-presence CID (CURL/RAND result)"
echo "   Called Number = lead (\${EXTEN:N} for campaign/carrier prefixes)"
echo ""
echo " New carriers/prefixes: no reinstall needed — cron/path watcher"
echo "   re-applies OpenAMD STORE within ~1 minute of VICIdial rebuild."
echo " Manual: bash ${SCRIPT_DIR}/fix_caller_called.sh"
echo ""
