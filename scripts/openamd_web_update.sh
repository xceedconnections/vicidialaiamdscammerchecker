#!/bin/bash
#
# Root helper for /srv/www/htdocs/update.php
# Usage: openamd_web_update.sh status|apply
# Invoked via: sudo -n /usr/local/sbin/openamd_web_update.sh <cmd>
#
set -euo pipefail

CMD="${1:-status}"
PROVIDED_KEY="${2:-}"
REPO="${OPENAMD_GITHUB_REPO:-xceedconnections/vicidialaiamdscammerchecker}"
BRANCH="${OPENAMD_GITHUB_BRANCH:-main}"
CONF="/etc/asterisk/openamd.conf"
LOCK="/var/lock/openamd_web_update.lock"
LOG_DIR="/var/log/openamd"
mkdir -p "${LOG_DIR}" 2>/dev/null || true

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1" 2>/dev/null \
    || printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

require_key() {
  read_conf || {
    echo '{"ok":false,"error":"Missing /etc/asterisk/openamd.conf"}'
    exit 1
  }
  local expected="${OPENAMD_API_KEY:-}"
  if [[ -z "${expected}" ]]; then
    echo '{"ok":false,"error":"OPENAMD_API_KEY empty in openamd.conf"}'
    exit 1
  fi
  if [[ -z "${PROVIDED_KEY}" || "${PROVIDED_KEY}" != "${expected}" ]]; then
    echo '{"ok":false,"error":"Unauthorized — invalid API key"}'
    exit 1
  fi
  REPO="${OPENAMD_GITHUB_REPO:-${REPO}}"
  BRANCH="${OPENAMD_GITHUB_BRANCH:-${BRANCH}}"
}

read_conf() {
  [[ -f "${CONF}" ]] || return 1
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "${CONF}"
  set +a
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

gh_latest() {
  local api url
  api="https://api.github.com/repos/${REPO}/commits/${BRANCH}"
  url="$(curl -fsS --max-time 12 \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: openamd-web-update" \
    "${api}" 2>/dev/null || true)"
  if [[ -z "${url}" && "${BRANCH}" == "main" ]]; then
    api="https://api.github.com/repos/${REPO}/commits/master"
    url="$(curl -fsS --max-time 12 \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: openamd-web-update" \
      "${api}" 2>/dev/null || true)"
    BRANCH="master"
  fi
  printf '%s' "${url}"
}

cmd_status() {
  read_conf || true
  local src="" local_full="" local_short="" local_date="" local_msg=""
  local remote_json="" remote_full="" remote_short="" remote_date="" remote_msg=""
  local behind=false err=""

  if ! src="$(find_source_dir)"; then
    err="Source git checkout not found under /root/vicidialaiamdscammerchecker"
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
  if [[ -z "${local_full}" || -z "${remote_full}" ]]; then
    ok=false
  fi

  printf '{'
  printf '"ok":%s,' "${ok}"
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

cmd_apply() {
  read_conf || {
    echo '{"ok":false,"error":"Missing /etc/asterisk/openamd.conf — run vicibox_install.sh once first."}'
    exit 1
  }

  local src key base_url analyze
  if ! src="$(find_source_dir)"; then
    echo '{"ok":false,"error":"Source git checkout not found. Clone repo to /root/vicidialaiamdscammerchecker first."}'
    exit 1
  fi

  key="${OPENAMD_API_KEY:-}"
  analyze="${OPENAMD_URL:-}"
  if [[ -z "${key}" || -z "${analyze}" ]]; then
    echo '{"ok":false,"error":"OPENAMD_URL / OPENAMD_API_KEY missing in openamd.conf"}'
    exit 1
  fi
  base_url="$(printf '%s' "${analyze}" | sed -E 's#/api/v1/analyze/?$##')"

  exec 9>"${LOCK}"
  if ! flock -n 9; then
    echo '{"ok":false,"error":"Update already in progress"}'
    exit 1
  fi

  local logf="${LOG_DIR}/web_update_$(date +%Y%m%d_%H%M%S).log"
  {
    echo "=== OpenAMD web update $(date -Is) ==="
    echo "source=${src}"
    echo "repo=${REPO} branch=${BRANCH}"
    echo "base=${base_url}"
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
    sed -i 's/\r$//' vicibox_install.sh 2>/dev/null || true
    bash vicibox_install.sh "${base_url}" "${key}"
    echo "=== done ==="
  } >"${logf}" 2>&1
  local rc=$?

  local_full="$(git -C "${src}" rev-parse HEAD 2>/dev/null || true)"
  local_short="$(git -C "${src}" rev-parse --short HEAD 2>/dev/null || true)"
  local_msg="$(git -C "${src}" log -1 --format='%s' 2>/dev/null || true)"
  local tail_txt
  tail_txt="$(tail -n 80 "${logf}" 2>/dev/null || true)"

  if [[ ${rc} -ne 0 ]]; then
    printf '{"ok":false,"error":"Update failed (see log)","log_file":%s,"log":%s,"local_commit":%s}\n' \
      "$(json_escape "${logf}")" "$(json_escape "${tail_txt}")" "$(json_escape "${local_short}")"
    exit 1
  fi

  printf '{"ok":true,"local_commit":%s,"local_full":%s,"local_message":%s,"log_file":%s,"log":%s}\n' \
    "$(json_escape "${local_short}")" \
    "$(json_escape "${local_full}")" \
    "$(json_escape "${local_msg}")" \
    "$(json_escape "${logf}")" \
    "$(json_escape "${tail_txt}")"
}

case "${CMD}" in
  verify)
    require_key
    echo '{"ok":true}'
    ;;
  status)
    require_key
    cmd_status
    ;;
  apply)
    require_key
    cmd_apply
    ;;
  *)
    echo '{"ok":false,"error":"Usage: openamd_web_update.sh verify|status|apply <api_key>"}'
    exit 1
    ;;
esac
