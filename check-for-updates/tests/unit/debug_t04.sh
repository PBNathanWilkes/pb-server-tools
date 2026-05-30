#!/usr/bin/env bash
# Diagnostic: reproduces T04 with full reporter output visible
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPORTER="${REPO_ROOT}/src/pb-patch-reporter.sh"

TMPDIR_TEST="$(mktemp -d)"
STATE_DIR_T="${TMPDIR_TEST}/pb-maintenance"
LOG_DIR_T="${TMPDIR_TEST}/patch-logs"
MOCK_BIN="${TMPDIR_TEST}/bin"
mkdir -p "$STATE_DIR_T" "$LOG_DIR_T" "$MOCK_BIN"
STATE_FILE_T="${STATE_DIR_T}/patch-state.json"
SUPP_FILE_T="${STATE_DIR_T}/patch-suppression.json"
MAIL_CAPTURE="${TMPDIR_TEST}/mail_capture.txt"

cat >"${MOCK_BIN}/mailx" <<'MOCK'
#!/usr/bin/env bash
subject=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-s" ]]; then subject="$2"; shift 2
  elif [[ "$1" == "-a" || "$1" == "-r" ]]; then shift 2
  else break
  fi
done
{ printf 'SUBJECT:%s\n' "$subject"; printf 'RECIPIENTS:%s\n' "$*"; cat -; } >>"${MAIL_CAPTURE}"
exit 0
MOCK
chmod +x "${MOCK_BIN}/mailx"

cat >"${MOCK_BIN}/hostname" <<'MOCK'
#!/usr/bin/env bash
printf 'TESTHOST\n'
MOCK
chmod +x "${MOCK_BIN}/hostname"

export PATH="${MOCK_BIN}:${PATH}"

now_iso() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
past_iso() { date -u -d "$1 hours ago" +'%Y-%m-%dT%H:%M:%SZ'; }

PKG="$(jq -n \
  --arg fs "$(past_iso 48)" --arg ls "$(now_iso)" \
  '{name:"curl", architecture:"amd64", candidate_version:"1.0",
    installed_version:"0.9", is_security:false, origin:"noble-updates",
    first_seen:$fs, last_seen:$ls, seen_count:2}')"

STATE="$(jq -n \
  --arg ea "$(now_iso)" \
  --argjson p "$PKG" \
  '{schema:2, evaluated_at:$ea, apt_updated_at:$ea, apt_update_failed:false,
    reboot_required:false, reboot_packages:[], lts_upgrade_available:false,
    lts_upgrade_version:null, packages:[$p]}')"

printf '%s\n' "$STATE" > "$STATE_FILE_T"
jq -n '{schema:2, updated_at:null, suppressions:[]}' > "$SUPP_FILE_T"

echo "=== STATE FILE ==="
cat "$STATE_FILE_T"
echo ""
echo "=== REPORTER RUN ==="

STATE_DIR="$STATE_DIR_T" \
LOG_DIR="$LOG_DIR_T" \
RECIPIENTS_NORMAL="test@example.com" \
RECIPIENTS_VALIDATE="test@example.com" \
RECIPIENTS_MONTHLY="test@example.com" \
bash "$REPORTER" --check
RC=$?

echo ""
echo "=== EXIT CODE: $RC ==="
echo "=== MAIL CAPTURE ==="
cat "$MAIL_CAPTURE" 2>/dev/null || echo "(no mail capture)"
echo "=== SUPP FILE ==="
cat "$SUPP_FILE_T"

rm -rf "$TMPDIR_TEST"
