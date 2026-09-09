#!/bin/bash
#
# One-command OpenAMD ViciBox / VICIdial extension 8399 install from GitHub.
# Run as root on ViciBox:
#
#   curl -fsSL https://raw.githubusercontent.com/xceedconnections/vicidialaiamdscammerchecker/main/remote-install.sh | bash -s -- <AI_AMD_BASE> oam_YOUR_API_KEY
#
# AI_AMD_BASE examples:
#   http://aiamd.xceedconnections.com:2130
#   https://aiamd.xceedconnections.com:2130
#   aiamd.xceedconnections.com:2130
#   204.168.200.221:2130
#
set -euo pipefail

AIAMD_RAW="${1:-${AIAMD_URL:-${AIAMD_IP:-}}}"
API_KEY="${2:-${OPENAMD_API_KEY:-}}"

if [[ -z "${AIAMD_RAW}" || -z "${API_KEY}" ]]; then
  echo "Usage:"
  echo "  curl -fsSL https://raw.githubusercontent.com/xceedconnections/vicidialaiamdscammerchecker/main/remote-install.sh | bash -s -- <AI_AMD_BASE> API_KEY"
  echo ""
  echo "Examples:"
  echo "  ... | bash -s -- http://aiamd.xceedconnections.com:2130 oam_xxxxxxxx"
  echo "  ... | bash -s -- 204.168.200.221:2130 oam_xxxxxxxx"
  exit 1
fi

REPO_URL="${OPENAMD_VICI_REPO_URL:-https://github.com/xceedconnections/vicidialaiamdscammerchecker.git}"
BRANCH="${OPENAMD_VICI_BRANCH:-main}"
DEST="${OPENAMD_VICI_DEST:-/root/vicidialaiamdscammerchecker}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

echo "==========================================="
echo " OpenAMD + SCAMMER checker — download + install"
echo " Repo : ${REPO_URL} (${BRANCH})"
echo " Dest : ${DEST}"
echo " AI   : ${AIAMD_RAW}"
echo "==========================================="

if ! command -v git >/dev/null 2>&1; then
  if command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install -y git || true
  elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y git
  fi
fi

rm -rf "${DEST}"
git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${DEST}"

# Normalize CRLF
find "${DEST}" -type f \( -name '*.sh' -o -name '*.agi' -o -name '*.py' \) -exec sed -i 's/\r$//' {} + 2>/dev/null || true

if [[ -f "${DEST}/vicibox_install.sh" ]]; then
  INSTALL_SCRIPT="${DEST}/vicibox_install.sh"
elif [[ -f "${DEST}/vicibox/vicibox_install.sh" ]]; then
  INSTALL_SCRIPT="${DEST}/vicibox/vicibox_install.sh"
else
  echo "ERROR: vicibox_install.sh not found in ${DEST}"
  exit 1
fi

bash "${INSTALL_SCRIPT}" "${AIAMD_RAW}" "${API_KEY}"
