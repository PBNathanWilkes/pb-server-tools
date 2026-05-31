#!/usr/bin/env bash
# =============================================================================
# install.sh — Build and deploy server-sanity
#
# Run from the repo root as:
#   sudo bash server-sanity/install.sh [--dry-run] [--quiet] [--verbose]
#
# What it does:
#   1. Verifies prerequisites
#   2. Deploys server-sanity-check to /usr/local/bin/
#   3. Deploys systemd service + timer (pb-server-sanity-check)
#   4. Verifies deployed files match source; aborts if any differ
#   5. Reloads systemd and enables the timer
#   6. Runs a smoke test (syntax check)
#
# Options:
#   --dry-run   Print what would be done; mutate nothing
#   --quiet     Suppress pass lines; show failures, warnings, summary
#   --verbose   Show commands and per-section elapsed time
#   --help, -h  Show this help
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
  _ERR_HANDLED=1
  local msg="$1" hint="${2:-}"
  printf "\n%s%sERROR:%s %s\n" "${BOLD}" "${RED}" "${RST}" "${msg}" >&2
  if [[ -n "${hint}" ]]; then
    printf "     %s%s%s\n" "${DIM}" "${hint}" "${RST}" >&2
  fi
  exit 1
}

# ── Traps ────────────────────────────────────────────────────────────────────
# _ERR_HANDLED: set by _die so the ERR trap does not double-print.
# _EXIT_CLEAN:  set just before a normal summary exit so the EXIT trap is silent.
_ERR_HANDLED=0
_EXIT_CLEAN=0

_trap_err() {
  local rc=$? line=${BASH_LINENO[0]} cmd="${BASH_COMMAND}"
  (( _ERR_HANDLED )) && return
  _ERR_HANDLED=1
  local _end _ms
  _end=$(date +%s%N)
  _ms=$(( (_end - ${_START:-$_end}) / 1000000 ))
  printf "\n%s%sERROR:%s unexpected failure at line %d (exit %d)\n" \
    "${BOLD}" "${RED}" "${RST}" "$line" "$rc" >&2
  printf "     %scommand: %s%s\n" "${DIM}" "$cmd" "${RST}" >&2
  printf "     %s(after %dms)%s\n" "${DIM}" "$_ms" "${RST}" >&2
}
trap '_trap_err' ERR

_trap_exit() {
  (( _EXIT_CLEAN )) && return
  local _end _ms
  _end=$(date +%s%N)
  _ms=$(( (_end - ${_START:-$_end}) / 1000000 ))
  printf "\n%s(exited after %dms)%s\n" "${DIM}" "$_ms" "${RST}" >&2
}
trap '_trap_exit' EXIT

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

printf '%s%s — server-sanity Installer%s\n' "${BOLD}" "$(hostname -s)" "${RST}"
printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
(( _DRY_RUN )) && printf '%s[dry-run mode — no changes will be made]%s\n' "${YLW}" "${RST}"
(( _QUIET   )) && printf '%s[quiet mode — pass lines suppressed]%s\n'      "${DIM}" "${RST}"
(( _VERBOSE )) && printf '%s[verbose mode — commands and section timings shown]%s\n' "${DIM}" "${RST}"

# =============================================================================
# ── STEP 1: Prerequisites ────────────────────────────────────────────────────
# =============================================================================

check_prereqs() {
  _head "Prerequisites"

  command -v jq        >/dev/null 2>&1 || _die "jq not found"        "Fix: sudo apt install jq"
  command -v systemctl >/dev/null 2>&1 || _die "systemctl not found" "Fix: systemd required"
  command -v msmtp     >/dev/null 2>&1 || _die "msmtp not found"     "Fix: sudo apt install msmtp"

  [[ -f "${SRC_DIR}/server-sanity-check.sh" ]] \
    || _die "source file not found: ${SRC_DIR}/server-sanity-check.sh" \
            "Check out is incomplete; re-clone or check SCRIPT_DIR"

  local unit
  for unit in "${SERVICES[@]}"; do
    [[ -f "${SYSTEMD_SRC}/${unit}" ]] \
      || _die "systemd unit not found: ${SYSTEMD_SRC}/${unit}" \
              "Check out is incomplete; re-clone or check SCRIPT_DIR"
  done

  _ok "all prerequisites present"
}

# =============================================================================
# ── STEP 2: Deploy script ────────────────────────────────────────────────────
# =============================================================================

