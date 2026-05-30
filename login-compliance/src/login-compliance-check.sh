#!/usr/bin/env bash
# login-compliance-check.sh — Login-time compliance quick check (msmtp-as-sendmail)
# One-line summary:
#   [login-check] Email=<OK|WARN|CRITICAL> Sent=<OK|WARN|CRITICAL> Patches=<OK|WARN|CRITICAL>
#
# INSTALL (recommended):
#   sudo install -m 0755 /tmp/login-compliance-check.sh /usr/local/bin/login-compliance-check.sh
#   Add to ~/.bashrc (interactive shells only):
#     if [[ $- == *i* ]] && [[ -x /usr/local/bin/login-compliance-check.sh ]]; then
#       /usr/local/bin/login-compliance-check.sh
#     fi
#   Ensure ~/.bash_profile sources ~/.bashrc so login shells pick it up:
#     [[ -f ~/.bashrc ]] && source ~/.bashrc
#
# PERFORMANCE (first-run speed):
#   The patch check (apt) is the slowest part and is cached after the first run.
#   Cache is invalidated whenever check-for-updates.sh runs apt-get update
#   (via /var/lib/apt/lists/pb-last-update), or when the TTL expires.
#   To pre-warm the cache so logins are always fast, add a cron job:
#     */30 * * * * /usr/local/bin/login-compliance-check.sh >/dev/null 2>&1
#
# Notes:
# - Script ALWAYS prints when executed directly.
# - Do NOT cache/suppress the banner itself; only the patch computation is cached.
# - msmtp is configured system-wide (/etc/msmtprc); no per-user config expected.
# - Patch count uses apt-get dist-upgrade -s (sim mode) — phased updates excluded,
#   consistent with check-for-updates.sh.
# - Cache is invalidated when /var/lib/apt/lists/pb-last-update is newer than the
#   cache write time (written by check-for-updates.sh after apt-get update).
#   Falls back to /var/lib/apt/lists/lock if pb-last-update is absent.
#
# v0.9.0
set -uo pipefail

: "${LCHECK_DAYS_SENT:=45}"
: "${LCHECK_MAX_LOG_LINES:=6000}"
: "${LCHECK_PATCH_STALE_DAYS:=7}"
: "${LCHECK_PATCH_CACHE_TTL:=3600}"   # seconds; 0 = always recompute
: "${LCHECK_VERBOSE:=0}"              # 1=print reasons for WARN/CRITICAL

# Shared stamp written by check-for-updates.sh after each apt-get update.
# Primary cache-invalidation signal; falls back to /var/lib/apt/lists/lock.
readonly APT_UPDATE_STAMP="/var/lib/apt/lists/pb-last-update"

_now_epoch() { date +%s; }
_has_cmd() { command -v "$1" >/dev/null 2>&1; }

_cache_dir() {
  local d
  d="${XDG_CACHE_HOME:-$HOME/.cache}/login-compliance"
  mkdir -p "$d" 2>/dev/null || true
  printf '%s' "$d"
}

_cache_time_get() {
  local key="$1" f
  f="$(_cache_dir)/${key}.time"
  [[ -f "$f" ]] || return 1
  cat "$f" 2>/dev/null || return 1
}

_cache_time_set() {
  local key="$1" val="$2" f
  f="$(_cache_dir)/${key}.time"
  printf '%s' "$val" >"$f" 2>/dev/null || true
}

_cache_value_get() {
  local key="$1" f
  f="$(_cache_dir)/${key}.value"
  [[ -f "$f" ]] || return 1
  cat "$f" 2>/dev/null || return 1
}

_cache_value_set() {
  local key="$1" val="$2" f
  f="$(_cache_dir)/${key}.value"
  printf '%s' "$val" >"$f" 2>/dev/null || true
}

_cache_fresh() {
  # Returns 0 (true) only when:
  #   1. TTL has not expired, AND
  #   2. The apt lists have NOT been updated since the cache was written.
  # Condition 2 uses pb-last-update (written by check-for-updates.sh) as the
  # primary signal, falling back to /var/lib/apt/lists/lock.
  local key="$1" ttl="$2" last now apt_stamp

  [[ "$ttl" =~ ^[0-9]+$ ]] || return 1
  (( ttl == 0 )) && return 1

  last="$(_cache_time_get "$key")" || return 1
  [[ "$last" =~ ^[0-9]+$ ]]       || return 1

  now="$(_now_epoch)"
  (( now - last < ttl )) || return 1   # TTL expired

  # Invalidate if apt lists have been refreshed since the cache was written.
  apt_stamp="$(_apt_update_stamp_epoch)"
  if [[ "$apt_stamp" =~ ^[0-9]+$ ]] && (( apt_stamp > 0 )); then
    (( apt_stamp <= last )) || return 1  # apt updated after cache → stale
  fi

  return 0
}

