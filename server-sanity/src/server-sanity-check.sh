#!/usr/bin/env bash
# =============================================================================
# server-sanity-check — PBWEBSRV03 infrastructure sanity check
#
# Checks the essential health of all three applications and the email stack.
# Read-only: no emails sent, no services triggered, no state mutated.
# Must run as root (sudo).
#
# Usage: sudo bash /opt/server-tools/server-sanity-check.sh
#
# Exit codes:
#   0 — all checks passed (warnings are acceptable)
#   1 — one or more checks failed
#   2 — must run as root
#
# Applications checked:
#   • Email stack (msmtp)
#   • Email DNS Monitor  (/opt/email-dns-monitor)
#   • Balena Monitor     (/opt/balena-monitor)
#   • SharePoint Export  (/opt/sharepoint-export)
#   • Server Tools       (/usr/local/libexec/pb-maintenance)
# =============================================================================

set -euo pipefail

# ── Colour palette ──────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED=$'\033[0;31m' GRN=$'\033[0;32m' YLW=$'\033[0;33m'
  BLU=$'\033[0;34m' BOLD=$'\033[1m'   RST=$'\033[0m'
else
  RED='' GRN='' YLW='' BLU='' BOLD='' RST=''
fi

# ── Counters ─────────────────────────────────────────────────────────────────
_pass=0; _fail=0; _warn=0

# ── Primitives ───────────────────────────────────────────────────────────────
_ok()   { printf "  ${GRN}✔${RST}  %s\n" "$*";           (( ++_pass )); }
_fail() { printf "  ${RED}✘${RST}  %s\n" "$*";           (( ++_fail )); }
_warn() { printf "  ${YLW}⚠${RST}  %s\n" "$*";           (( ++_warn )); }
_head() { printf "\n${BOLD}${BLU}══ %s${RST}\n" "$*"; }

# ── Guards ───────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  printf "${RED}Error:${RST} must run as root — use: sudo bash %s\n" "$0" >&2
  exit 2
fi

_START=$(date +%s%N)

printf "${BOLD}PBWEBSRV03 — Infrastructure Sanity Check${RST}\n"
printf "$(date '+%Y-%m-%d %H:%M:%S %Z')\n"

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


# =============================================================================
# ── SECTION 2: Email DNS Monitor ─────────────────────────────────────────────
# =============================================================================
_head "Email DNS Monitor"

EDM_INSTALL=/opt/email-dns-monitor
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
check_dir  "$EDM_LOG"             "log dir"
check_dir  "$EDM_BACKUP"          "backup dir"
check_dir  "$EDM_BACKUP/history"  "backup/history"
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

check_conf_keys "$EDM_CONF" \
  ALERT_EMAILS SUMMARY_EMAILS MAIL_TRANSPORT OBSERVATION_MINUTES \
  PARALLEL_QUERIES MAX_ALERTS_PER_RUN DNS_FAILURE_ALERT_THRESHOLD \
  HISTORY_RETAIN_DAYS

# Primary timer + last run
check_timer   email-dns-monitor.timer
check_last_run email-dns-monitor.service


# =============================================================================
# ── SECTION 3: Balena Monitor ────────────────────────────────────────────────
# =============================================================================
_head "Balena Monitor"

BM_INSTALL=/opt/balena-monitor
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


# =============================================================================
# ── SECTION 4: SharePoint Export ─────────────────────────────────────────────
# =============================================================================
_head "SharePoint Export"

SP_INSTALL=/opt/sharepoint-export
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
if [[ -f $SP_CONF ]]; then
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
        [[ -d $_sp_val ]] \
          && _ok  "cross-ref: ${_sp_key}=${_sp_val}" \
          || _fail "cross-ref: ${_sp_key}=${_sp_val}  (dir missing)"
        ;;
      EDM_DOMAINS_FILE)
        [[ -f $_sp_val ]] \
          && _ok  "cross-ref: ${_sp_key}=${_sp_val}" \
          || _fail "cross-ref: ${_sp_key}=${_sp_val}  (file missing)"
        ;;
    esac
  done <<< "$_sp_paths"
fi

check_timer    sharepoint-export-daily.timer
check_last_run sharepoint-export-daily.service


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
# ── Summary ──────────────────────────────────────────────────────────────────
# =============================================================================
_END=$(date +%s%N)
_ELAPSED=$(( (_END - _START) / 1000000 ))

printf "\n${BOLD}══ Summary${RST}\n"
printf "  ${GRN}PASS: %d${RST}   ${RED}FAIL: %d${RST}   ${YLW}WARN: %d${RST}   (elapsed: %dms)\n\n" \
  "$_pass" "$_fail" "$_warn" "$_ELAPSED"

if (( _fail > 0 )); then
  printf "${RED}${BOLD}NOT OK — %d check(s) failed${RST}\n\n" "$_fail"
  exit 1
elif (( _warn > 0 )); then
  printf "${YLW}${BOLD}OK with %d warning(s)${RST}\n\n" "$_warn"
  exit 0
else
  printf "${GRN}${BOLD}ALL OK${RST}\n\n"
  exit 0
fi
