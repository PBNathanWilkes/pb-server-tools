# CHANGELOG — pb-server-tools

All notable changes follow [Semantic Versioning](https://semver.org/).

---

## [1.0.6] — 2026-05-30

### Added

- `server-sanity` v1.1.0: `--email-on-failure` flag, `pb-server-sanity-check.service`
  and `pb-server-sanity-check.timer` (daily 08:00 watchdog).  Addresses
  OPEN-ITEM-server-sanity-scheduled-backstop: failures in any monitored service
  now generate an email alert automatically without manual intervention.
  No namespace-requiring sandbox directives in the new unit (avoids KFC-R02).

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/systemd/pb-server-sanity-check.service` — new
- `server-sanity/systemd/pb-server-sanity-check.timer` — new
- `server-sanity/install.sh`
- `server-sanity/CHANGELOG.md`
- `README.md`
- `DEV-GUIDE.md`
- `CHANGELOG.md` (this file)

---

## [1.0.5] — 2026-05-30

### Fixed

- `server-sanity`: added missing `check_dir` calls for four directories
  created by external application installers but not previously verified:
  - `/var/backups/email-dns-monitor` and `/var/backups/email-dns-monitor/history`
    (EDM backup infrastructure)
  - `/var/lib/sharepoint-export/export` (SPE working export subdir) and
    `/var/backups/sharepoint-export` (SPE archive dir)
  Bumps `server-sanity` to v1.0.1.

### Files changed

- `server-sanity/src/server-sanity-check.sh`
- `server-sanity/CHANGELOG.md`
- `CHANGELOG.md` (this file)

---

## [1.0.4] — 2026-05-30

### Fixed

- `overrides/pblinuxutility/` drop-ins: replaced empty-string resets with
  explicit permissive values for enumerated/boolean directives. This host's
  systemd version silently ignores empty-string resets for `ProtectSystem=`,
  `ProtectHome=`, `PrivateTmp=`, `ProtectKernelModules=`, and
  `ProtectKernelTunables=`, leaving base unit values active. KFC-R02 updated.

### Files changed

- `overrides/pblinuxutility/pb-check-for-updates.service.d/no-namespace.conf`
- `overrides/pblinuxutility/pb-check-for-updates-monthly.service.d/no-namespace.conf`
- `overrides/pblinuxutility/pb-security-hardening-check.service.d/no-namespace.conf`
- `overrides/pblinuxutility/pb-security-hardening-check-monthly.service.d/no-namespace.conf`
- `overrides/pblinuxutility/README.md`
- `check-for-updates/CHANGELOG.md`
- `security-hardening/CHANGELOG.md`
- `DEV-GUIDE.md`
- `CHANGELOG.md` (this file)

---

## [1.0.3] — 2026-05-30

### Fixed

- `overrides/pblinuxutility/` drop-ins: added `ReadOnlyPaths=` and
  `ReadWritePaths=` resets to all four no-namespace override files.
  Path-binding directives require `CLONE_NEWNS`; exit 226 persisted after
  v1.0.2 without these resets. KFC-R02 updated accordingly.

### Files changed

- `overrides/pblinuxutility/pb-check-for-updates.service.d/no-namespace.conf`
- `overrides/pblinuxutility/pb-check-for-updates-monthly.service.d/no-namespace.conf`
- `overrides/pblinuxutility/pb-security-hardening-check.service.d/no-namespace.conf`
- `overrides/pblinuxutility/pb-security-hardening-check-monthly.service.d/no-namespace.conf`
- `overrides/pblinuxutility/README.md`
- `check-for-updates/CHANGELOG.md`
- `security-hardening/CHANGELOG.md`
- `DEV-GUIDE.md`
- `CHANGELOG.md` (this file)

---

## [1.0.2] — 2026-05-30

### Fixed

- `overrides/pblinuxutility/` drop-ins: added `ProtectHome=` reset to all
  four no-namespace override files. `ProtectHome=true` was confirmed on
  pblinuxutility to also require `CLONE_NEWNS`; exit 226 persisted after
  v1.0.1 without this reset. KFC-R02 updated accordingly.

### Files changed

- `overrides/pblinuxutility/pb-check-for-updates.service.d/no-namespace.conf`
- `overrides/pblinuxutility/pb-check-for-updates-monthly.service.d/no-namespace.conf`
- `overrides/pblinuxutility/pb-security-hardening-check.service.d/no-namespace.conf`
- `overrides/pblinuxutility/pb-security-hardening-check-monthly.service.d/no-namespace.conf`
- `overrides/pblinuxutility/README.md`
- `check-for-updates/CHANGELOG.md`
- `security-hardening/CHANGELOG.md`
- `DEV-GUIDE.md`
- `CHANGELOG.md` (this file)

---



### Fixed

- `check-for-updates/install.sh`, `security-hardening/install.sh`: added
  `deploy_overrides()` step that installs host-specific systemd drop-in
  overrides for hosts in `NAMESPACE_OVERRIDE_HOSTS`.  Resolves exit 226
  (EXIT_NAMESPACE) on pblinuxutility caused by namespace-requiring sandbox
  directives (`ProtectSystem=strict`, `PrivateTmp=true`,
  `ProtectKernelModules=true`, `ProtectKernelTunables=true`) that the host's
  kernel or container runtime cannot honour.  Source unit files unchanged;
  sandboxing on PBWEBSRV03 unaffected.

- `DEV-GUIDE.md §6`: added KFC-R02.

### Files changed

- `check-for-updates/install.sh`
- `check-for-updates/CHANGELOG.md`
- `security-hardening/install.sh`
- `security-hardening/CHANGELOG.md`
- `overrides/pblinuxutility/pb-check-for-updates.service.d/no-namespace.conf` (new)
- `overrides/pblinuxutility/pb-check-for-updates-monthly.service.d/no-namespace.conf` (new)
- `overrides/pblinuxutility/pb-security-hardening-check.service.d/no-namespace.conf` (new)
- `overrides/pblinuxutility/pb-security-hardening-check-monthly.service.d/no-namespace.conf` (new)
- `overrides/pblinuxutility/README.md` (new)
- `DEV-GUIDE.md`
- `CHANGELOG.md` (this file)

---

## [1.0.0] — 2026-05-28

### Added

- Initial repository structure consolidating three Ubuntu server management
  components: `check-for-updates`, `security-hardening`, `login-compliance`.
- Top-level `install.sh` orchestrator: installs system prerequisites via
  `apt-get`, ensures log directories exist, and delegates to each component's
  `install.sh` in dependency order. Supports `--only <component>` for
  partial reinstalls.
- `security-hardening/install.sh`: prereq check, unit tests, deploy to
  `/usr/local/libexec/pb-maintenance/`, systemd unit verify + reload.
- `security-hardening/tests/unit/test_security_hardening.sh`: T01–T05
  covering `html_escape`, `validate_email`, and script syntax.
- `login-compliance/install.sh`: prereq check, unit tests, deploy to
  `/usr/local/bin/`, `.bashrc` snippet instructions.
- `login-compliance/tests/unit/test_login_compliance.sh`: T01–T05
  covering cache TTL logic, `_msmtp_line_is_success`, and script syntax.
  (Separate from the copy in `check-for-updates/tests/unit/` — each
  component owns its own test suite.)
- `README.md`: repo overview, quick-start, component descriptions,
  production layout, and post-install verification checklist.
- `DEV-GUIDE.md`: development conventions, test gates, release process,
  and repo-level KFC catalog.
