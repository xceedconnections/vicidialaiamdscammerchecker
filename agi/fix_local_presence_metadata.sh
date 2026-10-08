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
#   3) Installs openamd.agi + VD_amd_human_only.agi + [openamd-detect]
#   4) Injects AMD routing:
#        8369 = stock Vicidial (untouched)
#        8398 = stock AMD(), HUMAN/PERSON only → agent; else AA hangup (no scam)
#        8399 = stock AMD MACHINE→hangup; HUMAN/PERSON/NOTSURE→AIAMD final
#               via Answer+Wait+Record (NO MixMonitor on customer channel);
#               AIAMD HUMAN→agent+scam; AIAMD MACHINE/FALLBACK→8398 hangup
#        Strips leftover 8389 / 8397 / old 8398 / old 8399 on install
#   5) Does NOT add B(openamd-capture) and does NOT alter Dial() args
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

# VD_amd_human_only.agi — NEVER overwrite system VD_amd.agi
# Prefer patching a copy of live stock VD_amd.agi (PERSON|HUMAN only), else packaged file.
install_vd_amd_human_only() {
  local dest1="/usr/share/asterisk/agi-bin/VD_amd_human_only.agi"
  local dest2="/var/lib/asterisk/agi-bin/VD_amd_human_only.agi"
  local packaged="${SCRIPT_DIR}/VD_amd_human_only.agi"
  local live=""
  local tmp=""
  local src=""

  for live in /var/lib/asterisk/agi-bin/VD_amd.agi /usr/share/asterisk/agi-bin/VD_amd.agi; do
    if [[ -f "$live" ]]; then
      tmp="$(mktemp)"
      cp -f "$live" "$tmp"
      # Stock agent-exit often includes NOTSURE|HANGUP — strip to HUMAN-only.
      sed -i \
        -e 's/PERSON|HUMAN|NOTSURE|HANGUP/PERSON|HUMAN/g' \
        -e "s/\$script = 'VD_amd.agi';/\$script = 'VD_amd_human_only.agi';/g" \
        -e "s/\$script = \"VD_amd.agi\";/\$script = 'VD_amd_human_only.agi';/g" \
        "$tmp"
      if grep -q "PERSON|HUMAN|NOTSURE|HANGUP" "$tmp"; then
        echo "WARNING: live $live still has NOTSURE|HANGUP after sed — using packaged AGI"
        rm -f "$tmp"
        tmp=""
      elif ! grep -qE "AMDSTATUS =~ /PERSON\|HUMAN/" "$tmp"; then
        echo "WARNING: live $live missing PERSON|HUMAN exit after sed — using packaged AGI"
        rm -f "$tmp"
        tmp=""
      elif ! grep -q "VD_amd_human_only.agi" "$tmp"; then
        echo "WARNING: could not set \$script in copy of $live — using packaged AGI"
        rm -f "$tmp"
        tmp=""
      else
        src="$tmp"
        echo "Built VD_amd_human_only.agi from live $live (PERSON|HUMAN only)"
        break
      fi
    fi
  done

  if [[ -z "$src" ]]; then
    [[ -f "$packaged" ]] || {
      echo "ERROR: VD_amd_human_only.agi missing (no live VD_amd.agi to patch, no packaged file)."
      exit 1
    }
    src="$packaged"
    echo "Using packaged VD_amd_human_only.agi"
  fi

  cp -f "$src" "$dest1"
  cp -f "$src" "$dest2"
  chmod 755 "$dest1" "$dest2"
  sed -i 's/\r$//' "$dest1" "$dest2"
  chown asterisk:asterisk "$dest1" "$dest2" 2>/dev/null || true
  # Also keep packaged copy next to this script for reinstalls
  if [[ -f "$packaged" && "$src" != "$packaged" ]]; then
    :
  elif [[ ! -f "$packaged" ]]; then
    cp -f "$src" "$packaged"
    sed -i 's/\r$//' "$packaged"
  fi
  [[ -n "$tmp" && -f "$tmp" ]] && rm -f "$tmp"
  echo "Installed VD_amd_human_only.agi (system VD_amd.agi untouched)"
}
install_vd_amd_human_only

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

echo "[4/5] Write [openamd-detect] + inject 8398/8399..."
touch "$CUSTOM"
cp -a "$CUSTOM" "${CUSTOM}.bak.lpcurl.$(date +%Y%m%d%H%M%S)"

