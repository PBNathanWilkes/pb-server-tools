#!/usr/bin/env bash
# install.sh — Build, test, and deploy login-compliance
#
# Run from the source root as:
#   sudo bash install.sh
#
# What it does:
#   1. Verifies prerequisites
#   2. Runs unit tests; aborts on any failure
#   3. Deploys login-compliance-check.sh to /usr/local/bin/
#   4. Prints .bashrc snippet for operator to add manually
#
# Production layout:
#   /usr/local/bin/login-compliance-check.sh  (0755 root:root)
#
# Operators must add the following to each user's ~/.bashrc:
#   if [[ $- == *i* ]] && [[ -x /usr/local/bin/login-compliance-check.sh ]]; then
#     /usr/local/bin/login-compliance-check.sh
#   fi
# And ensure ~/.bash_profile sources ~/.bashrc:
#   [[ -f ~/.bashrc ]] && source ~/.bashrc

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SRC_DIR="${SCRIPT_DIR}/src"
readonly TESTS_DIR="${SCRIPT_DIR}/tests/unit"

readonly BIN_DIR="/usr/local/bin"

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
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found — Debian/Ubuntu required"
  command -v jq      >/dev/null 2>&1 || die "jq not found — sudo apt install jq"

  ok "all prerequisites present"
}

# ---------------------------------------------------------------------------
# Step 2 — Unit tests
# ---------------------------------------------------------------------------
run_tests() {
  info "Running unit tests"

  local test_user="${SUDO_USER:-$(id -un)}"

  printf '  >> test_login_compliance.sh\n'
  sudo -u "$test_user" bash "${TESTS_DIR}/test_login_compliance.sh" \
    || die "Login compliance tests failed — aborting deployment"
  ok "test_login_compliance.sh passed"
}

# ---------------------------------------------------------------------------
# Step 3 — Deploy
# ---------------------------------------------------------------------------
deploy_files() {
  info "Deploying files"

  install -m 0755 -o root -g root \
    "${SRC_DIR}/login-compliance-check.sh" \
    "${BIN_DIR}/login-compliance-check.sh"
  ok "${BIN_DIR}/login-compliance-check.sh"
}

# ---------------------------------------------------------------------------
# Step 4 — Print .bashrc snippet
# ---------------------------------------------------------------------------
print_bashrc_instructions() {
  info "Manual step required — add to each operator's ~/.bashrc"
  cat <<'EOF'

  # ---- login-compliance-check ----
  if [[ $- == *i* ]] && [[ -x /usr/local/bin/login-compliance-check.sh ]]; then
    /usr/local/bin/login-compliance-check.sh
  fi
  # --------------------------------

  Also ensure ~/.bash_profile sources ~/.bashrc:
    [[ -f ~/.bashrc ]] && source ~/.bashrc

EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  require_root
  check_prereqs
  run_tests
  deploy_files
  print_bashrc_instructions

  printf '\n[install] Deployment complete.\n'
}

main "$@"
