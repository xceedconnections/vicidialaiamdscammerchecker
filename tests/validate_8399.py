#!/usr/bin/env python3
"""Static safety checks for the generated 8399 dialplan."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "agi" / "fix_local_presence_metadata.sh"


def between(text: str, start: str, end: str) -> str:
    return text.split(start, 1)[1].split(end, 1)[0]


text = INSTALLER.read_text(encoding="utf-8")
extension = between(text, "new8399 = '''", "'''.replace('__AMD_APP__', amd_app)")
detect = between(text, "block = r'''", "'''\n\npath.write_text")
steps = [
    "AGI(agi://127.0.0.1:4577/call_log)",
    "Set(OPENAMD_ID=",
    "Set(OPENAMD_FILE=",
    "Monitor(wav,${OPENAMD_FILE})",
    "Playback(sip-silence)",
    "__AMD_APP__",
    "StopMonitor()",
    "Wait(0.8)",
    "Set(OPENAMD_CAPTURED=MONITOR)",
]

positions = [extension.index(step) for step in steps]
assert positions == sorted(positions), "8399 capture/AMD steps are out of order"

dialplan_lines = "\n".join(
    line for line in extension.splitlines() if line.lstrip().startswith("exten =>")
)
assert "MixMonitor(" not in dialplan_lines
assert "StopMixMonitor(" not in dialplan_lines
assert "Record(" not in dialplan_lines, "8399 itself must not Record; openamd-detect may"
assert not re.search(r"Monitor\([^)]*,[^)]*\bb\b[^)]*\)", dialplan_lines)
# No auto-merge "m" — keep -in/-out so AGI can pick the largest artifact
assert "Monitor(wav,${OPENAMD_FILE},m)" not in dialplan_lines

for artifact in (
    "${OPENAMD_FILE}.wav",
    "${OPENAMD_FILE}-in.wav",
    "${OPENAMD_FILE}-out.wav",
):
    assert artifact in extension, f"missing cleanup for {artifact}"

# Stock AMD must gate AIAMD: only HUMAN/PERSON/NOTSURE reach openamd-detect
assert 'GotoIf($["${AMDSTATUS}" = "HUMAN"]?aiamd_check)' in extension
assert "Gosub(openamd-detect,s,1(${CAMPCUST},))" in extension
assert extension.index('GotoIf($["${AMDSTATUS}" = "HUMAN"]?aiamd_check)') < extension.index(
    "Gosub(openamd-detect,s,1(${CAMPCUST},))"
)

# Empty Monitor must Record a real second-opinion clip before analyze AGI
assert "OPENAMD_BYTES" in detect
assert "Record(${OPENAMD_FILE}:wav,4,0,qy)" in detect
assert detect.index("OPENAMD_BYTES") < detect.index("Record(${OPENAMD_FILE}:wav,4,0,qy)")
assert detect.index("Record(${OPENAMD_FILE}:wav,4,0,qy)") < detect.index(
    "AGI(openamd.agi,${OPENAMD_ID}"
)
# Must not skip Record unconditionally just because MONITOR was set
assert 'GotoIf($["${OPENAMD_CAPTURED}" = "MONITOR"]?analyze)' not in detect

print("8399 static validation passed")
