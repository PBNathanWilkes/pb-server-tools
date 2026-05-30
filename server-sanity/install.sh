#!/usr/bin/env bash
# =============================================================================
# install.sh — Build and deploy server-sanity
#
# Run from the repo root as:
#   sudo bash server-sanity/install.sh
#
# What it does:
#   1. Verifies prerequisites
#   2. Deploys server-sanity-check to /usr/local/bin/
#   3. Deploys systemd service + timer (pb-server-sanity-check)
#   4. Verifies deployed files match source; aborts if any differ
#   5. Reloads systemd and enables the timer
#   6. Runs a smoke test (syntax check)
#
# Production layout:
#   /usr/local/bin/server-sanity-check       (0755 root:root)
#   /etc/systemd/system/pb-server-sanity-check.service
#   /etc/systemd/system/pb-server-sanity-check.timer
#
# Exit codes:
#   0 — all steps completed successfully
#   1 — a step failed
#   2 — must run as root
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SRC_DIR="${SCRIPT_DIR}/src"
readonly SYSTEMD_SRC="${SCRIPT_DIR}/systemd"
readonly BIN_DIR="/usr/local/bin"
readonly DEST="${BIN_DIR}/server-sanity-check"
readonly SYSTEMD_DEST="/etc/systemd/system"

readonly SERVICES=(
  pb-server-sanity-check.service
  pb-server-sanity-check.timer
)
readonly TIMERS=(
  pb-server-sanity-check.timer
)

# ── Colour palette ───────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED=$'\033[0;31m' GRN=$'\033[0;32m'
  BLU=$'\033[0;34m' BOLD=$'\033[1m'   RST=$'\033[0m'
else
  RED='' GRN='' BLU='' BOLD='' RST=''
fi

# ── Counters ─────────────────────────────────────────────────────────────────
_pass=0; _fail=0

# ── Primitives ───────────────────────────────────────────────────────────────
_ok()   { printf "  %s✔%s  %s\n" "${GRN}" "${RST}" "$*"; (( ++_pass )); }
_fail() { printf "  %s✘%s  %s\n" "${RED}" "${RST}" "$*"; (( ++_fail )); }
_head() { printf "\n%s%s══ %s%s\n" "${BOLD}" "${BLU}" "$*" "${RST}"; }
_die()  { printf "\n%s%sERROR:%s %s\n" "${BOLD}" "${RED}" "${RST}" "$*" >&2; exit 1; }

# ── Guards ───────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  printf "${RED}Error:${RST} must run as root — use: sudo bash %s\n" "$0" >&2
  exit 2
fi

_START=$(date +%s%N)

printf '%s%s — server-sanity Installer%s\n' "${BOLD}" "$(hostname -s)" "${RST}"
printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"

# =============================================================================
# ── STEP 1: Prerequisites ────────────────────────────────────────────────────
# =============================================================================

check_prereqs() {
  _head "Prerequisites"

  command -v jq        >/dev/null 2>&1 || _die "jq not found — sudo apt install jq"
  command -v systemctl >/dev/null 2>&1 || _die "systemctl not found — systemd required"
  command -v msmtp     >/dev/null 2>&1 || _die "msmtp not found — sudo apt install msmtp"

  [[ -f "${SRC_DIR}/server-sanity-check.sh" ]] \
    || _die "source file not found: ${SRC_DIR}/server-sanity-check.sh"

  local unit
  for unit in "${SERVICES[@]}"; do
    [[ -f "${SYSTEMD_SRC}/${unit}" ]] \
      || _die "systemd unit not found: ${SYSTEMD_SRC}/${unit}"
  done

  _ok "all prerequisites present"
}

# =============================================================================
# ── STEP 2: Deploy script ────────────────────────────────────────────────────
# =============================================================================

deploy_script() {
  _head "Deploy script"

  install -m 0755 -o root -g root \
    "${SRC_DIR}/server-sanity-check.sh" \
    "${DEST}"
  _ok "${DEST}"
}

# =============================================================================
# ── STEP 3: Deploy systemd units ─────────────────────────────────────────────
# =============================================================================

deploy_units() {
  _head "Deploy systemd units"

  local unit
  for unit in "${SERVICES[@]}"; do
    install -m 0644 -o root -g root \
      "${SYSTEMD_SRC}/${unit}" \
      "${SYSTEMD_DEST}/${unit}"
    _ok "${SYSTEMD_DEST}/${unit}"
  done
}

# =============================================================================
# ── STEP 4: Verify deployed files ────────────────────────────────────────────
# =============================================================================
#
# Guards against a deploy that silently wrote to the wrong path or left a
# stale file in place.  Aborts before daemon-reload if anything differs.

verify_files() {
  _head "Verify deployed files"

  local mismatches=0

  if ! diff -q "${SRC_DIR}/server-sanity-check.sh" "${DEST}" >/dev/null 2>&1; then
    _fail "${DEST} — differs from source"
    (( mismatches++ )) || true
  else
    _ok "${DEST}"
  fi

  local unit
  for unit in "${SERVICES[@]}"; do
    if ! diff -q "${SYSTEMD_SRC}/${unit}" "${SYSTEMD_DEST}/${unit}" >/dev/null 2>&1; then
      _fail "${SYSTEMD_DEST}/${unit} — differs from source"
      (( mismatches++ )) || true
    else
      _ok "${SYSTEMD_DEST}/${unit}"
    fi
  done

  [[ $mismatches -eq 0 ]] || _die "file verification failed (${mismatches} file(s) differ) — aborting"
}

# =============================================================================
# ── STEP 5: Reload systemd ───────────────────────────────────────────────────
# =============================================================================

reload_systemd() {
  _head "Reload systemd"

  systemctl daemon-reload
  _ok "daemon-reload"

  local timer
  for timer in "${TIMERS[@]}"; do
    systemctl enable --now "$timer"
    _ok "enabled + started ${timer}"
  done
}

# =============================================================================
# ── STEP 6: Smoke test ───────────────────────────────────────────────────────
# =============================================================================

smoke_test() {
  _head "Smoke test"

  bash -n "${DEST}" || _die "deployed script failed syntax check: ${DEST}"
  _ok "syntax check passed: ${DEST}"
}

# =============================================================================
# ── Main ─────────────────────────────────────────────────────────────────────
# =============================================================================

check_prereqs
deploy_script
deploy_units
verify_files
reload_systemd
smoke_test

# ── Summary ──────────────────────────────────────────────────────────────────
_END=$(date +%s%N)
_ELAPSED=$(( (_END - _START) / 1000000 ))

printf '\n%s══ Summary%s\n' "${BOLD}" "${RST}"
printf '  %sPASS: %d%s   %sFAIL: %d%s   (elapsed: %dms)\n\n' \
  "${GRN}" "$_pass" "${RST}" "${RED}" "$_fail" "${RST}" "$_ELAPSED"

if (( _fail > 0 )); then
  printf '%s%sINSTALL FAILED — %d step(s) failed%s\n\n' "${RED}" "${BOLD}" "$_fail" "${RST}"
  exit 1
fi

printf '%s%sDEPLOYMENT COMPLETE%s\n\n' "${GRN}" "${BOLD}" "${RST}"

printf 'Usage:\n'
printf '  sudo server-sanity-check\n'
printf '  sudo server-sanity-check --email-on-failure\n\n'
printf 'Scheduled watchdog:\n'
printf '  systemctl status pb-server-sanity-check.timer\n\n'
