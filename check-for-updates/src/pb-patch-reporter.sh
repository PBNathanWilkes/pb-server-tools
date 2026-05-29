#!/usr/bin/env bash
# pb-patch-reporter.sh — Patch report + email component for check-for-updates v4.2
#
# Reads  /var/lib/pb-maintenance/patch-state.json (read-only via shared flock)
# Writes /var/lib/pb-maintenance/patch-suppression.json (exclusive flock)
#
# Applies cross-run confirmation gate (seen_count >= 2), suppression
# keyed on (name, architecture, candidate_version), and escalation logic.
# Builds HTML email; sends via mailx.
#
# v4.2.0
#
# Exit codes:
#   0 — success
#   1 — infrastructure failure (missing state file, JSON parse error, jq absent)

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
readonly VERSION="4.2.0"
readonly SCRIPT_NAME="$(basename "$0")"

STATE_DIR="${STATE_DIR:-/var/lib/pb-maintenance}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/patch-state.json}"
STATE_LOCK="${STATE_LOCK:-${STATE_DIR}/patch-state.json.lock}"
SUPP_FILE="${SUPP_FILE:-${STATE_DIR}/patch-suppression.json}"
SUPP_LOCK="${SUPP_LOCK:-${STATE_DIR}/patch-suppression.json.lock}"
LOG_DIR="${LOG_DIR:-/backup/patch-logs}"
APT_STAMP="${APT_STAMP:-/var/lib/apt/lists/pb-last-update}"
readonly STATE_DIR STATE_FILE STATE_LOCK SUPP_FILE SUPP_LOCK LOG_DIR APT_STAMP

FROM_EMAIL="${FROM_EMAIL:-$(hostname) <donotreply@pbhcorp.com>}"RECIPIENTS_NORMAL="${RECIPIENTS_NORMAL:-nathan.wilkes@pbhcorp.com}"
RECIPIENTS_VALIDATE="${RECIPIENTS_VALIDATE:-nathan.wilkes@pbhcorp.com}"
RECIPIENTS_MONTHLY="${RECIPIENTS_MONTHLY:-nathan.wilkes@pbhcorp.com support@pbhcorp.com}"
readonly FROM_EMAIL RECIPIENTS_NORMAL RECIPIENTS_VALIDATE RECIPIENTS_MONTHLY
readonly SUBJECT_PREFIX="[$(hostname --fqdn 2>/dev/null || hostname)]"

readonly COMPLIANCE_CONTROL="Patch Management"
readonly EXECUTION_SOURCE="systemd timer"

# Suppression TTL: 4 days (F15 — covers 3-day weekend with stat holiday)
readonly SUPPRESSION_TTL_DAYS=4

# Staleness threshold: 26h (24h cadence + 2h grace)
readonly STALE_THRESHOLD_SECS=$((26 * 3600))

# Cross-run confirmation threshold
readonly SEEN_COUNT_THRESHOLD=2

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
MODE="check"
ADDITIONAL_RECIPIENT=""
EMAIL_HTML_FILE=""
LOG_FILE=""

readonly HOSTNAME_FQDN="$(hostname --fqdn 2>/dev/null || hostname)"

readonly C_CYAN=$'\033[0;36m'
readonly C_RESET=$'\033[0m'

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
  [[ -n "${EMAIL_HTML_FILE:-}" && -f "${EMAIL_HTML_FILE}" ]] && rm -f "$EMAIL_HTML_FILE"
}
trap cleanup EXIT

on_err() {
  local rc=$? line=${BASH_LINENO[0]:-$LINENO} ts
  [[ $rc -eq 0 ]] && return  # suppress spurious ERR trigger on return 0 in subshells
  ts="$(date +'%F %T %Z')"
  printf '[%s] ERROR line %s (exit %s): %s\n' "$ts" "$line" "$rc" "${BASH_COMMAND:-?}" >&2
}
trap on_err ERR
trap 'log "Received SIGTERM; exiting cleanly"; exit 0' TERM INT

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
  local ts line
  ts="$(date +'%Y-%m-%d %H:%M:%S')"
  line="[${ts}] $*"
  printf "%s\n" "$line"
  [[ -n "${LOG_FILE:-}" ]] && printf "%s\n" "$line" >>"$LOG_FILE"
}

