#!/usr/bin/env bash
# =============================================================================
# install.sh — Build, test, and deploy login-compliance
#
# Run from the repo root as:
#   sudo bash login-compliance/install.sh [--dry-run] [--quiet] [--verbose]
#
# What it does:
#   1. Verifies prerequisites
#   2. Runs unit tests; aborts on any failure
#   3. Deploys login-compliance-check.sh to /usr/local/bin/
#   4. Prints .bashrc snippet for operator to add manually
#
# Options:
#   --dry-run   Print what would be done; mutate nothing
#   --quiet     Suppress pass lines; show failures, warnings, summary
#   --verbose   Show commands and per-section elapsed time
#   --help, -h  Show this help
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
  RED=$'\033[0;31m' GRN=$'\033[0;32m' YLW=$'\033[0;33m'
  BLU=$'\033[0;34m' DIM=$'\033[2m'    BOLD=$'\033[1m' RST=$'\033[0m'
else
  RED='' GRN='' YLW='' BLU='' DIM='' BOLD='' RST=''
fi

# ── Counters and accumulators ─────────────────────────────────────────────────
_pass=0; _fail=0; _warn=0
_FAILURES=(); _WARNINGS=()

# ── Mode flags ────────────────────────────────────────────────────────────────
_QUIET=0; _VERBOSE=0; _DRY_RUN=0

# ── Section timing ────────────────────────────────────────────────────────────
_SECTION_START=0

# ── Primitives ───────────────────────────────────────────────────────────────
_ok()   {
  (( ++_pass ))
  (( _QUIET )) && return
  printf "  %s✔%s  %s\n" "${GRN}" "${RST}" "$*"
}
_fail() {
  (( ++_fail )) || true
  _FAILURES+=("$*")
  printf "  %s✘%s  %s\n" "${RED}" "${RST}" "$*"
}
_warn() {
  (( ++_warn )) || true
  _WARNINGS+=("$*")
  printf "  %s⚠%s  %s\n" "${YLW}" "${RST}" "$*"
}
_note() { printf "     %s%s%s\n" "${DIM}" "$*" "${RST}"; }
_head() {
  local now elapsed_str=''
  now=$(date +%s%N)
  if (( _VERBOSE && _SECTION_START > 0 )); then
    local ms=$(( (now - _SECTION_START) / 1000000 ))
    elapsed_str="  ${DIM}(${ms}ms)${RST}"
  fi
  _SECTION_START=$now
  printf "\n%s%s══ %s%s%s\n" "${BOLD}" "${BLU}" "$*" "${RST}" "${elapsed_str}"
}
_run() {
  local label="$1"; shift
  local t0 t1 ms rc=0
  printf "  %s·%s  %s\n" "${DIM}" "${RST}" "${label}"
  if (( _VERBOSE )); then
    printf "     %s%s%s\n" "${DIM}" "$*" "${RST}"
  fi
  if (( _DRY_RUN )); then
    printf "     %s[dry-run] %s%s\n" "${DIM}" "$*" "${RST}"
    _ok "${label}"
    return 0
  fi
  t0=$(date +%s%N)
  "$@" || rc=$?
  t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))
  if (( rc == 0 )); then
    _ok "${label}  (${ms}ms)"
  else
    _fail "${label}  (exit ${rc})"
  fi
  return $rc
}
_die() {
  local msg="$1" hint="${2:-}"
  printf "\n%s%sERROR:%s %s\n" "${BOLD}" "${RED}" "${RST}" "${msg}" >&2
  if [[ -n "${hint}" ]]; then
    printf "     %s%s%s\n" "${DIM}" "${hint}" "${RST}" >&2
  fi
  exit 1
}

# ── Guards ───────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  printf "${RED}Error:${RST} must run as root — use: sudo bash %s\n" "$0" >&2
  exit 2
fi

# ── Argument parsing ─────────────────────────────────────────────────────────
for _arg in "$@"; do
  case "$_arg" in
    --help|-h)
      sed -n '/^# Run from/,/^# Production layout/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
  esac
done

set -- "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  _DRY_RUN=1; shift ;;
    --quiet)    _QUIET=1;   shift ;;
    --verbose)  _VERBOSE=1; shift ;;
    --help|-h)  exit 0 ;;
    *)          _die "Unknown option: $1" "Usage: sudo bash $0 [--dry-run] [--quiet] [--verbose]" ;;
  esac
done

_START=$(date +%s%N)

