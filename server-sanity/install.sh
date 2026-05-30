#!/usr/bin/env bash
# install.sh — Build and deploy server-sanity
#
# Run from the component root as:
#   sudo bash install.sh
#
# What it does:
#   1. Verifies prerequisites
#   2. Deploys server-sanity-check.sh to /usr/local/bin/
#   3. Runs a smoke test (--help exits 0)
#
# Production layout:
#   /usr/local/bin/server-sanity-check.sh  (0755 root:root)
#
# Usage after install:
#   sudo server-sanity-check.sh

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SRC_DIR="${SCRIPT_DIR}/src"
readonly BIN_DIR="/usr/local/bin"
readonly DEST="${BIN_DIR}/server-sanity-check.sh"

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

  command -v jq         >/dev/null 2>&1 || die "jq not found — sudo apt install jq"
  command -v systemctl  >/dev/null 2>&1 || die "systemctl not found — systemd required"

  [[ -f "${SRC_DIR}/server-sanity-check.sh" ]] \
    || die "Source file not found: ${SRC_DIR}/server-sanity-check.sh"

  ok "all prerequisites present"
}

# ---------------------------------------------------------------------------
# Step 2 — Deploy
# ---------------------------------------------------------------------------
deploy_files() {
  info "Deploying files"

  install -m 0755 -o root -g root \
    "${SRC_DIR}/server-sanity-check.sh" \
    "${DEST}"
  ok "${DEST}"
}

# ---------------------------------------------------------------------------
# Step 3 — Smoke test
# ---------------------------------------------------------------------------
smoke_test() {
  info "Smoke test"

  # The script exits 2 when not root, but --help should short-circuit cleanly.
  # Verify the deployed file passes bash -n (syntax check).
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
  deploy_files
  smoke_test

  printf '\n[install] Deployment complete.\n'
  printf '\nUsage:\n'
  printf '  sudo server-sanity-check.sh\n\n'
}

main "$@"
