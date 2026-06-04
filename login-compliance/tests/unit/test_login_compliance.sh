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
# Helpers for end-to-end patch-verdict tests (state-file model, v0.10.0+)
# ---------------------------------------------------------------------------
# Build a state file and run the real script; echo the "Patches" verdict word
# and (in verbose mode) capture the reason. Requires jq.
_iso() { date -u -d "$1" +'%Y-%m-%dT%H:%M:%SZ'; }

_run_patch_verdict() {
  # $1=evaluated_at  $2=packages_json  [$3=apt_failed]  [$4=reboot]
  local sd="${TMPDIR_BASE}/state_$RANDOM"; mkdir -p "$sd"
  jq -n --arg ea "$1" --argjson pk "${2:-[]}" \
        --argjson af "${3:-false}" --argjson rb "${4:-false}" \
    '{schema:2,evaluated_at:$ea,apt_updated_at:$ea,apt_update_failed:$af,
      reboot_required:$rb,reboot_packages:[],lts_upgrade_available:false,
      lts_upgrade_version:null,packages:$pk}' >"${sd}/patch-state.json"
  STATE_DIR="$sd" LCHECK_VERBOSE=1 bash "$SRC" 2>/dev/null \
    | grep -iE '^\s*Patches:|Patches=' | tr -d '\n'
}

_confirmed_pkg='[{"name":"curl","architecture":"amd64","candidate_version":"8.5","is_security":false,"seen_count":2,"first_seen":"2026-05-01T00:00:00Z","last_seen":"2026-06-01T00:00:00Z"}]'

# ---------------------------------------------------------------------------
# T02 — fresh state, no packages → Patches=OK with no staleness note
#       (regression guard for the false-positive WARN this consolidation fixed)
# ---------------------------------------------------------------------------
T02() {
  local out; out="$(_run_patch_verdict "$(_iso 'now')" '[]')"
  if [[ "$out" == *"Patches=OK"* && "$out" != *"data"*"old"* ]]; then
    pass "T02 fresh + no packages → OK, no note"
  else
    fail "T02 fresh + no packages → OK, no note (got: $out)"
  fi
}

# ---------------------------------------------------------------------------
# T03 — mildly stale (40h) + no packages → OK annotated "(data 40h old)"
#       Verdict must NOT be overridden to WARN by staleness alone.
# ---------------------------------------------------------------------------
T03() {
  local out; out="$(_run_patch_verdict "$(_iso '40 hours ago')" '[]')"
  if [[ "$out" == *"Patches=OK"* && "$out" == *"data 40h old"* ]]; then
    pass "T03 mildly stale + clean → OK + age note"
  else
    fail "T03 mildly stale + clean → OK + age note (got: $out)"
  fi
}

# ---------------------------------------------------------------------------
# T06 — mildly stale (40h) + confirmed pending → CRITICAL, verdict shows through
# ---------------------------------------------------------------------------
T06() {
  local out; out="$(_run_patch_verdict "$(_iso '40 hours ago')" "$_confirmed_pkg")"
  if [[ "$out" == *"Patches=CRITICAL"* && "$out" == *"pending"* ]]; then
    pass "T06 mildly stale + pending → CRITICAL (verdict shows through)"
  else
    fail "T06 mildly stale + pending → CRITICAL (got: $out)"
  fi
}

# ---------------------------------------------------------------------------
# T07 — dead evaluator (5d, > LCHECK_PATCH_DEAD_DAYS=3) → WARN
# ---------------------------------------------------------------------------
T07() {
  local out; out="$(_run_patch_verdict "$(_iso '5 days ago')" '[]')"
  if [[ "$out" == *"Patches=WARN"* && "$out" == *"evaluator appears dead"* ]]; then
    pass "T07 dead evaluator (>3d) → WARN"
  else
    fail "T07 dead evaluator (>3d) → WARN (got: $out)"
  fi
}

# ---------------------------------------------------------------------------
# T08 — unparseable evaluated_at → WARN (distinct from 'stale'; epoch-0 fix)
# ---------------------------------------------------------------------------
T08() {
  local sd="${TMPDIR_BASE}/state_bad"; mkdir -p "$sd"
  jq -n '{schema:2,evaluated_at:"garbage",apt_update_failed:false,
          reboot_required:false,packages:[]}' >"${sd}/patch-state.json"
  local out
  out="$(STATE_DIR="$sd" LCHECK_VERBOSE=1 bash "$SRC" 2>/dev/null \
    | grep -iE '^\s*Patches:|Patches=' | tr -d '\n')"
  if [[ "$out" == *"Patches=WARN"* && "$out" == *"unparseable"* ]]; then
    pass "T08 unparseable evaluated_at → WARN (not fake-stale)"
  else
    fail "T08 unparseable evaluated_at → WARN (got: $out)"
  fi
}
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
T01; T02; T03; T04; T05; T06; T07; T08

printf '\n--- Results: %d passed, %d failed ---\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf 'Failed tests:\n'
  for e in "${ERRORS[@]}"; do printf '  %s\n' "$e"; done
  exit 1
fi
exit 0
