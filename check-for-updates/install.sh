#!/usr/bin/env bash
# =============================================================================
# install.sh — Build, test, and deploy check-for-updates
#
# Run from the repo root as:
#   sudo bash check-for-updates/install.sh [--dry-run] [--quiet] [--verbose]
#
# What it does:
#   1. Verifies prerequisites (jq, python3-apt, python3-pytest)
#   2. Runs all unit tests (Bash + Python); aborts on any failure
#   3. Removes __pycache__ and .pytest_cache from the source tree
#   4. Deploys source files to production locations with correct permissions
#   5. Deploys host-specific drop-in overrides (no-namespace on restricted hosts)
#   6. Verifies deployed systemd units match source; aborts if any differ
#   7. Reloads systemd and re-enables timers
#
# Options:
#   --dry-run   Print what would be done; mutate nothing
#   --quiet     Suppress pass lines; show failures, warnings, summary
#   --verbose   Show commands and per-section elapsed time
#   --help, -h  Show this help
#
# Production layout:
#   /usr/local/libexec/pb-maintenance/   check-for-updates.sh (0750 root:root)
#                                        pb-apt-evaluator.py   (0750 root:root)
#                                        pb-patch-reporter.sh  (0750 root:root)
#   /var/lib/pb-maintenance/             state directory (0755 root:root)
#   /etc/systemd/system/                 pb-check-for-updates{,-monthly}.{service,timer}
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
readonly TESTS_DIR="${SCRIPT_DIR}/tests/unit"

readonly LIBEXEC_DIR="/usr/local/libexec/pb-maintenance"
readonly STATE_DIR="/var/lib/pb-maintenance"
readonly SYSTEMD_DEST="/etc/systemd/system"

readonly SERVICES=(
  pb-check-for-updates.service
  pb-check-for-updates.timer
  pb-check-for-updates-monthly.service
  pb-check-for-updates-monthly.timer
)
readonly TIMERS=(
  pb-check-for-updates.timer
  pb-check-for-updates-monthly.timer
)

readonly NAMESPACE_OVERRIDE_HOSTS=(pblinuxutility)
readonly NAMESPACE_OVERRIDE_SERVICES=(
  pb-check-for-updates.service
  pb-check-for-updates-monthly.service
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

printf '%s%s — check-for-updates Installer%s\n' "${BOLD}" "$(hostname -s)" "${RST}"
printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
(( _DRY_RUN )) && printf '%s[dry-run mode — no changes will be made]%s\n' "${YLW}" "${RST}"
(( _QUIET   )) && printf '%s[quiet mode — pass lines suppressed]%s\n'      "${DIM}" "${RST}"
(( _VERBOSE )) && printf '%s[verbose mode — commands and section timings shown]%s\n' "${DIM}" "${RST}"

# =============================================================================
# ── STEP 1: Prerequisites ────────────────────────────────────────────────────
# =============================================================================

check_prereqs() {
  _head "Prerequisites"

  command -v jq      >/dev/null 2>&1 || _die "jq not found"      "Fix: sudo apt install jq"
  command -v python3 >/dev/null 2>&1 || _die "python3 not found" "Fix: sudo apt install python3"
  python3 -B -c "import apt_pkg" 2>/dev/null \
    || _die "python3-apt not found" "Fix: sudo apt install python3-apt"
  python3 -B -c "import pytest"  2>/dev/null \
    || _die "pytest not found"      "Fix: sudo apt install python3-pytest"

  _ok "jq, python3-apt, python3-pytest present"
}

# =============================================================================
# ── STEP 2: Unit tests ───────────────────────────────────────────────────────
# =============================================================================

run_tests() {
  _head "Unit tests"

  local test_user="${SUDO_USER:-$(id -un)}"

  # _run_pytest <label> <test_file>
  _run_pytest() {
    local label="$1" test_file="$2"
    printf '  %s·%s  running %s\n' "${DIM}" "${RST}" "${label}"
    if (( _VERBOSE )); then
      printf "     %spython3 -m pytest %s -v%s\n" "${DIM}" "${test_file}" "${RST}"
    fi
    local raw exit_code=0
    raw="$(sudo -u "$test_user" python3 -m pytest "$test_file" -v 2>&1)" || exit_code=$?
    local line
    while IFS= read -r line; do
      if [[ "$line" =~ ::([^[:space:]]+)[[:space:]]+(PASSED|FAILED) ]]; then
        local name="${BASH_REMATCH[1]}" result="${BASH_REMATCH[2]}"
        if [[ "$result" == "PASSED" ]]; then _ok "$name"; else _fail "$name"; fi
      fi
    done <<<"$raw"
    if (( exit_code != 0 )); then
      while IFS= read -r line; do
        [[ "$line" =~ ^FAILED[[:space:]] ]] && _note "$line"
      done <<<"$raw"
      _die "${label} failed — aborting deployment" \
           "Re-run: sudo bash ${SCRIPT_DIR}/install.sh --only check-for-updates"
    fi
  }

  # _run_bash_tests <label> <test_script>
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
           "Re-run: sudo bash ${SCRIPT_DIR}/install.sh --only check-for-updates"
    fi
  }

  _run_pytest     "test_pb_apt_evaluator.py"   "${TESTS_DIR}/test_pb_apt_evaluator.py"
  _run_bash_tests "test_pb_patch_reporter.sh"  "${TESTS_DIR}/test_pb_patch_reporter.sh"
}

