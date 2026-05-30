#!/usr/bin/env bash
# Unit tests for login-compliance-check.sh patch check section
# §9.3 of DESIGN-check-for-updates-v4_2.md
#
# Run: bash tests/unit/test_login_compliance.sh
# No root, no real apt, no network.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOGIN_CHECK="${REPO_ROOT}/src/login-compliance-check.sh"

PASS=0
FAIL=0
ERRORS=()

_pass() { (( PASS++ )); printf '  PASS %s\n' "$1"; }
_fail() { (( FAIL++ )); ERRORS+=("$1"); printf '  FAIL %s\n' "$1"; }

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then _pass "$name"
  else _fail "$name"; printf '       got  = %q\n       want = %q\n' "$got" "$want"; fi
}
assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then _pass "$name"
  else _fail "$name"; printf '       does not contain: %q\n' "$needle"; fi
}

# -------------------------------------------------------------------------
# Harness
# -------------------------------------------------------------------------
setup_env() {
  TMPDIR_T="$(mktemp -d)"
  STATE_DIR_T="${TMPDIR_T}/pb-maintenance"
  MOCK_BIN="${TMPDIR_T}/bin"
  mkdir -p "$STATE_DIR_T" "$MOCK_BIN"

  STATE_FILE_T="${STATE_DIR_T}/patch-state.json"
  SUPP_FILE_T="${STATE_DIR_T}/patch-suppression.json"

  # Lock files must exist for read-open (exec 9<) to succeed
  touch "${STATE_DIR_T}/patch-state.json.lock"
  touch "${STATE_DIR_T}/patch-suppression.json.lock"

  # msmtp mock log (success)
  MSMTP_LOG_T="${TMPDIR_T}/msmtp.log"
  printf '2026-05-10 08:00:00 sender=test@example.com exitcode=EX_OK\n' >"$MSMTP_LOG_T"

  # Mock msmtprc pointing to our log
  MSMTPRC_T="${TMPDIR_T}/msmtprc"
  printf 'defaults\nlogfile %s\n' "$MSMTP_LOG_T" >"$MSMTPRC_T"

  # Mock sendmail → msmtp
  cat >"${MOCK_BIN}/sendmail" <<'EOF'
#!/usr/bin/env bash
exec cat >/dev/null
EOF
  chmod +x "${MOCK_BIN}/sendmail"
  ln -s "${MOCK_BIN}/sendmail" "${MOCK_BIN}/msmtp" 2>/dev/null || true

  # mailx mock
  cat >"${MOCK_BIN}/mailx" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${MOCK_BIN}/mailx"

  export PATH="${MOCK_BIN}:${PATH}"
}

teardown_env() {
  rm -rf "${TMPDIR_T}"
}

now_iso() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
past_iso() {
  date -u -d "$1 hours ago" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -v-"${1}"H +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || now_iso
}
future_iso() {
  date -u -d "+$1 days" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -v+"${1}"d +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || now_iso
}

write_state() { printf '%s\n' "$1" >"$STATE_FILE_T"; }
write_suppression() { printf '%s\n' "$1" >"$SUPP_FILE_T"; }

empty_state() {
  local ea="${1:-$(now_iso)}" af="${2:-false}"
  jq -n \
    --arg ea "$ea" --argjson af "$af" \
    '{schema:2, evaluated_at:$ea, apt_updated_at:$ea, apt_update_failed:$af,
      reboot_required:false, reboot_packages:[], lts_upgrade_available:false,
      lts_upgrade_version:null, packages:[]}'
}

pkg_entry() {
  local name="${1:-curl}" arch="${2:-amd64}" ver="${3:-1.0}"
  local seen="${4:-2}" is_sec="${5:-false}" first_seen="${6:-$(past_iso 48)}"
  jq -n \
    --arg n "$name" --arg a "$arch" --arg v "$ver" \
    --argjson sc "$seen" --argjson is "$is_sec" \
    --arg fs "$first_seen" --arg ls "$(now_iso)" \
    '{name:$n, architecture:$a, candidate_version:$v,
      installed_version:"0.9", is_security:$is,
      origin:"noble-updates", first_seen:$fs, last_seen:$ls, seen_count:$sc}'
}

empty_suppression() { jq -n '{schema:2, updated_at:null, suppressions:[]}'; }