section() {
  local title bar
  title="$1"
  bar="$(printf '%*s' "${#title}" '' | tr ' ' '=')"
  if [[ -t 1 ]]; then
    printf "\n%s%s%s\n%s%s%s\n" "$C_CYAN" "$title" "$C_RESET" "$C_CYAN" "$bar" "$C_RESET"
  fi
  [[ -n "${LOG_FILE:-}" ]] && printf "\n%s\n%s\n" "$title" "$bar" >>"$LOG_FILE"
}

ensure_logdir() {
  local tag basename
  tag="$(date +%Y%m%d_%s)"
  basename="${tag}-${HOSTNAME_FQDN}-update-patch.log"
  local d="$LOG_DIR"
  if mkdir -p "$d" 2>/dev/null && [[ -w "$d" ]]; then
    LOG_FILE="${d}/${basename}"
  else
    LOG_FILE="/tmp/${basename}"
  fi
}

# ---------------------------------------------------------------------------
# TTY path display
# ---------------------------------------------------------------------------
display_paths() {
  [[ -t 1 ]] || return 0
  log "Script           : ${SCRIPT_NAME} v${VERSION}"
  log "State file       : ${STATE_FILE} (read-only)"
  log "Suppression file : ${SUPP_FILE}"
  log "Log file         : ${LOG_FILE}"
  log "Email from       : ${FROM_EMAIL}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
show_help() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --check|--validate|--monthly [--email ADDRESS]

  --check     Send email only if unsuppressed confirmed updates or reboot required.
  --validate  Always send a full audit report (includes suppressed/unconfirmed packages).
  --monthly   Always send a monthly verification report.
  --email     Add additional recipient.
  --help      Show this help.
EOF
}

validate_email() {
  [[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

parse_arguments() {
  if [[ $# -eq 0 ]]; then show_help; trap - ERR; exit 1; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)   MODE="check";    shift ;;
      --validate) MODE="validate"; shift ;;
      --monthly) MODE="monthly";  shift ;;
      --email)
        [[ -z "${2:-}" ]] && { printf "ERROR: --email requires an address\n" >&2; exit 1; }
        validate_email "$2" || { printf "ERROR: invalid email: %s\n" "$2" >&2; exit 1; }
        ADDITIONAL_RECIPIENT="$2"; shift 2 ;;
      --help|-h) show_help; trap - ERR; exit 0 ;;
      *) printf "ERROR: unknown option: %s\n" "$1" >&2; show_help; trap - ERR; exit 1 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# jq helpers
# ---------------------------------------------------------------------------
require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    log "ERROR: jq not installed (required for JSON state file parsing)"
    log "Install: sudo apt install jq"
    return 1
  fi
}

jq_s() {
  # jq query on a string input.  Usage: jq_s <json_string> <query>
  printf '%s' "$1" | jq -r "$2" 2>/dev/null
}

jq_n() {
  # jq query returning raw number; falls back to 0
  local v
  v="$(printf '%s' "$1" | jq -r "$2" 2>/dev/null)"
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf '0'
}

# ---------------------------------------------------------------------------
# Read state files with flock
# ---------------------------------------------------------------------------
read_state_file() {
  # Acquire shared flock on STATE_LOCK for the duration of the cat.
  exec 8>"${STATE_LOCK}"
  if ! flock -s -w 5 8; then
    log "WARN: state-file lock held by writer after 5s; reading anyway"
  fi
  local content
  content="$(cat "${STATE_FILE}" 2>/dev/null)"
  exec 8>&-
  printf '%s' "$content"
}

read_suppression_file() {
  if [[ ! -f "${SUPP_FILE}" ]]; then
    printf '{"schema":2,"updated_at":null,"suppressions":[]}'
    return 0
  fi
  cat "${SUPP_FILE}" 2>/dev/null || printf '{"schema":2,"updated_at":null,"suppressions":[]}'
}

write_suppression_file_atomic() {
  local content="$1"
  local tmp="${SUPP_FILE}.tmp"
  printf '%s\n' "$content" >"$tmp"
  mv "$tmp" "${SUPP_FILE}"
  chmod 644 "${SUPP_FILE}"
}

# ---------------------------------------------------------------------------
# Epoch conversion
# ---------------------------------------------------------------------------
iso_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || echo 0
}

now_epoch() {
  date -u +%s
}

now_iso() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

days_since_iso() {
  local iso="$1" then now_e
  then="$(iso_to_epoch "$iso")"
  now_e="$(now_epoch)"
  echo $(( (now_e - then) / 86400 ))
}

# ---------------------------------------------------------------------------
# HTML helpers
# ---------------------------------------------------------------------------
html_escape() {
  local t="$1"
  t="${t//&/&amp;}"
  t="${t//</&lt;}"
  t="${t//>/&gt;}"
  t="${t//\"/&quot;}"
  printf '%s' "$t"
}