deploy_script() {
  _head "Deploy script"

  if (( _DRY_RUN )); then
    printf "     %s[dry-run] install -m 0755 server-sanity-check.sh → %s%s\n" \
      "${DIM}" "${DEST}" "${RST}"
    _ok "${DEST}"
  else
    _run "${DEST}" \
      install -m 0755 -o root -g root "${SRC_DIR}/server-sanity-check.sh" "${DEST}"
  fi
}

# =============================================================================
# ── STEP 3: Deploy systemd units ─────────────────────────────────────────────
# =============================================================================

deploy_units() {
  _head "Deploy systemd units"

  local unit
  for unit in "${SERVICES[@]}"; do
    if (( _DRY_RUN )); then
      printf "     %s[dry-run] install %s → %s%s\n" \
        "${DIM}" "${unit}" "${SYSTEMD_DEST}/${unit}" "${RST}"
      _ok "${SYSTEMD_DEST}/${unit}"
    else
      _run "${SYSTEMD_DEST}/${unit}" \
        install -m 0644 -o root -g root \
          "${SYSTEMD_SRC}/${unit}" "${SYSTEMD_DEST}/${unit}"
    fi
  done
}

# =============================================================================
# ── STEP 4: Verify deployed files ────────────────────────────────────────────
# =============================================================================

verify_files() {
  _head "Verify deployed files"

  local mismatches=0

  if (( _DRY_RUN )); then
    _ok "${DEST}  [skipped in dry-run]"
    local unit
    for unit in "${SERVICES[@]}"; do
      _ok "${SYSTEMD_DEST}/${unit}  [skipped in dry-run]"
    done
    return
  fi

  if ! diff -q "${SRC_DIR}/server-sanity-check.sh" "${DEST}" >/dev/null 2>&1; then
    _fail "${DEST} — differs from source"
    _note "diff ${SRC_DIR}/server-sanity-check.sh ${DEST}"
    (( mismatches++ )) || true
  else
    _ok "${DEST}"
  fi

  local unit
  for unit in "${SERVICES[@]}"; do
    if ! diff -q "${SYSTEMD_SRC}/${unit}" "${SYSTEMD_DEST}/${unit}" >/dev/null 2>&1; then
      _fail "${SYSTEMD_DEST}/${unit} — differs from source"
      _note "diff ${SYSTEMD_SRC}/${unit} ${SYSTEMD_DEST}/${unit}"
      (( mismatches++ )) || true
    else
      _ok "${SYSTEMD_DEST}/${unit}"
    fi
  done

  [[ $mismatches -eq 0 ]] || _die \
    "file verification failed (${mismatches} file(s) differ) — aborting" \
    "Re-run: sudo bash ${SCRIPT_DIR}/install.sh --only server-sanity"
}

# =============================================================================
# ── STEP 5: Reload systemd ───────────────────────────────────────────────────
# =============================================================================

reload_systemd() {
  _head "Reload systemd"

  if (( _DRY_RUN )); then
    printf "     %s[dry-run] systemctl daemon-reload%s\n" "${DIM}" "${RST}"
    _ok "daemon-reload"
    local timer
    for timer in "${TIMERS[@]}"; do
      printf "     %s[dry-run] systemctl enable --now %s%s\n" "${DIM}" "${timer}" "${RST}"
      _ok "would enable + start ${timer}"
    done
    return
  fi

  _run "daemon-reload"  systemctl daemon-reload

  local timer
  for timer in "${TIMERS[@]}"; do
    _run "enable + start ${timer}"  systemctl enable --now "${timer}"
  done
}

# =============================================================================
# ── STEP 6: Smoke test ───────────────────────────────────────────────────────
# =============================================================================

smoke_test() {
  _head "Smoke test"

  if (( _DRY_RUN )); then
    printf "     %s[dry-run] bash -n %s%s\n" "${DIM}" "${DEST}" "${RST}"
    _ok "syntax check  [skipped in dry-run]"
    return
  fi

  if bash -n "${DEST}" 2>/dev/null; then
    _ok "syntax check passed: ${DEST}"
  else
    _fail "syntax check failed: ${DEST}"
    _note "bash -n ${DEST}"
    _die "deployed script failed syntax check" \
         "Re-run: sudo bash ${SCRIPT_DIR}/install.sh --only server-sanity"
  fi
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

_EXIT_CLEAN=1
printf '%s%sDEPLOYMENT COMPLETE%s\n\n' "${GRN}" "${BOLD}" "${RST}"
