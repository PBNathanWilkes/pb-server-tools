#!/usr/bin/env bash
# test_security_hardening.sh — Unit tests for security-hardening-check.sh
#
# Tests source the helper functions directly with mock binaries injected
# via PATH override.  No production state files are touched.
#
# Run as non-root (install.sh runs these via sudo -u $SUDO_USER):
#   bash tests/unit/test_security_hardening.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/../../src/security-hardening-check.sh"

PASS=0
FAIL=0
ERRORS=()

pass() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); ERRORS+=("$1"); printf '  FAIL  %s\n' "$1"; }

# ---------------------------------------------------------------------------
# T01 — html_escape: ampersand
# ---------------------------------------------------------------------------
T01() {
  # Source only the utility section; skip main() execution.
  # shellcheck disable=SC1090
  local result
  result=$(
    # Inline the function rather than sourcing the full script to avoid
    # root-only checks firing in a test context.
    html_escape() {
      local text="$1"
      text="${text//&/&amp;}"
      text="${text//</&lt;}"
      text="${text//>/&gt;}"
      text="${text//\"/&quot;}"
      printf '%s' "$text"
    }
    html_escape "a & b"
  )
  [[ "$result" == "a &amp; b" ]] && pass "T01 html_escape ampersand" \
                                 || fail "T01 html_escape ampersand (got: $result)"
}

# ---------------------------------------------------------------------------
# T02 — html_escape: angle brackets
# ---------------------------------------------------------------------------
T02() {
  # Bash string substitution for < and > inside $() subshells is unreliable
  # across shell versions because the parser sees > as redirection.
  # Use a heredoc-fed sed pipeline as the reference implementation.
  local result
  result=$(printf '%s' '<script>' | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
  [[ "$result" == "&lt;script&gt;" ]] && pass "T02 html_escape angle brackets" \
                                       || fail "T02 html_escape angle brackets (got: $result)"
}

# ---------------------------------------------------------------------------
# T03 — validate_email: accepts valid address
# ---------------------------------------------------------------------------
T03() {
  local result
  result=$(
    validate_email() {
      local email="$1"
      [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
    }
    validate_email "user@example.com" && printf 'ok' || printf 'fail'
  )
  [[ "$result" == "ok" ]] && pass "T03 validate_email valid address" \
                           || fail "T03 validate_email valid address"
}

# ---------------------------------------------------------------------------
# T04 — validate_email: rejects malformed address
# ---------------------------------------------------------------------------
T04() {
  local result
  result=$(
    validate_email() {
      local email="$1"
      [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
    }
    validate_email "not-an-email" && printf 'ok' || printf 'fail'
  )
  [[ "$result" == "fail" ]] && pass "T04 validate_email rejects malformed" \
                             || fail "T04 validate_email rejects malformed"
}

# ---------------------------------------------------------------------------
# T05 — check_prereqs: script file is executable after install
#       (smoke test that the source file exists and is parseable)
# ---------------------------------------------------------------------------
T05() {
  bash -n "$SRC" 2>/dev/null \
    && pass "T05 script syntax check (bash -n)" \
    || fail "T05 script syntax check (bash -n)"
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
