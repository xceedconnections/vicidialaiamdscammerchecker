# VICIdial / ViciBox — OpenAMD + SCAMMER full-call checker

GitHub: https://github.com/xceedconnections/vicidialaiamdscammerchecker

Use this package **only** on dialers that should upload **full agent-leg recordings** for the AIAMD **SCAMMERS** menu.

For normal AMD-only dialers, keep using:

https://github.com/xceedconnections/vicidialaiamd

## Rollback tag

Both repos are tagged `LastUpdatedTechnique` before this hybrid routing change.
Do **not** delete that tag. To roll back a dialer checkout:

```bash
git checkout LastUpdatedTechnique
```

## AMD routing (8369 / 8389 / 8399)

| Extension | Behavior |
|-----------|----------|
| **8369** | Stock Vicidial AMD — **untouched** by this package |
| **8389** | Stock `AMD()` → only **HUMAN/PERSON** → agent; NOTSURE/MACHINE/HANGUP/TOOLONG/all others → AA hangup via `VD_amd_human_only.agi` (never overwrites system `VD_amd.agi`) |
| **8399** | **Hybrid:** stock `AMD()` first. HUMAN/PERSON → agent (+ scam arm). All other stock results → Gosub `openamd-detect` (AIAMD). AIAMD HUMAN → agent (+ scam arm). AIAMD MACHINE or AIAMD down/CPS/FALLBACK → **8389-style AA hangup** (NOT Goto 8369) |

Critical: hybrid **8399 must not Goto 8389** on the AIAMD path (that would hang up before AIAMD runs). It only reuses 8389’s human-only hangup criteria when AIAMD is unavailable or returns MACHINE.

## Campaign settings

Set **AMD / routing extension** to:

- `8389` — human-only stock AMD (no AIAMD)
- `8399` — hybrid (recommended when AIAMD is available)

### WaitForSilence Options

`2000,2,30` is optional Vicidial answering-machine / message-related. It is **not required** for 8389/8399 hybrid routing.

### AMD Agent Route Options — leave DISABLED / blank

When the AMD Agent Route Options container is non-empty, Vicidial’s default `PERSON|HUMAN` agent exit is disabled (unless length &lt; 4). Only matching `STATUS,CAUSE` pairs set `AMD_agent_send`.

Do **not** enable lines such as:

```text
HUMAN,HUMAN
NOTSURE,TOOLONG
MACHINE,INITIALSILENCE
```

Those would send NOTSURE+TOOLONG and MACHINE+INITIALSILENCE to agents — which **breaks 8389 human-only** and fights the 8399 design. Leave **AMD Agent Route Options blank/disabled** for 8389 and 8399.

## What this package adds (SCAM)

After AMD decides **HUMAN** on agent-bound **8399** paths, before the agent script:

```text
AGI(openamd_scam.agi,arm)
```

That AGI:

1. Asks AIAMD `GET /api/v1/scam/config` (portal **SCAM protection** flag on that VICIdial server).
2. If **OFF** → no-op (AMD-only behavior).
3. If **ON** → `MixMonitor` the agent call for up to **`scam_record_seconds`** from the AIAMD portal (default 120; SCAMMER package often uses 60s when configured), then stop recording (call continues). On stop/hangup, `openamd_scam_upload.sh` **HTTP POSTs** the WAV to `/api/v1/scam/recording`.

Scam recording is independent of AMD analyze clips.

## Portal setup

1. Update **aiamdadvanced** and turn **SCAM protection** ON for that VICIdial server.
2. Install this package on that dialer only.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/xceedconnections/vicidialaiamdscammerchecker/main/remote-install.sh | bash -s -- http://aiamd.xceedconnections.com:2130 oam_YOUR_API_KEY
```

Or:

```bash
rm -rf /root/vicidialaiamdscammerchecker
git clone https://github.com/xceedconnections/vicidialaiamdscammerchecker.git /root/vicidialaiamdscammerchecker
find /root/vicidialaiamdscammerchecker -type f \( -name '*.sh' -o -name '*.agi' -o -name '*.py' \) -exec sed -i 's/\r$//' {} +
cd /root/vicidialaiamdscammerchecker
bash vicibox_install.sh http://aiamd.xceedconnections.com:2130 oam_YOUR_API_KEY
```

## New carrier prefixes (automatic)

Install also enables `openamd_auto_store.sh` (cron every minute + optional systemd path).
When VICIdial rebuilds `extensions-vicidial.conf` or you add a new carrier prefix,
OpenAMD STORE (Caller ID / Called Number) is re-applied automatically — no reinstall.

```bash
bash /usr/local/sbin/openamd_auto_store.sh
grep -n 'OpenAMD STORE' /etc/asterisk/extensions-vicidial.conf | head
```

## Verify

```bash
asterisk -rx "dialplan show 8369@default"
asterisk -rx "dialplan show 8389@default"
asterisk -rx "dialplan show 8399@default"
asterisk -rx "dialplan show openamd-detect"
ls -l /var/lib/asterisk/agi-bin/VD_amd_human_only.agi /var/lib/asterisk/agi-bin/VD_amd.agi
```

## Restore AMD-only dialer (no SCAM upload)

Reinstall the normal package (overwrites 8399 human path without scam AGI):

```bash
# from https://github.com/xceedconnections/vicidialaiamd
bash vicibox_install.sh http://aiamd.xceedconnections.com:2130 oam_YOUR_API_KEY
```

And turn **SCAM protection OFF** for that server in the portal.
