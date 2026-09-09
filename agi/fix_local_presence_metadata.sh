#!/bin/bash
#
# Fix Caller ID vs Called Number for VICIdial LOCAL-PRESENCE via CURL/RAND.
#
# Your dialplan (extensions-vicidial.conf) looks like:
#   exten => _9.,1,AGI(...)
#   exten => _9.,n,Set(CALLERID(num)=${CURL(http://callerid...&did=${EXTEN:1:4})})
#   exten => _9.,3,Dial(SIP/vos/${EXTEN:1},,To)
#
# At 8399 on SIP/vos, only the local-presence CID remains.
# Lead is ${EXTEN:1} and exists ONLY at dial time on the Local/_9. leg.
#
# This script:
#   1) After each outbound Set(CALLERID(num)=...), stores AstDB:
#        outcid = ${CALLERID(num)}   -> portal Caller ID
#        lead   = ${EXTEN:1}         -> portal Called Number  (_8. / _9.)
#   2) Converts following absolute Dial/Hangup priorities to 'n'
#      so inserted lines do not collide (Dial DESTINATION is never changed)
#   3) Installs openamd.agi + [openamd-detect]
#   4) Does NOT add B(openamd-capture) and does NOT alter Dial() args
#
set -euo pipefail
[[ "$(id -u)" -eq 0 ]] || { echo "Run as root"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGI_SRC="${SCRIPT_DIR}/openamd.agi"
CUSTOM="/etc/asterisk/extensions-custom.conf"
VICI="/etc/asterisk/extensions-vicidial.conf"

[[ -f "$AGI_SRC" ]] || {
  echo "ERROR: $AGI_SRC missing. Put openamd.agi next to this script."
  exit 1
}
[[ -f "$VICI" ]] || {
  echo "ERROR: $VICI not found"
  exit 1
}

echo "==========================================="
echo " OpenAMD CURL/RAND local-presence fix"
echo "==========================================="

if grep -R "openamd-capture" /etc/asterisk/extensions*.conf >/dev/null 2>&1; then
  echo "ERROR: openamd-capture still present. Run restore_vicidial_dialplan.sh first."
  exit 1
fi

echo "[1/5] Install AGI..."
mkdir -p /usr/share/asterisk/agi-bin /var/lib/asterisk/agi-bin
cp -f "$AGI_SRC" /usr/share/asterisk/agi-bin/openamd.agi
cp -f "$AGI_SRC" /var/lib/asterisk/agi-bin/openamd.agi
chmod 755 /usr/share/asterisk/agi-bin/openamd.agi /var/lib/asterisk/agi-bin/openamd.agi
chown asterisk:asterisk /usr/share/asterisk/agi-bin/openamd.agi 2>/dev/null || true
chown asterisk:asterisk /var/lib/asterisk/agi-bin/openamd.agi 2>/dev/null || true
sed -i 's/\r$//' /usr/share/asterisk/agi-bin/openamd.agi /var/lib/asterisk/agi-bin/openamd.agi

# SCAM full-call arm + upload (does not alter AMD analyze)
SCAM_AGI="${SCRIPT_DIR}/openamd_scam.agi"
SCAM_UP="${SCRIPT_DIR}/openamd_scam_upload.sh"
if [[ -f "$SCAM_AGI" ]]; then
  cp -f "$SCAM_AGI" /usr/share/asterisk/agi-bin/openamd_scam.agi
  cp -f "$SCAM_AGI" /var/lib/asterisk/agi-bin/openamd_scam.agi
  chmod 755 /usr/share/asterisk/agi-bin/openamd_scam.agi /var/lib/asterisk/agi-bin/openamd_scam.agi
  sed -i 's/\r$//' /usr/share/asterisk/agi-bin/openamd_scam.agi /var/lib/asterisk/agi-bin/openamd_scam.agi
  chown asterisk:asterisk /usr/share/asterisk/agi-bin/openamd_scam.agi /var/lib/asterisk/agi-bin/openamd_scam.agi 2>/dev/null || true
  echo "Installed openamd_scam.agi"
fi
if [[ -f "$SCAM_UP" ]]; then
  cp -f "$SCAM_UP" /usr/share/asterisk/agi-bin/openamd_scam_upload.sh
  cp -f "$SCAM_UP" /var/lib/asterisk/agi-bin/openamd_scam_upload.sh
  chmod 755 /usr/share/asterisk/agi-bin/openamd_scam_upload.sh /var/lib/asterisk/agi-bin/openamd_scam_upload.sh
  sed -i 's/\r$//' /usr/share/asterisk/agi-bin/openamd_scam_upload.sh /var/lib/asterisk/agi-bin/openamd_scam_upload.sh
  chown asterisk:asterisk /usr/share/asterisk/agi-bin/openamd_scam_upload.sh /var/lib/asterisk/agi-bin/openamd_scam_upload.sh 2>/dev/null || true
  echo "Installed openamd_scam_upload.sh"
fi

echo "[2/5] Backup + strip old OpenAMD helper / Gosub wraps..."
cp -a "$VICI" "${VICI}.bak.lpcurl.$(date +%Y%m%d%H%M%S)"
cp -a /etc/asterisk/extensions.conf "/etc/asterisk/extensions.conf.bak.lpcurl.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

python3 - <<'PY'
from pathlib import Path
import re, glob

gosub_re = re.compile(
    r'Gosub\(openamd-store,s,1\(([0-9]{7,15}),([0-9]{7,15})\)\)'
)

for name in sorted(set(glob.glob('/etc/asterisk/extensions*.conf'))):
    p = Path(name)
    lines = p.read_text(encoding='utf-8', errors='replace').splitlines(True)
    out = []
    removed = 0
    for line in lines:
        if re.search(r'Set\(DB\(openamd/', line):
            removed += 1
            continue
        if 'NoOp(OpenAMD STORE' in line:
            removed += 1
            continue
        if re.search(r'Set\(SHARED\(OPENAMD_', line) or re.search(r'Set\(__OPENAMD_', line):
            removed += 1
            continue
        if 'Dial(' in line and 'openamd-capture' in line:
            line = re.sub(r'B\(openamd-capture\^s\^1\)', '', line)
            line = re.sub(r',{3,}', ',,', line)
        m = gosub_re.search(line)
        if m:
            line = gosub_re.sub(r'Set(CALLERID(num)=\1)', line)
        out.append(line)
    p.write_text(''.join(out), encoding='utf-8')
    print('%s: stripped %d old helpers' % (name, removed))
PY

echo "[3/5] Inject AstDB store (any campaign/carrier prefix)..."
INJECT_PY=""
for c in \
  "${SCRIPT_DIR}/../inject_called_number.py" \
  "${SCRIPT_DIR}/inject_called_number.py" \
  "/root/vicidialaiamd/inject_called_number.py"
do
  if [[ -f "$c" ]]; then
    INJECT_PY="$c"
    break
  fi
done
if [[ -z "$INJECT_PY" ]]; then
  echo "ERROR: inject_called_number.py not found (needed for Caller ID / Called Number)."
  exit 1
fi
sed -i 's/\r$//' "$INJECT_PY"
python3 "$INJECT_PY"
INJECTED_N=$(grep -c 'DB(openamd/${CHANNEL(linkedid)}/lead)' /etc/asterisk/extensions-vicidial.conf 2>/dev/null || true)
INJECTED_N=${INJECTED_N:-0}
if [[ "${INJECTED_N}" -eq 0 ]]; then
  INJECTED_N=$(grep -c 'DB(openamd/${CHANNEL(linkedid)}/lead)' /etc/asterisk/extensions.conf 2>/dev/null || true)
  INJECTED_N=${INJECTED_N:-0}
fi
if [[ "${INJECTED_N}" -eq 0 ]]; then
  echo "ERROR: AstDB STORE not written — Called Number will be empty on the portal."
  echo "Show outbound dialplan samples:"
  grep -nE 'Set\(CALLERID\(num\)|exten => _|same =>.*,Dial\(' /etc/asterisk/extensions-vicidial.conf 2>/dev/null | head -40 || true
  exit 1
fi
echo "AstDB lead STORE lines present: ${INJECTED_N}"

echo "[4/5] Write [openamd-detect]..."
touch "$CUSTOM"
cp -a "$CUSTOM" "${CUSTOM}.bak.lpcurl.$(date +%Y%m%d%H%M%S)"

python3 - <<'PY'
from pathlib import Path

path = Path("/etc/asterisk/extensions-custom.conf")
text = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
out = []
skip = False
for line in text.splitlines(True):
    s = line.strip()
    if s.startswith("[openamd-detect]") or s.startswith("[openamd-store]"):
        skip = True
        continue
    if skip and line.startswith("["):
        skip = False
    if not skip:
        out.append(line)

block = r'''
; --- OpenAMD detect (reads AstDB filled at dial time on _8./_9.) ---
; HUMAN -> agent | MACHINE -> hangup | UNAVAILABLE/ERROR -> stock AMD 8369
[openamd-detect]
exten => s,1,NoOp(OpenAMD detect lid=${CHANNEL(linkedid)})
 same => n,Set(OAMD_LID=${CHANNEL(linkedid)})
 same => n,Set(OPENAMD_CALLER=${DB(openamd/${OAMD_LID}/outcid)})
 same => n,Set(OPENAMD_CALLED=${DB(openamd/${OAMD_LID}/lead)})
 same => n,Set(OPENAMD_CAMPAIGN=${IF($["${DB(openamd/${OAMD_LID}/campaign)}"!=""]?${DB(openamd/${OAMD_LID}/campaign)}:${IF($["${ARG1}"!=""]?${ARG1}:${CAMPCUST})})})
 ; Fallback: at 8399 CALLERID(num) is local-presence CID only
 same => n,ExecIf($["${OPENAMD_CALLER}"=""]?Set(OPENAMD_CALLER=${CALLERID(num)}))
 same => n,Set(OPENAMD_ID=${EPOCH}-${RAND(10000,99999)})
 same => n,Set(OPENAMD_FILE=/tmp/openamd-${OPENAMD_ID})
 same => n,NoOp(OpenAMD detect caller=${OPENAMD_CALLER} called=${OPENAMD_CALLED} camp=${OPENAMD_CAMPAIGN})
 ; Fast health ping — if AIAMD down, skip Record and use stock 8369
 same => n,AGI(openamd.agi,ping)
 same => n,GotoIf($["${OPENAMD_STATUS}" = "UNAVAILABLE"]?fallback)
 same => n,GotoIf($["${OPENAMD_STATUS}" = "ERROR"]?fallback)
 same => n,Wait(0.3)
 ; Slightly longer window so silence is captured as audio (BLANK->MACHINE), not empty WAV->8369
 same => n,Record(${OPENAMD_FILE}:wav,3,4,q)
 same => n,AGI(openamd.agi,${OPENAMD_ID},${OPENAMD_CAMPAIGN},${OPENAMD_CALLER},${OPENAMD_CALLED})
 same => n,NoOp(OpenAMD status=${OPENAMD_STATUS} conf=${OPENAMD_CONFIDENCE})
 same => n,GotoIf($["${OPENAMD_STATUS}" = "HUMAN"]?human)
 same => n,GotoIf($["${OPENAMD_STATUS}" = "MACHINE"]?machine)
 same => n,Goto(fallback)
 same => n(human),Set(AMDSTATUS=HUMAN)
 same => n,Set(AMDCAUSE=HUMAN)
 same => n,Return()
 same => n(machine),Set(AMDSTATUS=MACHINE)
 same => n,Set(AMDCAUSE=MACHINE)
 same => n,Return()
 same => n(fallback),Set(AMDSTATUS=FALLBACK)
 same => n,Set(AMDCAUSE=OPENAMD_UNAVAILABLE)
 same => n,Return()
'''

path.write_text("".join(out).rstrip() + "\n" + block + "\n", encoding="utf-8")
print("Updated [openamd-detect]")

# Exact 8399 with FAIL -> stock AMD 8369
# Must land inside [default] (never append after other contexts / EOF junk).
import re
from pathlib import Path

new8399 = '''
; --- OpenAMD exact 8399 (HUMAN -> agent, MACHINE -> hangup, FAIL -> 8369) ---
exten => 8399,1,AGI(agi://127.0.0.1:4577/call_log)
exten => 8399,n,Playback(sip-silence)
exten => 8399,n,Gosub(openamd-detect,s,1(${CAMPCUST},))
exten => 8399,n,NoOp(OpenAMD AMDSTATUS=${AMDSTATUS} AMDCAUSE=${AMDCAUSE})
exten => 8399,n,GotoIf($["${AMDSTATUS}" = "HUMAN"]?openamd_human)
exten => 8399,n,GotoIf($["${AMDSTATUS}" = "FALLBACK"]?openamd_fallback)
exten => 8399,n,AGI(VD_amd.agi,${EXTEN})
exten => 8399,n,Hangup()
exten => 8399,n(openamd_human),NoOp(OpenAMD HUMAN - sending to agent)
exten => 8399,n,AGI(openamd_scam.agi,arm)
exten => 8399,n,AGI(agi-VDAD_ALL_outbound.agi,NORMAL-----LB-----${CONNECTEDLINE(name)})
exten => 8399,n,Hangup()
exten => 8399,n(openamd_fallback),NoOp(OpenAMD unavailable - stock Vicidial AMD 8369)
exten => 8399,n,Goto(default,8369,1)
'''

def strip_8399(text: str) -> str:
    lines = text.splitlines(True)
    out = []
    for line in lines:
        s = line.strip()
        if s.startswith('; --- OpenAMD exact 8399'):
            continue
        if re.match(r'exten\s*=>\s*8399\b', s):
            continue
        out.append(line)
    return ''.join(out)

def inject_8399_in_default(text: str) -> str:
    """Insert OpenAMD 8399 inside [default], after the last 8369 Hangup if present."""
    text = strip_8399(text)
    lines = text.splitlines(True)
    start = None
    end = len(lines)
    for i, line in enumerate(lines):
        if re.match(r'^\[default\]', line):
            start = i
            break
    if start is not None:
        for j in range(start + 1, len(lines)):
            if re.match(r'^\[[^\]]+\]', lines[j]):
                end = j
                break
    insert_at = None
    search_from = start if start is not None else 0
    search_to = end if start is not None else len(lines)
    for i in range(search_from, search_to):
        if re.search(r'exten\s*=>\s*8369\s*,\s*n\s*,\s*Hangup\(\)', lines[i]):
            insert_at = i + 1
    if insert_at is None and start is not None:
        insert_at = end
        while insert_at > start + 1 and lines[insert_at - 1].strip() == '':
            insert_at -= 1
    if insert_at is None:
        insert_at = len(lines)
        print('WARNING: [default] / 8369 Hangup not found — appending 8399 at EOF')
    else:
        print('Injecting 8399 at line %d (inside [default]=%s)' % (
            insert_at + 1, 'yes' if start is not None else 'unknown'))
    block = new8399 if new8399.endswith('\n') else new8399 + '\n'
    if not block.startswith('\n'):
        block = '\n' + block
    return ''.join(lines[:insert_at]) + block + ''.join(lines[insert_at:])

# extensions.conf — primary home for 8399
p = Path('/etc/asterisk/extensions.conf')
p.write_text(inject_8399_in_default(p.read_text(encoding='utf-8', errors='replace')), encoding='utf-8')
print('Wrote exact extension 8399 in extensions.conf (failover -> 8369)')

# Remove conflicting 8399 from other Asterisk includes (keep OpenAMD one only)
for other in ('/etc/asterisk/extensions-vicidial.conf', '/etc/asterisk/extensions-custom.conf'):
    op = Path(other)
    if not op.exists():
        continue
    ot = op.read_text(encoding='utf-8', errors='replace')
    nt = strip_8399(ot)
    # Never strip [openamd-detect] — only bare exten 8399 lines
    if nt != ot:
        op.write_text(nt, encoding='utf-8')
        print('Removed conflicting exten 8399 from %s' % other)
PY

sed -i 's/\r$//' "$CUSTOM" "$VICI" /etc/asterisk/extensions.conf

EXT="/etc/asterisk/extensions.conf"
if ! grep -q '^#include extensions-custom.conf' "$EXT" 2>/dev/null; then
  echo '#include extensions-custom.conf' >>"$EXT"
  echo "Added #include extensions-custom.conf to $EXT"
fi

echo "[5/5] Show result + reload..."
echo ""
echo "=== outbound STORE sample (Caller ID + Called Number) ==="
grep -n 'OpenAMD STORE' /etc/asterisk/extensions-vicidial.conf 2>/dev/null | head -20 || true
grep -n 'DB(openamd/${CHANNEL(linkedid)}/lead)' /etc/asterisk/extensions-vicidial.conf 2>/dev/null | head -20 || true
grep -n 'OpenAMD STORE' /etc/asterisk/extensions.conf 2>/dev/null | head -10 || true

echo ""
echo "=== Dial destinations (must still use \${EXTEN:N} / unchanged) ==="
grep -nE 'Dial\((SIP|PJSIP|IAX2)' /etc/asterisk/extensions-vicidial.conf 2>/dev/null | head -15 || true

perl -c /usr/share/asterisk/agi-bin/openamd.agi
asterisk -rx "database deltree openamd" >/dev/null 2>&1 || true
asterisk -rx "dialplan reload"

echo ""
asterisk -rx "dialplan show openamd-detect" | head -25

echo ""
echo "DONE."
echo "Place ONE new call, then:"
echo "  grep 'OpenAMD STORE' /var/log/asterisk/full | tail -5"
echo "  tail -n 5 /tmp/openamd_debug.log"
echo ""
echo "Expect:"
echo "  OpenAMD STORE outcid=<CURL cid> lead=<EXTEN without 9>"
echo "  DB.outcid=... DB.lead=...   (both filled, different)"
