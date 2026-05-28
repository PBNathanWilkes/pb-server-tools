#!/usr/bin/env bash
# install.sh — Build, test, and deploy security-hardening
#
# Run from the source root as:
#   sudo bash install.sh
#
# What it does:
#   1. Verifies prerequisites
#   2. Runs unit tests; aborts on any failure
#   3. Deploys source files to production locations with correct permissions
#   4. Verifies deployed systemd units match source; aborts if any differ
#   5. Reloads systemd and re-enables timers

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SRC_DIR="${SCRIPT_DIR}/src"
readonly SYSTEMD_SRC="${SCRIPT_DIR}/systemd"
readonly TESTS_DIR="${SCRIPT_DIR}/tests/unit"

readonly LIBEXEC_DIR="/usr/local/libexec/pb-maintenance"
readonly STATE_DIR="/var/lib/pb-maintenance"
readonly SYSTEMD_DEST="/etc/systemd/system"

readonly SERVICES=(
  pb-security-hardening-check.service
  pb-security-hardening-check.timer
  pb-security-hardening-check-monthly.service
  pb-security-hardening-check-monthly.timer
)
readonly TIMERS=(
  pb-security-hardening-check.timer
  pb-security-hardening-check-monthly.timer
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf '\n[install] %s\n' "$*"; }
ok()    { printf '  OK  %s\n' "$*"; }
die()   { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Must run as root: sudo bash install.sh"
}

# ---------------------------------------------------------------------------
# Step 1 — Prerequisites
# ---------------------------------------------------------------------------
check_prereqs() {
  info "Checking prerequisites"

  command -v mailx   >/dev/null 2>&1 || die "mailx not found — sudo apt install s-nail"
  command -v msmtp   >/dev/null 2>&1 || die "msmtp not found — sudo apt install msmtp"
  command -v openssl >/dev/null 2>&1 || die "openssl not found — sudo apt install openssl"
  command -v ss      >/dev/null 2>&1 || die "ss not found — sudo apt install iproute2"
  command -v ufw     >/dev/null 2>&1 || die "ufw not found — sudo apt install ufw"

  ok "all prerequisites present"
}

# ---------------------------------------------------------------------------
# Step 2 — Unit tests
# ---------------------------------------------------------------------------
run_tests() {
  info "Running unit tests"

  local test_user="${SUDO_USER:-$(id -un)}"

  printf '  >> test_security_hardening.sh\n'
  sudo -u "$test_user" bash "${TESTS_DIR}/test_security_hardening.sh" \
    || die "Security hardening tests failed — aborting deployment"
  ok "test_security_hardening.sh passed"
}

# ---------------------------------------------------------------------------
# Step 3 — Deploy
# ---------------------------------------------------------------------------
deploy_files() {
  info "Deploying files"

  mkdir -p "${LIBEXEC_DIR}"
  install -d -m 0755 -o root -g root "${STATE_DIR}"

  install -m 0750 -o root -g root \
    "${SRC_DIR}/security-hardening-check.sh" \
    "${LIBEXEC_DIR}/security-hardening-check.sh"
  ok "${LIBEXEC_DIR}/security-hardening-check.sh"

  local unit
  for unit in "${SERVICES[@]}"; do
    install -m 0644 -o root -g root \
      "${SYSTEMD_SRC}/${unit}" \
      "${SYSTEMD_DEST}/${unit}"
    ok "${SYSTEMD_DEST}/${unit}"
  done
}

# ---------------------------------------------------------------------------
# Step 4 — Verify deployed units match source
# ---------------------------------------------------------------------------
verify_units() {
  info "Verifying deployed systemd units match source"

  local unit mismatches=0
  for unit in "${SERVICES[@]}"; do
    local src="${SYSTEMD_SRC}/${unit}"
    local dst="${SYSTEMD_DEST}/${unit}"

    if [[ ! -f "$dst" ]]; then
      printf '  FAIL  %s not found at %s\n' "$unit" "$dst" >&2
      (( mismatches++ )) || true
      continue
    fi

    if ! diff -q "$src" "$dst" >/dev/null 2>&1; then
      printf '  FAIL  %s differs from source:\n' "$unit" >&2
      diff "$src" "$dst" >&2 || true
      (( mismatches++ )) || true
    else
      ok "${dst}"
    fi
  done

  [[ $mismatches -eq 0 ]] || die "Unit verification failed ($mismatches file(s) differ) — aborting"
}

# ---------------------------------------------------------------------------
# Step 5 — Reload systemd and re-enable timers
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
# Main
# ---------------------------------------------------------------------------
main() {
  require_root
  check_prereqs
  run_tests
  deploy_files
  verify_units
  reload_systemd

  printf '\n[install] Deployment complete.\n'
}

main "$@"
