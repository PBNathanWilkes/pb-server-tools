# DEV-GUIDE.md — check-for-updates Development Guide

**Project:** `check-for-updates`
**Current version:** v4.2.18
**Platform:** Ubuntu 24.04 Noble

---

## 1. Architecture Overview

```
check-for-updates.sh          ← Bash orchestrator; systemd ExecStart entry point
  │                              runs as root via systemd
  ├─► pb-apt-evaluator.py     ← Python 3; writes /var/lib/pb-maintenance/patch-state.json
  │     apt_pkg.DepCache.phasing_applied() — native, in-process, no text scraping
  │
  └─► pb-patch-reporter.sh    ← Bash; reads state, sends HTML email
        Confirmation gate: seen_count >= 2 (cross-run; no in-run sleep)
        Suppression key:   (name, architecture, candidate_version)
        Suppression TTL:   4 days

login-compliance-check.sh     ← Bash; login banner check; runs as the operator user
                                 reads state files (world-readable); never writes them
```

State files:

| File | Writer | Readers |
|------|--------|---------|
| `/var/lib/pb-maintenance/patch-state.json` | `pb-apt-evaluator.py` only | reporter, login-check |
| `/var/lib/pb-maintenance/patch-suppression.json` | `pb-patch-reporter.sh` only | reporter, login-check |

**The file-level ownership separation is invariant.** The reporter must never
write `patch-state.json`. The evaluator must never write `patch-suppression.json`.
Tests enforce this (T16 in reporter tests, §9.4 step 8 in integration tests).

---

## 2. Pre-Merge Test Gate

**Tests run on the development machine only. Do not run tests on the production host.**

- Unit tests require `python3-apt`, `python3-pytest`, and `jq`.
- The Bash test harnesses (`test_pb_patch_reporter.sh`, `test_login_compliance.sh`)
  use mock binaries and temporary directories; they must not touch production state files.
- Production host is used only for the dry-run parity check (§2.1) and integration
  tests (§5) after deployment.

Install test dependencies on the dev machine (Ubuntu 24.04):

```bash
sudo apt install python3-apt python3-pytest jq
```

**Any change to phasing detection, suppression logic, `is_security_update`,
or any function that interprets `apt_pkg.Cache` / `apt_pkg.DepCache` state
MUST pass the full `tests/fixtures/phasing/` matrix before merging.**

```bash
# Run Python unit tests (dev machine)
python3 -m pytest tests/unit/test_pb_apt_evaluator.py -v

# Run reporter Bash tests (dev machine)
bash tests/unit/test_pb_patch_reporter.sh

# Run login-check Bash tests (dev machine)
bash tests/unit/test_login_compliance.sh

# Verify --dry-run stdout is clean JSON (no log line contamination)
sudo python3 src/pb-apt-evaluator.py --dry-run 2>/dev/null | python3 -m json.tool >/dev/null \
  && echo PASS || echo FAIL
```

The phasing fixture matrix is:

| Fixture | State | Expected behaviour |
|---------|-------|--------------------|
| `state-0pct-not-yet-phased.txt` | 0% rollout; not upgradable | Package skipped (is_upgradable == False) |
| `state-mid-rollout-50pct.txt` | 50% rollout; (phased 50%) tag present | Package excluded (phasing_applied == True) |
| `state-100pct-tag-absent.txt` | **100% rollout; tag purged from metadata** | **Package INCLUDED (phasing_applied == False; rollout complete)** |
| `state-non-phased.txt` | Normal update; no phasing involvement | Package included |

