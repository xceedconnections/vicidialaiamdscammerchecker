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
| **8399** | **Stock `AMD()` first** (same app/params as 8369). **MACHINE** (and any status that is not HUMAN/PERSON/NOTSURE) → immediate AA hangup — nothing is posted to AIAMD. **HUMAN / PERSON / NOTSURE** → ensure a real WAV exists → POST to AIAMD for double-check. AIAMD **HUMAN** → agent + scam; **MACHINE / BLANK / FAX / silent** → AA hangup. AIAMD down/timeout/CPS on a usable recording → trust stock and pass to the agent. |

**MixMonitor-during-AMD remains reverted:** attaching `MixMonitor` around stock `AMD()` caused one-way agent audio. 8399 uses `TryExec(Monitor(wav,${OPENAMD_FILE}))` (no auto-merge `m`) during AMD so `-in`/`-out` survive for the AGI. Bare `Monitor()` is wrapped in `TryExec` so a failed Monitor (cannot open files / already monitored) does **not** abort the dialplan — that used to cause Vicidial **NA** while the SIP trunk stayed up with no AIAMD POST.

**Current 8399 capture:**
1. `TryExec(Monitor(...))` starts before stock `AMD()` to catch the greeting; `TryExec(StopMonitor())` + short `Wait(0.2)` after AMD.
2. Stock AMD decides. Non-human → AA (temp files deleted; no portal POST).
3. Human path → `openamd-detect` measures Monitor bytes. If the largest artifact is under ~2KB (0s / header-only), it `Record()`s a hard-capped **4s** clip: `Record(...,8,4,qy)` (silence 8 > max 4). Never use `maxduration=0` — continuous fax/tone never ends, SIP orphans, Vicidial times out as NA, portal never sees the call.
4. AGI posts the largest WAV to AIAMD. Portal decides HUMAN / BLANK / VM / FAX — it never invents audio from stock AMD alone.

Scam `MixMonitor` remains independent and arms only after AIAMD HUMAN on the agent-bound path.

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

First-time install is always via PuTTY (enter the `oam_…` key there). After that, use the browser updater (no SSH):

```text
http://YOUR_DIALER_IP/update.php
```

The page shows the **installed OAM key**, lets you **change the key**, and **Update AGI from GitHub** when a newer commit is available (pulls + refreshes AGI scripts using the existing or new key — does not rewrite dialplan).

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
# 8399 output must show TryExec(Monitor/StopMonitor) and OPENAMD_CAPTURED=MONITOR (no MixMonitor).
# openamd-detect must show OPENAMD_BYTES + Record(...,8,4,qy) hard-capped fallback.
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
