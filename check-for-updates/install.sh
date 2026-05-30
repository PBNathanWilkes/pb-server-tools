#!/usr/bin/env bash
# install.sh — Build, test, and deploy check-for-updates
#
# Run from the source root (/opt/check-for-updates) as:
#   sudo bash install.sh
#
# What it does:
#   1. Verifies prerequisites (jq, python3-apt, python3-pytest)
#   2. Runs all unit tests (Bash + Python); aborts on any failure
#   3. Removes __pycache__ and .pytest_cache from the source tree
#   4. Deploys source files to production locations with correct permissions
#   5. Deploys host-specific drop-in overrides (e.g. no-namespace on restricted hosts)
#   6. Verifies deployed systemd units match source; aborts if any differ
#   7. Reloads systemd and re-enables timers
#
# Production layout:
#   /usr/local/libexec/pb-maintenance/   check-for-updates.sh (0750 root:root)
#                                        pb-apt-evaluator.py   (0750 root:root)
#                                        pb-patch-reporter.sh  (0750 root:root)

#   /var/lib/pb-maintenance/             state directory (0755 root:root)
#   /etc/systemd/system/                 pb-check-for-updates{,-monthly}.{service,timer}

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
#
# python3 -B suppresses bytecode compilation so the import checks do not
# create root-owned __pycache__ directories inside the source tree.
# ---------------------------------------------------------------------------
check_prereqs() {
  info "Checking prerequisites"

  command -v jq      >/dev/null 2>&1 || die "jq not found — sudo apt install jq"
  command -v python3 >/dev/null 2>&1 || die "python3 not found"
  python3 -B -c "import apt_pkg" 2>/dev/null || die "python3-apt not found — sudo apt install python3-apt"
  python3 -B -c "import pytest"  2>/dev/null || die "pytest not found — sudo apt install python3-pytest"

  ok "jq, python3-apt, python3-pytest present"
}

# ---------------------------------------------------------------------------
# Step 2 — Unit tests (run as the invoking user via sudo -u, so that
#           tests which assert non-root behaviour work correctly)
# ---------------------------------------------------------------------------
run_tests() {
  info "Running unit tests"

  # Resolve the non-root user who called sudo (falls back to current user)
  local test_user="${SUDO_USER:-$(id -un)}"

  # Python evaluator tests
  printf '  >> test_pb_apt_evaluator.py\n'
  sudo -u "$test_user" python3 -m pytest "${TESTS_DIR}/test_pb_apt_evaluator.py" -v \
    || die "Python unit tests failed — aborting deployment"
  ok "test_pb_apt_evaluator.py passed"

  # Reporter Bash tests
  printf '  >> test_pb_patch_reporter.sh\n'
  sudo -u "$test_user" bash "${TESTS_DIR}/test_pb_patch_reporter.sh" \
    || die "Reporter tests failed — aborting deployment"
  ok "test_pb_patch_reporter.sh passed"

}