html_begin() {
  cat >>"$EMAIL_HTML_FILE" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Patch Report</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; color: #1f2937; background: #f9fafb; margin: 0; padding: 24px; }
  .card { background: #ffffff; border: 1px solid #e5e7eb; border-radius: 8px; padding: 20px; max-width: 960px; margin: 0 auto; box-shadow: 0 1px 2px rgba(0,0,0,.05); }
  h1 { font-size: 20px; margin: 0 0 12px; color: #111827; }
  h2 { font-size: 16px; margin: 20px 0 8px; color: #111827; }
  .muted { color: #6b7280; font-size: 12px; }
  .banner { padding: 12px 16px; border-radius: 6px; margin: 12px 0; font-weight: bold; }
  .banner-critical { background: #fef2f2; border: 1px solid #ef4444; color: #991b1b; }
  .banner-warn { background: #fffbeb; border: 1px solid #f59e0b; color: #92400e; }
  .banner-info { background: #eff6ff; border: 1px solid #3b82f6; color: #1e40af; }
  table { width: 100%; border-collapse: collapse; margin-top: 10px; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid #e5e7eb; font-size: 14px; }
  th { background: #f9fafb; color: #374151; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 9999px; font-size: 12px; }
  .badge-ok   { background: #ecfdf5; color: #065f46; border: 1px solid #10b981; }
  .badge-warn { background: #fffbeb; color: #92400e; border: 1px solid #f59e0b; }
  .badge-err  { background: #fef2f2; color: #991b1b; border: 1px solid #ef4444; }
  .badge-info { background: #eff6ff; color: #1e40af; border: 1px solid #3b82f6; }
  .badge-supp { background: #f3f4f6; color: #374151; border: 1px solid #9ca3af; }
  pre { background: #0b1020; color: #e5e7eb; padding: 12px; border-radius: 6px; overflow: auto; font-size: 12px; line-height: 1.4; }
  .footer { margin-top: 16px; color: #6b7280; font-size: 12px; }
</style>
</head>
<body>
<div class="card">
HTML
}

html_end() {
  cat >>"$EMAIL_HTML_FILE" <<'HTML'
</div>
</body>
</html>
HTML
}

html_h1() {
  printf "<h1>%s</h1>\n<div class=\"muted\">%s</div>\n" \
    "$(html_escape "$1")" "$(html_escape "$2")" >>"$EMAIL_HTML_FILE"
}

html_h2() {
  printf "<h2>%s</h2>\n" "$(html_escape "$1")" >>"$EMAIL_HTML_FILE"
}

html_badge() {
  local text="$1" style="${2:-ok}"
  printf '<span class="badge badge-%s">%s</span>\n' \
    "$style" "$(html_escape "$text")" >>"$EMAIL_HTML_FILE"
}

html_banner() {
  local text="$1" style="${2:-warn}"
  printf '<div class="banner banner-%s">%s</div>\n' \
    "$style" "$(html_escape "$text")" >>"$EMAIL_HTML_FILE"
}

html_pre() {
  printf '<pre>%s</pre>\n' "$(html_escape "$1")" >>"$EMAIL_HTML_FILE"
}

html_package_table() {
  local title="$1" pkg_json="$2" extra_col_header="${3:-}" extra_col_field="${4:-}"

  html_h2 "$title"

  local count
  count="$(printf '%s' "$pkg_json" | jq 'length' 2>/dev/null || echo 0)"
  if [[ "$count" == "0" ]]; then
    html_badge "None" "ok"
    return 0
  fi

  cat >>"$EMAIL_HTML_FILE" <<HTML
<table>
  <thead>
    <tr>
      <th>Package</th>
      <th>Architecture</th>
      <th>Candidate Version</th>
      <th>Security</th>
      <th>Seen</th>
      ${extra_col_header:+<th>$extra_col_header</th>}
    </tr>
  </thead>
  <tbody>
HTML

  local i
  for (( i=0; i<count; i++ )); do
    local name arch ver is_sec seen_count extra_val
    name="$(printf '%s' "$pkg_json" | jq -r ".[$i].name")"
    arch="$(printf '%s' "$pkg_json" | jq -r ".[$i].architecture")"
    ver="$(printf '%s' "$pkg_json" | jq -r ".[$i].candidate_version")"
    is_sec="$(printf '%s' "$pkg_json" | jq -r ".[$i].is_security")"
    seen_count="$(printf '%s' "$pkg_json" | jq -r ".[$i].seen_count // 0")"
    extra_val=""
    [[ -n "$extra_col_field" ]] && extra_val="$(printf '%s' "$pkg_json" | jq -r ".[$i].${extra_col_field} // \"-\"")"

    local sec_badge
    if [[ "$is_sec" == "true" ]]; then
      sec_badge='<span class="badge badge-err">security</span>'
    else
      sec_badge='<span class="badge badge-ok">standard</span>'
    fi

    cat >>"$EMAIL_HTML_FILE" <<HTML
    <tr>
      <td>$(html_escape "$name")</td>
      <td>$(html_escape "$arch")</td>
      <td>$(html_escape "$ver")</td>
      <td>$sec_badge</td>
      <td>$(html_escape "${seen_count}×")</td>
      ${extra_col_header:+<td>$(html_escape "$extra_val")</td>}
    </tr>
HTML
  done

  printf '  </tbody>\n</table>\n' >>"$EMAIL_HTML_FILE"
}

html_suppressed_table() {
  local title="$1" pkg_json="$2"

  html_h2 "$title"

  local count
  count="$(printf '%s' "$pkg_json" | jq 'length' 2>/dev/null || echo 0)"
  if [[ "$count" == "0" ]]; then
    html_badge "None" "ok"
    return 0
  fi

  cat >>"$EMAIL_HTML_FILE" <<HTML
<table>
  <thead>
    <tr>
      <th>Package</th>
      <th>Architecture</th>
      <th>Candidate Version</th>
      <th>Security</th>
      <th>First Alerted</th>
      <th>Suppressed Until</th>
      <th>Alert Count</th>
    </tr>
  </thead>
  <tbody>
HTML

  local i
  for (( i=0; i<count; i++ )); do
    local name arch ver is_sec first_alerted suppressed_until alert_count
    name="$(printf '%s' "$pkg_json" | jq -r ".[$i].name")"
    arch="$(printf '%s' "$pkg_json" | jq -r ".[$i].architecture")"
    ver="$(printf '%s' "$pkg_json" | jq -r ".[$i].candidate_version")"
    is_sec="$(printf '%s' "$pkg_json" | jq -r ".[$i].is_security // false")"
    first_alerted="$(printf '%s' "$pkg_json" | jq -r ".[$i].first_alerted_at // \"-\"")"
    suppressed_until="$(printf '%s' "$pkg_json" | jq -r ".[$i].suppressed_until // \"-\"")"
    alert_count="$(printf '%s' "$pkg_json" | jq -r ".[$i].alert_count // 0")"

    local sec_badge
    if [[ "$is_sec" == "true" ]]; then
      sec_badge='<span class="badge badge-err">security</span>'
    else
      sec_badge='<span class="badge badge-ok">standard</span>'
    fi

    cat >>"$EMAIL_HTML_FILE" <<HTML
    <tr>
      <td>$(html_escape "$name")</td>
      <td>$(html_escape "$arch")</td>
      <td>$(html_escape "$ver") <span class="badge badge-supp">Suppressed</span></td>
      <td>$sec_badge</td>
      <td>$(html_escape "$first_alerted")</td>
      <td>$(html_escape "$suppressed_until")</td>
      <td>$(html_escape "$alert_count")</td>
    </tr>
HTML
  done

  printf '  </tbody>\n</table>\n' >>"$EMAIL_HTML_FILE"
}

html_update_command_section() {
  cat >>"$EMAIL_HTML_FILE" <<'HTML'
<h2>Run this to apply updates</h2>
<div style="margin-top:8px;padding:12px;background:#f3f4f6;border-left:4px solid #10b981;border-radius:4px;">
  <strong>Command:</strong>
  <pre style="margin-top:8px;background:#1f2937;color:#e5e7eb;padding:10px;border-radius:4px;font-size:13px;">sudo apt-get update &amp;&amp; sudo apt-get dist-upgrade -y</pre>
  <div style="font-size:12px;color:#6b7280;margin-top:8px;">
    <strong>Tip:</strong> Plan a maintenance window if a reboot is required.
  </div>
</div>
HTML
}

html_footer() {
  printf '<div class="footer">Generated by %s v%s on %s at %s</div>\n' \
    "$(html_escape "$SCRIPT_NAME")" "$(html_escape "$VERSION")" \
    "$(html_escape "$HOSTNAME_FQDN")" "$(date +'%F %T %Z')" \
    >>"$EMAIL_HTML_FILE"
}

html_kv_section() {
  local args="$1" eval_at="$2"
  cat >>"$EMAIL_HTML_FILE" <<HTML
<h2>System Information</h2>
<div style="display:grid;grid-template-columns:200px 1fr;gap:8px 16px;padding:12px;background:#f3f4f6;border-radius:6px;margin-top:10px;">
  <div style="color:#6b7280;">Host</div><div>$(html_escape "$HOSTNAME_FQDN")</div>
  <div style="color:#6b7280;">OS</div><div>$(lsb_release -ds 2>/dev/null || echo "Unknown")</div>
  <div style="color:#6b7280;">Kernel</div><div>$(html_escape "$(uname -r)")</div>
  <div style="color:#6b7280;">Reporter</div><div>$(html_escape "$SCRIPT_NAME") v$(html_escape "$VERSION")</div>
  <div style="color:#6b7280;">Mode</div><div>$(html_escape "$MODE")</div>
  <div style="color:#6b7280;">Args</div><div>$(html_escape "$args")</div>
  <div style="color:#6b7280;">Evaluated at</div><div>$(html_escape "$eval_at")</div>
  <div style="color:#6b7280;">Log file</div><div>$(html_escape "$LOG_FILE")</div>
</div>
HTML
}

html_reboot_section() {
  local reboot_required="$1" reboot_pkgs="$2"
  html_h2 "Reboot Status"
  if [[ "$reboot_required" == "true" ]]; then
    html_banner "🔴 System reboot required" "critical"
    if [[ -n "$reboot_pkgs" ]]; then
      printf '<p><strong>Packages requiring reboot:</strong></p>\n' >>"$EMAIL_HTML_FILE"
      html_pre "$reboot_pkgs"
    fi
  else
    html_badge "No reboot required" "ok"
  fi
}

html_lts_section() {
  local lts_avail="$1" lts_ver="$2"
  html_h2 "LTS Upgrade Status"
  if [[ "$lts_avail" == "true" ]]; then
    html_banner "ℹ️ LTS upgrade available: Ubuntu ${lts_ver}" "info"
    printf '<pre style="margin-top:8px;background:#1f2937;color:#e5e7eb;padding:8px;border-radius:4px;font-size:13px;">sudo do-release-upgrade</pre>\n' \
      >>"$EMAIL_HTML_FILE"
  else
    html_badge "System is on current LTS release" "ok"
  fi
}

html_activity_summary() {
  local days=30 total=0 check_count=0 validate_count=0 monthly_count=0 patches_count=0
  if [[ -d "$LOG_DIR" ]]; then
    while IFS= read -r f; do
      (( total += 1 ))
      local line mode pa
      line="$(grep -m1 'PATCH_MONITOR_RESULT' "$f" 2>/dev/null || true)"
      [[ -z "$line" ]] && continue
      mode="$(printf '%s' "$line" | sed -n 's/.*mode=\([^ ]*\).*/\1/p')"
      pa="$(printf '%s' "$line" | sed -n 's/.*patches_available=\([^ ]*\).*/\1/p')"
      case "$mode" in
        check)
          (( check_count += 1 ))
          [[ "$pa" == "true" ]] && (( patches_count += 1 )) || true
          ;;
        validate) (( validate_count += 1 )) ;;
        monthly)  (( monthly_count += 1 )) ;;
      esac
    done < <(find "$LOG_DIR" -maxdepth 1 -name '*-update-patch.log' -mtime -"$days" 2>/dev/null | sort)
  fi

  html_h2 "Last 30 Days Patch Monitor Activity"
  cat >>"$EMAIL_HTML_FILE" <<HTML
<table>
  <thead><tr><th>Metric</th><th>Count</th></tr></thead>
  <tbody>
    <tr><td>Total runs</td><td>$(html_escape "$total")</td></tr>
    <tr><td>Check runs</td><td>$(html_escape "$check_count")</td></tr>
    <tr><td><strong>Patches available (check mode)</strong></td><td><strong>$(html_escape "$patches_count")</strong></td></tr>
    <tr><td>Validate runs</td><td>$(html_escape "$validate_count")</td></tr>
    <tr><td>Monthly runs</td><td>$(html_escape "$monthly_count")</td></tr>
  </tbody>
</table>
HTML
}

# ---------------------------------------------------------------------------
# Suppression helpers
# ---------------------------------------------------------------------------
supp_key() {
  # Canonical suppression key: name|arch|candidate_version
  printf '%s|%s|%s' "$1" "$2" "$3"
}

lookup_suppression() {
  # Args: supp_json name arch candidate_ver
  # Returns JSON object for the matching suppression, or empty string
  local supp_json="$1" name="$2" arch="$3" ver="$4"
  printf '%s' "$supp_json" | jq -r \
    --arg name "$name" --arg arch "$arch" --arg ver "$ver" \
    '.suppressions[] | select(.name==$name and .architecture==$arch and .candidate_version==$ver)' \
    2>/dev/null
}

is_suppressed_now() {
  # Args: supp_obj
  # Returns 0 if currently suppressed (suppressed_until in the future)
  local supp_obj="$1"
  [[ -z "$supp_obj" ]] && return 1
  local until_epoch now_e
  until_epoch="$(printf '%s' "$supp_obj" | jq -r '.suppressed_until' | xargs -I{} date -u -d '{}' +%s 2>/dev/null || echo 0)"
  now_e="$(now_epoch)"
  [[ "$until_epoch" =~ ^[0-9]+$ ]] && (( until_epoch > now_e ))
}

upsert_suppression() {
  # Add or update a suppression entry in the suppression JSON.
  # Args: supp_json name arch ver first_alerted_at alert_count is_security
  local supp_json="$1" name="$2" arch="$3" ver="$4"
  local first_alerted="$5" alert_count="$6" is_security="${7:-false}"

  local now
  now="$(now_iso)"
  local suppressed_until
  suppressed_until="$(date -u -d "+${SUPPRESSION_TTL_DAYS} days" +'%Y-%m-%dT%H:%M:%SZ')"

  # Remove existing entry for this key, then append updated entry
  printf '%s' "$supp_json" | jq \
    --arg name "$name" --arg arch "$arch" --arg ver "$ver" \
    --arg fa "$first_alerted" --arg now "$now" --arg su "$suppressed_until" \
    --argjson ac "$alert_count" --argjson is_sec "$is_security" \
    '
      .suppressions = (
        [.suppressions[] | select((.name==$name and .architecture==$arch and .candidate_version==$ver) | not)]
        + [{
            "name": $name,
            "architecture": $arch,
            "candidate_version": $ver,
            "is_security": $is_sec,
            "alert_count": $ac,
            "first_alerted_at": $fa,
            "last_alerted_at": $now,
            "suppressed_until": $su
          }]
      )
      | .updated_at = $now
    ' 2>/dev/null
}

prune_suppressions() {
  # Remove suppression entries for which no matching (name, arch, ver) exists in state.
  local supp_json="$1" state_pkgs="$2"
  printf '%s' "$supp_json" | jq \
    --argjson pkgs "$state_pkgs" \
    '
      .suppressions = [
        .suppressions[]
        | . as $s
        | if ($pkgs | any(.name == $s.name and .architecture == $s.architecture and .candidate_version == $s.candidate_version))
          then .
          else empty
          end
      ]
    ' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Email sending
# ---------------------------------------------------------------------------
send_email() {
  local subject="$1" html_body_file="$2" recipients="$3"

  command -v mailx >/dev/null 2>&1 || { log "ERROR: mailx not installed"; return 1; }

  local -a rcpt
  read -r -a rcpt <<<"$recipients"

  local systemd_unit="${PB_SYSTEMD_UNIT:-${SYSTEMD_UNIT:-unknown}}"

  if mailx \
    -a "From: ${FROM_EMAIL}" \
    -a "Content-Type: text/html; charset=UTF-8" \
    -a "X-Compliance-Control: ${COMPLIANCE_CONTROL}" \
    -a "X-Execution-Source: ${EXECUTION_SOURCE}" \
    -a "X-Host: ${HOSTNAME_FQDN}" \
    -a "X-Script: ${SCRIPT_NAME} v${VERSION}" \
    -a "X-Systemd-Unit: ${systemd_unit}" \
    -a "X-Invocation-ID: ${INVOCATION_ID:-}" \
    -s "$subject" \
    "${rcpt[@]}" <"$html_body_file" 2>/dev/null; then
    log "Email sent to: $recipients"
    return 0
  fi

  # Fallback: -r envelope sender
  local envelope_sender
  envelope_sender="$(printf '%s' "$FROM_EMAIL" | sed -E 's/.*<(.+?)>.*/\1/')"
  if mailx \
    -r "$envelope_sender" \
    -a "Content-Type: text/html; charset=UTF-8" \
    -a "X-Compliance-Control: ${COMPLIANCE_CONTROL}" \
    -a "X-Host: ${HOSTNAME_FQDN}" \
    -a "X-Script: ${SCRIPT_NAME} v${VERSION}" \
    -s "$subject" \
    "${rcpt[@]}" <"$html_body_file" 2>&1; then
    log "Email sent (via -r) to: $recipients"
    return 0
  fi

  log "ERROR: Failed to send email"
  return 1
}

# ---------------------------------------------------------------------------
# Systemd timer schedule
# ---------------------------------------------------------------------------
timer_schedule_info() {
  local unit="${PB_SYSTEMD_UNIT:-${SYSTEMD_UNIT:-}}"
  if [[ -z "$unit" ]] || ! command -v systemctl >/dev/null 2>&1; then
    printf "Not running under systemd (unit not set)"
    return
  fi
  local base="${unit%.service}"
  systemctl list-timers --all --no-pager "${base}.timer" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
main() {
  local original_args="$*"
  parse_arguments "$@"
  ensure_logdir

  section "pb-patch-reporter started"
  log "Host: ${HOSTNAME_FQDN}"
  log "Mode: ${MODE}"
  log "Args: ${original_args:-none}"
  display_paths

  # --- Prerequisite check ---
  require_jq || return 1

  if [[ ! -f "${STATE_FILE}" ]]; then
    log "ERROR: state file absent: ${STATE_FILE}"
    log "Run pb-apt-evaluator.py first."
    return 1
  fi

  # --- Read state file (shared flock) ---
  section "Reading state file"
  local state_json
  state_json="$(read_state_file)"
  if [[ -z "$state_json" ]]; then
    log "ERROR: state file is empty or unreadable"
    return 1
  fi
  if ! printf '%s' "$state_json" | jq empty 2>/dev/null; then
    log "ERROR: state file is not valid JSON"
    return 1
  fi

  local schema
  schema="$(jq_n "$state_json" '.schema')"
  if [[ "$schema" != "2" ]]; then
    log "ERROR: state file schema is ${schema}; expected 2"
    return 1
  fi

  local evaluated_at apt_update_failed reboot_required lts_available lts_version
  evaluated_at="$(jq_s "$state_json" '.evaluated_at')"
  apt_update_failed="$(jq_s "$state_json" '.apt_update_failed')"
  reboot_required="$(jq_s "$state_json" '.reboot_required')"
  reboot_pkgs="$(jq_s "$state_json" '.reboot_packages | join(", ")')"
  lts_available="$(jq_s "$state_json" '.lts_upgrade_available')"
  lts_version="$(jq_s "$state_json" '.lts_upgrade_version // ""')"
  local all_packages_json
  all_packages_json="$(printf '%s' "$state_json" | jq '.packages')"

  log "State: evaluated_at=${evaluated_at} apt_update_failed=${apt_update_failed} reboot=${reboot_required}"

  # --- Staleness check ---
  local now_e eval_epoch stale_banner=""
  now_e="$(now_epoch)"
  eval_epoch="$(iso_to_epoch "$evaluated_at")"
  local age_secs=$(( now_e - eval_epoch ))
  if (( age_secs > STALE_THRESHOLD_SECS )); then
    local age_hours=$(( age_secs / 3600 ))
    stale_banner="🔴 EVALUATOR STALE — last evaluated ${age_hours}h ago; expected daily."
    log "WARN: $stale_banner"
  fi

  # --- Partition packages ---
  local confirmed_json unconfirmed_json
  confirmed_json="$(printf '%s' "$all_packages_json" | jq '[.[] | select(.seen_count >= '"$SEEN_COUNT_THRESHOLD"')]')"
  unconfirmed_json="$(printf '%s' "$all_packages_json" | jq '[.[] | select(.seen_count < '"$SEEN_COUNT_THRESHOLD"')]')"

  local confirmed_count unconfirmed_count
  confirmed_count="$(printf '%s' "$confirmed_json" | jq 'length')"
  unconfirmed_count="$(printf '%s' "$unconfirmed_json" | jq 'length')"
  log "Packages: confirmed=${confirmed_count} unconfirmed=${unconfirmed_count}"

  # --- Read suppression file (exclusive flock for the whole decision + write cycle) ---
  section "Applying suppression logic"
  exec 9>"${SUPP_LOCK}"
  flock -x 9

  local supp_json
  supp_json="$(read_suppression_file)"
  if ! printf '%s' "$supp_json" | jq empty 2>/dev/null; then
    log "WARN: suppression file corrupt; starting fresh"
    supp_json='{"schema":2,"updated_at":null,"suppressions":[]}'
  fi

  # Prune stale suppression entries
  local pruned_supp_json
  pruned_supp_json="$(prune_suppressions "$supp_json" "$all_packages_json")"
  supp_json="${pruned_supp_json:-$supp_json}"

  # Categorise confirmed packages: alert vs suppressed
  local alert_pkgs_json=()     # packages to alert on this run
  local suppressed_pkgs_json=() # currently suppressed
  local i confirmed_len
  confirmed_len="$(printf '%s' "$confirmed_json" | jq 'length')"

  for (( i=0; i<confirmed_len; i++ )); do
    local pkg_json name arch ver
    pkg_json="$(printf '%s' "$confirmed_json" | jq ".[$i]")"
    name="$(printf '%s' "$pkg_json" | jq -r '.name')"
    arch="$(printf '%s' "$pkg_json" | jq -r '.architecture')"
    ver="$(printf '%s' "$pkg_json" | jq -r '.candidate_version')"

    local supp_obj
    supp_obj="$(lookup_suppression "$supp_json" "$name" "$arch" "$ver")"

    if is_suppressed_now "$supp_obj"; then
      # Merge suppression fields into the package object for the report
      local merged
      merged="$(printf '%s' "$pkg_json" | jq \
        --argjson s "$supp_obj" \
        '. + {first_alerted_at: $s.first_alerted_at, suppressed_until: $s.suppressed_until, alert_count: $s.alert_count}')"
      suppressed_pkgs_json+=("$merged")
      log "suppressed until $(printf '%s' "$supp_obj" | jq -r '.suppressed_until'): ${name}:${arch} ${ver}"
    else
      alert_pkgs_json+=("$pkg_json")
    fi
  done

  # Build JSON arrays for alert and suppressed packages
  local alert_json="[]" suppressed_json="[]"
  if [[ "${#alert_pkgs_json[@]}" -gt 0 ]]; then
    alert_json="$(printf '%s\n' "${alert_pkgs_json[@]}" | jq -s '.')"
  fi
  if [[ "${#suppressed_pkgs_json[@]}" -gt 0 ]]; then
    suppressed_json="$(printf '%s\n' "${suppressed_pkgs_json[@]}" | jq -s '.')"
  fi

  local alert_count suppressed_count
  alert_count="$(printf '%s' "$alert_json" | jq 'length')"
  suppressed_count="$(printf '%s' "$suppressed_json" | jq 'length')"

  # Security counts
  local alert_security_count
  alert_security_count="$(printf '%s' "$alert_json" | jq '[.[] | select(.is_security==true)] | length')"

  log "Alert candidates: ${alert_count} (security: ${alert_security_count}) suppressed: ${suppressed_count}"

  # --- Escalation and suppression write-back ---
  section "Computing escalation and updating suppression"

  local escalation_flag=false
  local max_days_pending=0
  local alert_len="$alert_count"

  for (( i=0; i<alert_len; i++ )); do
    local pkg_json name arch ver is_sec first_seen
    pkg_json="$(printf '%s' "$alert_json" | jq ".[$i]")"
    name="$(printf '%s' "$pkg_json" | jq -r '.name')"
    arch="$(printf '%s' "$pkg_json" | jq -r '.architecture')"
    ver="$(printf '%s' "$pkg_json" | jq -r '.candidate_version')"
    is_sec="$(printf '%s' "$pkg_json" | jq -r '.is_security')"
    first_seen="$(printf '%s' "$pkg_json" | jq -r '.first_seen')"

    local days_pending
    days_pending="$(days_since_iso "$first_seen")"
    (( days_pending > max_days_pending )) && max_days_pending="$days_pending"

    # Look up existing suppression for alert_count
    local supp_obj prev_alert_count first_alerted
    supp_obj="$(lookup_suppression "$supp_json" "$name" "$arch" "$ver")"
    if [[ -n "$supp_obj" ]]; then
      prev_alert_count="$(printf '%s' "$supp_obj" | jq -r '.alert_count // 0')"
      first_alerted="$(printf '%s' "$supp_obj" | jq -r '.first_alerted_at // "null"')"
    else
      prev_alert_count=0
      first_alerted="$(now_iso)"
    fi

    local new_alert_count=$(( prev_alert_count + 1 ))

    if (( prev_alert_count >= 1 && days_pending >= SUPPRESSION_TTL_DAYS )); then
      escalation_flag=true
    fi

    # Update suppression entry
    supp_json="$(upsert_suppression "$supp_json" "$name" "$arch" "$ver" \
      "$first_alerted" "$new_alert_count" "$is_sec")"

    log "Will alert: ${name}:${arch} ${ver} (days_pending=${days_pending} alert_count=${new_alert_count})"
  done

  # Write updated suppression file
  if [[ "$alert_len" -gt 0 ]]; then
    write_suppression_file_atomic "$supp_json"
    log "Suppression file updated"
  else
    # Still write back pruned version
    write_suppression_file_atomic "$supp_json"
  fi

  exec 9>&-  # release suppression flock

  # --- Determine email send gate ---
  section "Email send decision"

  local send_mail=false
  local email_recipients="" email_subject="" subject_flags=""

  # Build subject flags
  if [[ "$alert_security_count" -gt 0 ]]; then
    subject_flags="${alert_security_count} SECURITY"
  fi
  if [[ "$reboot_required" == "true" ]]; then
    subject_flags="${subject_flags:+$subject_flags + }REBOOT REQUIRED"
  fi
  if [[ "$lts_available" == "true" ]]; then
    subject_flags="${subject_flags:+$subject_flags + }LTS UPGRADE"
  fi
  if [[ "$escalation_flag" == "true" ]]; then
    subject_flags="${subject_flags:+$subject_flags + }ESCALATION"
  fi

  local timestamp
  timestamp="$(date +'%Y-%m-%d %H:%M')"

  case "$MODE" in
    check)
      if [[ "$apt_update_failed" == "true" ]]; then
        send_mail=true
        email_recipients="$RECIPIENTS_NORMAL"
        email_subject="${SUBJECT_PREFIX} ⚠️ APT UPDATE FAILED — ${SCRIPT_NAME} @ ${timestamp}"
      elif [[ "$alert_count" -gt 0 || "$reboot_required" == "true" ]]; then
        send_mail=true
        email_recipients="$RECIPIENTS_NORMAL"
        if [[ -n "$subject_flags" ]]; then
          email_subject="${SUBJECT_PREFIX} ⚠️ ${subject_flags} — ${alert_count} update(s) — ${SCRIPT_NAME} @ ${timestamp}"
        else
          email_subject="${SUBJECT_PREFIX} Patch status: ${alert_count} update(s) pending — ${SCRIPT_NAME} @ ${timestamp}"
        fi
      else
        log "No unsuppressed confirmed updates; skipping email (check mode)"
      fi
      ;;
    validate)
      send_mail=true
      email_recipients="$RECIPIENTS_VALIDATE"
      if [[ "$alert_count" -gt 0 || "$reboot_required" == "true" ]]; then
        if [[ -n "$subject_flags" ]]; then
          email_subject="${SUBJECT_PREFIX} Patch validation: ⚠️ ${subject_flags} — ${alert_count} update(s) — ${SCRIPT_NAME} @ ${timestamp}"
        else
          email_subject="${SUBJECT_PREFIX} Patch validation: ${alert_count} update(s) pending — ${SCRIPT_NAME} @ ${timestamp}"
        fi
      else
        email_subject="${SUBJECT_PREFIX} Patch validation: no updates required — ${SCRIPT_NAME} @ ${timestamp}"
      fi
      ;;
    monthly)
      send_mail=true
      email_recipients="$RECIPIENTS_MONTHLY"
      if [[ "$alert_count" -gt 0 || "$reboot_required" == "true" ]]; then
        if [[ -n "$subject_flags" ]]; then
          email_subject="${SUBJECT_PREFIX} Monthly Patch Verification: ⚠️ ${subject_flags} — ${alert_count} update(s) — ${SCRIPT_NAME} @ ${timestamp}"
        else
          email_subject="${SUBJECT_PREFIX} Monthly Patch Verification: ${alert_count} update(s) pending — ${SCRIPT_NAME} @ ${timestamp}"
        fi
      else
        email_subject="${SUBJECT_PREFIX} Monthly Patch Verification: system up-to-date — ${SCRIPT_NAME} @ ${timestamp}"
      fi
      ;;
    *)
      log "ERROR: Unknown mode: ${MODE}"
      return 1
      ;;
  esac

  [[ -n "$ADDITIONAL_RECIPIENT" ]] && {
    email_recipients="${email_recipients} ${ADDITIONAL_RECIPIENT}"
    log "Additional recipient: ${ADDITIONAL_RECIPIENT}"
  }

  # --- Build HTML report ---
  section "Building HTML report"
  EMAIL_HTML_FILE="$(mktemp -t patch-report.XXXXXX.html)"
  html_begin
  html_h1 "Patch Report — ${HOSTNAME_FQDN}" "$(date +'%F %T %Z')"

  # Abnormal state banners (top of report)
  if [[ "$apt_update_failed" == "true" ]]; then
    html_banner "🔴 APT LIST REFRESH FAILED — package list is stale; this report may not reflect packages released since ${evaluated_at}. Investigate before relying on a clean bill of health." "critical"
  fi
  if [[ -n "$stale_banner" ]]; then
    html_banner "$stale_banner" "critical"
  fi
  if [[ "$unconfirmed_count" -gt 0 && ( "$MODE" == "validate" || "$MODE" == "monthly" ) ]]; then
    html_banner "🟡 ${unconfirmed_count} package(s) awaiting cross-run confirmation — listed below; not yet eligible for alert." "warn"
  fi

  # Update command
  if [[ "$alert_count" -gt 0 || "$reboot_required" == "true" ]]; then
    html_update_command_section
  fi

  # Alert packages
  if [[ "$alert_count" -gt 0 ]]; then
    # Security-only subset
    local sec_json
    sec_json="$(printf '%s' "$alert_json" | jq '[.[] | select(.is_security==true)]')"
    local sec_len
    sec_len="$(printf '%s' "$sec_json" | jq 'length')"
    if [[ "$sec_len" -gt 0 ]]; then
      html_banner "🔴 ${sec_len} security update(s) pending" "critical"
      html_package_table "Security Updates Pending" "$sec_json"
    fi
    html_package_table "All Pending Updates" "$alert_json" "First Seen" "first_seen"
  else
    html_h2 "Pending Updates"
    html_badge "No unsuppressed confirmed updates" "ok"
  fi

  # Suppressed packages (validate/monthly only)
  if [[ "$MODE" == "validate" || "$MODE" == "monthly" ]]; then
    html_suppressed_table "Suppressed Packages (alert sent, not yet patched)" "$suppressed_json"
    html_package_table "Awaiting Cross-Run Confirmation (seen 1×)" "$unconfirmed_json"
  fi

  # Reboot
  html_reboot_section "$reboot_required" "$reboot_pkgs"

  # LTS
  html_lts_section "$lts_available" "$lts_version"

  # 30-day activity summary (validate/monthly)
  if [[ "$MODE" == "validate" || "$MODE" == "monthly" ]]; then
    html_activity_summary
  fi

  # System info
  html_kv_section "${original_args:-none}" "$evaluated_at"
  html_footer
  html_end

  # --- PATCH_MONITOR_RESULT log marker ---
  local patches_available=false
  [[ "$alert_count" -gt 0 || "$reboot_required" == "true" ]] && patches_available=true

  log "PATCH_MONITOR_RESULT mode=${MODE} patches_available=${patches_available} upgrade_count=${alert_count} security_count=${alert_security_count} reboot_required=${reboot_required} suppressed_count=${suppressed_count} unconfirmed_count=${unconfirmed_count} apt_update_failed=${apt_update_failed}"

  # --- Send email ---
  if [[ "$send_mail" == "true" ]]; then
    section "Sending Email Report"
    send_email "$email_subject" "$EMAIL_HTML_FILE" "$email_recipients" || true
  fi

  section "pb-patch-reporter complete"
  log "Done."
  return 0
}

main "$@"
