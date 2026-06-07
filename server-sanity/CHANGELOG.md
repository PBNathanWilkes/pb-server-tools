# CHANGELOG — server-sanity

All notable changes follow [Semantic Versioning](https://semver.org/).

---

## [1.7.2] — 2026-06-07

### Changed

- **Section 8 — Server Sanity Check (self): removed previous-run journal
  check (`SANITY_CHECK_RESULT` parse block).**  The check read the prior
  scheduled run's journal line and failed if it contained `fail>0`.  This
  created a self-referential one-day lag: a genuine failure on day N caused
  a spurious failure on day N+1 (echoing the prior result), which in turn
  caused another spurious failure on day N+2 (because day N+1 also had
  `fail=1`).  The only exit was a manual trigger or waiting for a
  coincidentally clean prior run.  The check added no actionable signal —
  any real failure is detected directly by the current run.  The self section
  now covers: binary present, permissions correct, timer active, last service
  exit code.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md` (this file)

---

## [1.7.1] — 2026-06-06

### Fixed

- **Section 2 — EDM backup archive check: `sudo -u emaildns find` fails under
  systemd:** the sanity check service runs as root with `StandardInput=null`
  (no controlling terminal).  `/etc/sudoers` sets `Defaults use_pty`, which
  requires sudo to allocate a PTY — impossible in a tty-less systemd context.
  The `sudo` call exited non-zero, stderr was suppressed by `2>/dev/null`,
  `wc -l` received empty input, and the archive count was coerced to 0,
  producing a spurious `_fail "backup archives: none found"` on every
  scheduled run.  Interactive runs succeeded because the operator's terminal
  provided the required PTY.
  Fixed by changing `/var/backups/email-dns-monitor` from `0700` to `0750`
  on the production host and removing `sudo -u emaildns` from both `find`
  calls in the archive count and mtime pipelines.  Root can now stat the
  directory directly.  Closes `OPEN-ITEM-edm-install-backup-find-root.md`.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md` (this file)

---

## [1.7.0] — 2026-06-03

### Added

- **Per-host required packages and services (Sections 7 and 9):** replaces the
  hard-coded `pandoc`/`wkhtmltopdf`/`glow` checks with a conf-driven mechanism.
  Three new arrays in `/etc/server-tools/server-sanity.conf` (sourced at
  runtime from `overrides/<hostname>/server-sanity.conf` in the repo):
  - `REQUIRED_APT_PACKAGES`: apt packages that must be installed on this host.
  - `REQUIRED_SNAP_PACKAGES`: snap packages that must be installed on this host.
  - `REQUIRED_SERVICES`: systemd units that must be active on this host;
    format `"unit_name|display_label"`.
  All three arrays default to empty before the conf is sourced, so a host with
  an old conf (no new keys) skips the checks silently rather than erroring.
- **`check_apt_package <pkg>`:** extracted from the former inline Section 7
  loop; checks dpkg status and reports version on success.
- **`check_snap_package <pkg>`:** extracted from the former inline Section 7
  block; checks `snap list` and reports version on success.
- **`check_required_service <unit> <label>`:** new helper that checks
  `systemctl is-active` and `systemctl is-failed` independently.  Distinguishes
  three states: active (ok), failed (fail with reset-failed note), and any
  other inactive state (fail with enable note).
- **Section 9 — Required services:** new section that iterates `REQUIRED_SERVICES`
  and calls `check_required_service` for each entry.  Prints `⊘ no required
  services configured for this host` and increments no counters when the array
  is empty.
- **`overrides/pblinuxutility/server-sanity.conf`:** added
  `REQUIRED_APT_PACKAGES=(pandoc wkhtmltopdf)`, `REQUIRED_SNAP_PACKAGES=(glow)`,
  `REQUIRED_SERVICES=()`.
- **`overrides/PBWEBSRV03/server-sanity.conf`:** added
  `REQUIRED_APT_PACKAGES=()`, `REQUIRED_SNAP_PACKAGES=()`,
  `REQUIRED_SERVICES=("cloudflared.service|Cloudflare tunnel")`.

### Changed

- **Section 7 — System tools:** hard-coded `pandoc`, `wkhtmltopdf`, and `glow`
  checks removed; replaced by conf-driven loops over `REQUIRED_APT_PACKAGES`
  and `REQUIRED_SNAP_PACKAGES`.  Behaviour on pblinuxutility is unchanged;
  PBWEBSRV03 no longer emits failures for packages not installed there.
- **File header:** updated `Applications checked` list to include Section 7
  (system tools, conf-driven) and Section 9 (required services, conf-driven).

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md` (this file)
- `overrides/pblinuxutility/server-sanity.conf`
- `overrides/PBWEBSRV03/server-sanity.conf`
- `docs/CHANGELOG.md` (repo)

---

## [1.6.4] — 2026-06-03

### Fixed

- **Section 2 — backup archive recency: `|| echo 0` pipefail interaction:**
  under `set -Eeuo pipefail`, when `find` exits non-zero (e.g. a transient
  permission warning on a subdirectory), pipefail causes the `find | wc -l`
  pipeline to exit non-zero.  The original `|| echo 0` then fires, appending
  `0` to the already-captured count — producing a value like `82\n0` that
  causes `(( _edm_archive_count == 0 ))` to abort with a syntax error.  The
  same race applies to the mtime pipeline.
  Fixed by replacing `|| echo 0` with `|| true` on both pipelines, then
  stripping whitespace (`${var//[[:space:]]/}`) and coercing non-numeric
  values to `0` via a regex guard before any arithmetic.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md` (this file)

---

## [1.6.3] — 2026-06-03

### Added

- **Section 2 — Email DNS Monitor: directory ownership checks:** three
  `check_dir_owner` calls added for directories that were previously checked
  for existence only:
  - `$EDM_LOG` (`/var/log/email-dns-monitor`) — `emaildns` owner expected.
  - `$EDM_BACKUP` (`/var/backups/email-dns-monitor`) — `emaildns` owner expected.
  - `$EDM_BACKUP/history` — `emaildns` owner expected.
- **Section 2 — Email DNS Monitor: backup archive recency check:** after the
  `$EDM_BACKUP` ownership check, counts state archives matching
  `email-dns-monitor-state-*.tar.gz` and checks the most-recent archive mtime.
  All `find` calls use `sudo -u emaildns` because the directory is `0700
  emaildns:emaildns` and root cannot read it directly.  Thresholds:
  - count = 0 → `_fail` (no archives ever written)
  - most-recent > 48 h → `_fail` (service stale or backup broken)
  - most-recent > 25 h → `_warn` (missed at least one daily run window)
  - otherwise → `_ok` with count and age

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md` (this file)
- `server-sanity/OPEN-ITEM-edm-install-backup-find-root.md` — new

---

## [1.6.2] — 2026-06-03

### Fixed

- **ERR trap misfires on non-zero exit:** `_trap_err` was firing on the
  final `exit "$_EXIT"` call when `_fail > 0`, emitting a spurious
  `ERROR: unexpected failure at line 1` block after the summary.
  Added `(( _EXIT_CLEAN )) && return` as the first guard in `_trap_err`,
  matching the existing pattern in `_trap_exit`.  `_EXIT_CLEAN=1` is
  already set unconditionally before `exit "$_EXIT"` in all paths, so
  both traps are now silent on every normal exit (success and failure).
  Updated `_EXIT_CLEAN` comment to document it gates both traps.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md` (this file)

---

## [1.6.1] — 2026-06-03

### Added

- **Section 2 — Email DNS Monitor: `last_run.json` checks:** EDM v2.15.27
  writes `/var/lib/email-dns-monitor/last_run.json` unconditionally at the
  end of every `--run` cycle.  Four new checks added after `check_no_lockfile`:
  (1) file exists — `_fail` if absent;
  (2) valid JSON — `_fail` if not;
  (3) mtime ≤ 90 minutes (5400 s) — `_fail` if stale;
  (4) `exit_code` is 0, 2, or 3 — `_fail` on any other value.
  On a clean run the `_ok` line surfaces `confirmed_count` and
  `failure_count` from the JSON for visibility.  Uses the `$(( ))` age
  pattern already established by `check_no_lockfile`; no new helper
  functions introduced.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md` (this file)

---

## [1.6.0] — 2026-06-02

### Added

- **Section 7 — System tools:** new section checks that `pandoc` and
  `wkhtmltopdf` are installed via apt and that `glow` is installed via snap.
  Each missing package emits `_fail` with the install command as a `_note`.
  Present packages report their installed version.  Former Section 7 (self)
  renumbered to Section 8.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md` (this file)

---

## [1.5.1] — 2026-06-01

### Fixed

- **`install.sh` verify step:** the config file verification block was gated
  on `[[ -f $OVERRIDES_SRC ]]`, so when the override source was absent from
  the server (e.g. installer run before `st` sync completed), both the deploy
  step and the verify step silently passed — `CONF_DEST` was never written and
  no counter was incremented.  Fixed by splitting verify into two cases:
  (1) source present → `_fail` if `CONF_DEST` is missing or differs from
  source; (2) source absent → `_ok` if a previously-deployed config exists,
  `_warn` if neither source nor deployed file is present.  This ensures a
  stale or incomplete deploy is always surfaced.

### Files changed

- `server-sanity/install.sh`
- `server-sanity/CHANGELOG.md` (this file)
- `docs/CHANGELOG.md` (repo)

---

## [1.5.0] — 2026-06-01

### Added

- **msmtp group membership checks (Section 1):** new `check_group_member`
  helper verifies that every service account that sends email is a member of
  the `msmtp` system group.  Without membership msmtp exits silently — no log
  entry, no error output.  The set of accounts is host-specific and driven by
  `/etc/server-tools/server-sanity.conf` (deployed by `install.sh` from
  `overrides/<hostname>/server-sanity.conf` in the repo).  If the config file
  is absent or `MSMTP_GROUP_MEMBERS` is empty, the check emits a `_warn`
  rather than failing — missing config is not itself a breakage.  Each
  membership failure includes a remediation note (`usermod -aG msmtp <user>`).
  The helper checks both supplementary groups (via `getent group` field 4)
  and primary group (via `id -nG`) so no assignment path is missed.
- **`overrides/pblinuxutility/server-sanity.conf`:** initial override config
  for pblinuxutility declaring `MSMTP_GROUP_MEMBERS=(nathan emaildns
  balena-monitor golan sp-export)`.

### Changed

- **`install.sh`** — new Step 2a deploys `overrides/<hostname>/server-sanity.conf`
  to `/etc/server-tools/server-sanity.conf` (0644 root:root) when an override
  exists for the current host.  If no override is present for this host the
  step warns and continues — absence is not a hard failure.  Verify step
  extended to diff the deployed config against source when applicable.
  Header and production layout comments updated.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/install.sh`
- `server-sanity/CHANGELOG.md` (this file)
- `overrides/pblinuxutility/server-sanity.conf` — new
- `docs/CHANGELOG.md` (repo)

---

## [1.4.0] — 2026-05-31

### Added

- **Section 7 — Server Sanity Check (self):** the script now audits its own
  deployment and scheduled-run health.  Checks:
  - Deployed binary present at `/usr/local/bin/server-sanity-check` with
    expected permissions (0755 root:root).
  - `pb-server-sanity-check.timer` active with next trigger time.
  - `pb-server-sanity-check.service` last run result (via `check_last_run`).
  - `SANITY_CHECK_RESULT` journal line from the most recent run, parsed for
    pass/fail/warn counts.  The unit uses `SuccessExitStatus=0 1` so systemd
    always sees success — this check surfaces run-level failures that would
    otherwise be invisible.  A missing journal line (new host / journal
    rotated) is reported as a warning.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md` (this file)

---

## [1.4.2] — 2026-05-31

### Fixed

- **Section 7 journal write:** `SANITY_CHECK_RESULT` was printed to stderr
  only, which reaches the journal when launched by systemd but goes to the
  terminal only on interactive runs.  The line is now also written via
  `systemd-cat -t pb-server-sanity` so every run — interactive or scheduled —
  populates the journal entry that the next run's self-check reads.
- **Section 7 journal query:** changed from `-n 200` (line count limit) to
  `--until <script-start-timestamp>` so the query always finds the previous
  run's line rather than the current run's (which cannot be in the journal at
  query time).  Derived from `$_START` (nanosecond timestamp captured at
  script entry) converted to a wall-clock string via `date -d @`.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md` (this file)

---

## [1.4.1] — 2026-05-31

### Fixed

- **Section 7 journal query:** `journalctl -u pb-server-sanity-check` filters
  by unit name and does not match process stderr output, which is tagged with
  `SyslogIdentifier=pb-server-sanity`.  Changed to `journalctl -t pb-server-sanity`
  so the `SANITY_CHECK_RESULT` line is found correctly.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md` (this file)

---

## [1.3.2] — 2026-05-30

### Changed

- `install.sh`: applied CLI formatting and visual style — TTY-detected colour
  palette, `_ok`/`_fail`/`_head`/`_die` primitives with `✔`/`✘`/`══` chrome,
  PASS/FAIL counters, elapsed-time summary block, runtime banner, inline root
  guard, section banners on each step.  `verify_files` failures now route
  through `_fail` so they appear in the counter.  Post-install usage block
  unchanged.  ShellCheck clean.

### Files changed

- `server-sanity/install.sh`
- `server-sanity/CHANGELOG.md` (this file)

---

## [1.3.1] — 2026-05-30

### Fixed

- **lighttpd section:** added `command -v lighttpd` guard — section now
  prints `⊘ not installed` and increments no counters on hosts without
  lighttpd (e.g. pblinuxutility).  Previously emitted 4 failures.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md`
- `CHANGELOG.md` (repo)

---

## [1.3.0] — 2026-05-30

### Changed

- **`check_cert_expiry` → `check_cert_expiry_file`:** abandoned the
  `openssl s_client` network approach entirely.  PBWEBSRV03 has outbound
  port 443 blocked (hairpin NAT / egress firewall), so the TCP connection
  times out after 15s regardless of flags.  The new helper reads the PEM
  file directly from disk with `openssl x509 -noout -enddate -in <file>`,
  which returns in milliseconds and is more reliable (checks the cert
  actually loaded by lighttpd, not what the network sees).
- **Multi-cert scanner:** the lighttpd section now extracts all `ssl.pemfile`
  paths from `/etc/lighttpd/lighttpd.conf` at runtime (deduplicated), and
  checks each one.  On PBWEBSRV03 this covers `premiumbrandsholdings.com`,
  `www`, `beta`, `alpha`, `legacy`, `creeksidefoods.com`, and
  `gloriasbestoffresh.com` automatically.  No cert path is hard-coded.
  Label shown is the Let's Encrypt domain directory name.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md`
- `CHANGELOG.md` (repo)

---

## [1.2.4] — 2026-05-30

### Fixed

- **`check_cert_expiry`:** `wait "$sc_pid"` returns exit 143 (SIGTERM) when
  the background `s_client` is killed by our `kill` call.  Under
  `set -euo pipefail` this aborted the script after the lighttpd section with
  no cert output and a non-zero exit.  Fixed with `|| true`.  Poll iterations
  increased from 80 to 100 (10s ceiling, matching the `timeout 15` guard with
  headroom).

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md`
- `CHANGELOG.md` (repo)

---

## [1.2.3] — 2026-05-30

### Fixed

- **`check_cert_expiry`:** the `echo Q` and `-nocommands` approaches both
  failed because `premiumbrandsholdings.com` does not send a TLS close-notify
  promptly after the handshake, so `s_client` kept the session open and blocked
  its downstream pipe consumer for the full `timeout` duration (10s).  The
  real fix runs `s_client` in the background writing to a temp file, polls the
  file until the `-----END CERTIFICATE-----` line appears (typically one
  iteration / ~100ms), kills `s_client`, then extracts the expiry from the
  buffered output.  `timeout 15` on the background process is a last-resort
  guard against a completely unresponsive host.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md`
- `CHANGELOG.md` (repo)

---

## [1.2.2] — 2026-05-30

### Fixed

- **`check_cert_expiry`:** `echo Q |` did not prevent the hang on
  `premiumbrandsholdings.com` — the server does not respond to the close-notify
  promptly enough.  Replaced with `openssl s_client -nocommands` (exits after
  the handshake without waiting for stdin) plus `timeout 10` as a
  belt-and-suspenders guard against stalled TCP connections.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md`
- `CHANGELOG.md` (repo)

---

## [1.2.1] — 2026-05-30

### Fixed

- **`check_cert_expiry`:** replaced `</dev/null` with `echo Q |` to close
  the `openssl s_client` session after the TLS handshake.  Some servers do
  not send EOF in response to stdin closure, causing an indefinite hang.
  `echo Q` sends a TLS close-notify and exits immediately.
- **lighttpd section:** removed `check_last_run lighttpd.service`.
  lighttpd is a persistent daemon; systemd never sets `InactiveEnterTimestamp`
  for it, so `check_last_run` always emitted a spurious "no run recorded yet"
  warning.  Active state is already confirmed by the `systemctl is-active`
  check above it.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md`
- `CHANGELOG.md` (repo)

---

## [1.2.0] — 2026-05-30

### Added

- **Optional-section guards (sections 2–4):** Email DNS Monitor, Balena
  Monitor, and SharePoint Export are now skipped with a `⊘ not installed`
  notice when their `/opt/<app>` install root is absent.  No counters are
  incremented for skipped sections.  Sentinel is the install root directory
  (not the binary symlink) because a broken symlink would still satisfy
  `command -v`.
- **`check_cert_expiry <host> <port>` helper:** connects live via
  `openssl s_client`, extracts the TLS certificate expiry date, and emits
  `_fail` (≤7 days or already expired), `_warn` (≤30 days), or `_ok`.
  Days remaining and the raw `notAfter` date are always shown.
- **`_skip` primitive:** prints a `⊘` line without incrementing any counter.
- **Section 6 — lighttpd:** binary present; `systemctl is-active` check;
  config syntax via `lighttpd -t`; `/var/log/lighttpd` directory; last
  service run; TLS cert expiry for `premiumbrandsholdings.com:443`.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md`
- `CHANGELOG.md` (repo)

---

## [1.1.1] — 2026-05-30

### Fixed

- **`server-sanity-check.sh`:** runtime banner and file header comment used
  the hard-coded hostname `PBWEBSRV03` instead of the runtime value.
  Banner now calls `$(hostname -s)`; header comment is now generic.  The
  `--email-on-failure` subject line already used `$(hostname -s)` correctly
  and is unchanged.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md`
- `CHANGELOG.md` (repo)

---

## [1.1.0] — 2026-05-30

### Added

- **`--email-on-failure` flag** (`server-sanity-check.sh`): when passed,
  the full report is captured and emailed to `EMAIL_PRIMARY` (sourced from
  `/etc/balena-monitor/config`) if any check FAILED (exit 1).  Warnings
  (exit 0) do not trigger an email.  ANSI colour codes are stripped before
  delivery.  If `EMAIL_PRIMARY` is absent or `msmtp` is unavailable, the
  step is skipped with a diagnostic on stderr.
- **`pb-server-sanity-check.service`** and **`pb-server-sanity-check.timer`**:
  new systemd units that run `server-sanity-check --email-on-failure` daily
  at 08:00, after the monitored service windows have completed and before the
  09:00 windows fire.  Addresses the silent-failure gap identified in
  OPEN-ITEM-server-sanity-scheduled-backstop.md.  No namespace-requiring
  sandbox directives used (avoids KFC-R02 / EXIT_NAMESPACE on container/VM
  hosts).  `SuccessExitStatus=0 1` so a detected failure does not mask the
  next `check_last_run` result.
- **`install.sh`**: updated to deploy and enable the new systemd units;
  added verify step comparing deployed units to source; added `msmtp` to
  prerequisite check.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/systemd/pb-server-sanity-check.service` — new
- `server-sanity/systemd/pb-server-sanity-check.timer` — new
- `server-sanity/install.sh`
- `server-sanity/CHANGELOG.md`
- `CHANGELOG.md` (repo)
- `README.md`
- `DEV-GUIDE.md`

---

## [1.0.1] — 2026-05-30

### Fixed

- **Section 2 (Email DNS Monitor):** added `check_dir` calls for
  `/var/backups/email-dns-monitor` and `/var/backups/email-dns-monitor/history`.
  Both directories are created by the EDM installer; their absence was
  undetected by the sanity check.
- **Section 4 (SharePoint Export):** added `check_dir` calls for
  `/var/lib/sharepoint-export/export` (export working subdir) and
  `/var/backups/sharepoint-export` (archive dir). Both are created by the
  SPE installer and were absent from the previous check.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md`
- `CHANGELOG.md` (repo)

---

## [1.0.0] — 2026-05-30

### Added

- Initial release.
- `src/server-sanity-check.sh`: read-only infrastructure sanity check for
  PBWEBSRV03. Covers five sections — email stack, Email DNS Monitor, Balena
  Monitor, SharePoint Export, and Server Tools (pb-maintenance) — and exits
  in under 5 seconds on a healthy host.
- **Email stack:** verifies `msmtp` and `mailx` binaries; `/etc/msmtprc`
  presence, `account default` mapping, TLS and relay host directives;
  `/var/log/msmtp/` log directory; presence of at least one
  `exitcode=EX_OK` entry in the msmtp log.
- **Email DNS Monitor:** binary present and symlink target valid; `emaildns`
  service user exists; install root, config (syntax + 8 required keys), state
  dir + subdirs + ownership, `domains/domains.json` (valid JSON, enabled
  domain count); no stale lock file; primary timer active with next trigger
  time; last service run result.
- **Balena Monitor:** binary + symlink; `balena-monitor` user; install root,
  config (syntax + 3 required keys), state/log/spool dirs + ownership;
  `fleet_health_history.json` validity (warn-only if absent on first run);
  primary timer + last run.
- **SharePoint Export:** binary + symlink; `sp-export` user; install root,
  config (syntax + 10 required keys, enforced `0600 sp-export` permissions),
  state/log/lock dirs + ownership; cross-app path validation (`BM_STATE_DIR`,
  `EDM_STATE_DIR`, `EDM_LIB_DIR`, `EDM_DOMAINS_FILE` resolved against live
  config); primary timer + last run.
- **Server Tools:** 5 scripts present under
  `/usr/local/libexec/pb-maintenance/` and `/usr/local/bin/`; state dir and
  both log dirs; `patch-state.json` JSON validity (warn-only if absent);
  both `pb-check-for-updates.timer` and `pb-security-hardening-check.timer`
  active; last run result for both services.
- Colour-coded output (green/red/yellow); pass/fail/warn counters; elapsed
  time in summary. No emails sent, no services triggered, no state mutated.
  Exits 0 (all pass), 0 (warnings only), 1 (any failure), or 2 (not root).
- `install.sh`: prereq check, deploy to `/usr/local/bin/server-sanity-check.sh`
  (0755 root:root), post-install smoke test.

### Files changed

- `server-sanity/src/server-sanity-check.sh` — new
- `server-sanity/install.sh` — new
- `server-sanity/CHANGELOG.md` — new
