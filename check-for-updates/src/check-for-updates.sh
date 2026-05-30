#!/usr/bin/env bash
# check-for-updates.sh — Backward-compatible shim for check-for-updates v4.2
#
# External interface identical to v3.x. Invokes pb-apt-evaluator.py then
# pb-patch-reporter.sh, passing flags through.
#
# Systemd unit ExecStart lines require no changes.
#
# v4.2.12
## VERSION HISTORY (for maintainers):
# v4.2.16 — Fix: _check_lts() in pb-apt-evaluator.py. Removes defunct
#            check-new-release/check-new-release-gtk path lookup (scripts no
#            longer exist on Ubuntu 24.04+). Drops -f DistUpgradeViewNonInteractive
#            which suppressed all output on 24.04+, causing lts_upgrade_available
#            to always be false. Adds LANG/LC_ALL=C for locale-independent output.
# v4.2.12 — Fix: Eliminate TOCTOU race in APT lock handling. _wait_for_apt_lock()
#            replaced by _acquire_apt_locks() / _release_apt_locks(). Locks are
#            held open (pass_fds) across the apt-get update subprocess call so
#            apt-daily cannot interpose between our flock check and apt-get
#            update's own acquisition. Fixes intermittent apt_update_failed=true
#            on systemd-scheduled runs. (pb-apt-evaluator.py only.)
# v4.2.11 — Add /var/lib/apt/lists/lock to APT_LOCK_PATHS (was dpkg only).
# v4.2.0 — Full architectural rewrite. Native apt_pkg.DepCache.phasing_applied()
#           replaces text-scraping of dist-upgrade -s simulation output. Cross-run
#           confirmation gate (seen_count >= 2) replaces in-run sleep. State split
#           into evaluator-owned patch-state.json and reporter-owned
#           patch-suppression.json. Suppression keyed on (name, arch, candidate_ver).
#           Suppression TTL 4 days. apt_update_failed → CRITICAL at login.
#           login-compliance-check.sh reads JSON via jq (XDG cache TTL removed).
#           This shim preserves the v3.x external interface unchanged.
# v3.10.17 — Bugfix: Eliminate dual invocation of apt-get dist-upgrade -s.
# v3.10.16 — Fix: Remove PrivateTmp=true from service units.
# v3.10.15 — Bugfix: Exclude phased packages from get_actual_upgrades.
# v3.10.14 — Fix pb-last-update permissions.
# v3.10.13 — Write /var/lib/apt/lists/pb-last-update stamp after apt-get update.
# v3.10.12 — Add explicit PATCH_MONITOR_RESULT marker and base 30-day summary on it.
# v3.10.11 — Fix: show last 30 days run/email summary for --validate/--monthly.
# v3.10.3  — Systemd: remove crontab schedule reporting.
# v3.10.2  — Email layout: put update command + package lists first.
# v3.10.1  — ShellCheck clean.
# v3.10.0  — Feature: Filter out phased updates.
# v3.9.x   — Various bugfixes (LTS detection, security status).
# v3.8.x   — Display crontab/systemd schedule.
# v3.7.x   — LTS upgrade detection; --validate/--monthly modes.
# v3.6     — Filter held packages.
# v3.5     — dist-upgrade for kernel changes.
# v3.0     — Security updates separation, reboot detection, unattended-upgrades.
# v2.x     — Refactors.
# v1.1     — Original HTML email implementation.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
readonly VERSION="4.2.16"
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

readonly LIBEXEC_DIR="/usr/local/libexec/pb-maintenance"
readonly EVALUATOR="${LIBEXEC_DIR}/pb-apt-evaluator.py"
readonly REPORTER="${LIBEXEC_DIR}/pb-patch-reporter.sh"

readonly STATE_DIR="/var/lib/pb-maintenance"
readonly STATE_FILE="${STATE_DIR}/patch-state.json"
readonly APT_STAMP="/var/lib/apt/lists/pb-last-update"
readonly LOG_DIR="/backup/patch-logs"

readonly HOSTNAME_FQDN="$(hostname --fqdn 2>/dev/null || hostname)"

readonly C_CYAN=$'\033[0;36m'
readonly C_RESET=$'\033[0m'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
LOG_FILE=""

log() {
  local ts line
  ts="$(date +'%Y-%m-%d %H:%M:%S')"
  line="[${ts}] $*"
  printf "%s\n" "$line"
  [[ -n "${LOG_FILE:-}" ]] && printf "%s\n" "$line" >>"$LOG_FILE"
}

