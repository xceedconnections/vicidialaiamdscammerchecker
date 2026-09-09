#!/usr/bin/env python3
"""
Inject OpenAMD AstDB STORE for Caller ID + Called Number on ANY VICIdial
outbound pattern (_8. _9. _87899. _94455. _91NXXNXXXXXX _6. etc.).

Handles both:
  exten => _9.,n,Set(CALLERID(num)=...)
  same => n,Set(CALLERID(num)=...)

Called Number (lead) comes from Dial(...${EXTEN:N}...) when present.
Does NOT change Dial() destinations — only may normalize Dial/Hangup
priority from absolute to 'n' so inserted lines do not collide.
"""
from __future__ import print_function

import re
import sys
from pathlib import Path

DEFAULT_TARGETS = [
    Path("/etc/asterisk/extensions-vicidial.conf"),
    Path("/etc/asterisk/extensions.conf"),
]

EXT_RE = re.compile(
    r"^(?P<ind>\s*)exten\s*=>\s*(?P<pat>_[^,;\s]+)\s*,\s*(?P<pri>[^,\s]+)\s*,\s*(?P<app>.*)$"
)
SAME_RE = re.compile(
    r"^(?P<ind>\s*)same\s*=>\s*(?P<pri>[^,\s]+)\s*,\s*(?P<app>.*)$",
    re.I,
)
CID_RE = re.compile(r"Set\(CALLERID\((num|number)\)\s*=", re.I)
DIAL_RE = re.compile(r"^Dial\b", re.I)
EXTEN_OFF_RE = re.compile(r"\$\{EXTEN:(\d+)(?::\d+)?\}")
EXTEN_FULL_RE = re.compile(r"\$\{EXTEN\}")
# Skip obvious inbound / special contexts patterns we never want
SKIP_PAT_RE = re.compile(
    r"^_(h|i|s|t|e|fax|hang|agent|local)",
    re.I,
)


def lead_from_pattern(pat):
    """Fallback when Dial() has no ${EXTEN:N}."""
    m = re.match(r"_([0-9]+)\.", pat)
    if m:
        return "${EXTEN:%d}" % len(m.group(1))
    m = re.match(r"_([0-9]+)", pat)
    if m:
        return "${EXTEN:%d}" % len(m.group(1))
    return '${IF($["${phone_number}"!=""]?${phone_number}:${EXTEN})}'


def parse_line(line, current_pat):
    """Return (ind, pat, pri, app, kind) or None. kind = exten|same."""
    m = EXT_RE.match(line.rstrip("\n"))
    if m:
        return m.group("ind"), m.group("pat"), m.group("pri"), m.group("app"), "exten"
    m = SAME_RE.match(line.rstrip("\n"))
    if m and current_pat:
        return m.group("ind"), current_pat, m.group("pri"), m.group("app"), "same"
    return None


def find_lead_expr(lines, start_i, pat):
    current = pat
    for j in range(start_i, min(start_i + 40, len(lines))):
        parsed = parse_line(lines[j], current)
        if not parsed:
            # blank / comment — keep scanning a bit
            s = lines[j].strip()
            if not s or s.startswith(";"):
                continue
            if s.startswith("["):
                break
            continue
        ind, p, pri, app, kind = parsed
        if kind == "exten":
            current = p
        if p != pat:
            if j > start_i:
                break
            continue
        if not DIAL_RE.match(app.strip()):
            continue
        off = EXTEN_OFF_RE.search(app)
        if off:
            return "${EXTEN:%s}" % off.group(1), "Dial"
        if EXTEN_FULL_RE.search(app):
            return "${EXTEN}", "Dial"
        if "${phone_number}" in app:
            return "${phone_number}", "Dial"
    return lead_from_pattern(pat), "pattern"


