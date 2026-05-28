#!/usr/bin/env bash
# login-compliance-check.sh — Login-time compliance quick check
# One-line summary:
#   [login-check] Email=<OK|WARN|CRITICAL> Sent=<OK|WARN|CRITICAL> Patches=<OK|WARN|CRITICAL>
#
# INSTALL:
#   sudo install -m 0755 login-compliance-check.sh /usr/local/bin/login-compliance-check.sh
#   Add to ~/.bashrc (interactive shells only):
#     if [[ $- == *i* ]] && [[ -x /usr/local/bin/login-compliance-check.sh ]]; then
#       /usr/local/bin/login-compliance-check.sh
#     fi
#   Ensure ~/.bash_profile sources ~/.bashrc so login shells pick it up:
#     [[ -f ~/.bashrc ]] && source ~/.bashrc
#
# PATCH CHECK (v4.2):
#   Reads /var/lib/pb-maintenance/patch-state.json and patch-suppression.json via jq.
#   No apt-get invocation; no XDG cache TTL.  Staleness is measured against the
#   evaluated_at field in the JSON (26h threshold: 24h timer cadence + 2h grace).
#   Requires: jq >= 1.6 (Ubuntu Noble ships 1.7)
#
# Notes:
# - Script ALWAYS prints when executed directly.
# - msmtp is configured system-wide (/etc/msmtprc); no per-user config expected.
#
# v1.0.0
set -uo pipefail

: "${LCHECK_DAYS_SENT:=45}"
: "${LCHECK_MAX_LOG_LINES:=6000}"
: "${LCHECK_VERBOSE:=0}"

# State files (v4.2)
STATE_DIR="${STATE_DIR:-/var/lib/pb-maintenance}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/patch-state.json}"
STATE_LOCK="${STATE_LOCK:-${STATE_DIR}/patch-state.json.lock}"
SUPP_FILE="${SUPP_FILE:-${STATE_DIR}/patch-suppression.json}"
SUPP_LOCK="${SUPP_LOCK:-${STATE_DIR}/patch-suppression.json.lock}"
readonly STATE_DIR STATE_FILE SUPP_FILE

# Staleness threshold: 26h (24h cadence + 2h grace)
readonly STALE_THRESHOLD_SECS=$(( 26 * 3600 ))

# Cross-run confirmation threshold (must match reporter)
readonly SEEN_COUNT_THRESHOLD=2

_now_epoch() { date +%s; }
_has_cmd()   { command -v "$1" >/dev/null 2>&1; }

_iso_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || echo 0
}

_age_days_of_file() {
  local f="$1" m now
  [[ -e "$f" ]] || { printf ''; return 0; }
  m=$(stat -c %Y "$f" 2>/dev/null || echo '')
  [[ "$m" =~ ^[0-9]+$ ]] || { printf ''; return 0; }
  now=$(_now_epoch)
  printf '%s' $(( (now - m) / 86400 ))
}

_tail_safely() {
  local file="$1" n="$2"
  [[ -r "$file" ]] || return 1
  tail -n "$n" "$file" 2>/dev/null || return 1
}

_detect_sendmail_target() {
  local sm target
  sm=$(command -v sendmail 2>/dev/null || true)
  [[ -n "$sm" ]] || return 1
  target=$(readlink -f "$sm" 2>/dev/null || true)
  [[ -n "$target" ]] || target="$sm"
  printf '%s' "$target"
}

