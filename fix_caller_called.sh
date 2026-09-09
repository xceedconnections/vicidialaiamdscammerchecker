#!/bin/bash
#
# Re-apply Caller ID + Called Number metadata on an existing ViciBox install.
# Already run automatically by vicibox_install.sh — only needed if VICIdial
# rebuilt extensions-vicidial.conf and you do not want a full reinstall.
# Prefer full installer when possible:
#   bash vicibox_install.sh AI_AMD_BASE API_KEY
#
set -euo pipefail
[[ "$(id -u)" -eq 0 ]] || { echo "Run as root"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

FIX=""
for c in \
  "${SCRIPT_DIR}/agi/fix_local_presence_metadata.sh" \
  "${SCRIPT_DIR}/../agi/fix_local_presence_metadata.sh"
do
  if [[ -f "$c" ]]; then
    FIX="$c"
    break
  fi
done

if [[ -z "$FIX" ]]; then
  echo "ERROR: fix_local_presence_metadata.sh not found"
  echo "Run: bash vicibox_install.sh AI_AMD_IP API_KEY"
  exit 1
fi

AGI_SRC=""
for c in \
  "${SCRIPT_DIR}/agi/openamd.agi" \
  "${SCRIPT_DIR}/../agi/openamd.agi"
do
  [[ -f "$c" ]] && AGI_SRC="$c" && break
done

FIX_DIR="$(cd "$(dirname "$FIX")" && pwd)"
if [[ -n "$AGI_SRC" && ! -f "${FIX_DIR}/openamd.agi" ]]; then
  cp -f "$AGI_SRC" "${FIX_DIR}/openamd.agi"
  sed -i 's/\r$//' "${FIX_DIR}/openamd.agi"
fi

sed -i 's/\r$//' "$FIX"
bash "$FIX"

EXT="/etc/asterisk/extensions.conf"
if ! grep -q '^#include extensions-custom.conf' "$EXT" 2>/dev/null; then
  echo '#include extensions-custom.conf' >>"$EXT"
  echo "Added #include extensions-custom.conf to $EXT"
  asterisk -rx "dialplan reload"
fi