def store_lines(ind, pat, lead, style="exten"):
    """style=exten uses exten => pat,n ; style=same uses same => n."""
    if style == "same":
        pre = "%ssame => n," % ind
    else:
        pre = "%sexten => %s,n," % (ind, pat)
    return [
        pre + "Set(DB(openamd/${CHANNEL(linkedid)}/outcid)=${CALLERID(num)})\n",
        pre + "Set(DB(openamd/${CHANNEL(linkedid)}/lead)=%s)\n" % lead,
        pre
        + 'Set(DB(openamd/${CHANNEL(linkedid)}/campaign)=${IF($["${CAMPCUST}"!=""]?${CAMPCUST}:${campaign})})\n',
        pre
        + "NoOp(OpenAMD STORE outcid=${CALLERID(num)} lead=%s exten=${EXTEN})\n" % lead,
    ]


def already_has_store(lines, i, pat):
    current = pat
    for j in range(i + 1, min(i + 12, len(lines))):
        parsed = parse_line(lines[j], current)
        if parsed:
            _ind, p, _pri, _app, kind = parsed
            if kind == "exten":
                current = p
            if p != pat:
                break
        if "DB(openamd/${CHANNEL(linkedid)}/outcid)" in lines[j]:
            return True
        if "DB(openamd/${CHANNEL(linkedid)}/lead)" in lines[j]:
            return True
        if "NoOp(OpenAMD STORE" in lines[j]:
            return True
    return False


def normalize_following_dial(lines, i, pat):
    j = i + 1
    current = pat
    while j < len(lines):
        parsed = parse_line(lines[j], current)
        if not parsed:
            s = lines[j].strip()
            if not s or s.startswith(";"):
                j += 1
                continue
            break
        ind, p, pri, app, kind = parsed
        if kind == "exten":
            current = p
        if p != pat:
            break
        if pri != "n" and re.match(r"^(Dial|Hangup)\b", app, re.I):
            if kind == "same":
                lines[j] = "%ssame => n,%s\n" % (ind, app)
            else:
                lines[j] = "%sexten => %s,n,%s\n" % (ind, pat, app)
            print("  normalized %s priority %s -> n" % (pat, pri))
        elif pri != "n":
            break
        j += 1


def is_outbound_pat(pat):
    if not pat or not pat.startswith("_"):
        return False
    if SKIP_PAT_RE.match(pat):
        return False
    # Must look like a dial prefix (digits / NXZ / .)
    return bool(re.match(r"^_[0-9NXZ\.\[\]\-]+", pat, re.I))


def looks_outbound_dial(app):
    app = app.strip()
    if not DIAL_RE.match(app):
        return False
    if EXTEN_OFF_RE.search(app) or EXTEN_FULL_RE.search(app):
        return True
    if "${phone_number}" in app:
        return True
    # Dial(SIP/trunk/1415...) absolute — still outbound if SIP/IAX/PJSIP
    if re.search(r"Dial\((SIP|PJSIP|IAX2|DAHDI|Local)/", app, re.I):
        return "EXTEN" in app or "phone_number" in app
    return False


