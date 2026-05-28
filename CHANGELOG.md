# CHANGELOG — pb-server-tools

All notable changes follow [Semantic Versioning](https://semver.org/).

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
