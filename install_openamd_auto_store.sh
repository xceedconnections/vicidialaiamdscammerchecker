#!/bin/bash
# Install / update the OpenAMD auto-STORE watcher (cron every minute).
# Called from vicibox_install.sh — keeps Caller ID / Called Number working
# when admins add new carrier prefixes AFTER the initial install.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARE="/usr/local/share/openamd"
SBIN="/usr/local/sbin"
CRON_FILE="/etc/cron.d/openamd-auto-store"

mkdir -p "$SHARE" "$SBIN"

INJECT_SRC=""
for c in \
  "${SCRIPT_DIR}/inject_called_number.py" \
  "${SCRIPT_DIR}/../inject_called_number.py"
do
  if [[ -f "$c" ]]; then INJECT_SRC="$c"; break; fi
done
[[ -n "$INJECT_SRC" ]] || {
  echo "ERROR: inject_called_number.py not found next to installer"
  exit 1
}

AUTO_SRC=""
for c in \
  "${SCRIPT_DIR}/openamd_auto_store.sh" \
  "${SCRIPT_DIR}/../openamd_auto_store.sh"
do
  if [[ -f "$c" ]]; then AUTO_SRC="$c"; break; fi
done
[[ -n "$AUTO_SRC" ]] || {
  echo "ERROR: openamd_auto_store.sh not found"
  exit 1
}

cp -f "$INJECT_SRC" "${SHARE}/inject_called_number.py"
cp -f "$AUTO_SRC" "${SBIN}/openamd_auto_store.sh"
chmod 755 "${SBIN}/openamd_auto_store.sh"
sed -i 's/\r$//' "${SHARE}/inject_called_number.py" "${SBIN}/openamd_auto_store.sh" 2>/dev/null || true

cat >"$CRON_FILE" <<'EOF'
# OpenAMD — auto-inject Caller ID / Called Number STORE on new VICIdial prefixes
# Runs every minute; no-op unless extensions-vicidial.conf gained new carriers.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
* * * * * root /usr/local/sbin/openamd_auto_store.sh
EOF
chmod 644 "$CRON_FILE"
sed -i 's/\r$//' "$CRON_FILE" 2>/dev/null || true

# Optional systemd path unit (fires immediately when VICIdial rewrites the file)
if command -v systemctl >/dev/null 2>&1 && [[ -d /etc/systemd/system ]]; then
  cat >/etc/systemd/system/openamd-auto-store.service <<EOF
[Unit]
Description=OpenAMD auto-inject STORE for new VICIdial prefixes
After=asterisk.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openamd_auto_store.sh
EOF

  cat >/etc/systemd/system/openamd-auto-store.path <<'EOF'
[Unit]
Description=Watch VICIdial dialplan for OpenAMD STORE auto-inject

[Path]
PathChanged=/etc/asterisk/extensions-vicidial.conf
PathModified=/etc/asterisk/extensions-vicidial.conf

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now openamd-auto-store.path >/dev/null 2>&1 || true
fi

# Run once now
/usr/local/sbin/openamd_auto_store.sh || true

echo "Installed OpenAMD auto-STORE watcher:"
echo "  cron : ${CRON_FILE} (every minute)"
echo "  script: ${SBIN}/openamd_auto_store.sh"
echo "  inject: ${SHARE}/inject_called_number.py"
echo " New carrier prefixes get Caller ID / Called Number STORE automatically."
