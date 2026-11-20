# VICIdial / ViciBox — OpenAMD + SCAMMER full-call checker

GitHub: https://github.com/xceedconnections/vicidialaiamdscammerchecker

Use this package **only** on dialers that should upload **full agent-leg recordings** for the AIAMD **SCAMMERS** menu.

For normal AMD-only dialers, keep using:

https://github.com/xceedconnections/vicidialaiamd

## Rollback tags

Do **not** delete existing tags (including `10-08-2026-Working-STOCK-AIAMD` and `LastUpdatedTechnique`). To roll back a dialer checkout:

```bash
git checkout LastUpdatedTechnique
# or
git checkout 10-08-2026-Working-STOCK-AIAMD
```

## AMD routing (8369 / 8398 / 8399)

| Extension | Behavior |
|-----------|----------|
| **8369** | Stock Vicidial AMD — **untouched** by this package (system `VD_amd.agi` unchanged) |
| **8398** | Stock `AMD()` → only **HUMAN/PERSON** → agent; NOTSURE/MACHINE/HANGUP/TOOLONG/all others → AA hangup via `VD_amd_human_only.agi`. **No scam arm** (same as old 8389). |
| **8399** | Runs the same stock `AMD()` application/parameters cloned from 8369 while standard `Monitor()` captures the greeting. **MACHINE** (and any status that is not HUMAN/PERSON/NOTSURE) → immediate AA hangup. **HUMAN / PERSON / NOTSURE** → `openamd-detect`. AIAMD audible **HUMAN** (recording checked) → agent + scam; audible **MACHINE**, blank, silent, or 0-second capture → AA hangup. AIAMD down/timeout/CPS on a usable recording → trust stock and pass to the agent. A missing recording is never passed through. |

**MixMonitor-during-AMD remains reverted:** attaching `MixMonitor` to the live SIP/customer channel around stock `AMD()`, then `StopMixMonitor`, caused one-way agent audio. 8399 now uses Asterisk's standard channel recorder, `Monitor(wav,${OPENAMD_FILE},m)`, which VICIdial itself uses. It does not use the reverted MixMonitor audiohook.

**Current 8399 capture:** `Monitor()` starts after call logging and capture ID/file setup, before `Playback(sip-silence)` and stock `AMD()`. `StopMonitor()` merges the stream to `/tmp/openamd-ID.wav`; the AGI can use a nonempty split artifact if the merged WAV is unavailable. Capturing concurrently preserves the greeting and adds no post-AMD five-second dead-air window. The 8399 path never falls back to `Answer()`/`Wait()`/`Record()`. Missing, blank, or 0-second capture is AA hangup. A portal outage on a usable recording still trusts stock HUMAN/PERSON/NOTSURE. Scam `MixMonitor` remains independent and arms only after AIAMD HUMAN on the agent-bound path.

Critical: **8399 must not Goto 8369**. Clear MACHINE still AA-hangs. Install strips leftover **8389** and **8397** (and rewrites 8398/8399).

## Campaign settings

Set **AMD / routing extension** to:

- `8398` — human-only stock AMD (no AIAMD, no scam)
- `8399` — AIAMD final decide on HUMAN/NOTSURE (recommended when AIAMD is available; scam on agent path)

### WaitForSilence Options

`2000,2,30` is optional Vicidial answering-machine / message-related. It is **not required** for 8398/8399 routing.

### AMD Agent Route Options — leave DISABLED / blank

When the AMD Agent Route Options container is non-empty, Vicidial’s default `PERSON|HUMAN` agent exit is disabled (unless length &lt; 4). Only matching `STATUS,CAUSE` pairs set `AMD_agent_send`.

Do **not** enable lines such as:

```text
HUMAN,HUMAN
NOTSURE,TOOLONG
MACHINE,INITIALSILENCE
```

Those would send NOTSURE+TOOLONG and MACHINE+INITIALSILENCE to agents — which **breaks 8398 human-only** and fights the 8399 design. Leave **AMD Agent Route Options blank/disabled** for 8398 and 8399.

## What this package adds (SCAM)

After AIAMD decides **HUMAN** on agent-bound **8399** paths, before the agent script:

```text
AGI(openamd_scam.agi,arm)
```

**8398 does not arm scam** (strict human-only → VDAD, like old 8389).

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
asterisk -rx "dialplan show 8398@default"
asterisk -rx "dialplan show 8399@default"
asterisk -rx "dialplan show openamd-detect"
# 8399 output must show Monitor and StopMonitor, with no MixMonitor application.
# openamd-detect must show OPENAMD_CAPTURED compared with MONITOR.
# 8389 / 8397 should be gone after install
asterisk -rx "dialplan show 8389@default"
ls -l /var/lib/asterisk/agi-bin/VD_amd_human_only.agi /var/lib/asterisk/agi-bin/VD_amd.agi
```

## Restore AMD-only dialer (no SCAM upload)

Reinstall the normal package (overwrites 8399 human path without scam AGI):

```bash
# from https://github.com/xceedconnections/vicidialaiamd
bash vicibox_install.sh http://aiamd.xceedconnections.com:2130 oam_YOUR_API_KEY
```

And turn **SCAM protection OFF** for that server in the portal.
