#!/usr/bin/env bash
# =============================================================================
# server-sanity-check — infrastructure sanity check
#
# Checks the essential health of all three applications and the email stack.
# Read-only: no services triggered, no state mutated.
# Must run as root (sudo).
#
# Usage:
#   sudo server-sanity-check [--email-on-failure] [--quiet] [--verbose]
#
# Options:
#   --email-on-failure
#       After all checks complete, if any check FAILED (exit 1), email the
#       full report to EMAIL_PRIMARY sourced from /etc/balena-monitor/config.
#       Warnings (exit 0) do not trigger an email.  Intended for automated
#       scheduled runs; see pb-server-sanity-check.timer.
#   --quiet
#       Suppress pass lines; show only failures, warnings, and the summary.
#       Useful when capturing output to a log file or reviewing after the run.
#   --verbose
#       Show per-section elapsed time and annotate each _run call with the
#       underlying command.  Useful for diagnosing slow or failing steps.
#
# Exit codes:
#   0 — all checks passed (warnings are acceptable)
#   1 — one or more checks failed
#   2 — must run as root
#
# Applications checked:
#   • Email stack (msmtp)                          — always checked
#   • Email DNS Monitor  (/opt/email-dns-monitor)  — skipped if not installed
#   • Balena Monitor     (/opt/balena-monitor)      — skipped if not installed
#   • SharePoint Export  (/opt/sharepoint-export)  — skipped if not installed
#   • Server Tools       (/usr/local/libexec/pb-maintenance)
#   • lighttpd                                      — skipped if not installed
#   • Server Sanity Check (self)                   — always checked
#
# Optional sections (2–4, 6) are guarded: sections 2–4 by their /opt install
# root; section 6 (lighttpd) by binary presence.  If the sentinel is absent
# the section prints "not installed" and no counters are incremented.
# =============================================================================

set -Eeuo pipefail

# ── Argument parsing ─────────────────────────────────────────────────────────
_EMAIL_ON_FAILURE=0
_QUIET=0
_VERBOSE=0

for _arg in "$@"; do
  case "$_arg" in
    --email-on-failure) _EMAIL_ON_FAILURE=1 ;;
    --quiet)            _QUIET=1 ;;
    --verbose)          _VERBOSE=1 ;;
    --help|-h)
      sed -n '/^# Usage:/,/^# Applications checked:/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$_arg" >&2
      exit 2
      ;;
  esac
done

# ── Colour palette ──────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED=$'\033[0;31m' GRN=$'\033[0;32m' YLW=$'\033[0;33m'
  BLU=$'\033[0;34m' DIM=$'\033[2m'    BOLD=$'\033[1m' RST=$'\033[0m'
else
  RED='' GRN='' YLW='' BLU='' DIM='' BOLD='' RST=''
fi

# ── Counters and accumulators ─────────────────────────────────────────────────
_pass=0; _fail=0; _warn=0
_FAILURES=(); _WARNINGS=()

# ── Section timing ────────────────────────────────────────────────────────────
_SECTION_START=0

# ── Output capture for --email-on-failure ────────────────────────────────────
# When the flag is set we tee all stdout to a temp file so the email body
# is available after the run.  The file is cleaned up on EXIT via _trap_exit.
_CAPTURE_FILE=''
if (( _EMAIL_ON_FAILURE )); then
  _CAPTURE_FILE=$(mktemp /tmp/server-sanity-XXXXXX.txt)
  # Redirect stdout through tee; stderr goes to journal only (not emailed).
  exec > >(tee -a "$_CAPTURE_FILE")
fi

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
_skip() { printf "  ⊘  %s\n" "$*"; }

# ── Traps ────────────────────────────────────────────────────────────────────
# _ERR_HANDLED: not used by this script (no _die), but guards against re-entry
#               if a future ERR fires after the trap itself encounters an error.
# _EXIT_CLEAN:  set unconditionally before exit "$_EXIT" in the summary block.
#               Silences both _trap_err and _trap_exit on all normal exit paths
#               (success and failure).  Must be set before every top-level exit.
_ERR_HANDLED=0
_EXIT_CLEAN=0

