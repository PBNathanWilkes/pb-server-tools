#!/usr/bin/env bash
# =============================================================================
# install.sh — Build, test, and deploy security-hardening
#
# Run from the repo root as:
#   sudo bash security-hardening/install.sh
#
# What it does:
#   1. Verifies prerequisites
#   2. Runs unit tests; aborts on any failure
#   3. Deploys source files to production locations with correct permissions
#   4. Deploys host-specific drop-in overrides (no-namespace on restricted hosts)
#   5. Verifies deployed systemd units match source; aborts if any differ
#   6. Reloads systemd and re-enables timers
#
# Production layout:
#   /usr/local/libexec/pb-maintenance/   security-hardening-check.sh (0750 root:root)
#   /var/lib/pb-maintenance/             state directory (0755 root:root)
#   /etc/systemd/system/                 pb-security-hardening-check{,-monthly}.{service,timer}
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
  pb-security-hardening-check.service
  pb-security-hardening-check.timer
  pb-security-hardening-check-monthly.service
  pb-security-hardening-check-monthly.timer
)
readonly TIMERS=(
  pb-security-hardening-check.timer
  pb-security-hardening-check-monthly.timer
)

# Hosts that cannot honour CLONE_NEWNS (mount namespace) sandbox directives.
# See overrides/<hostname>/README.md and DEV-GUIDE.md §6 KFC-R02.
readonly NAMESPACE_OVERRIDE_HOSTS=(
  pblinuxutility
)
readonly NAMESPACE_OVERRIDE_SERVICES=(
  pb-security-hardening-check.service
  pb-security-hardening-check-monthly.service
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

printf '%s%s — security-hardening Installer%s\n' "${BOLD}" "$(hostname -s)" "${RST}"
printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"

# =============================================================================
# ── STEP 1: Prerequisites ────────────────────────────────────────────────────
# =============================================================================

check_prereqs() {
  _head "Prerequisites"

  command -v mailx   >/dev/null 2>&1 || _die "mailx not found — sudo apt install s-nail"
  command -v msmtp   >/dev/null 2>&1 || _die "msmtp not found — sudo apt install msmtp"
  command -v openssl >/dev/null 2>&1 || _die "openssl not found — sudo apt install openssl"
  command -v ss      >/dev/null 2>&1 || _die "ss not found — sudo apt install iproute2"
  command -v ufw     >/dev/null 2>&1 || _die "ufw not found — sudo apt install ufw"

  _ok "all prerequisites present"
}

# =============================================================================
# ── STEP 2: Unit tests ───────────────────────────────────────────────────────
# =============================================================================

run_tests() {
  _head "Unit tests"

  local test_user="${SUDO_USER:-$(id -un)}"

  printf '  running test_security_hardening.sh\n'
  sudo -u "$test_user" bash "${TESTS_DIR}/test_security_hardening.sh" \
    || _die "security hardening tests failed — aborting deployment"
  _ok "test_security_hardening.sh passed"
}

# =============================================================================
# ── STEP 3: Deploy files ─────────────────────────────────────────────────────
# =============================================================================

deploy_files() {
  _head "Deploy files"

  mkdir -p "${LIBEXEC_DIR}"
  install -d -m 0755 -o root -g root "${STATE_DIR}"

  install -m 0750 -o root -g root \
    "${SRC_DIR}/security-hardening-check.sh" \
    "${LIBEXEC_DIR}/security-hardening-check.sh"
  _ok "${LIBEXEC_DIR}/security-hardening-check.sh"

  local unit
  for unit in "${SERVICES[@]}"; do
    install -m 0644 -o root -g root \
      "${SYSTEMD_SRC}/${unit}" \
      "${SYSTEMD_DEST}/${unit}"
    _ok "${SYSTEMD_DEST}/${unit}"
  done
}

# =============================================================================
# ── STEP 4: Namespace-override drop-ins ──────────────────────────────────────
# =============================================================================
#
# On hosts listed in NAMESPACE_OVERRIDE_HOSTS, deploy a drop-in that resets
# namespace-requiring sandbox directives (ProtectSystem=strict, PrivateTmp=true,
# ProtectKernelModules=true, ProtectKernelTunables=true).  These cause exit 226
# (EXIT_NAMESPACE) on container/VM hosts that do not permit CLONE_NEWNS.
# Source unit files are not modified; sandboxing on capable hosts is preserved.

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
# ── STEP 5: Verify deployed units ────────────────────────────────────────────
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
# ── STEP 6: Reload systemd ───────────────────────────────────────────────────
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
