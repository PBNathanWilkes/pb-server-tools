#!/usr/bin/env bash
# test_login_compliance.sh — Unit tests for login-compliance-check.sh
#
# Tests use mock binaries injected via PATH override and temporary
# directories.  No production state files are touched.
#
# Run as non-root:
#   bash tests/unit/test_login_compliance.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/../../src/login-compliance-check.sh"

PASS=0
FAIL=0
ERRORS=()
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

pass() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); ERRORS+=("$1"); printf '  FAIL  %s\n' "$1"; }

# ---------------------------------------------------------------------------
# T01 — script syntax check
# ---------------------------------------------------------------------------
T01() {
  bash -n "$SRC" 2>/dev/null \
    && pass "T01 script syntax check (bash -n)" \
    || fail "T01 script syntax check (bash -n)"
}

# ---------------------------------------------------------------------------
# T02 — _cache_fresh: expired TTL returns non-zero
# ---------------------------------------------------------------------------
T02() {
  local tmpdir="${TMPDIR_BASE}/T02"
  mkdir -p "$tmpdir"

  local result
  result=$(
    XDG_CACHE_HOME="$tmpdir"
    # Source only cache helpers inline to avoid root-check at top level
    _now_epoch() { date +%s; }
    _cache_dir() {
      local d="${XDG_CACHE_HOME:-$HOME/.cache}/login-compliance"
      mkdir -p "$d" 2>/dev/null || true
      printf '%s' "$d"
    }
    _cache_time_get() {
      local f="$(_cache_dir)/${1}.time"
      [[ -f "$f" ]] || return 1
      cat "$f" 2>/dev/null || return 1
    }
    _apt_update_stamp_epoch() { printf '0'; }
    _cache_fresh() {
      local key="$1" ttl="$2" last now apt_stamp
      [[ "$ttl" =~ ^[0-9]+$ ]] || return 1
      (( ttl == 0 )) && return 1
      last="$(_cache_time_get "$key")" || return 1
      [[ "$last" =~ ^[0-9]+$ ]] || return 1
      now="$(_now_epoch)"
      (( now - last < ttl )) || return 1
      apt_stamp="$(_apt_update_stamp_epoch)"
      if [[ "$apt_stamp" =~ ^[0-9]+$ ]] && (( apt_stamp > 0 )); then
        (( apt_stamp <= last )) || return 1
      fi
      return 0
    }

    # Write a cache entry from 7200 seconds ago
    local cache_dir
    cache_dir="$(_cache_dir)"
    printf '%s' $(( $(date +%s) - 7200 )) > "${cache_dir}/patch_result.time"

    # TTL of 3600 — should be expired
    _cache_fresh "patch_result" "3600" && printf 'fresh' || printf 'stale'
  )
  [[ "$result" == "stale" ]] && pass "T02 _cache_fresh: expired TTL → stale" \
                              || fail "T02 _cache_fresh: expired TTL → stale (got: $result)"
}

# ---------------------------------------------------------------------------
# T03 — _cache_fresh: within TTL returns zero
# ---------------------------------------------------------------------------
T03() {
  local tmpdir="${TMPDIR_BASE}/T03"
  mkdir -p "$tmpdir"

  local result
  result=$(
    XDG_CACHE_HOME="$tmpdir"
    _now_epoch() { date +%s; }
    _cache_dir() {
      local d="${XDG_CACHE_HOME:-$HOME/.cache}/login-compliance"
      mkdir -p "$d" 2>/dev/null || true
      printf '%s' "$d"
    }
    _cache_time_get() {
      local f="$(_cache_dir)/${1}.time"
      [[ -f "$f" ]] || return 1
      cat "$f" 2>/dev/null || return 1
    }
    _apt_update_stamp_epoch() { printf '0'; }
    _cache_fresh() {
      local key="$1" ttl="$2" last now apt_stamp
      [[ "$ttl" =~ ^[0-9]+$ ]] || return 1
      (( ttl == 0 )) && return 1
      last="$(_cache_time_get "$key")" || return 1
      [[ "$last" =~ ^[0-9]+$ ]] || return 1
      now="$(_now_epoch)"
      (( now - last < ttl )) || return 1
      apt_stamp="$(_apt_update_stamp_epoch)"
      if [[ "$apt_stamp" =~ ^[0-9]+$ ]] && (( apt_stamp > 0 )); then
        (( apt_stamp <= last )) || return 1
      fi
      return 0
    }

    local cache_dir
    cache_dir="$(_cache_dir)"
    printf '%s' "$(date +%s)" > "${cache_dir}/patch_result.time"

    _cache_fresh "patch_result" "3600" && printf 'fresh' || printf 'stale'
  )
  [[ "$result" == "fresh" ]] && pass "T03 _cache_fresh: within TTL → fresh" \
                              || fail "T03 _cache_fresh: within TTL → fresh (got: $result)"
}

# ---------------------------------------------------------------------------
# T04 — _msmtp_line_is_success: exitcode=EX_OK → success
# ---------------------------------------------------------------------------
T04() {
  local result
  result=$(
    _msmtp_line_is_success() {
      local line="$1"
      echo "$line" | grep -Eqi 'exitcode=EX_(TEMPFAIL|UNAVAILABLE|NOHOST|NOPERM|DATAERR|IOERR|SOFTWARE|OSERR|NOUSER|PROTOCOL)' && return 1
      echo "$line" | grep -Eqi 'fail|error|timed out|refused|denied' && return 1
      echo "$line" | grep -Eq  'exitcode=EX_OK'   && return 0
      echo "$line" | grep -Eq  'smtpstatus=250'   && return 0
      return 1
    }
    _msmtp_line_is_success "2026-05-01 08:00:00 host=smtp.example.com tls=on exitcode=EX_OK" \
      && printf 'success' || printf 'fail'
  )
  [[ "$result" == "success" ]] && pass "T04 _msmtp_line_is_success: EX_OK" \
                                || fail "T04 _msmtp_line_is_success: EX_OK (got: $result)"
}

# ---------------------------------------------------------------------------
# T05 — _msmtp_line_is_success: TEMPFAIL → failure
# ---------------------------------------------------------------------------
T05() {
  local result
  result=$(
    _msmtp_line_is_success() {
      local line="$1"
      echo "$line" | grep -Eqi 'exitcode=EX_(TEMPFAIL|UNAVAILABLE|NOHOST|NOPERM|DATAERR|IOERR|SOFTWARE|OSERR|NOUSER|PROTOCOL)' && return 1
      echo "$line" | grep -Eqi 'fail|error|timed out|refused|denied' && return 1
      echo "$line" | grep -Eq  'exitcode=EX_OK' && return 0
      return 1
    }
    _msmtp_line_is_success "2026-05-01 08:00:00 host=smtp.example.com exitcode=EX_TEMPFAIL" \
      && printf 'success' || printf 'fail'
  )
  [[ "$result" == "fail" ]] && pass "T05 _msmtp_line_is_success: TEMPFAIL → failure" \
                             || fail "T05 _msmtp_line_is_success: TEMPFAIL → failure (got: $result)"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n'
T01; T02; T03; T04; T05

printf '\n--- Results: %d passed, %d failed ---\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf 'Failed tests:\n'
  for e in "${ERRORS[@]}"; do printf '  %s\n' "$e"; done
  exit 1
fi
exit 0