# =============================================================================
# ── STEP 3: Clean bytecode artefacts ─────────────────────────────────────────
# =============================================================================

cleanup_pycache() {
  _head "Bytecode artefacts"

  local dir
  while IFS= read -r -d '' dir; do
    if (( _DRY_RUN )); then
      printf "     %s[dry-run] rm -rf %s%s\n" "${DIM}" "${dir}" "${RST}"
      _ok "would remove ${dir}"
    else
      _run "remove ${dir}"  rm -rf "${dir}"
    fi
  done < <(find "$SCRIPT_DIR" \
    \( -name __pycache__ -o -name .pytest_cache \) \
    -type d -print0 2>/dev/null)
}

# =============================================================================
# ── STEP 4: Deploy files ─────────────────────────────────────────────────────
# =============================================================================

deploy_files() {
  _head "Deploy files"

  if (( ! _DRY_RUN )); then
    mkdir -p "${LIBEXEC_DIR}"
  fi

  local files=(
    "${SRC_DIR}/check-for-updates.sh:${LIBEXEC_DIR}/check-for-updates.sh:0750"
    "${SRC_DIR}/pb-apt-evaluator.py:${LIBEXEC_DIR}/pb-apt-evaluator.py:0750"
    "${SRC_DIR}/pb-patch-reporter.sh:${LIBEXEC_DIR}/pb-patch-reporter.sh:0750"
  )
  local entry src dst mode
  for entry in "${files[@]}"; do
    IFS=':' read -r src dst mode <<< "$entry"
    if (( _DRY_RUN )); then
      printf "     %s[dry-run] install -m %s -o root -g root %s %s%s\n" \
        "${DIM}" "${mode}" "${src}" "${dst}" "${RST}"
      _ok "${dst}"
    else
      _run "${dst}"  install -m "${mode}" -o root -g root "${src}" "${dst}"
    fi
  done

  if (( _DRY_RUN )); then
    printf "     %s[dry-run] install -d -m 0755 %s%s\n" "${DIM}" "${STATE_DIR}" "${RST}"
    _ok "${STATE_DIR}/"
  else
    _run "${STATE_DIR}/"  install -d -m 0755 -o root -g root "${STATE_DIR}"
  fi

  local lockfile
  for lockfile in \
    "${STATE_DIR}/patch-state.json.lock" \
    "${STATE_DIR}/patch-suppression.json.lock"
  do
    if [[ ! -e "$lockfile" ]]; then
      if (( _DRY_RUN )); then
        printf "     %s[dry-run] create %s%s\n" "${DIM}" "${lockfile}" "${RST}"
        _ok "would create ${lockfile}"
      else
        _run "create ${lockfile}"  install -m 0644 -o root -g root /dev/null "${lockfile}"
      fi
    else
      if (( _DRY_RUN )); then
        _ok "verified ${lockfile}"
      else
        chmod 0644 "${lockfile}"
        chown root:root "${lockfile}"
        _ok "verified ${lockfile}"
      fi
    fi
  done

  local unit
  for unit in "${SERVICES[@]}"; do
    if (( _DRY_RUN )); then
      printf "     %s[dry-run] install %s → %s%s\n" \
        "${DIM}" "${SYSTEMD_SRC}/${unit}" "${SYSTEMD_DEST}/${unit}" "${RST}"
      _ok "${SYSTEMD_DEST}/${unit}"
    else
      _run "${SYSTEMD_DEST}/${unit}" \
        install -m 0644 -o root -g root "${SYSTEMD_SRC}/${unit}" "${SYSTEMD_DEST}/${unit}"
    fi
  done
}

