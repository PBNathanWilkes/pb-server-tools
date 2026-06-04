#!/usr/bin/env bash
# Unit tests for pb-patch-reporter.sh
# §9.2 of DESIGN-check-for-updates-v4_2.md
#
# Run: bash tests/unit/test_pb_patch_reporter.sh
# No root, no real apt, no email sent. Uses a mock mailx wrapper.
# Requires: jq

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPORTER="${REPO_ROOT}/src/pb-patch-reporter.sh"

# -------------------------------------------------------------------------
# Test harness
# -------------------------------------------------------------------------
PASS=0
FAIL=0
ERRORS=()

_pass() { (( PASS++ )); printf '  PASS %s\n' "$1"; }
_fail() { (( FAIL++ )); ERRORS+=("$1"); printf '  FAIL %s\n' "$1"; }

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then _pass "$name"; else
    _fail "$name"; printf '       got  = %q\n       want = %q\n' "$got" "$want"; fi
}
assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then _pass "$name"; else
    _fail "$name"; printf '       haystack does not contain: %q\n' "$needle"; fi
}
assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then _pass "$name"; else
    _fail "$name"; printf '       haystack unexpectedly contains: %q\n' "$needle"; fi
}
assert_file_exists() {
  local name="$1" path="$2"
  [[ -f "$path" ]] && _pass "$name" || { _fail "$name"; printf '       missing: %s\n' "$path"; }
}
assert_file_absent() {
  local name="$1" path="$2"
  [[ ! -f "$path" ]] && _pass "$name" || { _fail "$name"; printf '       unexpected: %s\n' "$path"; }
}

# -------------------------------------------------------------------------
# Test environment setup
# -------------------------------------------------------------------------
setup_env() {
  TMPDIR_TEST="$(mktemp -d)"
  STATE_DIR_T="${TMPDIR_TEST}/pb-maintenance"
  LOG_DIR_T="${TMPDIR_TEST}/patch-logs"
  MOCK_BIN="${TMPDIR_TEST}/bin"
  mkdir -p "$STATE_DIR_T" "$LOG_DIR_T" "$MOCK_BIN"

  STATE_FILE_T="${STATE_DIR_T}/patch-state.json"
  SUPP_FILE_T="${STATE_DIR_T}/patch-suppression.json"

  # Mock mailx — writes subject + recipient to MAIL_CAPTURE file
  MAIL_CAPTURE="${TMPDIR_TEST}/mail_capture.txt"
  cat >"${MOCK_BIN}/mailx" <<EOF
#!/usr/bin/env bash
# Capture call; read stdin
subject=""
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "-s" ]]; then subject="\$2"; shift 2
  elif [[ "\$1" == "-a" || "\$1" == "-r" ]]; then shift 2
  else break
  fi
done
{
  printf 'SUBJECT:%s\n' "\$subject"
  printf 'RECIPIENTS:%s\n' "\$*"
  cat -
} >>"${MAIL_CAPTURE}"
exit 0
EOF
  chmod +x "${MOCK_BIN}/mailx"
  chmod +x "${MOCK_BIN}/jq" 2>/dev/null || true
  export PATH="${MOCK_BIN}:${PATH}"

  # hostname mock
  cat >"${MOCK_BIN}/hostname" <<'EOF'
#!/usr/bin/env bash
printf 'TESTHOST.pbhcorp.com\n'
EOF
  chmod +x "${MOCK_BIN}/hostname"
}

teardown_env() {
  rm -rf "${TMPDIR_TEST}"
}

now_iso() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}
past_iso() {
  date -u -d "$1 hours ago" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -v-"${1}"H +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || now_iso
}
future_iso() {
  date -u -d "$1 days" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -v+"${1}"d +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || now_iso
}

write_state() {
  # write_state <state_json>
  printf '%s\n' "$1" >"${STATE_FILE_T}"
}

write_suppression() {
  printf '%s\n' "$1" >"${SUPP_FILE_T}"
}

empty_state() {
  local eval_at="${1:-$(now_iso)}" apt_failed="${2:-false}"
  jq -n \
    --arg ea "$eval_at" \
    --argjson af "$apt_failed" \
    '{schema:2, evaluated_at:$ea, apt_updated_at:$ea, apt_update_failed:$af,
      reboot_required:false, reboot_packages:[], lts_upgrade_available:false,
      lts_upgrade_version:null, packages:[]}'
}

