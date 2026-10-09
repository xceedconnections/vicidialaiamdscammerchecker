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
    "Monitor(wav,${OPENAMD_FILE},m)",
    "Playback(sip-silence)",
    "__AMD_APP__",
    "StopMonitor()",
    "Wait(0.2)",
    "Set(OPENAMD_CAPTURED=MONITOR)",
]

positions = [extension.index(step) for step in steps]
assert positions == sorted(positions), "8399 capture/AMD steps are out of order"

dialplan_lines = "\n".join(
    line for line in extension.splitlines() if line.lstrip().startswith("exten =>")
)
assert "MixMonitor(" not in dialplan_lines
assert "StopMixMonitor(" not in dialplan_lines
assert "Record(" not in dialplan_lines, "8399 must not record after AMD"
assert not re.search(r"Monitor\([^)]*,[^)]*\bb\b[^)]*\)", dialplan_lines)

for artifact in (
    "${OPENAMD_FILE}.wav",
    "${OPENAMD_FILE}-in.wav",
    "${OPENAMD_FILE}-out.wav",
):
    assert artifact in extension, f"missing cleanup for {artifact}"

assert '${OPENAMD_CAPTURED}" = "MONITOR"' in detect
assert detect.index('${OPENAMD_CAPTURED}" = "MONITOR"') < detect.index("Record(")
print("8399 static validation passed")