# =============================================================================
# ── STEP 5: Namespace-override drop-ins ──────────────────────────────────────
# =============================================================================

deploy_overrides() {
  local current_host
  current_host="$(hostname -s)"

  local host
  for host in "${NAMESPACE_OVERRIDE_HOSTS[@]}"; do
    if [[ "$current_host" == "$host" ]]; then
      _head "Namespace-override drop-ins  (${host})"

      local unit
      for unit in "${NAMESPACE_OVERRIDE_SERVICES[@]}"; do
        local src="${SCRIPT_DIR}/../overrides/${host}/${unit}.d/no-namespace.conf"
        local drop_in_dir="${SYSTEMD_DEST}/${unit}.d"
        local dst="${drop_in_dir}/no-namespace.conf"

        [[ -f "$src" ]] || _die "override source not found: ${src}" \
          "Expected: ${src}"

        if (( _DRY_RUN )); then
          printf "     %s[dry-run] install %s → %s%s\n" "${DIM}" "${src}" "${dst}" "${RST}"
          _ok "would install ${dst}"
        else
          _run "install ${dst}"  bash -c "mkdir -p '${drop_in_dir}' && install -m 0644 -o root -g root '${src}' '${dst}'"
        fi
      done
      return 0
    fi
  done
}

# =============================================================================
# ── STEP 6: Verify deployed units ────────────────────────────────────────────
# =============================================================================

verify_units() {
  _head "Verify systemd units"

  local unit mismatches=0
  for unit in "${SERVICES[@]}"; do
    local src="${SYSTEMD_SRC}/${unit}"
    local dst="${SYSTEMD_DEST}/${unit}"

    if (( _DRY_RUN )); then
      _ok "${dst}  [skipped in dry-run]"
      continue
    fi

    if [[ ! -f "$dst" ]]; then
      _fail "${unit} — not found at ${dst}"
      _note "Deploy step may have failed; check step 4 output"
      (( mismatches++ )) || true
      continue
    fi

    if ! diff -q "$src" "$dst" >/dev/null 2>&1; then
      _fail "${unit} — differs from source"
      _note "diff ${src} ${dst}"
      (( mismatches++ )) || true
    else
      _ok "${dst}"
    fi
  done

  [[ $mismatches -eq 0 ]] || _die \
    "unit verification failed (${mismatches} file(s) differ) — aborting" \
    "Re-run: sudo bash ${SCRIPT_DIR}/install.sh --only check-for-updates"
}

# =============================================================================
# ── STEP 7: Reload systemd ───────────────────────────────────────────────────
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
# ── Main ─────────────────────────────────────────────────────────────────────
# =============================================================================

check_prereqs
run_tests
cleanup_pycache
deploy_files
deploy_overrides
verify_units
reload_systemd

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