# ---------------------------------------------------------------------------
# Step 3 — Remove bytecode artefacts from source tree
#
# Python bytecode caches (__pycache__) are written during:
#   a) check_prereqs — python3 import checks ran as root (fixed with -B above,
#      but cleanup handles any pre-existing root-owned dirs)
#   b) pytest — may write __pycache__ for the test files themselves;
#      ownership depends on the user pytest runs as
#
# .pytest_cache is written by pytest into tests/unit/ and is also not useful
# to keep in the source tree between installs.
#
# Both are removed here unconditionally so the source tree is clean after
# every install run regardless of who owns the directories.
# ---------------------------------------------------------------------------
cleanup_pycache() {
  info "Cleaning bytecode artefacts from source tree"

  local dir
  while IFS= read -r -d '' dir; do
    rm -rf "$dir"
    ok "removed ${dir}"
  done < <(find "$SCRIPT_DIR" \
    \( -name __pycache__ -o -name .pytest_cache \) \
    -type d -print0 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Step 4 — Deploy
# ---------------------------------------------------------------------------
deploy_files() {
  info "Deploying files"

  # --- libexec directory ---
  # Directory is shared with other projects (e.g. security-hardening-check.sh).
  # Create if absent; never chmod/chown the directory itself to avoid
  # disturbing co-tenant files.
  mkdir -p "${LIBEXEC_DIR}"

  install -m 0750 -o root -g root \
    "${SRC_DIR}/check-for-updates.sh" \
    "${LIBEXEC_DIR}/check-for-updates.sh"
  ok "${LIBEXEC_DIR}/check-for-updates.sh"

  install -m 0750 -o root -g root \
    "${SRC_DIR}/pb-apt-evaluator.py" \
    "${LIBEXEC_DIR}/pb-apt-evaluator.py"
  ok "${LIBEXEC_DIR}/pb-apt-evaluator.py"

  install -m 0750 -o root -g root \
    "${SRC_DIR}/pb-patch-reporter.sh" \
    "${LIBEXEC_DIR}/pb-patch-reporter.sh"
  ok "${LIBEXEC_DIR}/pb-patch-reporter.sh"

  # --- state directory (world-readable so login check works as any user) ---
  install -d -m 0755 -o root -g root "${STATE_DIR}"
  ok "${STATE_DIR}/"

  # Ensure lock files exist with correct permissions so shared flocks work
  # for non-root users (read-open requires read permission — 0644 is sufficient).
  for lockfile in \
    "${STATE_DIR}/patch-state.json.lock" \
    "${STATE_DIR}/patch-suppression.json.lock"
  do
    if [[ ! -e "$lockfile" ]]; then
      install -m 0644 -o root -g root /dev/null "$lockfile"
      ok "created ${lockfile}"
    else
      # Ensure permissions haven't drifted
      chmod 0644 "$lockfile"
      chown root:root "$lockfile"
      ok "verified ${lockfile}"
    fi
  done

  # --- systemd units ---
  local unit
  for unit in "${SERVICES[@]}"; do
    install -m 0644 -o root -g root \
      "${SYSTEMD_SRC}/${unit}" \
      "${SYSTEMD_DEST}/${unit}"
    ok "${SYSTEMD_DEST}/${unit}"
  done
}

# ---------------------------------------------------------------------------
# Step 5 — Deploy host-specific drop-in overrides
#
# On hosts listed in NAMESPACE_OVERRIDE_HOSTS (those whose kernel/container
# runtime cannot honour CLONE_NEWNS), deploy a drop-in that resets the
# namespace-requiring sandbox directives.  This resolves exit 226
# (EXIT_NAMESPACE) without modifying the source unit files, preserving full
# sandboxing on capable hosts such as PBWEBSRV03.
#
# The override source lives at:
#   overrides/<hostname>/<unit>.d/no-namespace.conf
# and is installed to:
#   /etc/systemd/system/<unit>.d/no-namespace.conf
# ---------------------------------------------------------------------------
deploy_overrides() {
  local current_host
  current_host="$(hostname -s)"

  local host
  for host in "${NAMESPACE_OVERRIDE_HOSTS[@]}"; do
    if [[ "$current_host" == "$host" ]]; then
      info "Host ${host}: deploying namespace-override drop-ins"

      local unit
      for unit in "${NAMESPACE_OVERRIDE_SERVICES[@]}"; do
        local src="${SCRIPT_DIR}/../overrides/${host}/${unit}.d/no-namespace.conf"
        local drop_in_dir="${SYSTEMD_DEST}/${unit}.d"
        local dst="${drop_in_dir}/no-namespace.conf"

        if [[ ! -f "$src" ]]; then
          die "Override source not found: ${src}"
        fi

        mkdir -p "$drop_in_dir"
        install -m 0644 -o root -g root "$src" "$dst"
        ok "installed ${dst}"
      done
      return 0
    fi
  done
}

# ---------------------------------------------------------------------------
# Step 6 — Verify deployed units match source
#
# Guards against the failure mode where stale unit files in /etc/systemd/system/
# shadow freshly-deployed files elsewhere, or where the deploy step silently
# wrote to the wrong path.  Diffs each deployed unit against its source;
# aborts if any differ so the operator knows before daemon-reload.
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
# Step 7 — Reload systemd and re-enable timers
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
  cleanup_pycache
  deploy_files
  deploy_overrides
  verify_units
  reload_systemd

  printf '\n[install] Deployment complete.\n'
}

main "$@"
