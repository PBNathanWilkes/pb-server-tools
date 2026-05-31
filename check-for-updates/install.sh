#!/usr/bin/env bash
# =============================================================================
# install.sh — Build, test, and deploy check-for-updates
#
# Run from the repo root as:
#   sudo bash check-for-updates/install.sh
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

# Hosts that cannot honour CLONE_NEWNS (mount namespace) sandbox directives.
# The installer deploys a drop-in override for each listed host that resets
# the offending directives.  Source unit files are never modified.
# See overrides/<hostname>/README.md and DEV-GUIDE.md §6 KFC-R02.
readonly NAMESPACE_OVERRIDE_HOSTS=(
  pblinuxutility
)
# Service units (not timers) that receive the no-namespace drop-in on
# restricted hosts.
readonly NAMESPACE_OVERRIDE_SERVICES=(
  pb-check-for-updates.service
  pb-check-for-updates-monthly.service
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

printf '%s%s — check-for-updates Installer%s\n' "${BOLD}" "$(hostname -s)" "${RST}"
printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"

# =============================================================================
# ── STEP 1: Prerequisites ────────────────────────────────────────────────────
# =============================================================================
#
# python3 -B suppresses bytecode compilation so the import checks do not
# create root-owned __pycache__ directories inside the source tree.

check_prereqs() {
  _head "Prerequisites"

  command -v jq      >/dev/null 2>&1 || _die "jq not found — sudo apt install jq"
  command -v python3 >/dev/null 2>&1 || _die "python3 not found"
  python3 -B -c "import apt_pkg" 2>/dev/null || _die "python3-apt not found — sudo apt install python3-apt"
  python3 -B -c "import pytest"  2>/dev/null || _die "pytest not found — sudo apt install python3-pytest"

  _ok "jq, python3-apt, python3-pytest present"
}

# =============================================================================
# ── STEP 2: Unit tests ───────────────────────────────────────────────────────
# =============================================================================
#
# Run as the invoking user via sudo -u so that tests which assert non-root
# behaviour work correctly.

run_tests() {
  _head "Unit tests"

  local test_user="${SUDO_USER:-$(id -un)}"

  # _run_pytest <label> <test_file>
  # Captures pytest -v output; re-emits each PASSED/FAILED line through
  # _ok/_fail so individual results appear as indented checkmarks in the
  # structured outline.  The raw progress output (percentages) is suppressed.
  # Aborts deployment on any test failure.
  _run_pytest() {
    local label="$1" test_file="$2"
    printf '  running %s\n' "$label"
    local raw exit_code=0
    raw="$(sudo -u "$test_user" python3 -m pytest "$test_file" -v 2>&1)" || exit_code=$?
    local line
    while IFS= read -r line; do
      # Per-test result lines: "path::Class::test_name PASSED [ N%]"
      if [[ "$line" =~ ::([^[:space:]]+)[[:space:]]+(PASSED|FAILED) ]]; then
        local name="${BASH_REMATCH[1]}" result="${BASH_REMATCH[2]}"
        if [[ "$result" == "PASSED" ]]; then
          _ok "$name"
        else
          _fail "$name"
        fi
      fi
    done <<<"$raw"
    if (( exit_code != 0 )); then
      # Print the failure detail lines from pytest for diagnosis
      while IFS= read -r line; do
        [[ "$line" =~ ^FAILED[[:space:]] ]] && printf '       %s\n' "$line"
      done <<<"$raw"
      _die "${label} failed — aborting deployment"
    fi
  }

  # _run_bash_tests <label> <test_script>
  # Captures bash test harness output (PASS/FAIL per line, --- Results --- footer);
  # re-emits each case through _ok/_fail.  Aborts deployment on any test failure.
  _run_bash_tests() {
    local label="$1" test_script="$2"
    printf '  running %s\n' "$label"
    local raw exit_code=0
    raw="$(sudo -u "$test_user" bash "$test_script" 2>&1)" || exit_code=$?
    local line
    while IFS= read -r line; do
      # Harness lines: "  PASS T01_name" or "  FAIL T01_name"
      if [[ "$line" =~ ^[[:space:]]+(PASS|FAIL)[[:space:]]+(.+)$ ]]; then
        local result="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]}"
        if [[ "$result" == "PASS" ]]; then
          _ok "$name"
        else
          _fail "$name"
          # Print any detail lines that follow a FAIL (indented by the harness)
        fi
      # Detail lines under a FAIL: "       got  = ..."
      elif [[ "$line" =~ ^[[:space:]]{6,} ]]; then
        printf '  %s\n' "${line#"${line%%[![:space:]]*}"}"
      fi
    done <<<"$raw"
    if (( exit_code != 0 )); then
      _die "${label} failed — aborting deployment"
    fi
  }

  _run_pytest      "test_pb_apt_evaluator.py"    "${TESTS_DIR}/test_pb_apt_evaluator.py"
  _run_bash_tests  "test_pb_patch_reporter.sh"   "${TESTS_DIR}/test_pb_patch_reporter.sh"
}

# =============================================================================
# ── STEP 3: Clean bytecode artefacts ─────────────────────────────────────────
# =============================================================================
#
# Python bytecode caches (__pycache__) may be written during import checks or
# pytest runs.  .pytest_cache is written by pytest into tests/unit/.  Both are
# removed unconditionally so the source tree is clean after every install run
# regardless of who owns the directories.

cleanup_pycache() {
  _head "Bytecode artefacts"

  local dir
  while IFS= read -r -d '' dir; do
    rm -rf "$dir"
    _ok "removed ${dir}"
  done < <(find "$SCRIPT_DIR" \
    \( -name __pycache__ -o -name .pytest_cache \) \
    -type d -print0 2>/dev/null)
}

# =============================================================================
# ── STEP 4: Deploy files ─────────────────────────────────────────────────────
# =============================================================================

deploy_files() {
  _head "Deploy files"

  # --- libexec directory ---
  # Shared with other components; create if absent but never chmod/chown
  # the directory itself to avoid disturbing co-tenant files.
  mkdir -p "${LIBEXEC_DIR}"

  install -m 0750 -o root -g root \
    "${SRC_DIR}/check-for-updates.sh" \
    "${LIBEXEC_DIR}/check-for-updates.sh"
  _ok "${LIBEXEC_DIR}/check-for-updates.sh"

  install -m 0750 -o root -g root \
    "${SRC_DIR}/pb-apt-evaluator.py" \
    "${LIBEXEC_DIR}/pb-apt-evaluator.py"
  _ok "${LIBEXEC_DIR}/pb-apt-evaluator.py"

  install -m 0750 -o root -g root \
    "${SRC_DIR}/pb-patch-reporter.sh" \
    "${LIBEXEC_DIR}/pb-patch-reporter.sh"
  _ok "${LIBEXEC_DIR}/pb-patch-reporter.sh"

  # --- state directory (world-readable so login check works as any user) ---
  install -d -m 0755 -o root -g root "${STATE_DIR}"
  _ok "${STATE_DIR}/"

  # Ensure lock files exist with correct permissions so shared flocks work
  # for non-root users (read-open requires read permission — 0644 is sufficient).
  local lockfile
  for lockfile in \
    "${STATE_DIR}/patch-state.json.lock" \
    "${STATE_DIR}/patch-suppression.json.lock"
  do
    if [[ ! -e "$lockfile" ]]; then
      install -m 0644 -o root -g root /dev/null "$lockfile"
      _ok "created ${lockfile}"
    else
      chmod 0644 "$lockfile"
      chown root:root "$lockfile"
      _ok "verified ${lockfile}"
    fi
  done

  # --- systemd units ---
  local unit
  for unit in "${SERVICES[@]}"; do
    install -m 0644 -o root -g root \
      "${SYSTEMD_SRC}/${unit}" \
      "${SYSTEMD_DEST}/${unit}"
    _ok "${SYSTEMD_DEST}/${unit}"
  done
}

# =============================================================================
# ── STEP 5: Namespace-override drop-ins ──────────────────────────────────────
# =============================================================================
#
# On hosts listed in NAMESPACE_OVERRIDE_HOSTS (those whose kernel/container
# runtime cannot honour CLONE_NEWNS), deploy a drop-in that resets the
# namespace-requiring sandbox directives.  This resolves exit 226
# (EXIT_NAMESPACE) without modifying the source unit files, preserving full
# sandboxing on capable hosts such as PBWEBSRV03.
#
# Override source: overrides/<hostname>/<unit>.d/no-namespace.conf
# Installed to:    /etc/systemd/system/<unit>.d/no-namespace.conf

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

        [[ -f "$src" ]] || _die "override source not found: ${src}"

        mkdir -p "$drop_in_dir"
        install -m 0644 -o root -g root "$src" "$dst"
        _ok "installed ${dst}"
      done
      return 0
    fi
  done
}

