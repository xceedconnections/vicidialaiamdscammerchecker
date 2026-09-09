# VICIdial / ViciBox — OpenAMD dialer installer

GitHub: https://github.com/xceedconnections/vicidialaiamd

Installs AGI + extension **8399** + Caller ID / Called Number capture on ViciBox.

## One-command install (root on ViciBox)

Pass the AI AMD **base** as IP, domain, or full `http://` / `https://` URL:

```bash
curl -fsSL https://raw.githubusercontent.com/xceedconnections/vicidialaiamd/main/remote-install.sh | bash -s -- https://aiamd.xceedconnections.com oam_YOUR_API_KEY
```

```bash
curl -fsSL https://raw.githubusercontent.com/xceedconnections/vicidialaiamd/main/remote-install.sh | bash -s -- http://aiamd.xceedconnections.com oam_YOUR_API_KEY
```

```bash
curl -fsSL https://raw.githubusercontent.com/xceedconnections/vicidialaiamd/main/remote-install.sh | bash -s -- 204.168.200.221 oam_YOUR_API_KEY
```

Bare IP/domain defaults to **http://**. Prefer **https://your-domain** when TLS is configured (certs rarely match raw IPs).

## Already cloned

```bash
bash /root/vicidialaiamd/vicibox_install.sh https://aiamd.xceedconnections.com oam_YOUR_API_KEY
bash /root/vicidialaiamd/vicibox_install.sh http://aiamd.xceedconnections.com oam_YOUR_API_KEY
bash /root/vicidialaiamd/vicibox_install.sh 204.168.200.221 oam_YOUR_API_KEY
```

## Campaign setting

Set VICIdial campaign AMD / routing extension to: **8399**

## What gets written

`/etc/asterisk/openamd.conf` example:

```text
OPENAMD_URL=https://aiamd.xceedconnections.com/api/v1/analyze
OPENAMD_API_KEY=oam_...
OPENAMD_AI_IP=aiamd.xceedconnections.com
OPENAMD_SSL_VERIFY=1
```

For a bare IP, `OPENAMD_SSL_VERIFY=0` so HTTPS redirects / IP certs still work.

## Layout

```text
vicibox_install.sh              # main installer (runs restore + fix_caller_called)
remote-install.sh               # curl | bash entry
agi/openamd.agi                 # AGI (http + https)
agi/fix_local_presence_metadata.sh   # called by installer
agi/restore_vicidial_dialplan.sh      # called by installer
fix_caller_called.sh                 # called by installer
```

One `vicibox_install.sh` run is enough: it restores a clean dialplan, installs
exact **8399**, and injects Caller ID / Called Number for any campaign or
carrier dial prefix. You do **not** need to run the helper scripts afterward.

## Re-run after VICIdial rebuilds dialplan

```bash
bash /root/vicidialaiamd/vicibox_install.sh https://aiamd.xceedconnections.com oam_YOUR_API_KEY
```
