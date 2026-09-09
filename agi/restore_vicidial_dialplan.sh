#!/bin/bash
#
# RESTORE VICIdial outbound dialing after OpenAMD caller/called experiments.
#
# Problem: Dial lines were modified (e.g. Dial(...,,ToB(openamd-capture^s^1)))
#          which breaks outbound dialing on ViciBox.
#
# This script:
#   1) Removes ALL OpenAMD injections from outbound dialplan (DB/SHARED/B/NoOp STORE)
#   2) Fixes mangled Dial() option strings
#   3) Keeps extension 8399 + [openamd-detect] for campaigns that USE 8399
#   4) Does NOT touch stock 8369 AMD
#
# Run as root on ViciBox:
#   bash restore_vicidial_dialplan.sh
#
set -euo pipefail
[[ "$(id -u)" -eq 0 ]] || { echo "Run as root"; exit 1; }

echo "==========================================="
echo " Restore VICIdial outbound dialplan"
echo "==========================================="

# Optional: restore from newest backup if dialplan still broken after cleanup
RESTORE_BACKUP="${1:-}"

if [[ -n "$RESTORE_BACKUP" && -f "$RESTORE_BACKUP" ]]; then
  echo "Restoring $RESTORE_BACKUP ..."
  cp -a "$RESTORE_BACKUP" /etc/asterisk/extensions.conf
  asterisk -rx "dialplan reload"
  echo "Restored extensions.conf from backup"
  exit 0
fi

echo "[1/3] Strip OpenAMD injections from ALL extensions*.conf ..."
python3 - <<'PY'
from pathlib import Path
import re, glob

fixed_dial = 0
removed = 0

for name in sorted(set(glob.glob('/etc/asterisk/extensions*.conf'))):
    p = Path(name)
    lines = p.read_text(encoding='utf-8', errors='replace').splitlines(True)
    out = []
    for line in lines:
        orig = line
        # Drop helper lines we added
        if re.search(r'Set\(DB\(openamd/', line):
            removed += 1
            continue
        if re.search(r'Set\(SHARED\(OPENAMD_', line):
            removed += 1
            continue
        if re.search(r'Set\(__OPENAMD_', line):
            removed += 1
            continue
        if 'NoOp(OpenAMD STORE' in line:
            removed += 1
            continue
        # Fix Dial lines: remove broken B(openamd-capture...) glued to options
        if 'Dial(' in line:
            before = line
            # ToB(openamd-capture^s^1) -> To
            line = re.sub(r'B\(openamd-capture\^s\^1\)', '', line)
            # stray double commas
            line = re.sub(r',{3,}', ',,', line)
            line = re.sub(r',\s*,\)', ')', line)
            line = re.sub(r',\)', ')', line)
            if line != before:
                fixed_dial += 1
        if line.strip():
            out.append(line)
    p.write_text(''.join(out), encoding='utf-8')
    print('%s: cleaned' % name)

print('Removed %d helper lines, fixed %d Dial lines' % (removed, fixed_dial))
PY

echo "[2/3] Ensure [openamd-capture] removed (was breaking Dial B option)..."
python3 - <<'PY'
from pathlib import Path
custom = Path('/etc/asterisk/extensions-custom.conf')
if not custom.exists():
    raise SystemExit(0)
ct = custom.read_text(encoding='utf-8', errors='replace')
out, skip = [], False
for line in ct.splitlines(True):
    s = line.strip()
    if s.startswith('[openamd-capture]'):
        skip = True
        continue
    if skip and line.startswith('['):
        skip = False
    if not skip:
        out.append(line)
custom.write_text(''.join(out), encoding='utf-8')
print('Removed [openamd-capture] context if present')
PY

echo "[3/3] Reload dialplan + verify ..."
for f in /etc/asterisk/extensions*.conf; do
  sed -i 's/\r$//' "$f"
done

if ! asterisk -rx "dialplan reload"; then
  echo "ERROR: dialplan reload failed — restore from backup:"
  ls -lt /etc/asterisk/extensions.conf.bak.* 2>/dev/null | head -5
  exit 1
fi

echo ""
echo "=== Sample Dial lines (should NOT contain openamd-capture) ==="
grep -n "Dial(SIP" /etc/asterisk/extensions*.conf 2>/dev/null | head -15 || true

echo ""
echo "=== 8369 (stock AMD) ==="
asterisk -rx "dialplan show 8369@default" 2>/dev/null | head -12 || true

echo ""
echo "=== 8399 (OpenAMD — only used when campaign AMD ext = 8399) ==="
asterisk -rx "dialplan show 8399@default" 2>/dev/null | head -12 || true

echo ""
echo "==========================================="
echo " DONE — outbound Dial lines restored"
echo "==========================================="
echo ""
if [[ "${OPENAMD_FROM_INSTALL:-0}" == "1" ]]; then
  echo "Continuing installer (8399 + Caller ID / Called Number next)..."
else
  echo "VICIdial campaign AMD extension:"
  echo "  8369 = stock VICIdial AMD (NO OpenAMD)"
  echo "  8399 = OpenAMD AI AMD"
  echo ""
  echo "After a full OpenAMD install, set AMD Extension = 8399."
  echo "For stock Vicidial AMD only, use 8369."
  echo ""
  echo "If dialing still broken, restore pre-change backup:"
  echo "  ls -lt /etc/asterisk/extensions.conf.bak.*"
  echo "  bash restore_vicidial_dialplan.sh /etc/asterisk/extensions.conf.bak.XXXXXXXX"
fi
