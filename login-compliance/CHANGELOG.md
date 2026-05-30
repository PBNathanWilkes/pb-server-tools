# CHANGELOG — login-compliance

All notable changes follow [Semantic Versioning](https://semver.org/).

---

## [0.9.1] — 2026-05-30

### Changed

- `install.sh`: applied CLI formatting and visual style — TTY-detected colour
  palette, `_ok`/`_fail`/`_head`/`_die` primitives with `✔`/`✘`/`══` chrome,
  PASS/FAIL counters, elapsed-time summary block, runtime banner, inline root
  guard, section banners on each step.  `print_bashrc_instructions` output
  unchanged.  ShellCheck clean.

### Files changed

- `login-compliance/install.sh`
- `login-compliance/CHANGELOG.md` (this file)

---

## [0.9.0] — current

See version history in `src/login-compliance-check.sh` header for
the full pre-repo history.

This component was extracted into `pb-server-tools` as a standalone
component at v0.9.0. Previously deployed as part of `check-for-updates`.
The `tests/unit/test_login_compliance.sh` is the canonical test file for
this component going forward (KFC-R01 in top-level DEV-GUIDE.md).
