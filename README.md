# VICIdial / ViciBox — OpenAMD + SCAMMER full-call checker

GitHub: https://github.com/xceedconnections/vicidialaiamdscammerchecker

Use this package **only** on dialers that should upload **full agent-leg recordings** for the AIAMD **SCAMMERS** menu.

For normal AMD-only dialers, keep using:

https://github.com/xceedconnections/vicidialaiamd

## What stays the same

- Extension **8399** AMD flow is unchanged (admit → short Record → analyze → HUMAN/MACHINE/8369).
- Caller ID / Called Number AstDB inject is the same.

## What this package adds

After AMD decides **HUMAN**, before the agent script:

```text
AGI(openamd_scam.agi,arm)
```

That AGI:

1. Asks AIAMD `GET /api/v1/scam/config` (portal **SCAM protection** flag on that VICIdial server).
2. If **OFF** → no-op (AMD-only behavior).
3. If **ON** → `MixMonitor` full agent call → on hangup, `openamd_scam_upload.sh` **HTTP POSTs** the WAV to `/api/v1/scam/recording` on port **2130** (same outbound path as AMD — not file sync).

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

Campaign AMD extension remains **8399**.

## Restore AMD-only dialer (no SCAM upload)

Reinstall the normal package (overwrites 8399 human path without scam AGI):

```bash
# from https://github.com/xceedconnections/vicidialaiamd
bash vicibox_install.sh http://aiamd.xceedconnections.com:2130 oam_YOUR_API_KEY
```

And turn **SCAM protection OFF** for that server in the portal.