printf '%s%s — login-compliance Installer%s\n' "${BOLD}" "$(hostname -s)" "${RST}"
printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
(( _DRY_RUN )) && printf '%s[dry-run mode — no changes will be made]%s\n' "${YLW}" "${RST}"
(( _QUIET   )) && printf '%s[quiet mode — pass lines suppressed]%s\n'      "${DIM}" "${RST}"
(( _VERBOSE )) && printf '%s[verbose mode — commands and section timings shown]%s\n' "${DIM}" "${RST}"

# =============================================================================
# ── STEP 1: Prerequisites ────────────────────────────────────────────────────
# =============================================================================

check_prereqs() {
  _head "Prerequisites"

  command -v mailx   >/dev/null 2>&1 || _die "mailx not found"   "Fix: sudo apt install s-nail"
  command -v msmtp   >/dev/null 2>&1 || _die "msmtp not found"   "Fix: sudo apt install msmtp"
  command -v apt-get >/dev/null 2>&1 || _die "apt-get not found" "Fix: Debian/Ubuntu required"
  command -v jq      >/dev/null 2>&1 || _die "jq not found"      "Fix: sudo apt install jq"

  _ok "all prerequisites present"
}

# =============================================================================
# ── STEP 2: Unit tests ───────────────────────────────────────────────────────
# =============================================================================

run_tests() {
  _head "Unit tests"

  local test_user="${SUDO_USER:-$(id -un)}"

  _run_bash_tests() {
    local label="$1" test_script="$2"
    printf '  %s·%s  running %s\n' "${DIM}" "${RST}" "${label}"
    if (( _VERBOSE )); then
      printf "     %sbash %s%s\n" "${DIM}" "${test_script}" "${RST}"
    fi
    local raw exit_code=0
    raw="$(sudo -u "$test_user" bash "$test_script" 2>&1)" || exit_code=$?
    local line
    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]+(PASS|FAIL)[[:space:]]+(.+)$ ]]; then
        local result="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]}"
        if [[ "$result" == "PASS" ]]; then _ok "$name"; else _fail "$name"; fi
      elif [[ "$line" =~ ^[[:space:]]{6,} ]]; then
        _note "${line#"${line%%[![:space:]]*}"}"
      fi
    done <<<"$raw"
    if (( exit_code != 0 )); then
      _die "${label} failed — aborting deployment" \
           "Re-run: sudo bash ${SCRIPT_DIR}/install.sh --only login-compliance"
    fi
  }

  _run_bash_tests "test_login_compliance.sh" "${TESTS_DIR}/test_login_compliance.sh"
}

# =============================================================================
# ── STEP 3: Deploy files ─────────────────────────────────────────────────────
# =============================================================================

deploy_files() {
  _head "Deploy files"

  if (( _DRY_RUN )); then
    printf "     %s[dry-run] install -m 0755 login-compliance-check.sh → %s%s\n" \
      "${DIM}" "${BIN_DIR}/login-compliance-check.sh" "${RST}"
    _ok "${BIN_DIR}/login-compliance-check.sh"
  else
    _run "${BIN_DIR}/login-compliance-check.sh" \
      install -m 0755 -o root -g root \
        "${SRC_DIR}/login-compliance-check.sh" \
        "${BIN_DIR}/login-compliance-check.sh"
  fi
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
printf '  %sPASS: %d%s   %sFAIL: %d%s   %sWARN: %d%s   (elapsed: %dms)\n\n' \
  "${GRN}" "$_pass" "${RST}" "${RED}" "$_fail" "${RST}" "${YLW}" "$_warn" "${RST}" "$_ELAPSED"

if (( ${#_FAILURES[@]} > 0 )); then
  printf '%s%sFailed steps:%s\n' "${BOLD}" "${RED}" "${RST}"
  for _f in "${_FAILURES[@]}"; do
    printf "  %s✘%s  %s\n" "${RED}" "${RST}" "${_f}"
  done
  printf '\n'
fi
if (( ${#_WARNINGS[@]} > 0 )); then
  printf '%s%sWarnings:%s\n' "${BOLD}" "${YLW}" "${RST}"
  for _w in "${_WARNINGS[@]}"; do
    printf "  %s⚠%s  %s\n" "${YLW}" "${RST}" "${_w}"
  done
  printf '\n'
fi

if (( _fail > 0 )); then
  printf '%s%sDEPLOYMENT FAILED — %d step(s) failed%s\n\n' "${RED}" "${BOLD}" "$_fail" "${RST}"
  exit 1
fi

printf '%s%sDEPLOYMENT COMPLETE%s\n\n' "${GRN}" "${BOLD}" "${RST}"
