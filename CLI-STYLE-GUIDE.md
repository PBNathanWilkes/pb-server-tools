# CLI Style Guide — pb-server-tools

**Applies to:** all Bash scripts in this repository  
**Canonical reference:** `server-sanity/src/server-sanity-check.sh`  
**Last updated:** 2026-05-30 (repo v1.0.15)

---

## Contents

1. [File header](#1-file-header)
2. [Shell options](#2-shell-options)
3. [Colour palette](#3-colour-palette)
4. [Output primitives](#4-output-primitives)
5. [Counters and summary block](#5-counters-and-summary-block)
6. [Section banners](#6-section-banners)
7. [Runtime banner](#7-runtime-banner)
8. [Argument parsing](#8-argument-parsing)
9. [Root guard](#9-root-guard)
10. [Variable conventions](#10-variable-conventions)
11. [Function signatures and inline docs](#11-function-signatures-and-inline-docs)
12. [Error handling](#12-error-handling)
13. [stdout vs stderr](#13-stdout-vs-stderr)
14. [Timing](#14-timing)
15. [What the old scripts do differently](#15-what-the-old-scripts-do-differently)
16. [Test runner output](#16-test-runner-output)

---

## 1. File header

Every script opens with a fixed-width banner block. The banner documents the script's purpose, usage, options, and exit codes. The `--help` handler extracts from this block using `sed` — the anchor comments must be present.

```bash
#!/usr/bin/env bash
# =============================================================================
# <script-name> — <one-line description>
#
# <Two to four sentences of purpose. State read-only/mutating behaviour,
# privilege requirements, and any invariants the caller should know.>
#
# Usage:
#   sudo <script-name> [--flag] [--option <value>]
#
# Options:
#   --flag
#       Description. Secondary detail on its own indented line.
#
# Exit codes:
#   0 — success / all checks passed
#   1 — failure / one or more checks failed
#   2 — must run as root
# =============================================================================
```

Rules:

- The `=====` line is exactly 79 `=` characters.
- `Usage:` and the first option or section heading are the sed anchors used by `--help` (see §8). Keep them consistent with how the `--help` handler is written.
- Exit codes are always documented in the header, even for simple scripts.

---

## 2. Shell options

```bash
set -euo pipefail
```

Use `set -Eeuo pipefail` in scripts that define an `ERR` trap. Use `set -euo pipefail` (no `E`) where no ERR trap is set. Do not weaken options for convenience — fix the code instead.

---

## 3. Colour palette

Colours are declared once, near the top of the script, behind a TTY guard. Scripts that write to files or pipe through `tee` must still honour the guard — colour codes in captured output are stripped before non-TTY delivery (e.g. email).

```bash
# ── Colour palette ───────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED=$'\033[0;31m' GRN=$'\033[0;32m' YLW=$'\033[0;33m'
  BLU=$'\033[0;34m' BOLD=$'\033[1m'   RST=$'\033[0m'
else
  RED='' GRN='' YLW='' BLU='' BOLD='' RST=''
fi
```

Omit colours not used in the script (ShellCheck SC2034 — unused variable). For example, `install.sh` has no `_warn` primitive and therefore omits `YLW`.

**Colour semantics:**

| Variable | Colour  | Use                                    |
|----------|---------|----------------------------------------|
| `RED`    | Red     | Failures, errors, fatal messages       |
| `GRN`    | Green   | Passes, success                        |
| `YLW`    | Yellow  | Warnings                               |
| `BLU`    | Blue    | Section headers (`_head`)              |
| `BOLD`   | Bold    | Section headers, summary result line   |
| `RST`    | Reset   | Terminates every coloured span         |

Every colour span must be closed with `${RST}`. Never leave a colour open at end-of-line.

---

## 4. Output primitives

Define these four functions early, before any output-producing code. They centralise formatting and keep the counter increments co-located with the print call.

```bash
# ── Primitives ───────────────────────────────────────────────────────────────
_ok()   { printf "  %s✔%s  %s\n" "${GRN}" "${RST}" "$*"; (( ++_pass )); }
_fail() { printf "  %s✘%s  %s\n" "${RED}" "${RST}" "$*"; (( ++_fail )); }
_warn() { printf "  %s⚠%s  %s\n" "${YLW}" "${RST}" "$*"; (( ++_warn )); }
_head() { printf "\n%s%s══ %s%s\n" "${BOLD}" "${BLU}" "$*" "${RST}"; }
```

And for optional/skipped sections:

```bash
_skip() { printf "  ⊘  %s\n" "$*"; }
```

And for fatal errors that must exit immediately:

```bash
_die()  { printf "\n%s%sERROR:%s %s\n" "${BOLD}" "${RED}" "${RST}" "$*" >&2; exit 1; }
```

Rules:

- `_ok`, `_fail`, `_warn` always increment their counter. Never call the `printf` directly — always go through the primitive.
- Two spaces of indent, then the glyph, then two more spaces, then the message. This indentation is load-bearing: it visually separates individual check results from section headers.
- `_head` emits a blank line before the banner. Do not add a blank `printf` before calling `_head` — it already provides the vertical separation.
- `_skip` is used when an optional component is absent. It does not increment any counter.
- `_die` writes to stderr and exits 1. It does not increment `_fail` — the script terminates immediately.

**Message format within primitives:**

Lead with a short noun phrase identifying the thing being checked, then a colon, then the specific detail. Use double-space to align related values:

```
binary:  msmtp  (/usr/bin/msmtp)
file:    /etc/msmtprc
dir:     /var/log/msmtp
timer:   pb-check-for-updates.timer  (next: Tue 2026-06-02 03:00:00)
```

On failure, state what was expected vs what was found in parentheses:

```
permissions: /etc/shadow  (expected 640/root, got 644/root)
ownership: /var/lib/email-dns-monitor  (expected emaildns, got root)
```

---

## 5. Counters and summary block

### Counters

Declare counters immediately after the colour palette:

```bash
# ── Counters ─────────────────────────────────────────────────────────────────
_pass=0; _fail=0; _warn=0
```

Omit `_warn` (and `YLW`) if the script has no `_warn` primitive.

### Timing

Start the clock before the first substantive operation, after argument parsing and guards:

```bash
_START=$(date +%s%N)
```

### Summary block

The summary block is always the last thing printed before the final `exit`. Its structure is fixed:

```bash
# ── Summary ──────────────────────────────────────────────────────────────────
_END=$(date +%s%N)
_ELAPSED=$(( (_END - _START) / 1000000 ))

printf '\n%s══ Summary%s\n' "${BOLD}" "${RST}"
printf '  %sPASS: %d%s   %sFAIL: %d%s   %sWARN: %d%s   (elapsed: %dms)\n\n' \
  "${GRN}" "$_pass" "${RST}" "${RED}" "$_fail" "${RST}" "${YLW}" "$_warn" "${RST}" "$_ELAPSED"

if (( _fail > 0 )); then
  printf '%s%sNOT OK — %d check(s) failed%s\n\n' "${RED}" "${BOLD}" "$_fail" "${RST}"
  _EXIT=1
elif (( _warn > 0 )); then
  printf '%s%sOK with %d warning(s)%s\n\n' "${YLW}" "${BOLD}" "$_warn" "${RST}"
  _EXIT=0
else
  printf '%s%sALL OK%s\n\n' "${GRN}" "${BOLD}" "${RST}"
  _EXIT=0
fi

exit "$_EXIT"
```

For scripts without warnings (e.g. installers), simplify accordingly and use a result-appropriate message (`ALL COMPONENTS INSTALLED`, `INSTALL FAILED — N step(s) failed`).

The `(elapsed: Nms)` field is always present. It is derived from nanosecond timestamps to avoid platform-specific `date` flag differences.

---

## 6. Section banners

Section banners use `_head`. They appear immediately before the first check in each logical group. For scripts with many sections, also add a full-width `# ===` comment block above the `_head` call for source navigation:

```bash
# =============================================================================
# ── SECTION 1: Email stack (msmtp) ──────────────────────────────────────────
# =============================================================================
_head "Email stack (msmtp)"
```

The `# ===` comment block spans the full 79-column width. The section title inside the comment uses the `── TITLE ──` em-dash style.

For helper-function groupings that are not user-visible sections, use a shorter comment divider:

```bash
# =============================================================================
# Helper functions
# =============================================================================
```

---

## 7. Runtime banner

Printed after argument parsing and guards, before the first section:

```bash
_START=$(date +%s%N)

printf '%s%s — <Script Title>%s\n' "${BOLD}" "$(hostname -s)" "${RST}"
printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
```

The hostname is `$(hostname -s)` (short name). The date format is `%Y-%m-%d %H:%M:%S %Z`. The title suffix (`— Infrastructure Sanity Check`, `— pb-server-tools Installer`) identifies the script without repeating its filename.

---

## 8. Argument parsing

### Simple scripts (flags only, no value-taking options)

Use a single `for` loop with a `case`:

```bash
# ── Argument parsing ─────────────────────────────────────────────────────────
_MY_FLAG=0

for _arg in "$@"; do
  case "$_arg" in
    --my-flag) _MY_FLAG=1 ;;
    --help|-h)
      sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$_arg" >&2
      exit 2
      ;;
  esac
done
```

### Scripts with value-taking options (`--option <value>`)

Use a `while` shift loop:

```bash
# ── Argument parsing ─────────────────────────────────────────────────────────
ONLY_COMPONENT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      [[ -n "${2:-}" ]] || _die "--only requires a component name"
      ONLY_COMPONENT="$2"
      shift 2
      ;;
    --help|-h)
      sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      _die "Unknown option: $1"
      ;;
  esac
done
```

### `--help` extraction

The `--help` handler extracts from the file header using `sed`. The two anchor patterns must match exactly what is in the header. Adjust the end anchor to the last line you want to show:

```bash
sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \?//'
```

The second `sed` strips the leading `# ` (or bare `#`) from each line. Do not add a `show_help()` function that duplicates the header — the header is the single source of truth.

---

## 9. Root guard

Place the root guard after argument parsing (so `--help` works without sudo) and before the runtime banner:

```bash
# ── Guards ───────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  printf "${RED}Error:${RST} must run as root — use: sudo bash %s\n" "$0" >&2
  exit 2
fi
```

Exit code 2 for privilege failure. Exit code 1 for runtime failures. Exit code 0 for success.

---

## 10. Variable conventions

| Pattern | Meaning | Example |
|---------|---------|---------|
| `_lowercase` leading underscore | Script-internal state (counters, flags, loop vars) | `_pass`, `_fail`, `_arg`, `_EXIT` |
| `UPPER_CASE` | Configuration constants, paths, exported values | `SCRIPT_DIR`, `EMAIL_ON_FAILURE` |
| `local` in all functions | All function-local variables | `local unit state` |

`SCRIPT_DIR` is always derived with the two-step declare/assign pattern to satisfy ShellCheck SC2155:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
```

`readonly` is applied after assignment, not combined with it.

Prefix loop variables and one-shot temporaries with a single underscore to signal they are not meaningful outside their immediate context:

```bash
for _arg in "$@"; do ...
for _pem in "${_pem_files[@]}"; do ...
```

---

## 11. Function signatures and inline docs

Every non-trivial function has a one-line comment immediately above it stating its signature and semantics. For functions with multiple arguments or non-obvious return conventions, expand to a multi-line block:

```bash
# check_binary <cmd>
check_binary() {
  local cmd=$1
  ...
}

# check_conf_keys <config_file> <key1> [key2 ...]
# Sources the config once and checks every key for non-empty value.
# Config values are NEVER printed.
check_conf_keys() {
  ...
}
```

Functions that are only used inside another function are declared inside it (using `local -f` is not portable; just define them locally with `_chk()` style names and `unset -f` after use).

---

## 12. Error handling

### `set -euo pipefail`

Always set. Under this mode:

- Every unchecked failing command aborts the script. Append `|| true` to commands that are allowed to fail.
- Unset variables cause an abort. Use `${var:-}` or `${var:-default}` for optional variables.
- Pipeline failures are not masked. The exit code of a pipe is the rightmost non-zero exit.

### Avoiding false ERR trap triggers

The pattern `[[ "$status" != "CRITICAL" ]] && status="WARN"` exits 1 (false) when `$status` IS `"CRITICAL"`. Under `set -E`, this triggers the ERR trap. Always append `|| true` to boolean short-circuit expressions used as statements:

```bash
# Wrong — triggers ERR trap when condition is false
[[ "$status" != "CRITICAL" ]] && status="WARN"

# Correct
[[ "$status" != "CRITICAL" ]] && status="WARN" || true
```

### Temp file cleanup

Always register a `trap` for temp files on `EXIT`:

```bash
_CAPTURE_FILE=$(mktemp /tmp/my-script-XXXXXX.txt)
trap 'rm -f "$_CAPTURE_FILE"' EXIT
```

---

## 13. stdout vs stderr

| Output type | Stream |
|-------------|--------|
| Normal check output (`_ok`, `_fail`, `_warn`, `_head`, `_skip`) | stdout |
| Summary block | stdout |
| Runtime banner, section headers | stdout |
| Error messages that precede `exit` (`_die`) | stderr |
| Diagnostic messages from background operations | stderr |
| Email delivery status messages | stderr |

The stdout/stderr split is deliberate: stdout can be captured (e.g. `--email-on-failure` tees stdout to a file), while stderr goes only to the journal.

---

## 14. Timing

Always use nanosecond timestamps for elapsed time to avoid platform-specific flags:

```bash
_START=$(date +%s%N)
# ... work ...
_END=$(date +%s%N)
_ELAPSED=$(( (_END - _START) / 1000000 ))   # convert ns → ms
```

Display as `(elapsed: ${_ELAPSED}ms)` in the summary line.

---

## 15. What the old scripts do differently

`check-for-updates.sh`, `pb-patch-reporter.sh`, and `security-hardening-check.sh` predate this style guide. They share the same functional architecture but diverge from it in several ways. Do not copy their patterns into new scripts:

| Pattern | Old scripts | New style |
|---------|-------------|-----------|
| Section output | `section()` function with cyan underline bar | `_head()` primitive with `══` prefix |
| Per-check output | Plain `log()` calls | `_ok()` / `_fail()` / `_warn()` with glyphs and counters |
| Counter tracking | None (no pass/fail/warn tallies) | `_pass`, `_fail`, `_warn` counters; printed in summary |
| Summary block | Log entry only; no structured terminal output | Structured `══ Summary` block with PASS/FAIL/WARN counts and elapsed time |
| Colour variables | `C_CYAN` / `C_RESET` | `RED` / `GRN` / `YLW` / `BLU` / `BOLD` / `RST` |
| `--help` | `show_help()` function with here-doc | `sed` extraction from the file header |
| Root check | `require_root()` function | Inline guard block |
| Indentation | 4-space | 2-space |
| `SCRIPT_DIR` | `readonly SCRIPT_DIR="$(…)"` (SC2155) | Two-step declare/assign |
| `@@N@@` placeholder | Used in `security-hardening-check.sh` as a newline surrogate for inter-process transport through `IFS='|'` splits | Not used outside that script; do not introduce in new scripts |

When making changes to the old scripts, you are not required to rewrite them to this style. Apply the new style to any new script or to an old script that is being substantially reworked.

---

## 16. Test runner output

Test harnesses (`test_*.sh`, pytest) are standalone scripts with their own output format. When an installer invokes a test harness, it must **not** let raw harness output stream through to the terminal. Raw output breaks the structured outline: `PASS T01_name` lines and `--- Results ---` banners have no glyphs, no colour, and no indent hierarchy.

### Contract

- Capture the harness's stdout+stderr into a variable.
- Parse each result line and re-emit it through `_ok` or `_fail`.
- Suppress progress noise (pytest percentage markers, blank lines, `--- Results ---` trailers).
- Preserve failure detail lines (indented `got =` / `want =` lines from the bash harnesses; `FAILED path::name - reason` lines from pytest) — print them with two-space indent, without going through a counter primitive.
- If the harness exits non-zero, call `_die` after the per-case output; do not call `_die` instead of parsing.

### Bash harness wrapper (`_run_bash_tests`)

Bash harnesses emit `  PASS name` / `  FAIL name` per case. Match with:

```bash
[[ "$line" =~ ^[[:space:]]+(PASS|FAIL)[[:space:]]+(.+)$ ]]
```

```bash
# _run_bash_tests <label> <test_script>
_run_bash_tests() {
  local label="$1" test_script="$2"
  printf '  running %s\n' "$label"
  local raw exit_code=0
  raw="$(sudo -u "$test_user" bash "$test_script" 2>&1)" || exit_code=$?
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]+(PASS|FAIL)[[:space:]]+(.+)$ ]]; then
      local result="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]}"
      if [[ "$result" == "PASS" ]]; then _ok "$name"; else _fail "$name"; fi
    elif [[ "$line" =~ ^[[:space:]]{6,} ]]; then
      printf '  %s\n' "${line#"${line%%[![:space:]]*}"}"
    fi
  done <<<"$raw"
  (( exit_code != 0 )) && _die "${label} failed — aborting deployment"
}
```

### Pytest wrapper (`_run_pytest`)

Pytest `-v` emits `path::Class::test_name PASSED [ N%]` per case. Match with:

```bash
[[ "$line" =~ ::([^[:space:]]+)[[:space:]]+(PASSED|FAILED) ]]
```

```bash
# _run_pytest <label> <test_file>
_run_pytest() {
  local label="$1" test_file="$2"
  printf '  running %s\n' "$label"
  local raw exit_code=0
  raw="$(sudo -u "$test_user" python3 -m pytest "$test_file" -v 2>&1)" || exit_code=$?
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ ::([^[:space:]]+)[[:space:]]+(PASSED|FAILED) ]]; then
      local name="${BASH_REMATCH[1]}" result="${BASH_REMATCH[2]}"
      if [[ "$result" == "PASSED" ]]; then _ok "$name"; else _fail "$name"; fi
    fi
  done <<<"$raw"
  if (( exit_code != 0 )); then
    while IFS= read -r line; do
      [[ "$line" =~ ^FAILED[[:space:]] ]] && printf '       %s\n' "$line"
    done <<<"$raw"
    _die "${label} failed — aborting deployment"
  fi
}
```

### Placement

Declare `_run_bash_tests` / `_run_pytest` as local functions **inside** the `run_tests()` function that calls them. They are not called anywhere else and do not belong at script scope.

### Test harness format requirement

New bash test harnesses must emit per-case lines in exactly this format so the wrapper regex matches:

```
  PASS  T01 description of test
  FAIL  T01 description of test
```

Two spaces before the keyword, two spaces after. The `test_login_compliance.sh` and `test_security_hardening.sh` harnesses already use this format (`pass()`/`fail()` functions). The `test_pb_patch_reporter.sh` harness uses single-space after the keyword (`_pass`/`_fail` functions) — both are matched by the `[[:space:]]+` quantifier in the regex.