**The `state-100pct-tag-absent.txt` fixture is the critical one.** It is the state
that defeated all five v3.x phasing patches (KFC #1–#4). All subsequent phasing
changes must demonstrate they do not re-introduce a false exclusion in this state.

Adding a new fixture is encouraged. Removing a fixture or skipping it requires
explicit justification in the commit message and approval from the maintainer.

### 2.1 Pre-merge production parity check

For any change to the evaluator path, before merging:

```bash
# 1. Dry-run against live apt state on the deployment host
sudo python3 pb-apt-evaluator.py --mode check --dry-run | python3 -m json.tool

# 2. Confirm: all packages present before change are present after change
#    (unless the diff is the intentional change)
# 3. Confirm: no phased package has moved from excluded to included without
#    a fixture covering the new behaviour (or vice versa)
```

This is a manual gate. It cannot be automated without production credentials in CI.
Given the deployment cadence (rare, deliberate) and the cost of regression, the
manual gate is sufficient.

---

## 3. KFC — Known Failure Catalog

Recurring failure patterns are numbered, documented, and used as a pre-merge
regression checklist. When a new failure is observed in production, file a new
KFC entry, add a fixture reproducing it, and require all subsequent changes to
the affected path to pass the new fixture.

Format: `KFC #N — <short description>`

---

### KFC #1 — `v3.10.0`: Phased package filter case-sensitive

**Observed:** v3.10.0 introduced a filter for `[phased N%]` text in
`apt-get dist-upgrade -s` output. Filter was case-sensitive. APT emitted the
tag in lowercase on some Ubuntu mirror configs, bypassing the filter.

**Failure mode:** Phased package appeared as genuinely pending → false-positive
alert email.

**Fix applied at the time:** v3.10.15 — case-insensitive filter.

**Root cause:** Text scraping of simulation output (see Flaw 1 in design §1).

**v4.2 mitigation:** `DepCache.phasing_applied()` is a boolean predicate;
case is irrelevant. Fixture `state-mid-rollout-50pct.txt` covers mid-rollout.

---

### KFC #2 — `v3.10.15`: 100% rollout case not handled

**Observed:** When a phased package reached 100% rollout, apt purged the
`(phased N%)` tag from package metadata. The v3.10.15 filter, which looked for
the tag, found nothing and therefore did not exclude the package. The package
appeared as genuinely pending, producing a false-positive alert.

**Failure mode:** 100%-rollout phased package → false-positive alert email.

**Affected versions:** v3.10.0 through v3.10.14 (inclusive).

**Root cause:** Text scraping cannot distinguish a 100%-rollout package from a
genuinely pending package when both exhibit no phased tag in `dist-upgrade -s`
output.

**v4.2 mitigation:** `DepCache.phasing_applied()` returns False for a 100%-rollout
package (correctly; the host IS included in the rollout). The evaluator includes
the package (correct — it will genuinely install). No text scraping involved.

**Critical fixture:** `state-100pct-tag-absent.txt`. This fixture must PASS
(package included, not excluded) for any phasing-detection change.

---

### KFC #3 — `v3.10.16`: `PrivateTmp=true` caused phasing re-evaluation

**Observed:** The `PrivateTmp=true` systemd directive mounts a fresh tmpfs over
`/tmp` per service invocation. APT uses `/tmp` for phasing state during
`dist-upgrade -s` simulation. A fresh tmpfs caused APT to recompute the phase
bucket and emit a plain `Inst` line (without phased tag) for a package that
should have been held, producing a false-positive alert.

**Failure mode:** Fresh tmpfs → phasing state lost → package appeared ungated
→ false-positive.

**Fix applied at the time:** v3.10.16 removed `PrivateTmp=true`.

**v4.2 status:** `PrivateTmp=true` is retained pending validation (§6 of design,
F9). The `dist-upgrade -s` interaction is gone; the evaluator uses
`apt_pkg.Cache` / `DepCache` directly without `/tmp` state. If the integration
tests (§9.4) pass with `PrivateTmp=true`, the hardening directive is preserved.
Only remove if a specific `/tmp`-related failure is reproduced.

---

### KFC #4 — `v3.10.17`: Dual `dist-upgrade -s` invocation caused phasing races

**Observed:** `get_actual_upgrades()` was called independently inside both
`get_upgradable()` and `get_security_updates()`. APT re-evaluates phasing on
every `dist-upgrade -s` invocation. A package at a phase boundary (e.g.
`open-vm-tools` at exactly the phase threshold) could appear installable in one
call and deferred in the other. This produced a false-positive `upgrade_count`
and a spurious alert email.

**Failure mode:** Phase-boundary package → non-deterministic inclusion across
two invocations → mismatch between `upgrade_count` and `security_count` →
false-positive alert.

**Fix applied at the time:** v3.10.17 — compute `actual_upgrades` once in
`main()` and pass as argument to both functions.

**v4.2 mitigation:** `dist-upgrade -s` is not called anywhere in the v4.2
pipeline. `DepCache` is opened once per evaluator run; phasing is evaluated
once per package in a single cache scan. No re-evaluation races possible.

---

## 4. API Survey Requirement

**Applies to any design that depends on a third-party library API.**

Before concluding an API is absent or unavailable, the design must:

1. State the library name and version installed on the deployment host.
2. Link documentation matched to the installed version (not generic "latest").
3. Enumerate ALL documented binding layers. For `python3-apt`:
   - High-level: `apt.*` module (`apt.Package`, `apt.Version`, etc.)
   - Low-level: `apt_pkg.*` module (`apt_pkg.Cache`, `apt_pkg.DepCache`, etc.)
4. Provide verification evidence for each layer.
5. Search for the negation of any "API absent" claim before finalising.
   - Example: design claims "phasing API absent in python-apt" →
     search `"phasing_applied" python-apt apt_pkg` before accepting that claim.

**Rationale:** The v4.1 design concluded that `python3-apt` had no phasing API
based on inspection of the high-level `apt.Package` / `apt.Version` objects only.
`apt_pkg.DepCache.phasing_applied()` — part of the same package, same install —
was not checked. v4.2 caught this in pre-mortem (DEFECT-design-review-completeness.md).
The API survey requirement exists so this pattern cannot recur.

A design that concludes an API is absent without this survey is **incomplete** and
should be returned for survey before review proceeds.

---

## 5. Deployment

All deployment is performed via `install.sh` from the source root:

```bash
cd /opt/check-for-updates
sudo bash install.sh
```

`install.sh` runs all unit tests before copying any file. Deployment aborts
on the first test failure. Do not copy files manually — permissions and lock
file state are managed by the script.

### Manual pre-deployment gates (still required before running install.sh)

```bash
# 1. Verify phasing_applied() available on the deployment host
python3 -c "
import apt_pkg
apt_pkg.init()
c = apt_pkg.Cache(progress=None)
d = apt_pkg.DepCache(c)
assert hasattr(d, 'phasing_applied'), 'FAIL: phasing_applied() missing'
print('PASS')
"

# 2. Verify jq installed
command -v jq && jq --version

# 3. Dry-run evaluator parity check (evaluator changes only)
sudo python3 src/pb-apt-evaluator.py --mode check --dry-run | python3 -m json.tool
```

Unit tests are run automatically by `install.sh`; do not run them separately
on the production host.

---

## 6. Adding a New Test or KFC Entry

1. Observe failure in production or pre-mortem review.
2. Assign next available KFC number.
3. Add entry to §3 of this file with: version observed, failure mode,
   root cause, fix applied, v4.2 mitigation.
4. Add or update a fixture in `tests/fixtures/phasing/` if the failure is
   phasing-related.
5. Add a test case to the appropriate unit test file asserting the failure
   mode is NOT present.
6. Note the KFC number in the commit message for the fix.

---

## 7. Script Locations (production)

The libexec dir and state dir use the `pb-maintenance` namespace because all
writers (`pb-apt-evaluator.py`, `pb-patch-reporter.sh`, `check-for-updates.sh`)
run as root via systemd. `login-compliance-check.sh` lives in `/usr/local/bin`
because it runs as the operator user at login time — it only reads state files,
never writes them.

```
/usr/local/libexec/pb-maintenance/
  check-for-updates.sh             # orchestrator (root, systemd)
  pb-apt-evaluator.py              # evaluator   (root, systemd)
  pb-patch-reporter.sh             # reporter    (root, systemd)

/usr/local/bin/
  login-compliance-check.sh        # login banner check (operator user)

/var/lib/pb-maintenance/           # state directory (755 root:root, world-readable)
  patch-state.json                 # evaluator-owned
  patch-state.json.lock            # flock target (644 root:root)
  patch-suppression.json           # reporter-owned
  patch-suppression.json.lock      # flock target (644 root:root)
```

Permissions: state files `644 root:root`; directory `755 root:root`.
World-readable: required so `login-compliance-check.sh` can read state as any user.
Lock files `644 root:root`: writers use exclusive write-open flock (root only);
`login-compliance-check.sh` uses shared read-open flock (`exec 9<`) which only
requires read permission.