section() {
  local title bar
  title="$1"
  bar="$(printf '%*s' "${#title}" '' | tr ' ' '=')"
  if [[ -t 1 ]]; then
    printf "\n%s%s%s\n%s%s%s\n" "$C_CYAN" "$title" "$C_RESET" "$C_CYAN" "$bar" "$C_RESET"
  fi
  [[ -n "${LOG_FILE:-}" ]] && printf "\n%s\n%s\n" "$title" "$bar" >>"$LOG_FILE"
}

ensure_logdir() {
  local tag basename
  tag="$(date +%Y%m%d_%s)"
  basename="${tag}-${HOSTNAME_FQDN}-update-patch.log"
  if mkdir -p "$LOG_DIR" 2>/dev/null && [[ -w "$LOG_DIR" ]]; then
    LOG_FILE="${LOG_DIR}/${basename}"
  else
    LOG_FILE="/tmp/${basename}"
  fi
}

# ---------------------------------------------------------------------------
# TTY path display
# ---------------------------------------------------------------------------
display_paths() {
  [[ -t 1 ]] || return 0
  log "Host          : ${HOSTNAME_FQDN}"
  log "Script        : ${SCRIPT_NAME} v${VERSION}"
  log "Mode          : ${MODE}"
  log "Evaluator     : ${EVALUATOR}"
  log "Reporter      : ${REPORTER}"
  log "State file    : ${STATE_FILE}"
  log "Log file      : ${LOG_FILE}"
  log "apt stamp     : ${APT_STAMP}"
  log "Patch logs    : ${LOG_DIR}/"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
MODE="check"
ADDITIONAL_RECIPIENT=""
DRY_RUN_FLAG=""

show_help() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [--check|--validate|--monthly] [--email ADDRESS] [--help|-h]

  --check     Check for updates; email only if updates exist or reboot required.
  --validate  Always email a full audit report.
  --monthly   Monthly verification report (always emails, both recipients).
  --email     Add an additional email recipient.
  --help, -h  Show this help.

Recipients:
  --check     ${RECIPIENTS_NORMAL:-nathan.wilkes@pbhcorp.com}  (conditional)
  --validate  ${RECIPIENTS_VALIDATE:-nathan.wilkes@pbhcorp.com}  (always)
  --monthly   ${RECIPIENTS_MONTHLY:-nathan.wilkes@pbhcorp.com support@pbhcorp.com}  (always)

Architecture (v4.2):
  This shim invokes:
    ${EVALUATOR}  (writes ${STATE_FILE})
    ${REPORTER}   (reads state, sends email)
EOF
}

validate_email_addr() {
  [[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

parse_arguments() {
  if [[ $# -eq 0 ]]; then
    show_help
    trap - ERR
    exit 1
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)   MODE="check";    shift ;;
      --validate) MODE="validate"; shift ;;
      --monthly) MODE="monthly";  shift ;;
      --email)
        [[ -z "${2:-}" ]] && { printf "ERROR: --email requires an address\n\n" >&2; show_help; trap - ERR; exit 1; }
        validate_email_addr "$2" || { printf "ERROR: invalid email: %s\n\n" "$2" >&2; show_help; trap - ERR; exit 1; }
        ADDITIONAL_RECIPIENT="$2"; shift 2 ;;
      --help|-h)
        show_help; trap - ERR; exit 0 ;;
      *)
        printf "ERROR: unknown option: %s\n\n" "$1" >&2
        show_help; trap - ERR; exit 1 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
require_root() {
  if [[ $EUID -ne 0 ]]; then
    printf "ERROR: must run as root (sudo).\n" >&2
    exit 1
  fi
}

require_evaluator() {
  if [[ ! -x "$EVALUATOR" ]]; then
    log "ERROR: evaluator not found or not executable: ${EVALUATOR}"
    log "Deploy pb-apt-evaluator.py to ${LIBEXEC_DIR}/"
    return 1
  fi
}

require_reporter() {
  if [[ ! -x "$REPORTER" ]]; then
    log "ERROR: reporter not found or not executable: ${REPORTER}"
    log "Deploy pb-patch-reporter.sh to ${LIBEXEC_DIR}/"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local original_args="$*"
  parse_arguments "$@"
  require_root
  ensure_logdir

  section "check-for-updates v${VERSION} started"
  display_paths

  require_evaluator || exit 1
  require_reporter  || exit 1

  # Build evaluator args
  local eval_args=("--mode" "$MODE")

  # Build reporter args
  local report_args=("--${MODE}")
  [[ -n "$ADDITIONAL_RECIPIENT" ]] && report_args+=("--email" "$ADDITIONAL_RECIPIENT")

  # --- Run evaluator ---
  section "Running evaluator"
  log "Invoking: python3 ${EVALUATOR} ${eval_args[*]}"

  if ! python3 "$EVALUATOR" "${eval_args[@]}"; then
    local rc=$?
    log "ERROR: pb-apt-evaluator.py exited ${rc}"
    log "State file not written or not updated. Reporter will not run."
    log "The absent/stale state file will surface as WARN at next login."
    exit "$rc"
  fi

  # --- Run reporter ---
  section "Running reporter"
  log "Invoking: ${REPORTER} ${report_args[*]}"

  if ! bash "$REPORTER" "${report_args[@]}"; then
    local rc=$?
    log "ERROR: pb-patch-reporter.sh exited ${rc}"
    exit "$rc"
  fi

  section "check-for-updates complete"
  log "Done."
}

main "$@"
exit 0