pkg_entry() {
  local name="${1:-curl}" arch="${2:-amd64}" ver="${3:-8.5.0-2ubuntu10.9}"
  local seen="${4:-2}" is_sec="${5:-false}" first_seen="${6:-$(past_iso 48)}"
  jq -n \
    --arg n "$name" --arg a "$arch" --arg v "$ver" \
    --argjson sc "$seen" --argjson is "$is_sec" \
    --arg fs "$first_seen" --arg ls "$(now_iso)" \
    '{name:$n, architecture:$a, candidate_version:$v,
      installed_version:"0.9", is_security:$is,
      origin:"noble-updates", first_seen:$fs, last_seen:$ls, seen_count:$sc}'
}

state_with_pkg() {
  local pkg_json="$1" apt_failed="${2:-false}"
  local base
  base="$(empty_state "$(now_iso)" "$apt_failed")"
  printf '%s' "$base" | jq --argjson p "$pkg_json" '.packages = [$p]'
}

empty_suppression() {
  jq -n '{schema:2, updated_at:null, suppressions:[]}'
}

run_reporter() {
  # Run reporter with overridden paths; capture output
  STATE_DIR="$STATE_DIR_T" \
  LOG_DIR="$LOG_DIR_T" \
  RECIPIENTS_NORMAL="test@example.com" \
  RECIPIENTS_VALIDATE="test@example.com" \
  RECIPIENTS_MONTHLY="test@example.com support@example.com" \
  bash "$REPORTER" "$@" 2>&1 || true
}

# -------------------------------------------------------------------------
# Helper to source reporter functions for unit-level testing
# -------------------------------------------------------------------------
source_reporter_functions() {
  # We can't source the reporter directly (it has a main() guard).
  # Instead, test at integration level via run_reporter and inspect output/files.
  true
}

