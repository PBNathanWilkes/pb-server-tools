# CHANGELOG — server-sanity

All notable changes follow [Semantic Versioning](https://semver.org/).

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