python3 - <<'PY'
from pathlib import Path
import re

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
; Used by 8399 for HUMAN/PERSON/NOTSURE stock AMD (AIAMD final decide).
; HUMAN -> agent (+ scam on 8399) | MACHINE -> AA hangup |
; UNAVAILABLE/ERROR/FALLBACK/BLANK -> dialplan uses 8398-style hangup (NOT Goto 8369).
;
; IMPORTANT: Do NOT MixMonitor the live SIP/customer channel during AMD.
; MixMonitor-during-AMD + StopMixMonitor broke one-way RX to MeetMe/agent
; (chan_sip audiohook). Agent audio > portal clip quality — reverted.
; Capture for AIAMD second opinion: Answer + Wait(0.8) + Record(8,5).
; Stock AMD() may consume the greeting, so some portal clips can be blank;
; blank/MACHINE/FALLBACK must hang up — never send empty audio to agents.
[openamd-detect]
exten => s,1,NoOp(OpenAMD detect lid=${CHANNEL(linkedid)})
 same => n,Set(OAMD_LID=${CHANNEL(linkedid)})
 same => n,Set(OPENAMD_CALLER=${DB(openamd/${OAMD_LID}/outcid)})
 same => n,Set(OPENAMD_CALLED=${DB(openamd/${OAMD_LID}/lead)})
 same => n,Set(OPENAMD_CAMPAIGN=${IF($["${DB(openamd/${OAMD_LID}/campaign)}"!=""]?${DB(openamd/${OAMD_LID}/campaign)}:${IF($["${ARG1}"!=""]?${ARG1}:${CAMPCUST})})})
 ; Fallback: at 8399 CALLERID(num) is local-presence CID only
 same => n,ExecIf($["${OPENAMD_CALLER}"=""]?Set(OPENAMD_CALLER=${CALLERID(num)}))
 same => n,ExecIf($["${OPENAMD_ID}"=""]?Set(OPENAMD_ID=${EPOCH}-${RAND(10000,99999)}))
 same => n,ExecIf($["${OPENAMD_FILE}"=""]?Set(OPENAMD_FILE=/tmp/openamd-${OPENAMD_ID}))
 same => n,NoOp(OpenAMD detect caller=${OPENAMD_CALLER} called=${OPENAMD_CALLED} camp=${OPENAMD_CAMPAIGN} id=${OPENAMD_ID})
 ; Fast admit ping (~2ms on the local network).
 ; OK -> analyze WAV + portal. DOWN/AUTH/NOKEY/CPS -> FALLBACK (8398-style hangup by 8399).
 same => n,AGI(openamd.agi,ping)
 same => n,GotoIf($["${OPENAMD_PING}" != "OK"]?fallback)
 ; Safe capture: Record on answered channel AFTER stock AMD (no MixMonitor).
 same => n,Answer()
 same => n,Wait(0.8)
 ; Record(file,silence,maxduration): silence must be ABOVE maxduration or a pause
 ; before "hello" ends the file early and the portal marks it BLANK.
 ; 8,5 = always keep 5 seconds (VM greeting + delayed hello).
 same => n,Record(${OPENAMD_FILE}:wav,8,5,q)
 same => n,AGI(openamd.agi,${OPENAMD_ID},${OPENAMD_CAMPAIGN},${OPENAMD_CALLER},${OPENAMD_CALLED})
 same => n,NoOp(OpenAMD status=${OPENAMD_STATUS} conf=${OPENAMD_CONFIDENCE})
 same => n,GotoIf($["${OPENAMD_STATUS}" = "HUMAN"]?human)
 same => n,GotoIf($["${OPENAMD_STATUS}" = "MACHINE"]?machine)
 ; BLANK / UNAVAILABLE / ERROR / anything else → FALLBACK hangup (never agent)
 same => n,Goto(fallback)
 same => n(human),Set(AMDSTATUS=HUMAN)
 same => n,Set(AMDCAUSE=HUMAN)
 same => n,Return()
 same => n(machine),Set(AMDSTATUS=MACHINE)
 same => n,Set(AMDCAUSE=MACHINE)
 same => n,Return()
 same => n(fallback),Set(AMDSTATUS=FALLBACK)
 same => n,Set(AMDCAUSE=OPENAMD_${IF($["${OPENAMD_PING}"!=""]?${OPENAMD_PING}:UNAVAILABLE)})
 same => n,NoOp(OpenAMD FALLBACK — 8399 will use 8398-style hangup reason=${AMDCAUSE})
 same => n,Return()