def inject_file(path):
    if not path.exists():
        print("SKIP (missing): %s" % path)
        return 0, []

    original = path.read_text(encoding="utf-8", errors="replace")
    lines = original.splitlines(True)
    out = []
    injected = 0
    patterns = []
    current_pat = None
    i = 0
    while i < len(lines):
        line = lines[i]
        parsed = parse_line(line, current_pat)
        if parsed:
            ind, pat, pri, app, kind = parsed
            if kind == "exten":
                current_pat = pat
            if is_outbound_pat(pat) and CID_RE.search(app):
                out.append(line)
                if not already_has_store(lines, i, pat):
                    lead, src = find_lead_expr(lines, i, pat)
                    style = "same" if kind == "same" else "exten"
                    # After same => CID, continue with same => store lines
                    # After exten => CID, use exten => pat,n store lines
                    out.extend(store_lines(ind, pat, lead, style=style))
                    injected += 1
                    patterns.append(
                        "%s:%s -> lead=%s (from %s, after CALLERID)"
                        % (path.name, pat, lead, src)
                    )
                    normalize_following_dial(lines, i, pat)
                i += 1
                continue
        out.append(line)
        i += 1

    # Second pass: Dial with EXTEN / phone_number and no STORE yet
    lines2 = out
    out = []
    current_pat = None
    i = 0
    while i < len(lines2):
        line = lines2[i]
        parsed = parse_line(line, current_pat)
        if parsed:
            ind, pat, pri, app, kind = parsed
            if kind == "exten":
                current_pat = pat
            if is_outbound_pat(pat) and looks_outbound_dial(app):
                has = False
                for k in range(len(out) - 1, max(-1, len(out) - 30), -1):
                    pk = parse_line(out[k], pat)
                    if pk:
                        _i, p, _pr, _a, kd = pk
                        if kd == "exten" and p != pat:
                            break
                        if p != pat and kd == "exten":
                            break
                    if "DB(openamd/${CHANNEL(linkedid)}/lead)" in out[k]:
                        has = True
                        break
                    if "NoOp(OpenAMD STORE" in out[k]:
                        has = True
                        break
                if not has:
                    lead, src = find_lead_expr(lines2, i, pat)
                    style = "same" if kind == "same" else "exten"
                    for sl in store_lines(ind, pat, lead, style=style):
                        out.append(sl)
                    injected += 1
                    patterns.append(
                        "%s:%s -> lead=%s (from %s, pre-Dial)"
                        % (path.name, pat, lead, src)
                    )
        out.append(line)
        i += 1

    new_text = "".join(out)
    changed = new_text != original
    if changed:
        path.write_text(new_text, encoding="utf-8")
    return injected, patterns, changed


def diagnose(path):
    """Print hints when nothing was injected."""
    if not path.exists():
        return
    text = path.read_text(encoding="utf-8", errors="replace")
    cid = len(re.findall(r"Set\(CALLERID\((num|number)\)\s*=", text, re.I))
    dial = len(re.findall(r"exten\s*=>\s*_[^,]+,.*,\s*Dial\(", text, re.I))
    dial_same = len(re.findall(r"same\s*=>\s*[^,]+,\s*Dial\(", text, re.I))
    pats = sorted(set(re.findall(r"exten\s*=>\s*(_[^,;\s]+)", text)))
    print("  diagnose %s: CALLERID(num) lines=%d Dial(exten)=%d Dial(same)=%d" % (
        path.name, cid, dial, dial_same
    ))
    if pats[:20]:
        print("  patterns sample: %s" % ", ".join(pats[:20]))


def inject(paths=None, quiet=False):
    targets = list(paths) if paths else list(DEFAULT_TARGETS)
    total = 0
    changed_any = False
    all_patterns = []
    for path in targets:
        n, pats, changed = inject_file(path)
        total += n
        changed_any = changed_any or changed
        all_patterns.extend(pats)

    if quiet:
        if total:
            print("Injected AstDB store on %d outbound pattern(s)" % total)
            for p in all_patterns:
                print("  %s" % p)
        return total, changed_any

    print("Injected AstDB store on %d outbound pattern(s)" % total)
    for p in all_patterns:
        print("  %s" % p)
    if total == 0:
        # Already covered vs truly missing
        has_store = False
        for path in targets:
            if path.exists() and "NoOp(OpenAMD STORE" in path.read_text(
                encoding="utf-8", errors="replace"
            ):
                has_store = True
                break
        if has_store:
            print("OK: outbound patterns already have OpenAMD STORE (nothing new).")
        else:
            print("WARNING: No outbound Set(CALLERID)/Dial patterns found to inject.")
            for path in targets:
                diagnose(path)
            print(
                "Called Number needs an outbound dialplan entry with "
                "Set(CALLERID) or Dial(${EXTEN:N})."
            )
    return total, changed_any


def main():
    args = [a for a in sys.argv[1:] if a != "--quiet"]
    quiet = "--quiet" in sys.argv[1:]
    if args:
        targets = [Path(a) for a in args]
        n, changed = inject(targets, quiet=quiet)
    else:
        n, changed = inject(quiet=quiet)
    # Exit 0 always for cron; print changed marker for wrappers
    if quiet and changed:
        print("CHANGED")
    sys.exit(0)


if __name__ == "__main__":
    main()