_find_msmtp_system_conf() {
  local candidates=("/etc/msmtprc" "/etc/msmtp/msmtprc" "/etc/msmtp/config")
  local f
  for f in "${candidates[@]}"; do
    [[ -e "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

_msmtp_value_if_readable() {
  local key="$1" conf="$2"
  [[ -r "$conf" ]] || { printf ''; return 0; }
  awk -v key="$key" '
    BEGIN{in_default=0;}
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*defaults[[:space:]]*$/ {in_default=1; next}
    /^[[:space:]]*account[[:space:]]+default/ {in_default=1; next}
    /^[[:space:]]*account[[:space:]]+/ {in_default=0; next}
    {
      if ($1==key && in_default==1) {
        $1=""; sub(/^[[:space:]]+/,"",$0); print; exit;
      }
    }
  ' "$conf" 2>/dev/null || true
}

_check_email_stack() {
  local issues=0 reasons=()

  _has_cmd mailx || { issues=$((issues+1)); reasons+=("mailx missing"); }

  local sm_target
  if sm_target=$(_detect_sendmail_target); then
    [[ "$sm_target" == *msmtp* ]] || { issues=$((issues+1)); reasons+=("sendmail not msmtp"); }
  else
    issues=$((issues+2)); reasons+=("sendmail missing")
  fi

  local conf
  if conf=$(_find_msmtp_system_conf); then
    true
  else
    issues=$((issues+1)); reasons+=("no system msmtprc found")
  fi

  if (( issues == 0 )); then
    printf 'OK\n'; printf '%s\n' "${reasons[*]}"
  elif (( issues <= 2 )); then
    printf 'WARN\n'; printf '%s\n' "${reasons[*]}"
  else
    printf 'CRITICAL\n'; printf '%s\n' "${reasons[*]}"
  fi
}

_find_msmtp_log_guess() {
  local f logfile
  local sysconfs=("/etc/msmtprc" "/etc/msmtp/msmtprc" "/etc/msmtp/config")
  for f in "${sysconfs[@]}"; do
    if [[ -r "$f" ]]; then
      logfile=$(_msmtp_value_if_readable logfile "$f")
      if [[ -n "$logfile" ]]; then
        logfile=${logfile/#~/$HOME}
        printf '%s' "$logfile"
        return 0
      fi
    fi
  done
  [[ -r /var/log/msmtp.log ]]       && { printf '%s' /var/log/msmtp.log; return 0; }
  [[ -r /var/log/msmtp/msmtp.log ]] && { printf '%s' /var/log/msmtp/msmtp.log; return 0; }
  printf '%s' /var/log/msmtp.log
}

_msmtp_line_is_success() {
  local line="${1,,}"  # lowercase once; no subprocesses
  # Explicit failure patterns
  [[ "$line" =~ exitcode=ex_(tempfail|unavailable|nohost|noperm|dataerr|ioerr|software|oserr|nouser|protocol) ]] && return 1
  [[ "$line" =~ (fail|error|timed\ out|refused|denied) ]] && return 1
  # Success patterns
  [[ "$line" =~ exitcode=ex_ok      ]] && return 0
  [[ "$line" =~ smtpstatus=250      ]] && return 0
  [[ "$line" =~ smtpmsg=.250        ]] && return 0
  [[ "$line" =~ (^|[^a-z])sent([^a-z]|$) ]] && return 0
  return 1
}

_check_recent_sent() {
  local days="$LCHECK_DAYS_SENT" log age
  log=$(_find_msmtp_log_guess)
  age=$(_age_days_of_file "$log")

  if [[ ! -r "$log" ]]; then
    printf 'WARN\n'
    printf 'log not readable: %s\n' "$log"
    return 0
  fi

  local snap
  snap=$(_tail_safely "$log" "$LCHECK_MAX_LOG_LINES" || true)
  [[ -n "$snap" ]] || { printf 'WARN\nlog empty: %s\n' "$log"; return 0; }

  local cutoff_date
  cutoff_date=$(date -d "$days days ago" +'%Y-%m-%d' 2>/dev/null || echo '0000-00-00')

  local found=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    _msmtp_line_is_success "$line" || continue
    if [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
      # YYYY-MM-DD lexicographic order matches chronological order
      [[ "${BASH_REMATCH[1]}" > "$cutoff_date" || "${BASH_REMATCH[1]}" == "$cutoff_date" ]] \
        && { found=1; break; }
    else
      [[ -n "$age" ]] && (( age <= days )) && { found=1; break; } || true
    fi
  done <<<"$snap"

  if (( found == 1 )); then
    printf 'OK\n'
    printf 'evidence: success line in %s (age %sd)\n' "$log" "${age:-?}"
  else
    printf 'WARN\n'
    printf 'no success evidence in %sd (tail); log=%s (age %sd)\n' "$days" "$log" "${age:-?}"
  fi
}

# ---------------------------------------------------------------------------
# Patch check — reads patch-state.json + patch-suppression.json via jq
# §4.4 of DESIGN-check-for-updates-v4_2.md
# ---------------------------------------------------------------------------
_check_patches() {
  # jq required
  if ! _has_cmd jq; then
    printf 'WARN\n'
    printf 'jq not installed — cannot parse state file\n'
    return 0
  fi

  # Acquire shared flock on state-file lock to avoid reading a mid-rename file
  local state_json supp_json

  # State file is written atomically (tmp+rename) by the evaluator;
  # no lock needed for a plain read.
  if [[ ! -f "$STATE_FILE" ]]; then
    printf 'WARN\n'
    printf 'state file missing — evaluator may not have run\n'
    return 0
  fi

  if [[ ! -r "$STATE_FILE" ]]; then
    printf 'WARN\n'
    printf 'state file not readable\n'
    return 0
  fi

  state_json="$(cat "$STATE_FILE" 2>/dev/null)"

  # Validate JSON
  if ! printf '%s' "$state_json" | jq empty 2>/dev/null; then
    printf 'WARN\n'
    printf 'state file corrupt\n'
    return 0
  fi

  local evaluated_at_str
  evaluated_at_str="$(printf '%s' "$state_json" | jq -r '.evaluated_at // ""')"

  # Staleness check
  if [[ -n "$evaluated_at_str" ]]; then
    local eval_epoch now_e age_secs
    eval_epoch="$(_iso_to_epoch "$evaluated_at_str")"
    now_e="$(_now_epoch)"
    age_secs=$(( now_e - eval_epoch ))
    if (( age_secs > STALE_THRESHOLD_SECS )); then
      printf 'WARN\n'
      printf 'state file stale — last evaluated %dh ago\n' "$(( age_secs / 3600 ))"
      return 0
    fi
  else
    printf 'WARN\n'
    printf 'state file missing evaluated_at field\n'
    return 0
  fi

  # apt_update_failed → CRITICAL (F4)
  local apt_update_failed
  apt_update_failed="$(printf '%s' "$state_json" | jq -r '.apt_update_failed // false')"
  if [[ "$apt_update_failed" == "true" ]]; then
    printf 'CRITICAL\n'
    printf 'apt-get update failed — package list stale; this host may be missing security updates\n'
    return 0
  fi

  # Reboot required → CRITICAL
  local reboot_required
  reboot_required="$(printf '%s' "$state_json" | jq -r '.reboot_required // false')"
  if [[ "$reboot_required" == "true" ]]; then
    printf 'CRITICAL\n'
    printf 'reboot required\n'
    return 0
  fi

  # Read suppression file (shared flock)
  supp_json='{"schema":2,"suppressions":[]}'
  if [[ -f "$SUPP_FILE" ]]; then
    exec 9<"${SUPP_LOCK}" 2>/dev/null || true
    if flock -s -w 2 9 2>/dev/null; then
      local raw_supp
      raw_supp="$(cat "$SUPP_FILE" 2>/dev/null)"
      exec 9>&-
      if printf '%s' "$raw_supp" | jq empty 2>/dev/null; then
        supp_json="$raw_supp"
      fi
    else
      exec 9>&- 2>/dev/null || true
    fi
  fi

  local now_e2
  now_e2="$(_now_epoch)"

  # Categorise confirmed packages
  local confirmed_json unconfirmed_json
  confirmed_json="$(printf '%s' "$state_json" | jq \
    --argjson t "$SEEN_COUNT_THRESHOLD" \
    '[.packages[] | select(.seen_count >= $t)]')"
  unconfirmed_json="$(printf '%s' "$state_json" | jq \
    --argjson t "$SEEN_COUNT_THRESHOLD" \
    '[.packages[] | select(.seen_count < $t)]')"

  local confirmed_count unconfirmed_count
  confirmed_count="$(printf '%s' "$confirmed_json" | jq 'length')"
  unconfirmed_count="$(printf '%s' "$unconfirmed_json" | jq 'length')"

  # Among confirmed, split unsuppressed vs suppressed
  local unsuppressed_count=0 suppressed_count=0

  if [[ "$confirmed_count" -gt 0 ]]; then
    local i
    for (( i=0; i<confirmed_count; i++ )); do
      local name arch ver
      name="$(printf '%s' "$confirmed_json" | jq -r ".[$i].name")"
      arch="$(printf '%s' "$confirmed_json" | jq -r ".[$i].architecture")"
      ver="$(printf '%s' "$confirmed_json" | jq -r ".[$i].candidate_version")"

      # Check suppression
      local supp_obj until_str until_epoch
      supp_obj="$(printf '%s' "$supp_json" | jq \
        --arg n "$name" --arg a "$arch" --arg v "$ver" \
        '.suppressions[] | select(.name==$n and .architecture==$a and .candidate_version==$v)' \
        2>/dev/null)"

      if [[ -n "$supp_obj" ]]; then
        until_str="$(printf '%s' "$supp_obj" | jq -r '.suppressed_until // ""')"
        if [[ -n "$until_str" ]]; then
          until_epoch="$(_iso_to_epoch "$until_str")"
          if (( until_epoch > now_e2 )); then
            (( suppressed_count++ ))
            continue
          fi
        fi
      fi
      (( unsuppressed_count++ ))
    done
  fi

  # --- Determine banner ---
  if (( unsuppressed_count > 0 )); then
    printf 'CRITICAL\n'
    printf '%d update(s) pending\n' "$unsuppressed_count"
  elif (( suppressed_count > 0 && unconfirmed_count > 0 )); then
    printf 'WARN\n'
    printf '%d suppressed — alert sent, not yet patched; %d awaiting cross-run confirmation\n' \
      "$suppressed_count" "$unconfirmed_count"
  elif (( suppressed_count > 0 )); then
    printf 'WARN\n'
    printf '%d suppressed — alert sent, not yet patched\n' "$suppressed_count"
  elif (( unconfirmed_count > 0 )); then
    printf 'WARN\n'
    printf '%d awaiting cross-run confirmation\n' "$unconfirmed_count"
  else
    printf 'OK\n'
    printf '\n'
  fi
}

# ---------------------------------------------------------------------------
# Status icon
# ---------------------------------------------------------------------------
_status_icon() {
  if [[ -t 1 ]]; then
    local GREEN='\033[0;32m' YELLOW='\033[0;33m' RED='\033[0;31m' RESET='\033[0m'
  else
    local GREEN='' YELLOW='' RED='' RESET=''
  fi
  case "$1" in
    OK)       printf '%b%s%b' "$GREEN" 'OK'       "$RESET" ;;
    WARN)     printf '%b%s%b' "$YELLOW" 'WARN'    "$RESET" ;;
    CRITICAL) printf '%b%s%b' "$RED"   'CRITICAL' "$RESET" ;;
    *)        printf '%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local e_s e_r m_s m_r p_s p_r

  { read -r e_s; read -r e_r; } < <(_check_email_stack)
  { read -r m_s; read -r m_r; } < <(_check_recent_sent)
  { read -r p_s; read -r p_r; } < <(_check_patches)

  printf '[login-check] Email='; _status_icon "$e_s"
  printf '  Sent=';              _status_icon "$m_s"
  printf '  Patches=';           _status_icon "$p_s"
  printf '\n'

  if (( LCHECK_VERBOSE == 1 )); then
    [[ "$e_s" == "OK" ]] || printf '  Email: %s\n' "${e_r:-no details}"
    [[ "$m_s" == "OK" ]] || printf '  Sent: %s\n' "${m_r:-no details}"
    [[ "$p_s" == "OK" ]] || printf '  Patches: %s\n' "${p_r:-no details}"
  fi
}

main "$@"
