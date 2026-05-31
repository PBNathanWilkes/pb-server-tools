#!/usr/bin/env bash
# =============================================================================
# install.sh — Bootstrap and deploy all pb-server-tools components
#
# Run from the repo root as:
#   sudo bash install.sh [--only <component>]
#
# Components (installed in dependency order):
#   check-for-updates   patch monitoring + systemd timers
#   security-hardening  security posture checks + systemd timers
#   login-compliance    login-time banner check
#   server-sanity       read-only infrastructure sanity check
#
# Options:
#   --only <component>  Install a single named component only
#   --help, -h          Show this help
#
# Each component's install.sh is independently runnable; this script
# is a convenience wrapper that handles prerequisites and ordering.
#
# Exit codes:
#   0 — all components installed successfully
#   1 — installation failed
#   2 — must run as root
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

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

# _component_open <label>
# Prints three blank lines then a full-width double-rule box top with the
# component name centred on the top bar.  Marks the start of a sub-installer
# block so it is visually distinct from surrounding orchestrator output.
_component_open() {
  local label="$1"
  local total=79
  local inner="  ${label}  "
  local inner_len=${#inner}
  local left=$(( (total - inner_len) / 2 ))
  local right=$(( total - inner_len - left ))
  local left_bar right_bar full_bar
  printf -v left_bar  '%*s' "$left"  ''; left_bar="${left_bar// /═}"
  printf -v right_bar '%*s' "$right" ''; right_bar="${right_bar// /═}"
  printf -v full_bar  '%*s' "$total" ''; full_bar="${full_bar// /═}"

  printf '\n\n\n'
  printf '%s%s%s%s\n' "${BOLD}" "${BLU}" "${left_bar}${inner}${right_bar}" "${RST}"
  printf '%s%s%s%s\n' "${BOLD}" "${BLU}" "${full_bar}" "${RST}"
}

# _component_close <label> <exit_code>
# Prints a full-width double-rule box bottom with a pass/fail outcome line
# centred on the bottom bar.  Must be called after the sub-installer exits,
# passing its exit code as $2.
_component_close() {
  local label="$1" exit_code="$2"
  local total=79
  local inner colour
  if (( exit_code == 0 )); then
    inner="  ✔  ${label} complete  "
    colour="${GRN}"
  else
    inner="  ✘  ${label} FAILED  "
    colour="${RED}"
  fi
  local inner_len=${#inner}
  local left=$(( (total - inner_len) / 2 ))
  local right=$(( total - inner_len - left ))
  local left_bar right_bar full_bar
  printf -v left_bar  '%*s' "$left"  ''; left_bar="${left_bar// /═}"
  printf -v right_bar '%*s' "$right" ''; right_bar="${right_bar// /═}"
  printf -v full_bar  '%*s' "$total" ''; full_bar="${full_bar// /═}"

  printf '%s%s%s%s\n' "${BOLD}" "${colour}" "${full_bar}" "${RST}"
  printf '%s%s%s%s\n' "${BOLD}" "${colour}" "${left_bar}${inner}${right_bar}" "${RST}"
}

# ── Guards ───────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  printf "${RED}Error:${RST} must run as root — use: sudo bash %s\n" "$0" >&2
  exit 2
fi

# ── Argument parsing ─────────────────────────────────────────────────────────
ONLY_COMPONENT=""

for _arg in "$@"; do
  case "$_arg" in
    --only)
      # --only consumed as a pair; handled by shift-based loop below
      ;;
    --help|-h)
      sed -n '/^# Run from/,/^# Each component/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
  esac
done

# Re-parse with shift to correctly handle --only <value>
set -- "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      [[ -n "${2:-}" ]] || _die "--only requires a component name"
      ONLY_COMPONENT="$2"
      shift 2
      ;;
    --help|-h)
      exit 0   # already handled above
      ;;
    *)
      _die "Unknown option: $1"
      ;;
  esac
done

_START=$(date +%s%N)

printf '%s%s — pb-server-tools Installer%s\n' "${BOLD}" "$(hostname -s)" "${RST}"
printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"

# =============================================================================
# ── SECTION 1: System prerequisites ─────────────────────────────────────────
# =============================================================================
#
# Each component install.sh also checks its own prerequisites; this step
# installs missing packages up front so failures are reported at the start
# rather than mid-way through deployment.

