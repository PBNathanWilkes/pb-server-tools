#!/usr/bin/env bash
# =============================================================================
# install.sh — Bootstrap and deploy all pb-server-tools components
#
# Run from the repo root as:
#   sudo bash install.sh [--only <component>] [--dry-run] [--quiet] [--verbose]
#
# Components (installed in dependency order):
#   check-for-updates   patch monitoring + systemd timers
#   security-hardening  security posture checks + systemd timers
#   login-compliance    login-time banner check
#   server-sanity       read-only infrastructure sanity check
#
# Options:
#   --only <component>  Install a single named component only
#   --dry-run           Print what would be done; mutate nothing
#   --quiet             Suppress pass lines; show failures, warnings, summary
#   --verbose           Show commands and per-section elapsed time
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
  RED=$'\033[0;31m' GRN=$'\033[0;32m' YLW=$'\033[0;33m'
  BLU=$'\033[0;34m' DIM=$'\033[2m'    BOLD=$'\033[1m' RST=$'\033[0m'
else
  RED='' GRN='' YLW='' BLU='' DIM='' BOLD='' RST=''
fi

# ── Counters and accumulators ─────────────────────────────────────────────────
_pass=0; _fail=0; _warn=0
_FAILURES=(); _WARNINGS=()

# ── Mode flags (set by argument parsing) ─────────────────────────────────────
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
# _note <text>  — plain indented annotation; attach below _fail or _warn lines.
# No glyph, no counter.
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
# _run <label> <cmd> [args...]  — shows a progress dot before executing, then
# records the result via _ok/_fail with elapsed time.  In --dry-run mode,
# prints the command and records _ok without executing.
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
# _die <message> [hint]  — fatal error to stderr, then exit 1.
# Optional second argument prints an indented remediation hint.
_die() {
  local msg="$1" hint="${2:-}"
  printf "\n%s%sERROR:%s %s\n" "${BOLD}" "${RED}" "${RST}" "${msg}" >&2
  if [[ -n "${hint}" ]]; then
    printf "     %s%s%s\n" "${DIM}" "${hint}" "${RST}" >&2
  fi
  exit 1
}

# ── Component boundary banners ────────────────────────────────────────────────
# _component_open <label>   — 3 blank lines + full-width BLU/BOLD box top
# _component_close <label> <exit_code>  — full-width GRN/RED box bottom
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
_component_close() {
  local label="$1" exit_code="$2"
  local total=79
  local inner colour
  if (( exit_code == 0 )); then
    inner="  ✔  ${label} complete  "; colour="${GRN}"
  else
    inner="  ✘  ${label} FAILED  ";   colour="${RED}"
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
    --help|-h)
      sed -n '/^# Run from/,/^# Each component/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
  esac
done

set -- "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      [[ -n "${2:-}" ]] || _die "--only requires a component name"
      ONLY_COMPONENT="$2"
      shift 2
      ;;
    --dry-run)   _DRY_RUN=1;  shift ;;
    --quiet)     _QUIET=1;    shift ;;
    --verbose)   _VERBOSE=1;  shift ;;
    --help|-h)   exit 0 ;;
    *)           _die "Unknown option: $1" "Usage: sudo bash $0 [--only <component>] [--dry-run] [--quiet] [--verbose]" ;;
  esac
done

_START=$(date +%s%N)

printf '%s%s — pb-server-tools Installer%s\n' "${BOLD}" "$(hostname -s)" "${RST}"
printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
(( _DRY_RUN  )) && printf '%s[dry-run mode — no changes will be made]%s\n' "${YLW}" "${RST}"
(( _QUIET    )) && printf '%s[quiet mode — pass lines suppressed]%s\n'      "${DIM}" "${RST}"
(( _VERBOSE  )) && printf '%s[verbose mode — commands and section timings shown]%s\n' "${DIM}" "${RST}"

# =============================================================================
# ── SECTION 1: System prerequisites ─────────────────────────────────────────
# =============================================================================

install_prereqs() {
  _head "System prerequisites"

  local missing=()
  local packages=(
    jq msmtp s-nail openssl python3 python3-apt python3-pytest ufw iproute2
  )

  for pkg in "${packages[@]}"; do
    local bin="$pkg"
    case "$pkg" in
      s-nail)         bin="mailx" ;;
      iproute2)       bin="ss"    ;;
      python3-apt)    bin=""      ;;
      python3-pytest) bin=""      ;;
    esac
    if [[ -n "$bin" ]]; then
      command -v "$bin" >/dev/null 2>&1 || missing+=("$pkg")
    fi
  done

  python3 -B -c "import apt_pkg" 2>/dev/null || missing+=("python3-apt")
  python3 -B -c "import pytest"  2>/dev/null || missing+=("python3-pytest")

  if [[ ${#missing[@]} -gt 0 ]]; then
    _note "installing missing packages: ${missing[*]}"
    if (( ! _DRY_RUN )); then
      _run "apt-get update"  apt-get update -qq
      _run "apt-get install ${missing[*]}"  apt-get install -y "${missing[@]}"
    else
      printf "     %s[dry-run] apt-get install -y %s%s\n" "${DIM}" "${missing[*]}" "${RST}"
      _ok "packages would be installed: ${missing[*]}"
    fi
  else
    _ok "all prerequisites already present"
  fi
}

# =============================================================================
# ── SECTION 2: Log directories ───────────────────────────────────────────────
# =============================================================================

ensure_log_dirs() {
  _head "Log directories"

  local dirs=(/backup/patch-logs /backup/security-logs)
  local d
  for d in "${dirs[@]}"; do
    if [[ ! -d "$d" ]]; then
      if (( _DRY_RUN )); then
        printf "     %s[dry-run] mkdir -p %s && chmod 0750 %s%s\n" "${DIM}" "$d" "$d" "${RST}"
        _ok "would create  $d"
      else
        _run "create  $d"  bash -c "mkdir -p '$d' && chmod 0750 '$d'"
      fi
    else
      _ok "exists   $d"
    fi
  done
}

# =============================================================================
# ── Component installer ──────────────────────────────────────────────────────
# =============================================================================

# run_component <component>
# Wraps a component sub-installer with open/close boundary banners.
# Passes through --dry-run / --quiet / --verbose flags to the sub-installer.
run_component() {
  local component="$1"
  local component_dir="${SCRIPT_DIR}/${component}"

  _component_open "${component}"

  local rc=0
  if [[ ! -d "$component_dir" ]]; then
    _fail "component directory not found: ${component_dir}"
    _note "Expected: ${component_dir}"
    _component_close "${component}" 1
    return 1
  fi
  if [[ ! -f "${component_dir}/install.sh" ]]; then
    _fail "no install.sh found in: ${component_dir}"
    _component_close "${component}" 1
    return 1
  fi

  local flags=()
  (( _DRY_RUN )) && flags+=(--dry-run)
  (( _QUIET   )) && flags+=(--quiet)
  (( _VERBOSE )) && flags+=(--verbose)

  bash "${component_dir}/install.sh" "${flags[@]}" || rc=$?

  _component_close "${component}" "$rc"

  if (( rc == 0 )); then
    _ok "${component} installed"
  else
    _fail "${component} install.sh exited ${rc}"
    _note "Re-run: sudo bash ${SCRIPT_DIR}/install.sh --only ${component}"
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
