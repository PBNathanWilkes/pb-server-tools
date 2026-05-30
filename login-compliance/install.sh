#!/usr/bin/env bash
# =============================================================================
# install.sh — Build, test, and deploy login-compliance
#
# Run from the repo root as:
#   sudo bash login-compliance/install.sh
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
# Manual step required — add to each operator's ~/.bashrc:
#   if [[ $- == *i* ]] && [[ -x /usr/local/bin/login-compliance-check.sh ]]; then
#     /usr/local/bin/login-compliance-check.sh
#   fi
# And ensure ~/.bash_profile sources ~/.bashrc:
#   [[ -f ~/.bashrc ]] && source ~/.bashrc
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
readonly TESTS_DIR="${SCRIPT_DIR}/tests/unit"

readonly BIN_DIR="/usr/local/bin"

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

printf '%s%s — login-compliance Installer%s\n' "${BOLD}" "$(hostname -s)" "${RST}"
printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"

# =============================================================================
# ── STEP 1: Prerequisites ────────────────────────────────────────────────────
# =============================================================================

check_prereqs() {
  _head "Prerequisites"

  command -v mailx   >/dev/null 2>&1 || _die "mailx not found — sudo apt install s-nail"
  command -v msmtp   >/dev/null 2>&1 || _die "msmtp not found — sudo apt install msmtp"
  command -v apt-get >/dev/null 2>&1 || _die "apt-get not found — Debian/Ubuntu required"
  command -v jq      >/dev/null 2>&1 || _die "jq not found — sudo apt install jq"

  _ok "all prerequisites present"
}

# =============================================================================
# ── STEP 2: Unit tests ───────────────────────────────────────────────────────
# =============================================================================

run_tests() {
  _head "Unit tests"

  local test_user="${SUDO_USER:-$(id -un)}"

  printf '  running test_login_compliance.sh\n'
  sudo -u "$test_user" bash "${TESTS_DIR}/test_login_compliance.sh" \
    || _die "login compliance tests failed — aborting deployment"
  _ok "test_login_compliance.sh passed"
}

# =============================================================================
# ── STEP 3: Deploy files ─────────────────────────────────────────────────────
# =============================================================================

deploy_files() {
  _head "Deploy files"

  install -m 0755 -o root -g root \
    "${SRC_DIR}/login-compliance-check.sh" \
    "${BIN_DIR}/login-compliance-check.sh"
  _ok "${BIN_DIR}/login-compliance-check.sh"
}

# =============================================================================
# ── STEP 4: Manual .bashrc step ──────────────────────────────────────────────
# =============================================================================

print_bashrc_instructions() {
  _head "Manual step required"

  printf '  Add to each operator'"'"'s ~/.bashrc:\n\n'
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

# =============================================================================
# ── Main ─────────────────────────────────────────────────────────────────────
# =============================================================================

check_prereqs
run_tests
deploy_files
print_bashrc_instructions

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