'''

path.write_text("".join(out).rstrip() + "\n" + block + "\n", encoding="utf-8")
print("Updated [openamd-detect]")

# Clone AMD() application line from live 8369 when possible (labeled AMD step etc.)
def amd_app_from_8369(text: str) -> str:
    """Return AMD() dialplan app token, e.g. 'AMD()' or '(AMD),AMD()'."""
    for line in text.splitlines():
        s = line.strip()
        m = re.match(r'exten\s*=>\s*8369\s*,\s*(?:\d+|n(?:\([^)]*\))?)\s*,\s*(.+)$', s)
        if not m:
            continue
        app = m.group(1).strip()
        # Match AMD() with optional leading label like (AMD),AMD()
        if re.search(r'\bAMD\s*\(', app, re.I):
            return app
    return 'AMD()'

amd_app = 'AMD()'
for conf in (
    '/etc/asterisk/extensions.conf',
    '/etc/asterisk/extensions-vicidial.conf',
    '/etc/asterisk/extensions-custom.conf',
):
    p = Path(conf)
    if p.exists():
        found = amd_app_from_8369(p.read_text(encoding='utf-8', errors='replace'))
        if found != 'AMD()':
            amd_app = found
            print('Cloned 8369 AMD app line: %s' % amd_app)
            break
if amd_app == 'AMD()':
    print('Using default AMD() (no labeled 8369 AMD step found)')

new8398 = '''
; --- OpenAMD 8398 human-only (stock AMD; only HUMAN/PERSON → agent; no scam) ---
exten => 8398,1,AGI(agi://127.0.0.1:4577/call_log)
exten => 8398,n,Playback(sip-silence)
exten => 8398,n,__AMD_APP__
exten => 8398,n,NoOp(8398 human-only AMDSTATUS=${AMDSTATUS} AMDCAUSE=${AMDCAUSE})
exten => 8398,n,AGI(VD_amd_human_only.agi,${EXTEN}-----NO)
exten => 8398,n,AGI(agi-VDAD_ALL_outbound.agi,NORMAL-----LB-----${CONNECTEDLINE(name)})
exten => 8398,n,Hangup()
'''.replace('__AMD_APP__', amd_app)

new8399 = '''
; --- OpenAMD 8399 (stock MACHINE→hangup; HUMAN/PERSON/NOTSURE→AIAMD; AIAMD HUMAN→agent+scam; down→8398 hangup) ---
; NO MixMonitor on the customer SIP channel here. MixMonitor-during-AMD caused
; agent one-way audio (no client voice after StopMixMonitor / MeetMe bridge).
; openamd-detect uses Answer+Wait+Record for the AIAMD clip instead.
exten => 8399,1,AGI(agi://127.0.0.1:4577/call_log)
exten => 8399,n,Playback(sip-silence)
exten => 8399,n,Set(OPENAMD_ID=${EPOCH}-${RAND(10000,99999)})
exten => 8399,n,Set(OPENAMD_FILE=/tmp/openamd-${OPENAMD_ID})
exten => 8399,n,__AMD_APP__
exten => 8399,n,NoOp(8399 stock AMD AMDSTATUS=${AMDSTATUS} AMDCAUSE=${AMDCAUSE})
exten => 8399,n,GotoIf($["${AMDSTATUS}" = "HUMAN"]?aiamd_check)
exten => 8399,n,GotoIf($["${AMDSTATUS}" = "PERSON"]?aiamd_check)
exten => 8399,n,GotoIf($["${AMDSTATUS}" = "NOTSURE"]?aiamd_check)
; MACHINE / HANGUP / TOOLONG / all others → AA hangup (like 8398)
exten => 8399,n,GotoIf($[1]?aa_hangup)
exten => 8399,n(aiamd_check),NoOp(8399 AIAMD final decide)
exten => 8399,n,Gosub(openamd-detect,s,1(${CAMPCUST},))
exten => 8399,n,NoOp(8399 AIAMD AMDSTATUS=${AMDSTATUS} AMDCAUSE=${AMDCAUSE})
exten => 8399,n,GotoIf($["${AMDSTATUS}" = "HUMAN"]?aiamd_human)
; MACHINE or FALLBACK → 8398-style AA hangup
exten => 8399,n,GotoIf($[1]?aa_hangup)
exten => 8399,n(aiamd_human),NoOp(8399 AIAMD HUMAN → agent)
exten => 8399,n,AGI(VD_amd.agi,${EXTEN}-----NO)
exten => 8399,n,AGI(openamd_scam.agi,arm)
exten => 8399,n,AGI(agi-VDAD_ALL_outbound.agi,NORMAL-----LB-----${CONNECTEDLINE(name)})
exten => 8399,n,Hangup()
exten => 8399,n(aa_hangup),NoOp(8399 AA hangup)
exten => 8399,n,ExecIf($["${AMDSTATUS}" != "MACHINE"]?Set(AMDSTATUS=MACHINE))
exten => 8399,n,ExecIf($["${OPENAMD_FILE}"!=""]?System(rm -f ${OPENAMD_FILE}.wav))
exten => 8399,n,AGI(VD_amd_human_only.agi,${EXTEN}-----NO)
exten => 8399,n,Hangup()
'''.replace('__AMD_APP__', amd_app)

def strip_openamd_extens(text: str) -> str:
    """Remove OpenAMD 8389/8397/8398/8399 and leftover exact 138399 Local-hold blocks."""
    lines = text.splitlines(True)
    out = []
    for line in lines:
        s = line.strip()
        if s.startswith('; --- OpenAMD exact 8399'):
            continue
        if s.startswith('; --- OpenAMD 8399'):
            continue
        if s.startswith('; --- OpenAMD 8398'):
            continue
        if s.startswith('; --- OpenAMD 8389'):
            continue
        if s.startswith('; --- OpenAMD 8397'):
            continue
        if s.startswith('; --- OpenAMD local-optimize'):
            continue
        if '138399' in s and s.startswith(';'):
            continue
        if re.match(r'exten\s*=>\s*8399\b', s):
            continue
        if re.match(r'exten\s*=>\s*8398\b', s):
            continue
        if re.match(r'exten\s*=>\s*8397\b', s):
            continue
        if re.match(r'exten\s*=>\s*8389\b', s):
            continue
        if re.match(r'exten\s*=>\s*138399\b', s):
            continue
        out.append(line)
    return ''.join(out)

def inject_openamd_in_default(text: str) -> str:
    """Insert 8398 + 8399 inside [default], after the last 8369 Hangup if present."""
    text = strip_openamd_extens(text)
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
        print('WARNING: [default] / 8369 Hangup not found — appending 8398/8399 at EOF')
    else:
        print('Injecting 8398+8399 at line %d (inside [default]=%s)' % (
            insert_at + 1, 'yes' if start is not None else 'unknown'))
    block = new8398 + new8399
    if not block.endswith('\n'):
        block = block + '\n'
    if not block.startswith('\n'):
        block = '\n' + block
    return ''.join(lines[:insert_at]) + block + ''.join(lines[insert_at:])

# extensions.conf — primary home for 8398/8399
p = Path('/etc/asterisk/extensions.conf')
p.write_text(inject_openamd_in_default(p.read_text(encoding='utf-8', errors='replace')), encoding='utf-8')
print('Wrote extensions 8398 (human-only) + 8399 (AIAMD final); stripped 8389/8397/old 8398/8399/138399 if any')

# Remove conflicting AMD extens from other Asterisk includes (keep OpenAMD ones only)
for other in ('/etc/asterisk/extensions-vicidial.conf', '/etc/asterisk/extensions-custom.conf'):
    op = Path(other)
    if not op.exists():
        continue
    ot = op.read_text(encoding='utf-8', errors='replace')
    nt = strip_openamd_extens(ot)
    # Never strip [openamd-detect] — only bare exten 8389/8397/8398/8399 lines
    if nt != ot:
        op.write_text(nt, encoding='utf-8')
        print('Removed conflicting exten 8389/8397/8398/8399 from %s' % other)
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
perl -c /usr/share/asterisk/agi-bin/VD_amd_human_only.agi 2>/dev/null || true
asterisk -rx "database deltree openamd" >/dev/null 2>&1 || true
asterisk -rx "dialplan reload"

echo ""
asterisk -rx "dialplan show openamd-detect" | head -25
echo ""
echo "=== 8369 (stock AMD — unchanged) ==="
asterisk -rx "dialplan show 8369@default" | head -12
echo ""
echo "=== 8398 (human-only stock AMD; no scam) ==="
asterisk -rx "dialplan show 8398@default" | head -14
echo ""
echo "=== 8399 (stock MACHINE hangup; HUMAN/NOTSURE → AIAMD final) ==="
asterisk -rx "dialplan show 8399@default" | head -28
echo ""
echo "=== 8389 / 8397 (must be absent after strip) ==="
asterisk -rx "dialplan show 8389@default" 2>/dev/null | head -5 || true
asterisk -rx "dialplan show 8397@default" 2>/dev/null | head -5 || true
echo ""
echo "=== 138399 (must be ONLY stock _1383XX Wait(2) — no exact Wait(14400)) ==="
asterisk -rx "dialplan show 138399@default" | head -10

echo ""
echo "DONE."
echo "Campaign AMD extensions:"
echo "  8369 = stock Vicidial AMD (untouched)"
echo "  8398 = human-only (stock AMD; HUMAN/PERSON → agent; no scam)"
echo "  8399 = stock MACHINE→hangup; HUMAN/PERSON/NOTSURE→AIAMD;"
echo "         AIAMD HUMAN→agent+scam; AIAMD down→8398 hangup"
echo ""
echo "Place ONE new call, then:"
echo "  grep 'OpenAMD STORE' /var/log/asterisk/full | tail -5"
echo "  tail -n 5 /tmp/openamd_debug.log"
echo ""
echo "Expect:"
echo "  OpenAMD STORE outcid=<CURL cid> lead=<EXTEN without 9>"
echo "  DB.outcid=... DB.lead=...   (both filled, different)"