# =========================================================================
# Tests
# =========================================================================
run_all_tests() {

  printf '\n--- pb-patch-reporter.sh unit tests ---\n\n'

  # ------------------------------------------------------------------
  # T01: no packages, no apt_update_failed, no reboot → no email
  # ------------------------------------------------------------------
  {
    setup_env
    write_state "$(empty_state)"
    write_suppression "$(empty_suppression)"
    run_reporter --check >/dev/null
    [[ ! -f "$MAIL_CAPTURE" ]] && _pass "T01_no_packages_no_email" \
      || { [[ "$(wc -l <"$MAIL_CAPTURE" 2>/dev/null)" == "0" ]] \
        && _pass "T01_no_packages_no_email" \
        || _fail "T01_no_packages_no_email: email was sent when it shouldn't be"; }
    teardown_env
  }

  # ------------------------------------------------------------------
  # T02: unconfirmed package (seen_count=1) → no email in check mode
  # ------------------------------------------------------------------
  {
    setup_env
    local pkg
    pkg="$(pkg_entry curl amd64 1.0 1)"
    write_state "$(state_with_pkg "$pkg")"
    write_suppression "$(empty_suppression)"
    local out
    out="$(run_reporter --check)"
    local mail_lines=0
    [[ -f "$MAIL_CAPTURE" ]] && mail_lines="$(wc -l <"$MAIL_CAPTURE")"
    assert_eq "T02_unconfirmed_no_email_check" "$mail_lines" "0"
    assert_contains "T02_unconfirmed_no_email_check_log" "$out" "PATCH_MONITOR_RESULT"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T03: unconfirmed package → email sent in validate mode with awaiting-confirmation
  # ------------------------------------------------------------------
  {
    setup_env
    local pkg
    pkg="$(pkg_entry curl amd64 1.0 1)"
    write_state "$(state_with_pkg "$pkg")"
    write_suppression "$(empty_suppression)"
    run_reporter --validate >/dev/null
    assert_file_exists "T03_validate_email_sent" "$MAIL_CAPTURE"
    local mail_content
    mail_content="$(cat "$MAIL_CAPTURE" 2>/dev/null)"
    assert_contains "T03_unconfirmed_awaiting_section" "$mail_content" "Awaiting"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T04: confirmed pending (seen_count=2) → email sent, suppression entry created
  # ------------------------------------------------------------------
  {
    setup_env
    local pkg
    pkg="$(pkg_entry curl amd64 1.0 2)"
    write_state "$(state_with_pkg "$pkg")"
    write_suppression "$(empty_suppression)"
    run_reporter --check >/dev/null
    assert_file_exists "T04_confirmed_email_sent" "$MAIL_CAPTURE"
    # Suppression file should now contain an entry for curl
    assert_file_exists "T04_suppression_file_created" "$SUPP_FILE_T"
    local supp_count
    supp_count="$(jq '.suppressions | length' "$SUPP_FILE_T" 2>/dev/null || echo 0)"
    assert_eq "T04_suppression_entry_count" "$supp_count" "1"
    # Check TTL ≥ 3 days ahead
    local until_str until_epoch now_e
    until_str="$(jq -r '.suppressions[0].suppressed_until' "$SUPP_FILE_T")"
    until_epoch="$(date -u -d "$until_str" +%s 2>/dev/null || echo 0)"
    now_e="$(date -u +%s)"
    local delta=$(( until_epoch - now_e ))
    [[ "$delta" -ge $(( 3 * 86400 )) ]] \
      && _pass "T04_suppression_ttl_at_least_3d" \
      || _fail "T04_suppression_ttl_at_least_3d: TTL ${delta}s < 3 days"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T05: suppressed package → no email in check mode
  # ------------------------------------------------------------------
  {
    setup_env
    local pkg
    pkg="$(pkg_entry curl amd64 1.0 2)"
    write_state "$(state_with_pkg "$pkg")"
    local supp
    supp="$(jq -n \
      --arg name "curl" --arg arch "amd64" --arg ver "1.0" \
      --arg su "$(future_iso 3)" \
      '{schema:2, updated_at:null,
        suppressions:[{name:$name, architecture:$arch, candidate_version:$ver,
          is_security:false, alert_count:1,
          first_alerted_at:"2026-05-09T08:00:00Z",
          last_alerted_at:"2026-05-09T08:00:00Z",
          suppressed_until:$su}]}')"
    write_suppression "$supp"
    run_reporter --check >/dev/null
    local mail_lines=0
    [[ -f "$MAIL_CAPTURE" ]] && mail_lines="$(wc -l <"$MAIL_CAPTURE")"
    assert_eq "T05_suppressed_no_email_check" "$mail_lines" "0"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T06: suppressed package → shown in validate mode
  # ------------------------------------------------------------------
  {
    setup_env
    local pkg
    pkg="$(pkg_entry curl amd64 1.0 2)"
    write_state "$(state_with_pkg "$pkg")"
    local supp
    supp="$(jq -n \
      --arg su "$(future_iso 3)" \
      '{schema:2, updated_at:null,
        suppressions:[{name:"curl", architecture:"amd64", candidate_version:"1.0",
          is_security:false, alert_count:1,
          first_alerted_at:"2026-05-09T08:00:00Z",
          last_alerted_at:"2026-05-09T08:00:00Z",
          suppressed_until:$su}]}')"
    write_suppression "$supp"
    run_reporter --validate >/dev/null
    assert_file_exists "T06_validate_sends_email" "$MAIL_CAPTURE"
    local mail_content
    mail_content="$(cat "$MAIL_CAPTURE")"
    assert_contains "T06_suppressed_badge_present" "$mail_content" "Suppressed"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T07: suppression expires → email re-sent, TTL reset
  # ------------------------------------------------------------------
  {
    setup_env
    local pkg
    pkg="$(pkg_entry curl amd64 1.0 2)"
    write_state "$(state_with_pkg "$pkg")"
    local supp
    supp="$(jq -n \
      '{schema:2, updated_at:null,
        suppressions:[{name:"curl", architecture:"amd64", candidate_version:"1.0",
          is_security:false, alert_count:1,
          first_alerted_at:"2026-05-05T08:00:00Z",
          last_alerted_at:"2026-05-05T08:00:00Z",
          suppressed_until:"2026-05-01T08:00:00Z"}]}')"  # in the past
    write_suppression "$supp"
    run_reporter --check >/dev/null
    assert_file_exists "T07_expired_suppression_email_sent" "$MAIL_CAPTURE"
    # TTL should be reset
    local new_until new_epoch
    new_until="$(jq -r '.suppressions[0].suppressed_until' "$SUPP_FILE_T")"
    new_epoch="$(date -u -d "$new_until" +%s 2>/dev/null || echo 0)"
    local now_e
    now_e="$(date -u +%s)"
    [[ "$new_epoch" -gt "$now_e" ]] \
      && _pass "T07_ttl_reset_to_future" \
      || _fail "T07_ttl_reset_to_future"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T08: suppression key is (name, arch, candidate_version) — multi-arch F10
  # ------------------------------------------------------------------
  {
    setup_env
    # libfoo:amd64 suppressed, libfoo:i386 not
    local pkg_amd64 pkg_i386
    pkg_amd64="$(pkg_entry libfoo amd64 1.0 2)"
    pkg_i386="$(pkg_entry libfoo i386 1.0 2)"
    local base_state
    base_state="$(empty_state)"
    write_state "$(printf '%s' "$base_state" | jq \
      --argjson p1 "$pkg_amd64" --argjson p2 "$pkg_i386" \
      '.packages = [$p1, $p2]')"
    local supp
    supp="$(jq -n \
      --arg su "$(future_iso 3)" \
      '{schema:2, updated_at:null,
        suppressions:[{name:"libfoo", architecture:"amd64", candidate_version:"1.0",
          is_security:false, alert_count:1,
          first_alerted_at:"2026-05-09T08:00:00Z",
          last_alerted_at:"2026-05-09T08:00:00Z",
          suppressed_until:$su}]}')"
    write_suppression "$supp"
    run_reporter --check >/dev/null
    # Email should fire for i386 only
    assert_file_exists "T08_multiarch_i386_triggers_email" "$MAIL_CAPTURE"
    local mail_content
    mail_content="$(cat "$MAIL_CAPTURE")"
    assert_contains "T08_i386_in_email" "$mail_content" "i386"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T09: suppression invalidated on candidate version change (F3)
  # ------------------------------------------------------------------
  {
    setup_env
    # State has curl 10.9; suppression is for curl 10.8
    local pkg
    pkg="$(pkg_entry curl amd64 8.5.0-2ubuntu10.9 2)"
    write_state "$(state_with_pkg "$pkg")"
    local supp
    supp="$(jq -n \
      --arg su "$(future_iso 3)" \
      '{schema:2, updated_at:null,
        suppressions:[{name:"curl", architecture:"amd64",
          candidate_version:"8.5.0-2ubuntu10.8",
          is_security:false, alert_count:1,
          first_alerted_at:"2026-05-05T08:00:00Z",
          last_alerted_at:"2026-05-05T08:00:00Z",
          suppressed_until:$su}]}')"
    write_suppression "$supp"
    run_reporter --check >/dev/null
    # Email must fire because candidate version changed (suppression does not match)
    assert_file_exists "T09_version_change_re_alerts" "$MAIL_CAPTURE"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T10: escalation subject when pending >= 4 days and alert_count >= 1
  # ------------------------------------------------------------------
  {
    setup_env
    local first_seen_old
    first_seen_old="$(past_iso 120)"  # 5 days ago
    local pkg
    pkg="$(pkg_entry curl amd64 1.0 2 false "$first_seen_old")"
    write_state "$(state_with_pkg "$pkg")"
    local supp
    supp="$(jq -n \
      '{schema:2, updated_at:null,
        suppressions:[{name:"curl", architecture:"amd64", candidate_version:"1.0",
          is_security:false, alert_count:1,
          first_alerted_at:"2026-05-05T08:00:00Z",
          last_alerted_at:"2026-05-06T08:00:00Z",
          suppressed_until:"2026-05-01T08:00:00Z"}]}')"
    write_suppression "$supp"
    run_reporter --check >/dev/null
    assert_file_exists "T10_escalation_email_sent" "$MAIL_CAPTURE"
    local subj
    subj="$(grep '^SUBJECT:' "$MAIL_CAPTURE" | head -1)"
    assert_contains "T10_escalation_in_subject" "$subj" "ESCALATION"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T11: alert_count incremented after send
  # ------------------------------------------------------------------
  {
    setup_env
    local pkg
    pkg="$(pkg_entry curl amd64 1.0 2)"
    write_state "$(state_with_pkg "$pkg")"
    local supp
    supp="$(jq -n \
      '{schema:2, updated_at:null,
        suppressions:[{name:"curl", architecture:"amd64", candidate_version:"1.0",
          is_security:false, alert_count:2,
          first_alerted_at:"2026-05-05T08:00:00Z",
          last_alerted_at:"2026-05-08T08:00:00Z",
          suppressed_until:"2026-05-01T08:00:00Z"}]}')"
    write_suppression "$supp"
    run_reporter --check >/dev/null
    local new_count
    new_count="$(jq '.suppressions[0].alert_count' "$SUPP_FILE_T" 2>/dev/null || echo 0)"
    assert_eq "T11_alert_count_incremented" "$new_count" "3"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T12: reboot_required → email sent even with no packages
  # ------------------------------------------------------------------
  {
    setup_env
    local state
    state="$(empty_state | jq '.reboot_required = true | .reboot_packages = ["linux-image-6.8"]')"
    write_state "$state"
    write_suppression "$(empty_suppression)"
    run_reporter --check >/dev/null
    assert_file_exists "T12_reboot_sends_email" "$MAIL_CAPTURE"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T13: apt_update_failed → email sent even with no packages (F4)
  # ------------------------------------------------------------------
  {
    setup_env
    write_state "$(empty_state "$(now_iso)" true)"
    write_suppression "$(empty_suppression)"
    run_reporter --check >/dev/null
    assert_file_exists "T13_apt_update_failed_sends_email" "$MAIL_CAPTURE"
    local mail_content
    mail_content="$(cat "$MAIL_CAPTURE")"
    assert_contains "T13_apt_failed_banner" "$mail_content" "APT"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T14: PATCH_MONITOR_RESULT logged
  # ------------------------------------------------------------------
  {
    setup_env
    write_state "$(empty_state)"
    write_suppression "$(empty_suppression)"
    local out
    out="$(run_reporter --check)"
    assert_contains "T14_patch_monitor_result_logged" "$out" "PATCH_MONITOR_RESULT"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T15: extended PATCH_MONITOR_RESULT fields (suppressed_count, unconfirmed_count, apt_update_failed)
  # ------------------------------------------------------------------
  {
    setup_env
    # 1 suppressed + 1 unconfirmed
    local pkg_confirmed pkg_unconfirmed
    pkg_confirmed="$(pkg_entry curl amd64 1.0 2)"
    pkg_unconfirmed="$(pkg_entry wget amd64 1.0 1)"
    local state
    state="$(empty_state | jq \
      --argjson p1 "$pkg_confirmed" --argjson p2 "$pkg_unconfirmed" \
      '.packages = [$p1, $p2]')"
    write_state "$state"
    local supp
    supp="$(jq -n \
      --arg su "$(future_iso 3)" \
      '{schema:2, updated_at:null,
        suppressions:[{name:"curl", architecture:"amd64", candidate_version:"1.0",
          is_security:false, alert_count:1,
          first_alerted_at:"2026-05-09T08:00:00Z",
          last_alerted_at:"2026-05-09T08:00:00Z",
          suppressed_until:$su}]}')"
    write_suppression "$supp"
    local out
    out="$(run_reporter --validate)"
    assert_contains "T15_suppressed_count_field" "$out" "suppressed_count=1"
    assert_contains "T15_unconfirmed_count_field" "$out" "unconfirmed_count=1"
    assert_contains "T15_apt_update_failed_field" "$out" "apt_update_failed=false"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T16: reporter does NOT write patch-state.json (F6 ownership invariant)
  # ------------------------------------------------------------------
  {
    setup_env
    write_state "$(empty_state)"
    write_suppression "$(empty_suppression)"
    local mtime_before
    mtime_before="$(stat -c %Y "${STATE_FILE_T}" 2>/dev/null || echo 0)"
    sleep 1
    run_reporter --validate >/dev/null
    local mtime_after
    mtime_after="$(stat -c %Y "${STATE_FILE_T}" 2>/dev/null || echo 0)"
    assert_eq "T16_reporter_does_not_write_state_file" "$mtime_before" "$mtime_after"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T17: suppression file written atomically (.tmp absent after completion)
  # ------------------------------------------------------------------
  {
    setup_env
    local pkg
    pkg="$(pkg_entry curl amd64 1.0 2)"
    write_state "$(state_with_pkg "$pkg")"
    write_suppression "$(empty_suppression)"
    run_reporter --check >/dev/null
    assert_file_absent "T17_no_tmp_after_write" "${SUPP_FILE_T}.tmp"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T18: KFC #6 — an UNEXPIRED suppression for a package transiently absent
  #      from state must be RETAINED (not pruned).  Pruning it here would reset
  #      the escalation clock.  This replaces the pre-fix assertion that pruned
  #      purely on absence.
  # ------------------------------------------------------------------
  {
    setup_env
    write_state "$(empty_state)"  # package transiently absent (e.g. degraded eval)
    local supp
    supp="$(jq -n \
      --arg su "$(future_iso 3)" \
      '{schema:2, updated_at:null,
        suppressions:[{name:"curl", architecture:"amd64", candidate_version:"1.0",
          is_security:false, alert_count:1,
          first_alerted_at:"2026-05-09T08:00:00Z",
          last_alerted_at:"2026-05-09T08:00:00Z",
          suppressed_until:$su}]}')"
    write_suppression "$supp"
    run_reporter --validate >/dev/null
    local remaining
    remaining="$(jq '.suppressions | length' "$SUPP_FILE_T" 2>/dev/null || echo 0)"
    assert_eq "T18_unexpired_suppression_retained_when_pkg_absent" "$remaining" "1"
    # alert_count must be preserved across the absence
    local ac
    ac="$(jq -r '.suppressions[0].alert_count' "$SUPP_FILE_T" 2>/dev/null || echo "?")"
    assert_eq "T18_alert_count_preserved" "$ac" "1"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T18b: KFC #6 — a suppression that is BOTH absent from state AND expired is
  #       pruned (genuinely gone package, window passed).
  # ------------------------------------------------------------------
  {
    setup_env
    write_state "$(empty_state)"  # no packages
    local supp
    supp="$(jq -n \
      '{schema:2, updated_at:null,
        suppressions:[{name:"curl", architecture:"amd64", candidate_version:"1.0",
          is_security:false, alert_count:1,
          first_alerted_at:"2026-05-05T08:00:00Z",
          last_alerted_at:"2026-05-05T08:00:00Z",
          suppressed_until:"2026-05-01T08:00:00Z"}]}')"  # expired
    write_suppression "$supp"
    run_reporter --validate >/dev/null
    local remaining
    remaining="$(jq '.suppressions | length' "$SUPP_FILE_T" 2>/dev/null || echo 1)"
    assert_eq "T18b_expired_and_absent_suppression_pruned" "$remaining" "0"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T18c: KFC #6 — dry-run must NOT write the suppression file.
  # ------------------------------------------------------------------
  {
    setup_env
    local pkg
    pkg="$(pkg_entry curl amd64 1.0 2)"
    write_state "$(state_with_pkg "$pkg")"
    write_suppression "$(empty_suppression)"
    # Capture the suppression file mtime/content before
    local before
    before="$(cat "$SUPP_FILE_T")"
    run_reporter --check --dry-run >/dev/null
    local after
    after="$(cat "$SUPP_FILE_T")"
    assert_eq "T18c_dry_run_leaves_suppression_unchanged" "$after" "$before"
    assert_file_absent "T18c_dry_run_no_email" "$MAIL_CAPTURE"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T18d: M2 — an invalid evaluated_at must NOT produce a fake STALE age;
  #       it emits the distinct TIMESTAMP INVALID banner instead.
  # ------------------------------------------------------------------
  {
    setup_env
    write_state "$(empty_state "not-a-timestamp")"
    write_suppression "$(empty_suppression)"
    run_reporter --validate >/dev/null
    local mail_content
    mail_content="$(cat "$MAIL_CAPTURE" 2>/dev/null || echo "")"
    assert_contains "T18d_invalid_timestamp_banner" "$mail_content" "TIMESTAMP INVALID"
    assert_not_contains "T18d_no_fake_stale_hours" "$mail_content" "last evaluated"
    teardown_env
  }

  # ------------------------------------------------------------------
  # T19: evaluator stale banner in validate mode
  # ------------------------------------------------------------------
  {
    setup_env
    local stale_time
    stale_time="$(past_iso 30)"  # 30 hours ago → stale
    write_state "$(empty_state "$stale_time")"
    write_suppression "$(empty_suppression)"
    run_reporter --validate >/dev/null
    assert_file_exists "T19_stale_sends_email" "$MAIL_CAPTURE"
    local mail_content
    mail_content="$(cat "$MAIL_CAPTURE")"
    assert_contains "T19_stale_banner_present" "$mail_content" "STALE"
    teardown_env
  }

  # -----------------------------------------------------------------------
  # Summary
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
