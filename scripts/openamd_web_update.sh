#!/bin/bash
#
# Root helper for /srv/www/htdocs/update.php
# First install is always via PuTTY (vicibox_install.sh + oam_ key).
# This helper only: show status/key, change key, pull GitHub + refresh AGIs.
#
# Usage: openamd_web_update.sh status|set_key|apply [new_api_key]
#
set -euo pipefail

CMD="${1:-status}"
NEW_KEY="${2:-}"
REPO="${OPENAMD_GITHUB_REPO:-xceedconnections/vicidialaiamdscammerchecker}"
BRANCH="${OPENAMD_GITHUB_BRANCH:-main}"
CONF="/etc/asterisk/openamd.conf"
LOCK="/var/lock/openamd_web_update.lock"
LOG_DIR="/var/log/openamd"
AGI1="/usr/share/asterisk/agi-bin"
AGI2="/var/lib/asterisk/agi-bin"
mkdir -p "${LOG_DIR}" 2>/dev/null || true

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1" 2>/dev/null \
    || printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

read_conf() {
  [[ -f "${CONF}" ]] || return 1
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "${CONF}"
  set +a
  REPO="${OPENAMD_GITHUB_REPO:-${REPO}}"
  BRANCH="${OPENAMD_GITHUB_BRANCH:-${BRANCH}}"
  return 0
}

find_source_dir() {
  local c
  if [[ -n "${OPENAMD_SOURCE_DIR:-}" && -d "${OPENAMD_SOURCE_DIR}/.git" ]]; then
    echo "${OPENAMD_SOURCE_DIR}"
    return 0
  fi
  for c in \
    /root/vicidialaiamdscammerchecker \
    /root/vicidialaiamd \
    /usr/local/src/vicidialaiamdscammerchecker
  do
    if [[ -d "${c}/.git" ]]; then
      echo "${c}"
      return 0
    fi
  done
  return 1
}

write_api_key() {
  local key="$1"
  [[ -n "${key}" ]] || return 1
  if [[ ! -f "${CONF}" ]]; then
    echo '{"ok":false,"error":"Missing /etc/asterisk/openamd.conf — install once via PuTTY first."}'
    exit 1
  fi
  if grep -qE '^\s*OPENAMD_API_KEY=' "${CONF}"; then
    sed -i "s|^[[:space:]]*OPENAMD_API_KEY=.*|OPENAMD_API_KEY=${key}|" "${CONF}"
  else
    printf '\nOPENAMD_API_KEY=%s\n' "${key}" >>"${CONF}"
  fi
  chmod 640 "${CONF}" 2>/dev/null || true
}

gh_latest() {
  local api body
  api="https://api.github.com/repos/${REPO}/commits/${BRANCH}"
  body="$(curl -fsS --max-time 12 \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: openamd-web-update" \
    "${api}" 2>/dev/null || true)"
  if [[ -z "${body}" && "${BRANCH}" == "main" ]]; then
    BRANCH="master"
    api="https://api.github.com/repos/${REPO}/commits/${BRANCH}"
    body="$(curl -fsS --max-time 12 \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: openamd-web-update" \
      "${api}" 2>/dev/null || true)"
  fi
  printf '%s' "${body}"
}

install_agi_files() {
  local src="$1"
  local agi_dir="" f name dest
  mkdir -p "${AGI1}" "${AGI2}"

  if [[ -d "${src}/agi" ]]; then
    agi_dir="${src}/agi"
  else
    agi_dir="${src}"
  fi

  for name in openamd.agi VD_amd_human_only.agi openamd_scam.agi; do
    f="${agi_dir}/${name}"
    [[ -f "${f}" ]] || continue
    sed -i 's/\r$//' "${f}" 2>/dev/null || true
    for dest in "${AGI1}/${name}" "${AGI2}/${name}"; do
      cp -f "${f}" "${dest}"
      chmod 755 "${dest}"
      chown asterisk:asterisk "${dest}" 2>/dev/null || true
    done
    echo "installed ${name}"
  done

  # scam upload helper (shell, not AGI, but used by scam path)
  if [[ -f "${agi_dir}/openamd_scam_upload.sh" ]]; then
    sed -i 's/\r$//' "${agi_dir}/openamd_scam_upload.sh" 2>/dev/null || true
    for dest in "${AGI1}/openamd_scam_upload.sh" "${AGI2}/openamd_scam_upload.sh"; do
      cp -f "${agi_dir}/openamd_scam_upload.sh" "${dest}"
      chmod 755 "${dest}"
      chown asterisk:asterisk "${dest}" 2>/dev/null || true
    done
    echo "installed openamd_scam_upload.sh"
  fi

  if [[ -f "${AGI1}/openamd.agi" ]]; then
    perl -c "${AGI1}/openamd.agi" >/dev/null
  else
    echo "ERROR: openamd.agi missing after copy" >&2
    return 1
  fi
}