# =============================================================================
# ── STEP 6: Verify deployed units ────────────────────────────────────────────
# =============================================================================
#
# Guards against stale unit files or a deploy that silently wrote to the wrong
# path.  Diffs each deployed unit against its source; aborts if any differ so
# the operator knows before daemon-reload.

verify_units() {
  _head "Verify systemd units"

  local unit mismatches=0
  for unit in "${SERVICES[@]}"; do
    local src="${SYSTEMD_SRC}/${unit}"
    local dst="${SYSTEMD_DEST}/${unit}"

    if [[ ! -f "$dst" ]]; then
      _fail "${unit} — not found at ${dst}"
      (( mismatches++ )) || true
      continue
    fi

    if ! diff -q "$src" "$dst" >/dev/null 2>&1; then
      _fail "${unit} — differs from source"
      diff "$src" "$dst" >&2 || true
      (( mismatches++ )) || true
    else
      _ok "${dst}"
    fi
  done

  [[ $mismatches -eq 0 ]] || _die "unit verification failed (${mismatches} file(s) differ) — aborting"
}

# =============================================================================
# ── STEP 7: Reload systemd ───────────────────────────────────────────────────
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
printf '  %sPASS: %d%s   %sFAIL: %d%s   (elapsed: %dms)\n\n' \
  "${GRN}" "$_pass" "${RST}" "${RED}" "$_fail" "${RST}" "$_ELAPSED"

if (( _fail > 0 )); then
  printf '%s%sINSTALL FAILED — %d step(s) failed%s\n\n' "${RED}" "${BOLD}" "$_fail" "${RST}"
  exit 1
fi

printf '%s%sDEPLOYMENT COMPLETE%s\n\n' "${GRN}" "${BOLD}" "${RST}"