run_patch_check() {
  # Run only the _check_patches function by sourcing the script with env overrides.
  # We do this by temporarily overriding the state file paths via the constants.
  STATE_DIR="$STATE_DIR_T" \
  STATE_FILE="$STATE_FILE_T" \
  STATE_LOCK="${STATE_DIR_T}/patch-state.json.lock" \
  SUPP_FILE="$SUPP_FILE_T" \
  SUPP_LOCK="${STATE_DIR_T}/patch-suppression.json.lock" \
  bash -c "
    source '$LOGIN_CHECK' 2>/dev/null || true
    # Override constants
    readonly STATE_FILE='$STATE_FILE_T' 2>/dev/null || STATE_FILE='$STATE_FILE_T'
    readonly STATE_LOCK='${STATE_DIR_T}/patch-state.json.lock' 2>/dev/null || true
    readonly SUPP_FILE='$SUPP_FILE_T' 2>/dev/null || SUPP_FILE='$SUPP_FILE_T'
    readonly SUPP_LOCK='${STATE_DIR_T}/patch-suppression.json.lock' 2>/dev/null || true
    _check_patches
  " 2>/dev/null || true
}

# Simpler approach: run the full script but with overridden state paths
run_full_check() {
  # State paths: passed via env vars (script honours ${STATE_DIR:-default} pattern)
  # msmtprc path: patched via sed (array literal in script, not a single constant)
  local tmp_script
  tmp_script="${TMPDIR_T}/login-compliance-patched.sh"
  sed -e "s|/etc/msmtprc|${MSMTPRC_T}|g" \
      -e "s|/etc/msmtp/msmtprc|${MSMTPRC_T}|g" \
    "$LOGIN_CHECK" >"$tmp_script"
  chmod +x "$tmp_script"
  STATE_DIR="$STATE_DIR_T" \
  STATE_FILE="$STATE_FILE_T" \
  STATE_LOCK="${STATE_DIR_T}/patch-state.json.lock" \
  SUPP_FILE="$SUPP_FILE_T" \
  SUPP_LOCK="${STATE_DIR_T}/patch-suppression.json.lock" \
  bash "$tmp_script" 2>/dev/null || true
}

extract_patches() {
  # Extract just the Patches= part from login-check output
  local output="$1"
  printf '%s' "$output" | grep -oE 'Patches=.[^[:space:]]*' | head -1 || echo "Patches=MISSING"
}

# =========================================================================
# Tests
# =========================================================================