refresh_web_updater() {
  local src="$1"
  local htdocs=""
  if [[ -f "${src}/scripts/openamd_web_update.sh" ]]; then
    sed -i 's/\r$//' "${src}/scripts/openamd_web_update.sh" 2>/dev/null || true
    install -m 755 -o root -g root "${src}/scripts/openamd_web_update.sh" /usr/local/sbin/openamd_web_update.sh
  fi
  for htdocs in /srv/www/htdocs /var/www/html; do
    if [[ -d "${htdocs}" && -f "${src}/www/update.php" ]]; then
      sed -i 's/\r$//' "${src}/www/update.php" 2>/dev/null || true
      install -m 644 "${src}/www/update.php" "${htdocs}/update.php"
      echo "refreshed ${htdocs}/update.php"
      break
    fi
  done
}

cmd_status() {
  local src="" local_full="" local_short="" local_date="" local_msg=""
  local remote_json="" remote_full="" remote_short="" remote_date="" remote_msg=""
  local behind=false err="" key="" analyze="" base=""

  if ! read_conf; then
    err="Missing /etc/asterisk/openamd.conf — run vicibox_install.sh once via PuTTY first."
  else
    key="${OPENAMD_API_KEY:-}"
    analyze="${OPENAMD_URL:-}"
    base="$(printf '%s' "${analyze}" | sed -E 's#/api/v1/analyze/?$##')"
  fi

  if ! src="$(find_source_dir)"; then
    [[ -z "${err}" ]] && err="Source git checkout not found under /root/vicidialaiamdscammerchecker"
  else
    local_full="$(git -C "${src}" rev-parse HEAD 2>/dev/null || true)"
    local_short="$(git -C "${src}" rev-parse --short HEAD 2>/dev/null || true)"
    local_date="$(git -C "${src}" log -1 --format='%cI' 2>/dev/null || true)"
    local_msg="$(git -C "${src}" log -1 --format='%s' 2>/dev/null || true)"
  fi

  remote_json="$(gh_latest || true)"
  if [[ -n "${remote_json}" ]]; then
    remote_full="$(printf '%s' "${remote_json}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("sha",""))' 2>/dev/null || true)"
    remote_short="${remote_full:0:7}"
    remote_date="$(printf '%s' "${remote_json}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(((d.get("commit") or {}).get("committer") or {}).get("date",""))' 2>/dev/null || true)"
    remote_msg="$(printf '%s' "${remote_json}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(((d.get("commit") or {}).get("message","") or "").splitlines()[0] if d.get("commit") else "")' 2>/dev/null || true)"
  else
    [[ -z "${err}" ]] && err="Could not reach GitHub API for ${REPO}"
  fi

  if [[ -n "${local_full}" && -n "${remote_full}" && "${local_full}" != "${remote_full}" ]]; then
    behind=true
  fi

  local ok=true
  if [[ -z "${key}" || -z "${local_full}" ]]; then
    ok=false
  fi

  printf '{'
  printf '"ok":%s,' "${ok}"
  printf '"api_key":%s,' "$(json_escape "${key}")"
  printf '"analyze_url":%s,' "$(json_escape "${analyze}")"
  printf '"base_url":%s,' "$(json_escape "${base}")"
  printf '"repo":%s,' "$(json_escape "${REPO}")"
  printf '"branch":%s,' "$(json_escape "${BRANCH}")"
  printf '"source_dir":%s,' "$(json_escape "${src}")"
  printf '"local_commit":%s,' "$(json_escape "${local_short}")"
  printf '"local_full":%s,' "$(json_escape "${local_full}")"
  printf '"local_date":%s,' "$(json_escape "${local_date}")"
  printf '"local_message":%s,' "$(json_escape "${local_msg}")"
  printf '"remote_commit":%s,' "$(json_escape "${remote_short}")"
  printf '"remote_full":%s,' "$(json_escape "${remote_full}")"
  printf '"remote_date":%s,' "$(json_escape "${remote_date}")"
  printf '"remote_message":%s,' "$(json_escape "${remote_msg}")"
  printf '"update_available":%s,' "${behind}"
  printf '"error":%s' "$(json_escape "${err}")"
  printf '}\n'
}

