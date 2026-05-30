#!/usr/bin/env bash
# install.sh — Build and deploy server-sanity
#
# Run from the component root as:
#   sudo bash install.sh
#
# What it does:
#   1. Verifies prerequisites
#   2. Deploys server-sanity-check to /usr/local/bin/
#   3. Deploys systemd service + timer (pb-server-sanity-check)
#   4. Verifies deployed files match source
#   5. Reloads systemd and enables the timer
#   6. Runs a smoke test (syntax check)
#
# Production layout:
#   /usr/local/bin/server-sanity-check       (0755 root:root)
#   /etc/systemd/system/pb-server-sanity-check.service
#   /etc/systemd/system/pb-server-sanity-check.timer
#
# Usage after install:
#   sudo server-sanity-check
#   sudo server-sanity-check --email-on-failure

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info() { printf '\n[install] %s\n' "$*"; }
ok()   { printf '  OK  %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Must run as root: sudo bash install.sh"
}

# ---------------------------------------------------------------------------
# Step 1 — Prerequisites
# ---------------------------------------------------------------------------
check_prereqs() {
  info "Checking prerequisites"

  command -v jq        >/dev/null 2>&1 || die "jq not found — sudo apt install jq"
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found — systemd required"
  command -v msmtp     >/dev/null 2>&1 || die "msmtp not found — sudo apt install msmtp"

  [[ -f "${SRC_DIR}/server-sanity-check.sh" ]] \
    || die "Source file not found: ${SRC_DIR}/server-sanity-check.sh"

  for unit in "${SERVICES[@]}"; do
    [[ -f "${SYSTEMD_SRC}/${unit}" ]] \
      || die "Systemd unit not found: ${SYSTEMD_SRC}/${unit}"
  done

  ok "all prerequisites present"
}

# ---------------------------------------------------------------------------
# Step 2 — Deploy script
# ---------------------------------------------------------------------------
deploy_script() {
  info "Deploying script"

  install -m 0755 -o root -g root \
    "${SRC_DIR}/server-sanity-check.sh" \
    "${DEST}"
  ok "${DEST}"
}

# ---------------------------------------------------------------------------
# Step 3 — Deploy systemd units
# ---------------------------------------------------------------------------
deploy_units() {
  info "Deploying systemd units"

  local unit
  for unit in "${SERVICES[@]}"; do
    install -m 0644 -o root -g root \
      "${SYSTEMD_SRC}/${unit}" \
      "${SYSTEMD_DEST}/${unit}"
    ok "${SYSTEMD_DEST}/${unit}"
  done
}

# ---------------------------------------------------------------------------
# Step 4 — Verify deployed files match source
# ---------------------------------------------------------------------------
verify_files() {
  info "Verifying deployed files match source"

  # Script
  diff -q "${SRC_DIR}/server-sanity-check.sh" "${DEST}" >/dev/null 2>&1 \
    || die "Deployed script differs from source: ${DEST}"
  ok "${DEST}"

  # Units
  local unit
  for unit in "${SERVICES[@]}"; do
    diff -q "${SYSTEMD_SRC}/${unit}" "${SYSTEMD_DEST}/${unit}" >/dev/null 2>&1 \
      || die "Deployed unit differs from source: ${SYSTEMD_DEST}/${unit}"
    ok "${SYSTEMD_DEST}/${unit}"
  done
}

# ---------------------------------------------------------------------------
# Step 5 — Reload systemd and enable timer
# ---------------------------------------------------------------------------
reload_systemd() {
  info "Reloading systemd"
  systemctl daemon-reload
  ok "daemon-reload"

  local timer
  for timer in "${TIMERS[@]}"; do
    systemctl enable --now "$timer"
    ok "enabled + started ${timer}"
  done
}

# ---------------------------------------------------------------------------
# Step 6 — Smoke test
# ---------------------------------------------------------------------------
smoke_test() {
  info "Smoke test"

  bash -n "${DEST}" \
    || die "Deployed script failed syntax check: ${DEST}"
  ok "syntax check passed: ${DEST}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  require_root
  check_prereqs
  deploy_script
  deploy_units
  verify_files
  reload_systemd
  smoke_test

  printf '\n[install] Deployment complete.\n'
  printf '\nUsage:\n'
  printf '  sudo server-sanity-check\n'
  printf '  sudo server-sanity-check --email-on-failure\n\n'
  printf 'Scheduled watchdog:\n'
  printf '  systemctl status pb-server-sanity-check.timer\n\n'
}

main "$@"
