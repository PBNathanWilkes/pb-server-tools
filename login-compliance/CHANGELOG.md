# CHANGELOG — login-compliance

All notable changes follow [Semantic Versioning](https://semver.org/).

---

## [0.10.0] — 2026-06-03

### Changed

- `login-compliance-check.sh`: the patch check now reads
  `/var/lib/pb-maintenance/patch-state.json` (and `patch-suppression.json`) via
  `jq` instead of recomputing patch state with `apt-get dist-upgrade -s`. This
  is both faster (a single small-file read, no apt invocation) and accurate by
  construction (it consumes the same `seen_count >= 2` confirmation gate and
  suppression model the validated evaluator/reporter pipeline produces). The
  1-hour XDG patch cache and all `_cache_*` / `_apt_update_stamp_epoch`
  machinery were removed — a jq read is fast enough that the banner reflects the
  true current state file on every login, eliminating the cache as a staleness
  source.

### Added

- Two-tier staleness model so the banner indicates a *real current problem*
  rather than merely old data:
  - fresh (≤ 26h): patch verdict reported as-is.
  - mildly stale (26h .. `LCHECK_PATCH_DEAD_DAYS`, default 3d): the real patch
    verdict is still reported, annotated `(data Nh old)`; a clean host stays
    `OK`, genuinely pending patches still surface.
  - dead (> `LCHECK_PATCH_DEAD_DAYS`): `WARN` — the evaluator looks dead and the
    data is no longer trusted.
  - New env var `LCHECK_PATCH_DEAD_DAYS` (default 3).

### Fixed

- `_iso_to_epoch()` returned `0` on parse failure, so an unparseable
  `evaluated_at` read as 1970-01-01 and produced a false "stale" banner. It now
  returns empty; an unparseable timestamp is reported as a distinct `WARN`
  rather than masquerading as staleness.
- **KFC-R01 regression** (see repo `DEV-GUIDE.md`): the canonical
  `login-compliance/src/` copy had drifted to the obsolete dist-upgrade/cache
  implementation while the correct state-file implementation lived in the
  `check-for-updates/src/` duplicate that KFC-R01 says should not exist, and the
  installer shipped the obsolete one. Consolidated: the state-file
  implementation is now the sole canonical copy; the `check-for-updates/src/`
  and `check-for-updates/tests/unit/` login-compliance duplicates were deleted.

### Tests

- `tests/unit/test_login_compliance.sh`: removed the two `_cache_fresh` tests
  (tested now-deleted cache machinery); added end-to-end staleness-band tests
  against the real script — T02 (fresh+clean → OK, no note), T03 (mildly stale
  → OK + age note), T06 (mildly stale + pending → CRITICAL, verdict shows
  through), T07 (dead evaluator → WARN), T08 (unparseable timestamp → WARN).
  Now 8 tests.

### Files changed

- `login-compliance/src/login-compliance-check.sh`
- `login-compliance/tests/unit/test_login_compliance.sh`
- `check-for-updates/src/login-compliance-check.sh` (deleted — duplicate)
- `check-for-updates/tests/unit/test_login_compliance.sh` (deleted — duplicate)
- `docs/DEV-GUIDE.md` (KFC-R01 status)
- `docs/SESSION-PROTOCOL.md` (test mapping; current-version block)
- `README.md` (test command list)
- `login-compliance/CHANGELOG.md` (this file)
- `docs/CHANGELOG.md` (repo version bump)

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