_apt_update_stamp_epoch() {
  # Return the mtime of the most recent reliable apt-update stamp, or 0.
  # pb-last-update is written by check-for-updates.sh and is authoritative.
  # /var/lib/apt/lists/lock is the fallback for manual apt-get update runs.
  local f
  for f in "$APT_UPDATE_STAMP" \
            /var/lib/apt/lists/lock \
            /var/lib/apt/periodic/update-success-stamp \
            /var/lib/apt/periodic/apt-update-stamp-stable; do
    if [[ -e "$f" ]]; then
      stat -c %Y "$f" 2>/dev/null && return 0
    fi
  done
  printf '0'
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

  # System-level config check only — no per-user msmtprc expected
  local conf
  if conf=$(_find_msmtp_system_conf); then
    true  # config exists, that's sufficient
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
  local line="$1"

  echo "$line" | grep -Eqi 'exitcode=EX_(TEMPFAIL|UNAVAILABLE|NOHOST|NOPERM|DATAERR|IOERR|SOFTWARE|OSERR|NOUSER|PROTOCOL)' && return 1
  echo "$line" | grep -Eqi 'fail|error|timed out|refused|denied' && return 1

  echo "$line" | grep -Eq  'exitcode=EX_OK'   && return 0
  echo "$line" | grep -Eq  'smtpstatus=250'   && return 0
  echo "$line" | grep -Eq  "smtpmsg='250"     && return 0
  echo "$line" | grep -Eq  "smtpmsg=\"250"    && return 0
  echo "$line" | grep -Eqi '\bsent\b'         && return 0

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

  local cutoff
  cutoff=$(date -d "$days days ago" +%s 2>/dev/null || echo 0)

  local found=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    _msmtp_line_is_success "$line" || continue

    if [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
      local ts epoch
      ts=${line:0:19}
      epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0)
      (( epoch >= cutoff )) && { found=1; break; } || true
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

_check_patches_compute() {
  # Uses apt-get dist-upgrade -s (sim mode) — same method as check-for-updates.sh.
  # Phased updates are excluded because they won't actually be installed.
  local issues=0 reasons=()

  [[ -f /var/run/reboot-required ]] && { issues=$((issues+1)); reasons+=("reboot required"); }

  # Check whether apt lists are stale using the dedicated stamp first.
  local stamp age
  for stamp in "$APT_UPDATE_STAMP" \
               /var/lib/apt/periodic/update-success-stamp \
               /var/lib/apt/periodic/apt-update-stamp-stable; do
    if [[ -e "$stamp" ]]; then
      age=$(_age_days_of_file "$stamp")
      if [[ -n "$age" ]] && (( age > LCHECK_PATCH_STALE_DAYS )); then
        issues=$((issues+1)); reasons+=("apt lists stale (${age}d)")
      fi
      break
    fi
  done

  if _has_cmd apt-get; then
    local upg
    upg=$(DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -s 2>/dev/null \
          | awk '/^Inst / {print $2}' | grep -c . || true)
    if (( upg > 0 )); then
      # Determine how many of those are security updates.
      local actual upgradable_list sec pkg
      actual=$(DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -s 2>/dev/null \
               | awk '/^Inst / {print $2}' || true)
      upgradable_list=$(apt list --upgradable 2>/dev/null | tail -n +2 || true)
      sec=0
      while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        printf '%s\n' "$upgradable_list" | grep -qE "^${pkg}/.*security" && sec=$((sec+1))
      done <<< "$actual"

      if (( sec > 0 )); then
        issues=$((issues+2)); reasons+=("${sec} security / ${upg} total update(s) pending")
      else
        issues=$((issues+1)); reasons+=("${upg} update(s) pending")
      fi
    fi
  else
    issues=$((issues+1)); reasons+=("apt-get not found")
  fi

  if (( issues == 0 )); then
    printf 'OK\n'; printf '%s\n' "${reasons[*]}"
  elif (( issues <= 2 )); then
    printf 'WARN\n'; printf '%s\n' "${reasons[*]}"
  else
    printf 'CRITICAL\n'; printf '%s\n' "${reasons[*]}"
  fi
}

_check_patches() {
  local key="patch_result" ttl="$LCHECK_PATCH_CACHE_TTL"

  if _cache_fresh "$key" "$ttl"; then
    local cached
    cached="$(_cache_value_get "$key" || true)"
    if [[ -n "$cached" ]]; then
      printf '%s' "$cached"
      return 0
    fi
  fi

  local out
  out="$(_check_patches_compute)"
  printf '%s' "$out"
  _cache_value_set "$key" "$out"
  _cache_time_set "$key" "$(_now_epoch)"
}

_status_icon() {
  local GREEN='\033[0;32m' YELLOW='\033[0;33m' RED='\033[0;31m' RESET='\033[0m'
  case "$1" in
    OK)       printf '%b%s%b' "$GREEN" '✔ OK'       "$RESET" ;;
    WARN)     printf '%b%s%b' "$YELLOW" '⚠ WARN'    "$RESET" ;;
    CRITICAL) printf '%b%s%b' "$RED"   '✘ CRITICAL' "$RESET" ;;
    *)        printf '%s' "$1" ;;
  esac
}

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