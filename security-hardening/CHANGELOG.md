# CHANGELOG — security-hardening

All notable changes follow [Semantic Versioning](https://semver.org/).

---

## [2.1.15] — 2026-05-29

### Fixed
- **Password Policy check** — replaced file-only detection (`[[ -f /etc/security/pwquality.conf ]]`) with a dual check: `libpam-pwquality` package installed **and** `/etc/security/pwquality.conf` present. Eliminates false-positive WARN on servers where the file exists but the installed-version check was inconsistent.
- **Sudo logging check** — replaced single-file grep of `/etc/sudoers` with `grep -rE` across both `/etc/sudoers` and `/etc/sudoers.d/`. Correctly detects `Defaults logfile=` when configured in a drop-in file (Ubuntu best practice). Eliminates false-positive WARN on servers using `/etc/sudoers.d/logging`.

---

## [2.1.14] — current

See version history in `src/security-hardening-check.sh` header for
the full pre-repo history (v1.0.0–v2.1.14).

This component was moved into `pb-server-tools` at v2.1.14 without
functional changes. All future changes will be logged here.
