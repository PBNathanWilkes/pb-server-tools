# CHANGELOG — check-for-updates

All notable changes follow [Semantic Versioning](https://semver.org/).

---

## [4.2.18] — 2026-05-30

### Fixed

- `overrides/pblinuxutility/pb-check-for-updates*.service.d/no-namespace.conf`:
  added `ProtectHome=` reset. `ProtectHome=true` requires a mount namespace
  (`CLONE_NEWNS`) and was confirmed to also cause exit 226 on pblinuxutility
  after the v4.2.17 drop-ins were deployed. The four directives now reset are:
  `ProtectSystem=`, `ProtectHome=`, `ProtectKernelModules=`,
  `ProtectKernelTunables=`.

### Files changed

- `overrides/pblinuxutility/pb-check-for-updates.service.d/no-namespace.conf`
- `overrides/pblinuxutility/pb-check-for-updates-monthly.service.d/no-namespace.conf`
- `overrides/pblinuxutility/README.md`
- `DEV-GUIDE.md` (KFC-R02 updated)
- `CHANGELOG.md` (this file)

---



### Fixed

- `install.sh`: on hosts listed in `NAMESPACE_OVERRIDE_HOSTS` (currently:
  `pblinuxutility`), the installer now deploys a host-specific systemd drop-in
  override that resets `ProtectSystem=`, `ProtectKernelModules=`, and
  `ProtectKernelTunables=`.  These directives require `CLONE_NEWNS` (mount
  namespace support) and cause **exit 226 (EXIT_NAMESPACE)** on container/VM
  hosts whose kernel or container runtime does not permit unprivileged mount
  namespaces.  The source unit files are unchanged; full sandboxing is preserved
  on PBWEBSRV03 and any other capable host.

  Drop-in sources: `overrides/pblinuxutility/pb-check-for-updates.service.d/`
  and `overrides/pblinuxutility/pb-check-for-updates-monthly.service.d/`.

  See `overrides/pblinuxutility/README.md` and DEV-GUIDE.md §6 KFC-R02.

### Files changed

- `install.sh`
- `overrides/pblinuxutility/pb-check-for-updates.service.d/no-namespace.conf` (new)
- `overrides/pblinuxutility/pb-check-for-updates-monthly.service.d/no-namespace.conf` (new)
- `overrides/pblinuxutility/README.md` (new, shared across components)
- `CHANGELOG.md` (this file)

---

## [4.2.16] — 2026-05-29

### Fixed

- `pb-apt-evaluator.py`: `_check_lts()` never detected an available Ubuntu LTS
  upgrade on Ubuntu 24.04+ hosts. Two compounding causes:
  1. The function tried `/usr/lib/ubuntu-release-upgrader/check-new-release` and
     `check-new-release-gtk` first; these scripts do not exist on Ubuntu 24.04+
     (removed when ubuntu-release-upgrader was refactored). Execution always fell
     through to the `do-release-upgrade` fallback.
  2. The fallback invoked `do-release-upgrade -c -f DistUpgradeViewNonInteractive`.
     On Ubuntu 24.04+, `-f DistUpgradeViewNonInteractive` suppresses all
     stdout/stderr output (the command exits 1 silently). Both regex patterns
     matched against an empty string and both returned `None`, so
     `lts_upgrade_available` was always `false` in the state file.

  Fixed by replacing the entire function with a single `do-release-upgrade -c`
  call (no `-f` flag). Added `LANG=C LC_ALL=C` to prevent localised output from
  breaking the `New release '(\d+\.\d+)'` regex. Removed the defunct
  `check-new-release` lookup entirely.

- `check-for-updates.sh`: `VERSION` constant was `4.2.0` (never updated from
  the initial v4.2 shim release). Bumped to `4.2.16` to match the evaluator.

### Tests

- `tests/unit/test_pb_apt_evaluator.py`: added `TestCheckLts` (11 tests).
  Covers: stdout detection, stderr detection, no-LTS-available, exception
  safety, timeout safety, `-f` flag absent (regression guard), `-c` flag
  present, `check-new-release` not called (regression guard), C locale set,
  single subprocess call, version extraction, unquoted version format.

---



### Fixed

- `install.sh`: `SYSTEMD_DEST` was set to `/lib/systemd/system/` (package-managed
  unit path) but the units were already present in `/etc/systemd/system/` (admin-managed
  unit path) from a prior manual install. systemd gives `/etc/systemd/system/` strict
  precedence, so every subsequent `install.sh` run deployed updated unit files to
  `/lib/systemd/system/` while the stale `/etc/systemd/system/` copies continued to
  be used. The symptom: `NoNewPrivileges=true` (removed in v4.2.13) persisted on disk
  after the v4.2.13 and v4.2.14 installs, blocking `apt-get update` from dropping
  privileges to `_apt` and causing `apt_update_failed=true` on every run. Fixed by
  changing `SYSTEMD_DEST` to `/etc/systemd/system/`.

- `install.sh`: Added `verify_units()` (Step 5) which diffs each deployed unit file
  against its source immediately after `deploy_files()`. Aborts with a non-zero exit
  and a diff if any unit on disk differs from source, ensuring the operator knows
  before `daemon-reload` if deployment to the wrong path occurred. Addresses
  DEFECT-install-does-not-deploy-service-files.md.

---

## [4.2.14] — 2026-05-15

### Fixed

- `pb-apt-evaluator.py`: `_wait_for_apt_lock()` acquired each APT lock and
  immediately released it before calling `apt-get update`. This is a TOCTOU
  race: `apt-daily.service` can re-acquire `/var/lib/apt/lists/lock` in the
  window between our release and `apt-get update`'s own acquisition, causing
  `apt-get update` to exit non-zero and setting `apt_update_failed=true` in
  the state file. Adding the second lock path in v4.2.11 widened the check
  but left the check-release-use pattern intact; this is the correct fix.

  Replaced `_wait_for_apt_lock()` with `_acquire_apt_locks()` /
  `_release_apt_locks()`. `_acquire_apt_locks()` opens and flocks each path
  in `APT_LOCK_PATHS` and returns the live file handles without releasing
  them. These handles are passed to `_run_apt_update()` via `pass_fds=`; the
  kernel keeps the flocks live for the lifetime of the `apt-get update` child
  process. `apt-daily` is blocked for the duration. Locks are released in a
  `finally` block immediately after `apt-get update` exits. No deadlock:
  `apt-get update` acquires the locks on the same open file descriptions
  (same-process flock upgrade, not a competing acquisition).

  This is the root cause of the recurring **APT LIST REFRESH FAILED** banner.
  Manual runs (`sudo check-for-updates.sh --check`) were never affected because
  `apt-daily` does not compete with interactive invocations.

---

## [4.2.13] — 2026-05-14

### Fixed

- `systemd/pb-check-for-updates.service`,
  `systemd/pb-check-for-updates-monthly.service`: `NoNewPrivileges=true` prevented
  `apt-get update` from calling `seteuid(105)` to drop privileges to the `_apt` user
  before making network connections. The kernel's `PR_SET_NO_NEW_PRIVS` flag blocks all
  `setuid`/`seteuid` calls in the process tree — including privilege drops, not only
  escalations — causing `apt-get update` to exit 100 on every scheduled run. Evaluator
  wrote `apt_update_failed: true`; reporter emailed APT LIST REFRESH FAILED every morning;
  login check reported `Patches=CRITICAL`. Removed `NoNewPrivileges=true` from both units.
  Addresses DEFECT-service-unit-sandbox-regression.md.
- `systemd/pb-check-for-updates.service`,
  `systemd/pb-check-for-updates-monthly.service`: `PrivateTmp=true` reintroduced into
  both units after its documented removal in v3.10.16. Removed again. See v3.10.16 entry
  for original rationale.

---

## [4.2.12] — 2026-05-13

### Fixed

- `install.sh`: `check_prereqs()` invoked `python3 -c "import apt_pkg"` and
  `python3 -c "import pytest"` as root, causing Python to bytecode-compile
  both modules and write root-owned `__pycache__` directories into `src/` and
  `tests/unit/` inside the source tree.  The non-root operator could not
  subsequently remove these without `sudo`.  Fixed by adding the `-B` flag
  (`python3 -B -c "..."`) to suppress bytecode output during the import
  checks; `-B` does not affect the correctness of the check.
- `install.sh`: `__pycache__` and `.pytest_cache` directories left in the
  source tree after previous installs were not cleaned up.  Added
  `cleanup_pycache()` (Step 3, between `run_tests` and `deploy_files`) which
  uses `find … -type d \( -name __pycache__ -o -name .pytest_cache \)` and
  `rm -rf` to remove all bytecode artefact directories under `SCRIPT_DIR`.
  Runs unconditionally so the tree is clean after every install regardless of
  who created the directories.  The `-B` fix prevents new root-owned dirs;
  the cleanup step handles any pre-existing ones.

---

## [4.2.11] — 2026-05-13

### Fixed

- `pb-apt-evaluator.py`: `_wait_for_apt_lock()` checked only
  `/var/lib/dpkg/lock-frontend` before invoking `apt-get update`.
  `apt-get update` acquires a second lock, `/var/lib/apt/lists/lock`, which
  is held by Ubuntu's `apt-daily.service` during its background refresh pass.
  `apt-daily.timer` fires with `OnCalendar=*-*-* 6,18:00` and
  `RandomizedDelaySec=12h`, placing it in a 12-hour window that can overlap
  any scheduled or manual run.  When apt-daily held `lists/lock`, our TOCTOU
  check against `dpkg/lock-frontend` passed, `apt-get update` then raced for
  `lists/lock`, lost, and exited non-zero.  The evaluator wrote
  `apt_update_failed=true` to the state file; the login-compliance check read
  that state on the next SSH login and reported `Patches=CRITICAL`; the
  reporter emitted the **APT LIST REFRESH FAILED** banner in the next email.
  Fixed by extending `_wait_for_apt_lock()` to probe all paths in the new
  `APT_LOCK_PATHS` tuple (`dpkg/lock-frontend`, `lists/lock`) against a
  single shared deadline (`APT_LOCK_TIMEOUT_S = 300s`).  The deadline is
  shared so total wait remains capped at 5 minutes regardless of how many
  locks are checked.  Addresses DEFECT-persistent-timer-network-race.md
  (root cause: wrong lock; network/reboot hypotheses ruled out).
- `tests/unit/test_pb_apt_evaluator.py`: added `TestAptLockWait` (6 tests)
  covering: `APT_LOCK_PATHS` contains both locks; both free returns
  immediately without sleeping; `dpkg/lock-frontend` held causes retry;
  `lists/lock` held causes retry (the specific apt-daily failure mode);
  shared deadline raises `TimeoutError` on `lists/lock` timeout; regression
  guard asserting `lists/lock` remains in `APT_LOCK_PATHS`.

---

## [4.2.10] — 2026-05-12

### Fixed

- `login-compliance-check.sh`: login latency was ~220ms warm on production
  due to two hotspots in `_check_recent_sent()`:
  1. `_msmtp_line_is_success()` spawned 6–8 `grep` subprocesses per log line.
     Replaced with pure bash `[[ =~ ]]` pattern matching after a single
     `${line,,}` lowercase expansion. No subprocesses.
  2. `date -d "$ts" +%s` was called inside the log-scanning loop, spawning
     one subprocess per line across up to 6000 lines. Replaced with a single
     `date -d "$days days ago" +'%Y-%m-%d'` call before the loop; per-line
     comparison uses lexicographic string ordering on `YYYY-MM-DD` (which is
     equivalent to chronological ordering). No per-line subprocesses.
  Addresses DEFECT-login-check-latency.md.

---

## [4.2.9] — 2026-05-12

### Fixed

- `DEV-GUIDE.md` §1, §7: paths used `check-for-updates` namespace throughout
  but all deployed files use `pb-maintenance`. Corrected to match the actual
  production layout. Added rationale: `pb-maintenance` is used because all
  writers run as root via systemd; `login-compliance-check.sh` lives in
  `/usr/local/bin` because it runs as the operator user at login time.
  Updated lock file permission notes to reflect the `exec 9<` (read-open)
  fix from v4.2.8. Closes DEFECT-inconsistent-libexec-state-paths.md.
- `/usr/local/bin/login-compliance-check-msmtp.sh` (production host): file
  had no counterpart in the source tree and no references in any source,
  systemd unit, or install script. Removed. Closes
  DEFECT-untracked-login-compliance-msmtp.md.

---

## [4.2.8] — 2026-05-12

### Fixed

- `login-compliance-check.sh`: suppression lock file (fd 9) was opened for
  writing (`exec 9>"${SUPP_LOCK}"`). Bash requires write permission to open
  a descriptor for writing even when the flock is shared (`-s`). The lock
  file is `0644 root:root` (written by the evaluator running as root), so
  non-root login sessions received `Permission denied` on every login.
  Changed to read-open (`exec 9<"${SUPP_LOCK}"`); a shared flock only
  requires read permission. The login check never writes the suppression
  file, so read-open is correct. Addresses
  DEFECT-login-check-suppression-lock-permission.md.
- `tests/unit/test_login_compliance.sh`: `setup_env` did not create lock
  files in the temp state directory. After the v4.2.8 fix changed fd 9 to
  read-open (`exec 9<"${SUPP_LOCK}"`), the open failed on the non-existent
  lock file; `flock` was then called on an invalid fd and returned non-zero;
  the suppression file was never read; confirmed-suppressed packages fell
  through to `unsuppressed_count` → CRITICAL instead of WARN. T09 failed.
  Fixed by adding `touch` for both lock files in `setup_env`.
- `pb-patch-reporter.sh`: `upsert_suppression()` used `select(not (expr))` in
  a jq filter. In jq 1.7 (Ubuntu 24.04 Noble), `not` is a postfix operator
  only — `not (expr)` is a compile error (jq exit 3). The `2>/dev/null` on
  the jq call silently swallowed the error; the ERR trap then aborted the
  reporter before `write_suppression_file_atomic` or `send_email` were
  reached. All 11 remaining reporter test failures were a cascade of this
  single defect. Fixed to `select((expr) | not)`.
- `tests/unit/test_pb_patch_reporter.sh`: `mailx` mock heredoc used `<<EOF`
  (unquoted) so `${MAIL_CAPTURE}` expands correctly at write-time, but
  `$#`, `$1`, `$2`, `$subject`, and `$*` were also expanded at write-time
  (to the test script's empty/unset positional parameters). The mock was
  written with `$#` already expanded to `0`, so its argument-parsing loop
  never ran and the capture file was never created. All 20 mail-dependent
  test assertions failed as a cascade. Escaped positional parameters as
  `\$#`, `\$1`, `\$2`, `\$subject`, `\$*`; left `${MAIL_CAPTURE}` unescaped.

### Added

- `install.sh`: source-tree install script. Run `sudo bash install.sh` from
  `/opt/check-for-updates`. Checks prerequisites (jq, python3-apt,
  python3-pytest), runs all three unit test suites (aborting on any failure),
  deploys files to production locations with correct permissions, ensures
  lock files exist at `0644`, and reloads + re-enables systemd timers.

---

## [4.2.7] — 2026-05-11

### Fixed

- `pb-patch-reporter.sh`: `cleanup()` was called explicitly at the end of
  `main()` and again by the `trap cleanup EXIT` handler. The second call
  found `EMAIL_HTML_FILE` already deleted; `[[ -f "$EMAIL_HTML_FILE" ]]`
  exited 1, triggering the ERR trap with `BASH_COMMAND=return 0` and
  `rc=1`. Removed the redundant explicit `cleanup` call — the EXIT trap
  is sufficient.

---

## [4.2.6] — 2026-05-11

### Fixed

- `pb-patch-reporter.sh`: recipient defaults were set to `root` and
  `FROM_EMAIL` to `check-for-updates <donotreply@localhost>` when org
  references were removed in v4.2.3. This broke email delivery — v3.x had
  the real addresses hardcoded directly. Restored the real addresses as
  `${VAR:-default}` defaults, matching v3.x behaviour exactly. Env var
  override still works (for tests and future configuration).

---

## [4.2.5] — 2026-05-11

### Fixed

- `tests/unit/test_pb_patch_reporter.sh`: mailx mock used `<<'EOF'` (single-quoted
  heredoc), so `${MAIL_CAPTURE}` was written literally into the mock script rather
  than expanded to the temp file path. The mock wrote to a file named
  `${MAIL_CAPTURE}` in the current directory; the test looked for the capture file
  at the correct path and never found it. All 20 "missing mail_capture.txt" failures
  were caused by this. Changed to `<<EOF` (unquoted).
- `pb-patch-reporter.sh`: `on_err` ERR trap fired spuriously on `return 0` inside
  subshells under `set -E`, printing a false `ERROR line 1 (exit 1): return 0`
  after every successful reporter run. Added `[[ $rc -eq 0 ]] && return` guard.

---

## [4.2.4] — 2026-05-11

### Fixed

- `pb-patch-reporter.sh`: `html_activity_summary()` used `(( var++ ))` for five
  counters. Under `set -Eeuo pipefail`, `(( 0 ))` exits 1 and is fatal. Reporter
  crashed at first log file scan on a clean system with zero prior runs. Changed
  all five to `(( var += 1 ))` which always exits 0.
- `login-compliance-check.sh`: state-file lock acquired with `exec 8>"${STATE_LOCK}"`
  (write-open). `/var/lib/pb-maintenance` is root-owned; non-root login sessions
  received `Permission denied` and a spurious `WARN` at every login. The state
  file is written atomically (tmp+rename) by the evaluator, so a read lock is
  not needed — removed entirely. Suppression lock (fd 9) already used `|| true`
  and degrades gracefully; left in place.

---

## [4.2.3] — 2026-05-11

### Fixed

- `pb-patch-reporter.sh`: path and recipient constants (`STATE_DIR`, `STATE_FILE`,
  `STATE_LOCK`, `SUPP_FILE`, `SUPP_LOCK`, `LOG_DIR`, `APT_STAMP`, `FROM_EMAIL`,
  `RECIPIENTS_*`) were declared `readonly` at script load time, silently ignoring
  env var overrides. Test harness passed overrides via env but the script always
  used `/var/lib/pb-maintenance`, causing early exit ("state file absent") before
  any email was sent or `PATCH_MONITOR_RESULT` was logged. Changed to
  `${VAR:-default}` pattern before `readonly`. 26 of 32 reporter test assertions
  were failing as a cascade of this one defect.
- `login-compliance-check.sh`: same `readonly` issue for state path constants.
  Also: `_status_icon()` always emitted ANSI escape codes and Unicode symbols
  (`✔`, `⚠`, `✘`), even when stdout was not a TTY. Test harness captures
  stdout in a subshell (non-TTY), so `grep` for bare `OK`/`WARN`/`CRITICAL`
  never matched. Added `-t 1` guard; plain text emitted when not a TTY. 11 of
  12 login test assertions were failing as a cascade of these two defects.
- `tests/unit/test_login_compliance.sh`: `run_full_check()` redirected state
  paths via `sed` on a script copy; updated to pass env vars directly (matching
  the now-supported `${VAR:-default}` pattern). `sed` patch retained for
  `msmtprc` path (array literal, not a single constant).

---



### Fixed

- `test_pb_patch_reporter.sh`, `test_login_compliance.sh`: `set -euo pipefail`
  at the top level caused the test runner to abort on the first non-zero exit
  from any subshell (e.g. a tested script returning non-zero, or `jq` not yet
  mocked). Changed to `set -uo pipefail`; individual tests already use `|| true`
  guards. All 19 reporter tests and 12 login tests now run to completion.

### Changed

- `DEV-GUIDE.md` §2: clarified that tests run on the development machine only,
  not on the production host. Added `sudo apt install` prerequisite line.
  Added `--dry-run` stdout-clean JSON pre-merge check (from
  DEFECT-evaluator-logging-stdout.md prevention section).

---



### Fixed

- `pb-apt-evaluator.py`: logging `StreamHandler` was attached to `sys.stdout`
  instead of `sys.stderr`. All log lines were written to stdout ahead of the
  `--dry-run` JSON output, producing `jq: parse error: Invalid numeric literal`
  and a cascade of `BrokenPipeError` tracebacks. Logging now routes to stderr;
  `--dry-run` JSON output on stdout is clean.

---



### Breaking changes (internal architecture only; external interface preserved)

- `dist-upgrade -s` is no longer called anywhere in the pipeline. The
  `[apt-get dist-upgrade -s snapshot captured]` log line is gone.
- State is now split across two JSON files (`patch-state.json`,
  `patch-suppression.json`). No single-file `patch-state.json` from v4.1
  exists; this is a first v4.x production deployment.
- Login banner patch check no longer runs `apt-get dist-upgrade -s`.
  Reads `patch-state.json` via `jq`. Requires `jq`.
- XDG cache TTL mechanism removed from `login-compliance-check.sh`.
  `evaluated_at` in `patch-state.json` is the freshness signal.
- Schema version bumped to 2.

### Added

- `pb-apt-evaluator.py` — new Python 3 component. Opens
  `apt_pkg.Cache + apt_pkg.DepCache` in-process. Detects phased packages
  via `DepCache.phasing_applied()` (native API; no subprocess; no text
  scraping). Writes `patch-state.json` atomically. Merges `first_seen` /
  `seen_count` from prior state.
- `pb-patch-reporter.sh` — new Bash component. Reads `patch-state.json`
  (read-only, shared flock). Reads/writes `patch-suppression.json`
  (exclusive flock). Applies cross-run confirmation gate (`seen_count >= 2`).
  Suppression keyed on `(name, architecture, candidate_version)`.
  Suppression TTL 4 days. HTML email with abnormal-state banners.
- `check-for-updates.sh` rewritten as shim. Identical external interface to
  v3.x. Systemd `ExecStart` lines unchanged.
- `login-compliance-check.sh` rewritten to read JSON state files via `jq`.
  Shared flock on state-file lock. `apt_update_failed: true` → CRITICAL
  (was WARN in v4.1 design). All degradation paths surface as WARN or
  CRITICAL; never silently OK when state is unknown.
- `DEV-GUIDE.md` with KFC catalog, pre-merge test gate, API survey
  requirement, and deployment checklist.
- `tests/unit/test_pb_apt_evaluator.py` — 30+ unit tests for evaluator.
  Covers full phasing state matrix, security origin detection, prior-state
  merge, atomic write, fallback path (F8 anchored matching), and no-sleep guard.
- `tests/unit/test_pb_patch_reporter.sh` — 19 tests for reporter.
  Covers confirmation gate, suppression lifecycle, escalation, PATCH_MONITOR_RESULT
  marker, F6 ownership invariant, atomic write.
- `tests/unit/test_login_compliance.sh` — 12 tests for login-check.
  Covers all banner states, staleness, apt_update_failed CRITICAL,
  latency guard.
- `tests/fixtures/phasing/` — four phasing-state fixtures (0%, 50%,
  100%-tag-absent [the v3.x regression state], non-phased). Pre-merge test
  gate runs all four. Addresses DEFECT-patch-quality-discipline.md §4.1–4.3.
- Suppression invalidation on candidate-version change (F3): CVE-driven
  version bumps always re-alert even if the prior version was suppressed.
- Multi-arch suppression keys (F10): `libfoo:amd64` and `libfoo:i386`
  are suppressed independently.
- Security archive suffix matching (F14): `*-security` suffix match;
  handles future Ubuntu release names without code changes.
- `apt_update_failed: true` triggers email even when `packages: []` (F4).
- Stale evaluator banner in email (>26h since last evaluation).
- `--dry-run` flag on evaluator (F13): outputs JSON to stdout without
  writing state file or apt stamp.

### Changed

- Phasing detection: `DepCache.phasing_applied()` (native) replaces
  `awk | grep` text filter on `dist-upgrade -s` output.
- Confirmation strategy: cross-run `seen_count >= 2` replaces in-run
  60s sleep (F2).
- State split into evaluator-owned `patch-state.json` and reporter-owned
  `patch-suppression.json` (F6).
- Suppression TTL: 4 days (was 3 days in v4.1 design, F15).
- `apt_update_failed: true` → CRITICAL at login (was WARN in v4.1, F4).
- `PrivateTmp=true` retained pending validation (F9): the v3.10.16 root
  cause (`dist-upgrade -s` + fresh tmpfs) does not apply to v4.2. Only
  remove if integration tests fail and failure traces to `/tmp` isolation.

### Defects addressed

- **DEFECT-false-positive-patch-email.md** — primary: text-scraping
  architecture replaced with native `apt_pkg.DepCache.phasing_applied()`.
- **DEFECT-patch-quality-discipline.md** — phasing fixture matrix and
  KFC catalog added (KFC #1–#4 retroactively documented).
- **DEFECT-design-review-completeness.md** — API survey requirement
  codified in DEV-GUIDE.md §4.

### KFC entries this release addresses

- KFC #1 (v3.10.0 case-sensitive filter) — covered by fixture + DepCache API
- KFC #2 (v3.10.15 100%-rollout tag-absent state) — `state-100pct-tag-absent.txt` fixture; critical regression guard
- KFC #3 (v3.10.16 PrivateTmp/tmpfs interaction) — eliminated by dropping `dist-upgrade -s`
- KFC #4 (v3.10.17 dual invocation race) — eliminated by single-pass DepCache scan

---

## [3.10.17] — prior series (reference only)

Bugfix: Eliminate dual invocation of `apt-get dist-upgrade -s`.
`get_actual_upgrades()` was called independently inside both `get_upgradable()`
and `get_security_updates()`. APT re-evaluates phasing on each invocation;
a package at a phase boundary could appear installable in one call and deferred
in the other, producing a spurious alert (KFC #4).

---

## [3.10.16] — prior series (reference only)

Fix: Remove `PrivateTmp=true` from service units.
A fresh tmpfs over `/tmp` per invocation caused APT to recompute phase bucket
during `dist-upgrade -s`, emitting a plain `Inst` line for a held package (KFC #3).

---

## [3.10.15] — prior series (reference only)

Bugfix: Exclude phased packages from `get_actual_upgrades`.
Added case-insensitive filter for `[phased N%]` text in `dist-upgrade -s`
output. Did not handle the 100%-rollout case where the tag is absent (KFC #2).

---

## [3.10.14] — prior series (reference only)

Fix: Correct permissions on `pb-last-update` stamp file.

---

## [3.10.13] — prior series (reference only)

Write `/var/lib/apt/lists/pb-last-update` stamp after `apt-get update`.

---

## [3.10.12] — prior series (reference only)

Add explicit `PATCH_MONITOR_RESULT` marker; base 30-day summary on it.

---

## [3.10.11] — prior series (reference only)

Fix: Show last 30 days run/email summary for `--validate`/`--monthly`.

---

## [3.10.3] — prior series (reference only)

Systemd: remove crontab schedule reporting.

---

## [3.10.2] — prior series (reference only)

Email layout: put update command and package lists first.

---

## [3.10.1] — prior series (reference only)

ShellCheck clean pass.

---

## [3.10.0] — prior series (reference only)

Feature: Filter out phased updates (case-sensitive; see KFC #1).

---

## [3.9.x] — prior series (reference only)

Various bugfixes: LTS detection, security status.

---

## [3.8.x] — prior series (reference only)

Display crontab/systemd schedule.

---

## [3.7.x] — prior series (reference only)

LTS upgrade detection; `--validate`/`--monthly` modes.

---

## [3.6.0] — prior series (reference only)

Filter held packages.

---

## [3.5.0] — prior series (reference only)

Switch to `dist-upgrade` for kernel changes.

---

## [3.0.0] — prior series (reference only)

Security updates separation, reboot detection, unattended-upgrades integration.

## [Unreleased — next patch]

### Removed

- `src/login-compliance-check.sh` — canonical copy moved to
  `login-compliance/src/`. Deployed by `login-compliance/install.sh`.
- `tests/unit/test_login_compliance.sh` — canonical copy moved to
  `login-compliance/tests/unit/`. Owned by the `login-compliance` component.
- `tests/unit/debug_t04.sh` — development scratch file, not part of the
  test suite.

### Changed

- `install.sh`: removed login-compliance deploy step, test invocation,
  `BIN_DIR` constant, and header comment referencing `/usr/local/bin/`.