cmd_set_key() {
  local key="${NEW_KEY}"
  if [[ -z "${key}" ]]; then
    echo '{"ok":false,"error":"New API key required"}'
    exit 1
  fi
  if [[ ! "${key}" =~ ^oam_ ]]; then
    echo '{"ok":false,"error":"Key should look like oam_…"}'
    exit 1
  fi
  write_api_key "${key}"
  printf '{"ok":true,"api_key":%s,"message":"API key saved to openamd.conf"}\n' "$(json_escape "${key}")"
}

cmd_apply() {
  read_conf || {
    echo '{"ok":false,"error":"Missing /etc/asterisk/openamd.conf — install once via PuTTY first."}'
    exit 1
  }

  local src key
  key="${OPENAMD_API_KEY:-}"
  if [[ -n "${NEW_KEY}" ]]; then
    if [[ ! "${NEW_KEY}" =~ ^oam_ ]]; then
      echo '{"ok":false,"error":"Key should look like oam_…"}'
      exit 1
    fi
    write_api_key "${NEW_KEY}"
    key="${NEW_KEY}"
    OPENAMD_API_KEY="${key}"
  fi

  if [[ -z "${key}" ]]; then
    echo '{"ok":false,"error":"No OPENAMD_API_KEY in openamd.conf"}'
    exit 1
  fi

  if ! src="$(find_source_dir)"; then
    echo '{"ok":false,"error":"Source git checkout not found. Clone to /root/vicidialaiamdscammerchecker via PuTTY first."}'
    exit 1
  fi

  exec 9>"${LOCK}"
  if ! flock -n 9; then
    echo '{"ok":false,"error":"Update already in progress"}'
    exit 1
  fi

  local logf="${LOG_DIR}/web_update_$(date +%Y%m%d_%H%M%S).log"
  {
    echo "=== OpenAMD AGI web update $(date -Is) ==="
    echo "source=${src}"
    echo "repo=${REPO} branch=${BRANCH}"
    echo "api_key=${key}"
    cd "${src}"
    git remote set-url origin "https://github.com/${REPO}.git" 2>/dev/null || \
      git remote add origin "https://github.com/${REPO}.git" 2>/dev/null || true
    git fetch --prune origin
    if git show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; then
      git checkout -B "${BRANCH}" "origin/${BRANCH}"
      git reset --hard "origin/${BRANCH}"
    elif git show-ref --verify --quiet refs/remotes/origin/master; then
      BRANCH=master
      git checkout -B master origin/master
      git reset --hard origin/master
    else
      echo "ERROR: origin/${BRANCH} (and origin/master) not found after fetch"
      exit 1
    fi
    echo "HEAD=$(git rev-parse --short HEAD) $(git log -1 --format='%s')"
    find "${src}" -type f \( -name '*.sh' -o -name '*.agi' -o -name '*.py' -o -name '*.php' \) -exec sed -i 's/\r$//' {} + 2>/dev/null || true
    install_agi_files "${src}"
    refresh_web_updater "${src}"
    # Keep conf key in sync (URL unchanged)
    write_api_key "${key}"
    echo "=== AGI update done (dialplan not rewritten) ==="
  } >"${logf}" 2>&1
  local rc=$?

  local_full="$(git -C "${src}" rev-parse HEAD 2>/dev/null || true)"
  local_short="$(git -C "${src}" rev-parse --short HEAD 2>/dev/null || true)"
  local_msg="$(git -C "${src}" log -1 --format='%s' 2>/dev/null || true)"
  local tail_txt
  tail_txt="$(tail -n 80 "${logf}" 2>/dev/null || true)"

  if [[ ${rc} -ne 0 ]]; then
    printf '{"ok":false,"error":"AGI update failed (see log)","api_key":%s,"log_file":%s,"log":%s,"local_commit":%s}\n' \
      "$(json_escape "${key}")" "$(json_escape "${logf}")" "$(json_escape "${tail_txt}")" "$(json_escape "${local_short}")"
    exit 1
  fi

  printf '{"ok":true,"api_key":%s,"local_commit":%s,"local_full":%s,"local_message":%s,"log_file":%s,"log":%s}\n' \
    "$(json_escape "${key}")" \
    "$(json_escape "${local_short}")" \
    "$(json_escape "${local_full}")" \
    "$(json_escape "${local_msg}")" \
    "$(json_escape "${logf}")" \
    "$(json_escape "${tail_txt}")"
}

case "${CMD}" in
  status)  cmd_status ;;
  set_key) cmd_set_key ;;
  apply)   cmd_apply ;;
  *)
    echo '{"ok":false,"error":"Usage: openamd_web_update.sh status|set_key|apply [api_key]"}'
    exit 1
    ;;
esac
