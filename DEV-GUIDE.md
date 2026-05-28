# DEV-GUIDE.md — pb-server-tools Repository Guide

**Repo:** `PBNathanWilkes/pb-server-tools`
**Platform:** Ubuntu 24.04 Noble

---

## 1. Repository structure

```
pb-server-tools/
├── install.sh                  Top-level orchestrator
├── README.md
├── CHANGELOG.md
├── DEV-GUIDE.md                (this file)
│
├── check-for-updates/
│   ├── install.sh
│   ├── CHANGELOG.md
│   ├── DEV-GUIDE.md            Component-specific guide
│   ├── src/
│   ├── systemd/
│   └── tests/
│
├── security-hardening/
│   ├── install.sh
│   ├── src/
│   ├── systemd/
│   └── tests/unit/
│
└── login-compliance/
    ├── install.sh
    ├── src/
    └── tests/unit/
```

Each component is independently installable via its own `install.sh`.
The top-level `install.sh` installs system prerequisites then delegates
to each component in dependency order.

---

## 2. Pre-merge test gate

**Tests run on the development machine only. Do not run tests on the
production host.**

```bash
# All components
bash check-for-updates/tests/unit/test_pb_patch_reporter.sh
bash check-for-updates/tests/unit/test_login_compliance.sh
python3 -m pytest check-for-updates/tests/unit/test_pb_apt_evaluator.py -v
bash security-hardening/tests/unit/test_security_hardening.sh
bash login-compliance/tests/unit/test_login_compliance.sh
```

Any change to business logic **must** pass the full test suite before
merging. New behaviour requires new tests — a test count that decreases
across a PR is a defect.

---

## 3. Coding conventions

- `set -Eeuo pipefail` in all scripts.
- `readonly` for constants; declare at top of script.
- `local` for all function variables.
- No silent failures — use `die()` or `|| die "..."`.
- ShellCheck-clean. Run `shellcheck <script>` before committing.
- No hardcoded email addresses in test files.
- Mock binaries injected via PATH override; no production files touched
  in tests.

---

## 4. Changelog discipline

Every change requires:
- `CHANGELOG.md` update (SemVer) in the affected component **and** the
  top-level `CHANGELOG.md` if the repo version bumps.
- Commit message: `<component>: <type>(<scope>): <description>` — e.g.
  `security-hardening: fix(install): correct SYSTEMD_DEST path`
- Updated tests for any changed or added behaviour.
- Updated docs — any doc that contradicts current behaviour is a defect.

---

## 5. Versioning

Each component is versioned independently (see its own `CHANGELOG.md`).
The repo itself uses a separate version in the top-level `CHANGELOG.md`.

Version bump rules:
- PATCH: bug fixes, documentation corrections
- MINOR: new features, new checks, new test coverage
- MAJOR: breaking changes to deploy layout, state format, or systemd unit
  names

---

## 6. Known Failure Catalog (KFC)

Repo-level defects are tracked here. Component-level KFCs live in each
component's `DEV-GUIDE.md`.

| KFC # | Component | Description | Status |
|-------|-----------|-------------|--------|
| KFC-R01 | login-compliance | `test_login_compliance.sh` exists in both `check-for-updates/tests/unit/` (original) and `login-compliance/tests/unit/` (new). The two files must stay in sync when login-compliance logic changes. Consider a single canonical copy in a future refactor. | Open |

---

## 7. Release process

1. Run full test suite (§2) — zero failures required.
2. Update component `CHANGELOG.md` and bump version in script header.
3. Update top-level `CHANGELOG.md` if repo version bumps.
4. Commit: `git commit -m "<component>: <type>: <description>"`
5. For structural changes (new component, new deploy layout, new state
   machine): create a signed tag.
   ```
   git tag -a v1.1.0 -m "feat: add vlan-monitor component"
   git push origin v1.1.0
   ```
6. Deploy on PBWEBSRV03: `sudo bash install.sh` (or `--only <component>`).
7. Verify post-install checklist in README.md.