run_all_tests() {
  printf '\n--- login-compliance-check.sh unit tests ---\n\n'

  # ------------------------------------------------------------------
  # T01: jq not installed → WARN
  # ------------------------------------------------------------------
  {
    setup_env
    write_state "$(empty_state)"
    write_suppression "$(empty_suppression)"
    # Hide jq
    cat >"${MOCK_BIN}/jq" <<'EOF'
#!/usr/bin/env bash
echo "jq not found" >&2; exit 127
EOF
    chmod +x "${MOCK_BIN}/jq"
    local out patches
    out="$(run_full_check)"
    patches="$(extract_patches "$out")"
    assert_contains "T01_jq_missing_warn" "$patches" "WARN"
    rm "${MOCK_BIN}/jq"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T02: state file missing → WARN
  # ------------------------------------------------------------------
  {
    setup_env
    # Don't write state file
    local out patches
    out="$(run_full_check)"
    patches="$(extract_patches "$out")"
    assert_contains "T02_state_file_missing_warn" "$patches" "WARN"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T03: state file stale (27h ago) → WARN
  # ------------------------------------------------------------------
  {
    setup_env
    local stale_time
    stale_time="$(past_iso 27)"
    write_state "$(empty_state "$stale_time")"
    write_suppression "$(empty_suppression)"
    local out patches
    out="$(run_full_check)"
    patches="$(extract_patches "$out")"
    assert_contains "T03_stale_state_warn" "$patches" "WARN"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T04: state file corrupt → WARN
  # ------------------------------------------------------------------
  {
    setup_env
    printf '{corrupt json{{\n' >"$STATE_FILE_T"
    local out patches
    out="$(run_full_check)"
    patches="$(extract_patches "$out")"
    assert_contains "T04_corrupt_state_warn" "$patches" "WARN"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T05: apt_update_failed=true → CRITICAL (F4)
  # ------------------------------------------------------------------
  {
    setup_env
    write_state "$(empty_state "$(now_iso)" true)"
    write_suppression "$(empty_suppression)"
    local out patches
    out="$(run_full_check)"
    patches="$(extract_patches "$out")"
    assert_contains "T05_apt_update_failed_critical" "$patches" "CRITICAL"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T06: no pending packages, no issues → OK
  # ------------------------------------------------------------------
  {
    setup_env
    write_state "$(empty_state)"
    write_suppression "$(empty_suppression)"
    local out patches
    out="$(run_full_check)"
    patches="$(extract_patches "$out")"
    assert_contains "T06_no_pending_ok" "$patches" "OK"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T07: 2 confirmed unsuppressed packages → CRITICAL
  # ------------------------------------------------------------------
  {
    setup_env
    local pkg1 pkg2 state
    pkg1="$(pkg_entry curl amd64 1.0 2)"
    pkg2="$(pkg_entry wget amd64 1.0 2)"
    state="$(empty_state | jq --argjson p1 "$pkg1" --argjson p2 "$pkg2" '.packages = [$p1,$p2]')"
    write_state "$state"
    write_suppression "$(empty_suppression)"
    local out patches
    out="$(run_full_check)"
    patches="$(extract_patches "$out")"
    assert_contains "T07_confirmed_pending_critical" "$patches" "CRITICAL"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T08: unconfirmed only (seen_count=1) → WARN
  # ------------------------------------------------------------------
  {
    setup_env
    local pkg state
    pkg="$(pkg_entry curl amd64 1.0 1)"
    state="$(empty_state | jq --argjson p "$pkg" '.packages = [$p]')"
    write_state "$state"
    write_suppression "$(empty_suppression)"
    local out patches
    out="$(run_full_check)"
    patches="$(extract_patches "$out")"
    assert_contains "T08_unconfirmed_only_warn" "$patches" "WARN"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T09: suppressed only (no unsuppressed) → WARN
  # ------------------------------------------------------------------
  {
    setup_env
    local pkg state supp
    pkg="$(pkg_entry curl amd64 1.0 2)"
    state="$(empty_state | jq --argjson p "$pkg" '.packages = [$p]')"
    write_state "$state"
    supp="$(jq -n \
      --arg su "$(future_iso 3)" \
      '{schema:2, updated_at:null,
        suppressions:[{name:"curl", architecture:"amd64", candidate_version:"1.0",
          is_security:false, alert_count:1,
          first_alerted_at:"2026-05-09T08:00:00Z",
          last_alerted_at:"2026-05-09T08:00:00Z",
          suppressed_until:$su}]}')"
    write_suppression "$supp"
    local out patches
    out="$(run_full_check)"
    patches="$(extract_patches "$out")"
    assert_contains "T09_suppressed_only_warn" "$patches" "WARN"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T10: reboot_required=true → CRITICAL
  # ------------------------------------------------------------------
  {
    setup_env
    local state
    state="$(empty_state | jq '.reboot_required = true')"
    write_state "$state"
    write_suppression "$(empty_suppression)"
    local out patches
    out="$(run_full_check)"
    patches="$(extract_patches "$out")"
    assert_contains "T10_reboot_required_critical" "$patches" "CRITICAL"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T11: validate-mode state file (no confirmed_at field) → OK (F16)
  # No spurious WARN for absence of v4.1 fields.
  # ------------------------------------------------------------------
  {
    setup_env
    write_state "$(empty_state)"
    write_suppression "$(empty_suppression)"
    local out patches
    out="$(run_full_check)"
    patches="$(extract_patches "$out")"
    assert_contains "T11_validate_mode_state_ok_no_spurious_warn" "$patches" "OK"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T12: login banner latency under 100ms (warm)
  # ------------------------------------------------------------------
  {
    setup_env
    write_state "$(empty_state)"
    write_suppression "$(empty_suppression)"
    local start_ns end_ns elapsed_ms
    start_ns="$(date +%s%N 2>/dev/null || echo 0)"
    run_full_check >/dev/null
    end_ns="$(date +%s%N 2>/dev/null || echo 0)"
    if [[ "$start_ns" != "0" && "$end_ns" != "0" ]]; then
      elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
      [[ "$elapsed_ms" -lt 100 ]] \
        && _pass "T12_login_latency_under_100ms (${elapsed_ms}ms)" \
        || printf '  WARN T12_login_latency_under_100ms: %dms (target <100ms; file a defect if >100ms warm)\n' "$elapsed_ms"
    else
      printf '  SKIP T12_login_latency_under_100ms (nanosecond timer unavailable)\n'
    fi
    teardown_env
  }

  # -----------------------------------------------------------------------
  printf '\n--- Results: %d passed, %d failed ---\n' "$PASS" "$FAIL"
  if [[ "$FAIL" -gt 0 ]]; then
    printf '\nFailed tests:\n'
    local e
    for e in "${ERRORS[@]}"; do printf '  - %s\n' "$e"; done
    return 1
  fi
  return 0
}

run_all_tests
