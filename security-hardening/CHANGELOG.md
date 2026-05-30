# CHANGELOG — security-hardening

All notable changes follow [Semantic Versioning](https://semver.org/).

---

## [2.1.18] — 2026-05-29

### Fixed

- **`check_ssh_security()`: `sshd -T` now invoked with `-C` context flags.**
  OpenSSH ≥6.5 requires a synthetic connection context
  (`user=root,host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=22`) when
  any `Match` block is present in the server configuration. Without `-C`,
  `sshd -T` exits non-zero even when `sshd` itself is healthy. The script
  treated any non-zero exit as a failure and fell back to grepping
  `/etc/ssh/sshd_config` directly — silently missing all directives set in
  drop-ins under `/etc/ssh/sshd_config.d/` (e.g. `99-hardening.conf`).
  The result was that hardening directives applied via drop-ins were reported
  as absent (WARN) even though sshd was enforcing them.

### Tests

- `tests/unit/test_security_hardening.sh`: added T23.
  T23: regression guard — source must contain the `-C` context flag string
  in the `sshd -T` invocation; a bare `sshd -T` without `-C` is a defect.

### KFC — new entry

**`check-for-updates` / `security-hardening` shared pattern — KFC-SH01**
(security-hardening component, `check_ssh_security`)

- **Version observed:** v2.1.16–v2.1.17
- **Failure mode:** `sshd -T` exits non-zero on hosts that have `Match`
  blocks in `sshd_config` (including the Ubuntu default
  `/etc/ssh/sshd_config.d/50-cloud-init.conf`). Script falls back to
  file-grep, missing all drop-in directives. SSH checks report WARN for
  settings that are in fact configured.
- **Root cause:** OpenSSH ≥6.5 requires `-C user=…,host=…,addr=…` context
  when evaluating `Match` blocks. Without it, `sshd -T` cannot resolve
  conditional blocks and aborts.
- **Fix applied:** v2.1.18 — `sshd -T -C user=root,host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=22`
- **Current-version mitigation:** Fallback to file-grep is retained; it
  now only triggers if the context-injected call also fails (true pre-install
  environment or corrupt sshd binary). T23 guards against regression to bare
  `sshd -T`.

---

## [2.1.17] — 2026-05-29

### Fixed

- **ERR trap firing spuriously on every `[[ "$status" != "CRITICAL" ]] && status="WARN"` expression.**
  Under `set -Eeuo pipefail`, when `$status` is already `"CRITICAL"` the `[[ ]]` test
  exits 1 (false condition), the `&&` short-circuits without executing the assignment, and
  `set -E` propagates the exit-1 to the ERR trap — printing a false
  `ERROR on line N (exit 0)` for each call. This pattern appeared 7 times across
  `check_ssh_security`, `check_kernel_security`, `check_auditd`, and
  `check_unattended_upgrades_scope`. Fixed all 7 by appending `|| true` so the
  compound expression always exits 0 regardless of the `[[ ]]` result.

- **`check_shadow_hash_algorithm()` reported CRITICAL DES hashes for Ubuntu 24.04
  system accounts** (`systemd-network`, `systemd-timesync`, `systemd-resolve`,
  `polkitd`, `fwupd-refresh`). Ubuntu 24.04 locks service accounts by writing `!*`
  in the `/etc/shadow` password field (locked-with-note convention). The previous
  skip condition used exact matches (`"!"`, `"!!"`, `"*"`), which did not match `"!*"`.
  Since `"!*"` does not start with `$`, it fell through to the DES branch and was
  reported as a crackable hash. Fixed by replacing the exact-match check with a
  prefix match: `[[ "$password" == "!"* || "$password" == "*" ]]`.

### Tests

- `tests/unit/test_security_hardening.sh`: added T21 and T22.
  T21: ERR trap regression — `status=CRITICAL` is preserved and the expression
  exits 0 under `set -Eeuo pipefail`. T22: shadow DES regression — `!*`, `!`, `!!`,
  and `*` are all classified as SKIP (locked), not DES.

---

## [2.1.16] — 2026-05-29

### Fixed

- **SSH check now uses `sshd -T`** (effective configuration dump) instead of
  grepping `/etc/ssh/sshd_config`. Ubuntu 22.04+ processes `Include` directives
  and drop-ins in `/etc/ssh/sshd_config.d/` which take precedence over the main
  file; grepping the main file missed any overrides in those files. `sshd -T`
  returns the fully resolved effective configuration, handling all includes.
  Falls back to file-grep with a WARN if `sshd -T` fails (e.g. pre-install
  environment).

- **`PasswordAuthentication` default corrected.** The script previously warned
  "default: yes" when the directive was absent. The compiled default changed to
  `no` in OpenSSH 8.8 (Ubuntu 22.04+). The old message would mislead operators
  into thinking the server accepted password logins when it did not.

- **`check_file_permissions()` octal comparison replaced with bitwise AND.**
  The previous `actual_dec > expected_dec` numeric comparison does not correctly
  model Unix permission semantics: `640 > 600` numerically but `600` has no bits
  that `640` lacks; neither is universally "more permissive" than the other.
  Fixed to `actual & ~expected & 0777`: fires WARN only when the actual mode has
  bits set that the expected mode does not.

- **`check_sudo_configuration()` NOPASSWD scan now covers `/etc/sudoers.d/*`.**
  The previous grep was limited to `/etc/sudoers`; a NOPASSWD entry in a drop-in
  (the recommended Ubuntu pattern for site-local rules) was silently missed.
  Changed to `grep -rv` across both paths.

- **VERSION constant** was `2.1.14`; file header said `2.1.15`. Bumped to
  `2.1.16` so the version reported in email matches the actual deployed version.

### Added

- **`check_ssh_security()`**: four new checks: `MaxAuthTries` (should be ≤4;
  default 6 allows brute-force); `LoginGraceTime` (should be ≤30s; default 120s);
  `ClientAliveInterval`/`ClientAliveCountMax` (idle session termination); and
  `AllowUsers`/`AllowGroups` (allowlist enforcement — absence means any valid
  account may attempt login).

- **`check_kernel_security()`**: seven additional sysctl parameters:
  `kernel.randomize_va_space` (full ASLR, =2), `kernel.yama.ptrace_scope` (=1),
  `fs.protected_hardlinks` (=1), `fs.protected_symlinks` (=1),
  `net.ipv4.conf.default.accept_redirects` (=0), `net.ipv6.conf.all.accept_redirects`
  (=0), `net.ipv4.conf.all.rp_filter` (=1), `net.ipv4.conf.all.log_martians` (=1).

- **`check_auditd()`**: verifies auditd is installed, enabled, and running; warns
  if no audit rules are loaded. Auditd provides the tamper-evident record of
  privileged commands, file access, and authentication events required by CIS
  benchmarks.

- **`check_shadow_hash_algorithm()`**: scans `/etc/shadow` for MD5 (`$1$`) and
  DES (no `$` prefix) password hashes; reports CRITICAL if found. Reports WARN
  for SHA-256 (`$5$`). Skips locked (`!`, `*`) accounts.

- **`check_unattended_upgrades_scope()`**: verifies that a `-security` origin is
  present and uncommented in `Allowed-Origins` in
  `/etc/apt/apt.conf.d/50unattended-upgrades`. The existing `check_automatic_updates()`
  check only verified the scheduler was on; this check verifies security updates
  are actually in scope.

### Tests

- `tests/unit/test_security_hardening.sh`: added T10–T20 (11 new tests).
  T10: `sshd -T` effective config parsing. T11: MaxAuthTries > 4 → WARN.
  T12: `randomize_va_space` present in kernel params. T13: `yama.ptrace_scope`
  present. T14: bitwise perm check — 640 vs 600 → WARN. T15: 600 vs 644 → OK
  (more restrictive is acceptable). T16: NOPASSWD in sudoers.d drop-in detected.
  T17: MD5 hash → CRITICAL. T18: yescrypt hash → OK. T19: security origin in
  50unattended-upgrades detected. T20: absent security origin → WARN condition.

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