install_prereqs() {
  _head "System prerequisites"

  local missing=()
  local packages=(
    jq
    msmtp
    s-nail
    openssl
    python3
    python3-apt
    python3-pytest
    ufw
    iproute2
  )

  for pkg in "${packages[@]}"; do
    # Map package name to binary name where they differ
    local bin="$pkg"
    case "$pkg" in
      s-nail)         bin="mailx" ;;
      iproute2)       bin="ss" ;;
      python3-apt)    bin="" ;;    # checked via python3 import below
      python3-pytest) bin="" ;;    # checked via python3 import below
    esac

    if [[ -n "$bin" ]]; then
      command -v "$bin" >/dev/null 2>&1 || missing+=("$pkg")
    fi
  done

  # python3-apt and python3-pytest need import checks
  python3 -B -c "import apt_pkg" 2>/dev/null || missing+=("python3-apt")
  python3 -B -c "import pytest"  2>/dev/null || missing+=("python3-pytest")

  if [[ ${#missing[@]} -gt 0 ]]; then
    printf "  installing missing packages: %s\n" "${missing[*]}"
    apt-get update -qq
    apt-get install -y "${missing[@]}"
    _ok "packages installed: ${missing[*]}"
  else
    _ok "all prerequisites already present"
  fi
}

# =============================================================================
# ── SECTION 2: Log directories ───────────────────────────────────────────────
# =============================================================================

ensure_log_dirs() {
  _head "Log directories"

  local dirs=(
    /backup/patch-logs
    /backup/security-logs
  )
  local d
  for d in "${dirs[@]}"; do
    if [[ ! -d "$d" ]]; then
      mkdir -p "$d"
      chmod 0750 "$d"
      _ok "created  $d"
    else
      _ok "exists   $d"
    fi
  done
}

# =============================================================================
# ── Component installer ──────────────────────────────────────────────────────
# =============================================================================

# run_component <component>
# Wraps a component sub-installer with open/close boundary banners so its
# output is visually isolated from orchestrator output.  On success, records
# one _ok at the orchestrator level.  On failure, records one _fail and
# returns 1 so the caller can decide whether to abort or continue.
run_component() {
  local component="$1"
  local component_dir="${SCRIPT_DIR}/${component}"

  _component_open "${component}"

  local rc=0
  if [[ ! -d "$component_dir" ]]; then
    _fail "component directory not found: ${component_dir}"
    _component_close "${component}" 1
    return 1
  fi
  if [[ ! -f "${component_dir}/install.sh" ]]; then
    _fail "no install.sh found in: ${component_dir}"
    _component_close "${component}" 1
    return 1
  fi

  bash "${component_dir}/install.sh" || rc=$?

  _component_close "${component}" "$rc"

  if (( rc == 0 )); then
    _ok "${component} installed"
  else
    _fail "${component} install.sh exited ${rc}"
    return 1
  fi
}

# =============================================================================
# ── Main ─────────────────────────────────────────────────────────────────────
# =============================================================================

if [[ -n "$ONLY_COMPONENT" ]]; then
  install_prereqs
  run_component "$ONLY_COMPONENT"
else
  install_prereqs
  ensure_log_dirs
  run_component "check-for-updates"
  run_component "security-hardening"
  run_component "login-compliance"
  run_component "server-sanity"
fi

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

printf '%s%sALL COMPONENTS INSTALLED%s\n\n' "${GRN}" "${BOLD}" "${RST}"

printf 'Next steps:\n'
printf '  1. Verify msmtp config:    sudo msmtp --serverinfo --host=<smtp-host>\n'
printf '  2. Check-for-updates:      sudo /usr/local/libexec/pb-maintenance/check-for-updates.sh --validate\n'
printf '  3. Security hardening:     sudo /usr/local/libexec/pb-maintenance/security-hardening-check.sh --validate\n'
printf '  4. Login compliance:       add snippet to ~/.bashrc (printed during login-compliance install)\n'
printf '  5. Confirm timers:         systemctl list-timers --all --no-pager\n'
printf '  6. Run sanity check:       sudo server-sanity-check\n'