# Called indirectly: trap '_trap_err' ERR
# shellcheck disable=SC2317
_trap_err() {
  local rc=$? line=${BASH_LINENO[0]} cmd="${BASH_COMMAND}"
  # Suppress after a normal exit path (including failure exits).  _EXIT_CLEAN
  # is set unconditionally before exit "$_EXIT" in the summary block, so the
  # ERR trap must not fire on the exit call itself.
  (( _EXIT_CLEAN )) && return
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

# Called indirectly: trap '_trap_exit' EXIT
# shellcheck disable=SC2317
_trap_exit() {
  # Clean up capture file regardless of exit path
  [[ -n "${_CAPTURE_FILE}" ]] && rm -f "${_CAPTURE_FILE}"
  (( _EXIT_CLEAN )) && return
  local _end _ms
  _end=$(date +%s%N)
  _ms=$(( (_end - ${_START:-$_end}) / 1000000 ))
  printf "\n%s(exited after %dms)%s\n" "${DIM}" "$_ms" "${RST}" >&2
}
trap '_trap_exit' EXIT
if [[ $EUID -ne 0 ]]; then
  printf "${RED}Error:${RST} must run as root — use: sudo bash %s\n" "$0" >&2
  exit 2
fi

_START=$(date +%s%N)

printf '%s%s — Infrastructure Sanity Check%s\n' "${BOLD}" "$(hostname -s)" "${RST}"
printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
(( _QUIET   )) && printf '%s[quiet mode — pass lines suppressed]%s\n'      "${DIM}" "${RST}"
(( _VERBOSE )) && printf '%s[verbose mode — section timings shown]%s\n'    "${DIM}" "${RST}"

# =============================================================================
# Helper functions
# =============================================================================

# check_binary <cmd>
check_binary() {
  local cmd=$1
  if command -v "$cmd" >/dev/null 2>&1; then
    _ok "binary:  $cmd  ($(command -v "$cmd"))"
  else
    _fail "binary missing: $cmd"
  fi
}

# check_file <path> [label]
check_file() {
  local path=$1 label=${2:-$1}
  if [[ -f $path ]]; then _ok  "file:    $label"
  else                   _fail "file missing: $label"
  fi
}

# check_dir <path> [label]
check_dir() {
  local path=$1 label=${2:-$1}
  if [[ -d $path ]]; then _ok  "dir:     $label"
  else                    _fail "dir missing: $label"
  fi
}

# check_dir_owner <path> <expected_owner>
check_dir_owner() {
  local path=$1 owner=$2
  if [[ ! -d $path ]]; then
    _fail "dir missing (ownership unchecked): $path"
    return
  fi
  local actual
  actual=$(stat -c '%U' "$path" 2>/dev/null || echo '?')
  if [[ $actual == "$owner" ]]; then
    _ok  "ownership: $path  (owner: $actual)"
  else
    _fail "ownership: $path  (expected $owner, got $actual)"
  fi
}

# check_file_mode <path> <expected_octal> <expected_owner>
check_file_mode() {
  local path=$1 mode=$2 owner=$3
  if [[ ! -f $path ]]; then return; fi   # file-existence checked separately
  local actual_mode actual_owner
  actual_mode=$(stat -c '%a'  "$path" 2>/dev/null || echo '?')
  actual_owner=$(stat -c '%U' "$path" 2>/dev/null || echo '?')
  if [[ $actual_mode == "$mode" && $actual_owner == "$owner" ]]; then
    _ok  "permissions: $path  (${mode} ${owner})"
  else
    _fail "permissions: $path  (expected ${mode}/${owner}, got ${actual_mode}/${actual_owner})"
    _note "Fix: chmod ${mode} ${path} && chown ${owner} ${path}"
  fi
}

# check_user <username>
check_user() {
  local u=$1
  if id -- "$u" >/dev/null 2>&1; then _ok  "user:    $u"
  else                                _fail "service user missing: $u"
  fi
}

# check_symlink_target <symlink>
# Warns if the symlink target does not exist (install root gone / not a symlink).
check_symlink_target() {
  local link=$1
  if [[ ! -L $link ]]; then return; fi   # not a symlink — binary check already handled it
  local target
  target=$(readlink -f "$link" 2>/dev/null || true)
  if [[ -n $target && -f $target ]]; then
    _ok  "symlink: $link → $target"
  else
    _fail "symlink target missing: $link → ${target:-<unresolvable>}"
  fi
}

# check_group_member <group> <user>
# Fails if <user> is not a member of <group>.
# Also fails if the group itself does not exist.
check_group_member() {
  local group=$1 user=$2
  if ! getent group "$group" >/dev/null 2>&1; then
    _fail "group membership: group '$group' does not exist"
    return
  fi
  local members
  members=$(getent group "$group" | cut -d: -f4)
  # getent group returns comma-separated members in field 4; also check
  # primary group via id so users whose primary GID is msmtp are not missed.
  if echo ",$members," | grep -q ",${user}," 2>/dev/null \
      || id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$group"; then
    _ok  "group membership: $user ∈ $group"
  else
    _fail "group membership: $user not in $group  (emails will fail silently)"
    _note "Fix: sudo usermod -aG ${group} ${user}  (then re-login or newgrp)"
  fi
}

# check_conf_keys <config_file> <key1> [key2 ...]
# Sources the config once and checks every key for non-empty value.
# Config values are NEVER printed.
check_conf_keys() {
  local conf=$1; shift
  local keys=("$@")

  if [[ ! -f $conf ]]; then
    for key in "${keys[@]}"; do
      _fail "conf key $key (config file missing)"
    done
    return
  fi

  # Build a small inline script that sources the config and emits OK/MISS lines.
  local script
  script="source \"$conf\" 2>/dev/null"$'\n'
  for key in "${keys[@]}"; do
    script+="[[ -n \"\${${key}:-}\" ]] && echo \"OK:${key}\" || echo \"MISS:${key}\""$'\n'
  done

  local output
  output=$(bash -c "$script" 2>/dev/null) || true

  while IFS= read -r line; do
    local status=${line%%:*} key=${line#*:}
    if [[ $status == "OK" ]];   then _ok   "conf key: $key"
    elif [[ $status == "MISS" ]]; then _fail "conf key missing/empty: $key"
    fi
  done <<< "$output"
}

# check_conf_syntax <config_file>
check_conf_syntax() {
  local conf=$1
  if [[ ! -f $conf ]]; then return; fi
  if bash -n "$conf" 2>/dev/null; then
    _ok  "conf syntax OK: $(basename "$conf")"
  else
    _fail "conf has invalid shell syntax: $conf"
  fi
}

# check_timer <unit>
# Checks the timer is active and shows next scheduled trigger.
check_timer() {
  local unit=$1
  local state
  state=$(systemctl is-active "$unit" 2>/dev/null || echo "inactive")

  if [[ $state == "active" ]]; then
    # list-timers gives human-readable NEXT column; avoids µs→epoch arithmetic
    # overflow in bash signed 64-bit integers with large NextElapseUSecRealtime values.
    local next_str
    next_str=$(systemctl list-timers "$unit" --no-pager --no-legend 2>/dev/null \
               | awk 'NR==1 {print $2, $3, $4}')
    [[ -z $next_str ]] && next_str="unknown"
    _ok "timer:   $unit  (next: $next_str)"
  else
    _fail "timer not active: $unit  (state: $state)"
    _note "Fix: sudo systemctl enable --now ${unit}"
  fi
}

# check_last_run <service_unit>
# Reports result of the most recent completed run.
# Result=success is the only acceptance criterion (systemd honours SuccessExitStatus).
# Treats "never run" as a warning — acceptable on a freshly provisioned host.
check_last_run() {
  local unit=$1

  # Read Result, ExecMainStatus, and the last inactive timestamp in one call.
  local props
  props=$(systemctl show "$unit" \
    -p Result \
    -p ExecMainStatus \
    -p InactiveEnterTimestamp \
    2>/dev/null) || true

  local result exit_status timestamp
  result=$(      grep '^Result='                  <<< "$props" | cut -d= -f2-)
  exit_status=$( grep '^ExecMainStatus='          <<< "$props" | cut -d= -f2-)
  timestamp=$(   grep '^InactiveEnterTimestamp='  <<< "$props" | cut -d= -f2-)

  if [[ -z $timestamp || $timestamp == "n/a" || $timestamp == " " ]]; then
    _warn "last run: $unit — no run recorded yet (new host?)"
    return
  fi

  if [[ $result == "success" ]]; then
    _ok  "last run: $unit — success (exit $exit_status) at $timestamp"
  else
    _fail "last run: $unit — ${result:-unknown} (exit $exit_status) at $timestamp"
  fi
}

# check_no_lockfile <path>
check_no_lockfile() {
  local lf=$1
  if [[ -f $lf ]]; then
    # Check age to distinguish "actively running" from "stale"
    local age
    age=$(( $(date +%s) - $(stat -c '%Y' "$lf" 2>/dev/null || echo 0) ))
    if (( age > 3600 )); then
      _fail "stale lock file: $lf  (age: ${age}s — possible stuck run)"
    else
      _warn "lock file present: $lf  (age: ${age}s — run may be in progress)"
    fi
  else
    _ok  "no stale lock file"
  fi
}


# check_cert_expiry_file <pemfile> [label]
# Reads a PEM certificate file from disk and checks expiry.
# Thresholds: ≤7 days → _fail; ≤30 days → _warn; otherwise → _ok.
# Uses the first certificate block in the file (correct for fullchain.pem).
check_cert_expiry_file() {
  local pem=$1 label=${2:-$1}

  if [[ ! -f $pem ]]; then
    _fail "cert expiry: file not found: ${label}"
    return
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    _warn "cert expiry: openssl not found — skipping ${label}"
    return
  fi

  local enddate
  enddate=$(openssl x509 -noout -enddate -in "$pem" 2>/dev/null | sed 's/notAfter=//')

  if [[ -z $enddate ]]; then
    _fail "cert expiry: could not parse certificate: ${label}"
    return
  fi

  local expiry_epoch now_epoch days_left
  expiry_epoch=$(date -d "$enddate" +%s 2>/dev/null)
  if [[ -z $expiry_epoch ]]; then
    _fail "cert expiry: could not parse expiry date for ${label} (${enddate})"
    return
  fi

  now_epoch=$(date +%s)
  days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

  if   (( days_left <= 0 ));  then _fail "cert expiry: ${label} — EXPIRED  (${enddate})"
  elif (( days_left <= 7 ));  then _fail "cert expiry: ${label} — ${days_left}d remaining  (${enddate})"
  elif (( days_left <= 30 )); then _warn "cert expiry: ${label} — ${days_left}d remaining  (${enddate})"
  else                              _ok   "cert expiry: ${label} — ${days_left}d remaining  (${enddate})"
  fi
}


# =============================================================================
# ── SECTION 1: Email stack (msmtp) ──────────────────────────────────────────
# =============================================================================
_head "Email stack (msmtp)"

check_binary msmtp
check_binary mailx

MSMTPRC=/etc/msmtprc
check_file "$MSMTPRC" "/etc/msmtprc"

if [[ -f $MSMTPRC ]]; then
  # Check a default account is configured
  if grep -qE '^account[[:space:]]+default' "$MSMTPRC" 2>/dev/null; then
    _ok  "msmtprc: 'account default' mapping found"
  else
    _warn "msmtprc: no 'account default' mapping found"
  fi

  # TLS enabled
  if grep -qE '^tls[[:space:]]+(on|yes)' "$MSMTPRC" 2>/dev/null; then
    _ok  "msmtprc: TLS enabled"
  else
    _warn "msmtprc: TLS not detected"
  fi

  # host configured
  if grep -qE '^host[[:space:]]+\S' "$MSMTPRC" 2>/dev/null; then
    _msmtp_host=$(grep -E '^host[[:space:]]+' "$MSMTPRC" | awk '{print $2}' | head -1)
    _ok  "msmtprc: relay host configured ($_msmtp_host)"
  else
    _fail "msmtprc: no 'host' directive found"
  fi
fi

# msmtp log — evidence of a successful recent send
MSMTP_LOG_DIR=/var/log/msmtp
if [[ -d $MSMTP_LOG_DIR ]]; then
  _ok  "dir:     $MSMTP_LOG_DIR"
  # Look for a successful send in any log file under the dir
  if grep -rqE 'exitcode=EX_OK' "$MSMTP_LOG_DIR" 2>/dev/null; then
    last_ok_ts=$(grep -rh 'exitcode=EX_OK' "$MSMTP_LOG_DIR" 2>/dev/null \
                 | tail -1 | grep -oE '^[A-Za-z]{3}[[:space:]]+[0-9]+ [0-9:]+' || echo "unknown")
    _ok  "msmtp log: last successful send — $last_ok_ts"
  else
    _warn "msmtp log: no successful send found (first run, or emails not yet sent)"
  fi
else
  _warn "msmtp log dir not found: $MSMTP_LOG_DIR  (created on first send)"
fi


# msmtp group membership — sourced from /etc/server-tools/server-sanity.conf.
# Without msmtp group membership the binary exits silently with a permission
# error and no log entry is written.
# The config file is installed by server-sanity/install.sh from
# overrides/<hostname>/server-sanity.conf in the repo.
MSMTP_GROUP_MEMBERS=()
_SANITY_CONF=/etc/server-tools/server-sanity.conf
if [[ -f $_SANITY_CONF ]]; then
  # shellcheck source=/dev/null
  source "$_SANITY_CONF"
  if (( ${#MSMTP_GROUP_MEMBERS[@]} == 0 )); then
    _warn "msmtp group members: config present but MSMTP_GROUP_MEMBERS is empty"
    _note "Edit ${_SANITY_CONF} and add the accounts that send email on this host"
  else
    for _member in "${MSMTP_GROUP_MEMBERS[@]}"; do
      check_group_member msmtp "$_member"
    done
  fi
else
  _warn "msmtp group members: ${_SANITY_CONF} not found — group membership unchecked"
  _note "Deploy: sudo bash server-sanity/install.sh  (from the repo root)"
fi


# =============================================================================
# ── SECTION 2: Email DNS Monitor ─────────────────────────────────────────────
# =============================================================================
_head "Email DNS Monitor"

EDM_INSTALL=/opt/email-dns-monitor

if [[ -d $EDM_INSTALL ]]; then

  EDM_BIN=/usr/local/bin/email-dns-monitor
  EDM_CONF=/etc/email-dns-monitor/email-dns-monitor.conf
  EDM_STATE=/var/lib/email-dns-monitor
  EDM_BACKUP=/var/backups/email-dns-monitor
  EDM_LOG=/var/log/email-dns-monitor
  EDM_DOMAINS_JSON=${EDM_INSTALL}/domains/domains.json

  check_binary email-dns-monitor
  check_symlink_target "$EDM_BIN"
  check_user emaildns
  check_dir  "$EDM_INSTALL"     "install root"
  check_file "$EDM_CONF"        "config"
  check_conf_syntax "$EDM_CONF"
  check_dir  "$EDM_STATE"           "state dir"
  check_dir  "$EDM_STATE/history"   "state/history"
  check_dir  "$EDM_STATE/domains"   "state/domains"
  check_dir_owner "$EDM_STATE"  emaildns
  check_dir       "$EDM_LOG"             "log dir"
  check_dir_owner "$EDM_LOG"        emaildns
  check_dir       "$EDM_BACKUP"          "backup dir"
  check_dir_owner "$EDM_BACKUP"     emaildns

  # Backup archive recency — EDM writes email-dns-monitor-state-*.tar.gz to
  # $EDM_BACKUP on each run.  The directory is 0700 emaildns:emaildns so root
  # cannot stat it directly; all find calls must use sudo -u emaildns.
  #
  # Thresholds: count = 0 → _fail (no archives ever written);
  #             most-recent mtime > 48 h → _fail (service stale or backups broken);
  #             most-recent mtime > 25 h → _warn (missed at least one daily window);
  #             otherwise → _ok.
  # Count archives.  Use || true so pipefail does not fire when find exits
  # non-zero (e.g. a transient permission warning on a subdirectory).
  # Trim whitespace from wc -l output before integer comparison.
  _edm_archive_count=0
  _edm_archive_count=$(sudo -u emaildns find "$EDM_BACKUP" \
    -maxdepth 1 -name 'email-dns-monitor-state-*.tar.gz' \
    2>/dev/null | wc -l || true)
  _edm_archive_count="${_edm_archive_count//[[:space:]]/}"
  # Coerce to 0 if empty or non-numeric (e.g. find failed entirely)
  [[ $_edm_archive_count =~ ^[0-9]+$ ]] || _edm_archive_count=0

  if (( _edm_archive_count == 0 )); then
    _fail "backup archives: none found in ${EDM_BACKUP}  (expected ≥1 state archive)"
    _note "Check email-dns-monitor.timer is active and has completed at least one run"
  else
    # Find the most-recent archive mtime via find -printf; newest first, take top line.
    # || true: same pipefail guard as the count pipeline above.
    _edm_newest_mtime=$(sudo -u emaildns find "$EDM_BACKUP" \
      -maxdepth 1 -name 'email-dns-monitor-state-*.tar.gz' \
      -printf '%T@\n' 2>/dev/null \
      | sort -rn | head -1 || true)
    # Strip fractional seconds and whitespace for integer arithmetic.
    # If empty (find produced no -printf output), default to 0 so the age
    # calculation yields a very large value and falls through to _fail.
    _edm_newest_mtime="${_edm_newest_mtime%%.*}"
    _edm_newest_mtime="${_edm_newest_mtime//[[:space:]]/}"
    [[ $_edm_newest_mtime =~ ^[0-9]+$ ]] || _edm_newest_mtime=0
    _edm_archive_age=$(( $(date +%s) - _edm_newest_mtime ))

    if   (( _edm_archive_age > 172800 )); then
      _fail "backup archives: most-recent is ${_edm_archive_age}s old  (count: ${_edm_archive_count}, threshold: >48h)"
      _note "Check email-dns-monitor.timer is active and last run produced a backup"
    elif (( _edm_archive_age > 90000 )); then
      _warn "backup archives: most-recent is ${_edm_archive_age}s old  (count: ${_edm_archive_count}, threshold: >25h)"
      _note "Expected a fresh archive within the last 25h; service may have missed a window"
    else
      _ok  "backup archives: ${_edm_archive_count} found, most-recent ${_edm_archive_age}s old"
    fi
  fi

  check_dir       "$EDM_BACKUP/history"  "backup/history"
  check_dir_owner "$EDM_BACKUP/history" emaildns
  check_file "$EDM_DOMAINS_JSON" "domains/domains.json"

  # Validate domains.json is non-empty valid JSON
  if [[ -f $EDM_DOMAINS_JSON ]]; then
    if jq -e . "$EDM_DOMAINS_JSON" >/dev/null 2>&1; then
      domain_count=$(jq '[.domains[]? | select(.enabled == true)] | length' "$EDM_DOMAINS_JSON" 2>/dev/null || echo "?")
      _ok  "domains.json: valid JSON  ($domain_count enabled domains)"
    else
      _fail "domains.json: invalid JSON — $EDM_DOMAINS_JSON"
    fi
  fi

  check_no_lockfile "${EDM_STATE}/monitor.lock"

  # last_run.json — written unconditionally at the end of every --run cycle
  # (EDM v2.15.27+).  Confirms the service ran recently and exited cleanly.
  _EDM_LAST_RUN=${EDM_STATE}/last_run.json

  if [[ ! -f $_EDM_LAST_RUN ]]; then
    _fail "last_run.json missing: ${_EDM_LAST_RUN}  (EDM v2.15.27+ required)"
  else
    # Assert valid JSON
    if ! jq -e . "$_EDM_LAST_RUN" >/dev/null 2>&1; then
      _fail "last_run.json: invalid JSON — ${_EDM_LAST_RUN}"
    else
      # Assert mtime ≤ 90 minutes (5400 seconds)
      _edm_age=$(( $(date +%s) - $(stat -c '%Y' "$_EDM_LAST_RUN" 2>/dev/null || echo 0) ))
      if (( _edm_age > 5400 )); then
        _fail "last_run.json: stale  (age: ${_edm_age}s — expected within 5400s/90min)"
        _note "Check email-dns-monitor.timer is active and the last service run succeeded"
      else
        # Assert exit_code is 0, 2, or 3 (all other values indicate an unexpected failure)
        _edm_exit=$(jq -r '.exit_code' "$_EDM_LAST_RUN" 2>/dev/null || echo "?")
        case "$_edm_exit" in
          0|2|3)
            _edm_confirmed=$(jq -r '.confirmed_count' "$_EDM_LAST_RUN" 2>/dev/null || echo "?")
            _edm_failures=$( jq -r '.failure_count'   "$_EDM_LAST_RUN" 2>/dev/null || echo "?")
            _ok "last_run.json: age ${_edm_age}s  exit_code=${_edm_exit}  confirmed=${_edm_confirmed}  failures=${_edm_failures}"
            ;;
          *)
            _fail "last_run.json: unexpected exit_code=${_edm_exit}  (expected 0, 2, or 3)"
            _note "Review: journalctl -u email-dns-monitor.service --no-pager | tail -50"
            ;;
        esac
      fi
    fi
  fi

  check_conf_keys "$EDM_CONF" \
    ALERT_EMAILS SUMMARY_EMAILS MAIL_TRANSPORT OBSERVATION_MINUTES \
    PARALLEL_QUERIES MAX_ALERTS_PER_RUN DNS_FAILURE_ALERT_THRESHOLD \
    HISTORY_RETAIN_DAYS

  # Primary timer + last run
  check_timer   email-dns-monitor.timer
  check_last_run email-dns-monitor.service

else
  _skip "not installed on this host (${EDM_INSTALL} absent)"
fi


# =============================================================================
# ── SECTION 3: Balena Monitor ────────────────────────────────────────────────
# =============================================================================
_head "Balena Monitor"

BM_INSTALL=/opt/balena-monitor

if [[ -d $BM_INSTALL ]]; then

  BM_BIN=/usr/local/bin/balena-monitor
  BM_CONF=/etc/balena-monitor/config
  BM_STATE=/var/lib/balena-monitor
  BM_LOG=/var/log/balena-monitor
  BM_SPOOL=/var/spool/balena-reports

  check_binary balena-monitor
  check_symlink_target "$BM_BIN"
  check_user balena-monitor
  check_dir  "$BM_INSTALL"  "install root"
  check_file "$BM_CONF"     "config"
  check_conf_syntax "$BM_CONF"
  check_dir  "$BM_STATE"    "state dir"
  check_dir  "$BM_LOG"      "log dir"
  check_dir  "$BM_SPOOL"    "spool dir"
  check_dir_owner "$BM_STATE" balena-monitor

  check_conf_keys "$BM_CONF" \
    BALENA_API_URL BALENA_API_TOKEN BALENA_FLEET_ID

  # State file written after first run
  BM_FHH=${BM_STATE}/fleet_health_history.json
  if [[ -f $BM_FHH ]]; then
    if jq -e . "$BM_FHH" >/dev/null 2>&1; then
      _ok  "state:   fleet_health_history.json  (valid JSON)"
    else
      _fail "state:   fleet_health_history.json  (invalid JSON)"
    fi
  else
    _warn "state:   fleet_health_history.json not present (written after first run)"
  fi

  check_timer    balena-monitor-daily.timer
  check_last_run balena-monitor-daily.service

else
  _skip "not installed on this host (${BM_INSTALL} absent)"
fi


# =============================================================================
# ── SECTION 4: SharePoint Export ─────────────────────────────────────────────
# =============================================================================
_head "SharePoint Export"

SP_INSTALL=/opt/sharepoint-export

if [[ -d $SP_INSTALL ]]; then

  SP_BIN=/usr/local/bin/sharepoint-export
  SP_CONF=/etc/sharepoint-export/config
  SP_STATE=/var/lib/sharepoint-export
  SP_EXPORT_DIR=/var/lib/sharepoint-export/export
  SP_ARCHIVE_DIR=/var/backups/sharepoint-export
  SP_LOG=/var/log/sharepoint-export
  SP_LOCK_DIR=/var/lock/sharepoint-export

  check_binary sharepoint-export
  check_symlink_target "$SP_BIN"
  check_user sp-export
  check_dir  "$SP_INSTALL"      "install root"
  check_file "$SP_CONF"         "config"
  check_conf_syntax "$SP_CONF"
  # Config must be 0600 owned by sp-export (install requirement)
  check_file_mode "$SP_CONF" 600 sp-export
  check_dir  "$SP_STATE"        "state dir"
  check_dir  "$SP_EXPORT_DIR"   "state/export"
  check_dir  "$SP_ARCHIVE_DIR"  "backup/archive dir"
  check_dir  "$SP_LOG"          "log dir"
  check_dir  "$SP_LOCK_DIR"     "lock dir"
  check_dir_owner "$SP_STATE" sp-export

  check_conf_keys "$SP_CONF" \
    AZURE_TENANT_ID AZURE_CLIENT_ID AZURE_CLIENT_SECRET \
    SHAREPOINT_SITE_ID \
    BM_STATE_DIR EDM_STATE_DIR EDM_LIB_DIR EDM_DOMAINS_FILE \
    ALERT_EMAIL EMAIL_FROM

  # Cross-app path validation: source config once and check the 4 path references.
  # Single subshell: source config once, emit all 4 path values on separate lines.
  _sp_paths=$(bash -c "
    source \"$SP_CONF\" 2>/dev/null
    printf 'BM_STATE_DIR=%s\n'    \"\${BM_STATE_DIR:-}\"
    printf 'EDM_STATE_DIR=%s\n'   \"\${EDM_STATE_DIR:-}\"
    printf 'EDM_LIB_DIR=%s\n'     \"\${EDM_LIB_DIR:-}\"
    printf 'EDM_DOMAINS_FILE=%s\n' \"\${EDM_DOMAINS_FILE:-}\"
  " 2>/dev/null) || true

  while IFS='=' read -r _sp_key _sp_val; do
    [[ -z $_sp_val ]] && continue   # key-presence already checked above
    case $_sp_key in
      BM_STATE_DIR|EDM_STATE_DIR|EDM_LIB_DIR)
        if [[ -d $_sp_val ]]; then
          _ok  "cross-ref: ${_sp_key}=${_sp_val}"
        else
          _fail "cross-ref: ${_sp_key}=${_sp_val}  (dir missing)"
        fi
        ;;
      EDM_DOMAINS_FILE)
        if [[ -f $_sp_val ]]; then
          _ok  "cross-ref: ${_sp_key}=${_sp_val}"
        else
          _fail "cross-ref: ${_sp_key}=${_sp_val}  (file missing)"
        fi
        ;;
    esac
  done <<< "$_sp_paths"

  check_timer    sharepoint-export-daily.timer
  check_last_run sharepoint-export-daily.service

else
  _skip "not installed on this host (${SP_INSTALL} absent)"
fi


# =============================================================================
# ── SECTION 5: Server Tools (pb-maintenance) ─────────────────────────────────
# =============================================================================
_head "Server Tools (pb-maintenance)"

PBMAINT_LIBEXEC=/usr/local/libexec/pb-maintenance
PBMAINT_STATE=/var/lib/pb-maintenance
PBMAINT_PATCH_LOGS=/backup/patch-logs
PBMAINT_SEC_LOGS=/backup/security-logs

check_file "${PBMAINT_LIBEXEC}/check-for-updates.sh"       "check-for-updates.sh"
check_file "${PBMAINT_LIBEXEC}/pb-apt-evaluator.py"         "pb-apt-evaluator.py"
check_file "${PBMAINT_LIBEXEC}/pb-patch-reporter.sh"        "pb-patch-reporter.sh"
check_file "${PBMAINT_LIBEXEC}/security-hardening-check.sh" "security-hardening-check.sh"
check_file /usr/local/bin/login-compliance-check.sh         "login-compliance-check.sh"

check_dir  "$PBMAINT_STATE"      "state dir (/var/lib/pb-maintenance)"
check_dir  "$PBMAINT_PATCH_LOGS"  "patch log dir (/backup/patch-logs)"
check_dir  "$PBMAINT_SEC_LOGS"    "security log dir (/backup/security-logs)"

# State files (written after first run)
if [[ -f ${PBMAINT_STATE}/patch-state.json ]]; then
  if jq -e . "${PBMAINT_STATE}/patch-state.json" >/dev/null 2>&1; then
    _ok  "state:   patch-state.json  (valid JSON)"
  else
    _fail "state:   patch-state.json  (invalid JSON)"
  fi
else
  _warn "state:   patch-state.json not present (written after first run)"
fi

check_timer    pb-check-for-updates.timer
check_timer    pb-security-hardening-check.timer
check_last_run pb-check-for-updates.service
check_last_run pb-security-hardening-check.service


# =============================================================================
# ── SECTION 6: lighttpd ───────────────────────────────────────────────────────
# =============================================================================
_head "lighttpd"

if command -v lighttpd >/dev/null 2>&1; then

  LIGHTTPD_CONF=/etc/lighttpd/lighttpd.conf
  LIGHTTPD_LOG=/var/log/lighttpd

  check_binary lighttpd

  # Service state
  _lighty_state=$(systemctl is-active lighttpd 2>/dev/null || echo "inactive")
  if [[ $_lighty_state == "active" ]]; then
    _ok  "service: lighttpd  (active)"
  else
    _fail "service: lighttpd  (state: ${_lighty_state})"
  fi

  # Config syntax
  check_file "$LIGHTTPD_CONF" "/etc/lighttpd/lighttpd.conf"
  if [[ -f $LIGHTTPD_CONF ]]; then
    if lighttpd -t -f "$LIGHTTPD_CONF" >/dev/null 2>&1; then
      _ok  "config syntax OK: lighttpd.conf"
    else
      _fail "config syntax error: lighttpd.conf"
    fi
  fi

  check_dir "$LIGHTTPD_LOG" "/var/log/lighttpd"

  # TLS certificate expiry — read all ssl.pemfile paths from the live config,
  # deduplicate, and check each one directly from disk.  No network required.
  if [[ -f $LIGHTTPD_CONF ]]; then
    # Extract quoted pemfile paths; label is the Let's Encrypt domain dir name.
    mapfile -t _pem_files < <(
      sed -nE 's/^[[:space:]]*ssl\.pemfile[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
        "$LIGHTTPD_CONF" \
      | sort -u
    )

    if [[ ${#_pem_files[@]} -eq 0 ]]; then
      _warn "cert expiry: no ssl.pemfile entries found in ${LIGHTTPD_CONF}"
    else
      for _pem in "${_pem_files[@]}"; do
        _label=$(basename "$(dirname "$_pem")")
        check_cert_expiry_file "$_pem" "$_label"
      done
    fi
  fi

else
  _skip "lighttpd not installed on this host"
fi


# =============================================================================
# ── SECTION 7: System tools ──────────────────────────────────────────────────
# =============================================================================
_head "System tools"

# apt-managed tools
for _pkg in pandoc wkhtmltopdf; do
  if /usr/bin/dpkg-query -W -f='${Status}' "$_pkg" 2>/dev/null | /bin/grep -q "install ok installed"; then
    _ok "apt package:  ${_pkg}  ($(/usr/bin/dpkg-query -W -f='${Version}' "$_pkg" 2>/dev/null))"
  else
    _fail "apt package missing: ${_pkg}"
    _note "Fix: sudo apt-get install ${_pkg}"
  fi
done

# snap-managed tools
if ! /usr/bin/snap list glow >/dev/null 2>&1; then
  _fail "snap package missing: glow"
  _note "Fix: sudo snap install glow"
else
  _glow_ver=$(/usr/bin/snap list glow 2>/dev/null | /usr/bin/awk 'NR==2 {print $2}')
  _ok "snap package:  glow  (${_glow_ver})"
fi


# =============================================================================
# ── SECTION 8: Server Sanity Check (self) ────────────────────────────────────
# =============================================================================
_head "Server Sanity Check (self)"

SANITY_BIN=/usr/local/bin/server-sanity-check

check_file "$SANITY_BIN" "server-sanity-check binary"
if [[ -f $SANITY_BIN ]]; then
  check_file_mode "$SANITY_BIN" 755 root
fi

check_timer    pb-server-sanity-check.timer
check_last_run pb-server-sanity-check.service

# Parse the SANITY_CHECK_RESULT journal line from the most recent completed
# run to detect check-level failures that systemd does not surface (the unit
# uses SuccessExitStatus=0 1, so a run with failures is still "success" at the
# systemd level).  A missing journal line is a warning — expected on a freshly
# provisioned host.
#
# --until bounds the query to before this run started so the previous run's
# line is found whether we are running interactively or via systemd.  An
# interactive run writes SANITY_CHECK_RESULT to the terminal (stderr), not to
# the journal, so the current run's line is never present at query time.
_sanity_until=$(date -d "@$(( _START / 1000000000 ))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)
_sanity_journal_line=$(journalctl -t pb-server-sanity --no-pager \
  ${_sanity_until:+--until="$_sanity_until"} 2>/dev/null \
  | grep 'SANITY_CHECK_RESULT' | tail -1 || true)

if [[ -z $_sanity_journal_line ]]; then
  _warn "last run journal: no SANITY_CHECK_RESULT line found (new host or journal rotated)"
else
  _sanity_fail_count=$(echo "$_sanity_journal_line" | grep -oE 'fail=[0-9]+' | cut -d= -f2 || echo "?")
  _sanity_warn_count=$(echo "$_sanity_journal_line" | grep -oE 'warn=[0-9]+' | cut -d= -f2 || echo "?")
  _sanity_pass_count=$(echo "$_sanity_journal_line" | grep -oE 'pass=[0-9]+' | cut -d= -f2 || echo "?")
  _sanity_elapsed=$(   echo "$_sanity_journal_line" | grep -oE 'elapsed_ms=[0-9]+' | cut -d= -f2 || echo "?")

  if [[ $_sanity_fail_count == "0" ]]; then
    _ok  "last run checks: pass=${_sanity_pass_count} fail=${_sanity_fail_count} warn=${_sanity_warn_count}  (${_sanity_elapsed}ms)"
  else
    _fail "last run checks: pass=${_sanity_pass_count} fail=${_sanity_fail_count} warn=${_sanity_warn_count}  (${_sanity_elapsed}ms)"
    _note "The last scheduled run detected ${_sanity_fail_count} failure(s) — review the journal:"
    _note "  journalctl -u pb-server-sanity-check --no-pager | tail -100"
  fi
fi


# =============================================================================
# ── Summary ──────────────────────────────────────────────────────────────────
# =============================================================================
_END=$(date +%s%N)
_ELAPSED=$(( (_END - _START) / 1000000 ))

printf '\n%s══ Summary%s\n' "${BOLD}" "${RST}"
printf '  %sPASS: %d%s   %sFAIL: %d%s   %sWARN: %d%s   (elapsed: %dms)\n\n' \
  "${GRN}" "$_pass" "${RST}" "${RED}" "$_fail" "${RST}" "${YLW}" "$_warn" "${RST}" "$_ELAPSED"

if (( ${#_FAILURES[@]} > 0 )); then
  printf '%s%sFailed checks:%s\n' "${BOLD}" "${RED}" "${RST}"
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
  printf '%s%sNOT OK — %d check(s) failed%s\n\n' "${RED}" "${BOLD}" "$_fail" "${RST}"
  _EXIT=1
elif (( _warn > 0 )); then
  printf '%s%sOK with %d warning(s)%s\n\n' "${YLW}" "${BOLD}" "$_warn" "${RST}"
  _EXIT=0
else
  printf '%s%sALL OK%s\n\n' "${GRN}" "${BOLD}" "${RST}"
  _EXIT=0
fi

# =============================================================================
# ── Email delivery (--email-on-failure) ──────────────────────────────────────
# =============================================================================
# Send the captured report if any check failed.  Warnings are not emailed —
# transient warnings (e.g. msmtp first-run) should not generate noise.
# EMAIL_PRIMARY is sourced from /etc/balena-monitor/config; if the file or
# key is absent the email step is skipped with a warning to stderr.
# =============================================================================
if (( _EMAIL_ON_FAILURE && _fail > 0 )); then
  _BM_CONF=/etc/balena-monitor/config
  _email_to=''

  if [[ -f $_BM_CONF ]]; then
    _email_to=$(bash -c "source \"$_BM_CONF\" 2>/dev/null; printf '%s' \"\${EMAIL_PRIMARY:-}\"" 2>/dev/null || true)
  fi

  if [[ -z $_email_to ]]; then
    printf 'server-sanity-check: --email-on-failure: EMAIL_PRIMARY not found in %s — skipping email\n' \
      "$_BM_CONF" >&2
  elif ! command -v msmtp >/dev/null 2>&1; then
    printf 'server-sanity-check: --email-on-failure: msmtp not found — skipping email\n' >&2
  else
    _hostname=$(hostname -s 2>/dev/null || echo unknown)
    _subject="[server-sanity] FAIL on ${_hostname} — ${_fail} check(s) failed"
    _body_file=${_CAPTURE_FILE:-}

    if [[ -n $_body_file && -f $_body_file ]]; then
      # Strip ANSI colour codes so the email body is plain text.
      _plain=$(sed 's/\x1b\[[0-9;]*m//g' "$_body_file")
    else
      _plain="(report capture unavailable)"
    fi

    if printf 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=utf-8\n\n%s\n' \
         "$_email_to" "$_subject" "$_plain" \
         | msmtp "$_email_to" 2>/dev/null; then
      printf 'server-sanity-check: failure report emailed to %s\n' "$_email_to" >&2
    else
      printf 'server-sanity-check: msmtp failed — failure report NOT delivered to %s\n' "$_email_to" >&2
    fi
  fi
fi

# ── Journal log line ──────────────────────────────────────────────────────────
# Written to the systemd journal via systemd-cat so the line lands regardless
# of whether the script is invoked by systemd or run interactively.  When run
# interactively stderr goes to the terminal only; systemd-cat routes directly
# to journald under the same SyslogIdentifier used by the service unit.
# Also printed to stderr for terminal visibility.
# Grep-friendly for post-hoc queries:
#   journalctl -t pb-server-sanity | grep SANITY_CHECK_RESULT
_END=$(date +%s%N)
_ELAPSED=$(( (_END - _START) / 1000000 ))
_sanity_result_line=$(printf 'SANITY_CHECK_RESULT pass=%d fail=%d warn=%d elapsed_ms=%d' \
  "$_pass" "$_fail" "$_warn" "$_ELAPSED")
printf '%s\n' "$_sanity_result_line" >&2
if command -v systemd-cat >/dev/null 2>&1; then
  printf '%s\n' "$_sanity_result_line" \
    | systemd-cat -t pb-server-sanity -p info 2>/dev/null || true
fi

_EXIT_CLEAN=1
exit "$_EXIT"
