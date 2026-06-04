# SESSION PROTOCOL — pb-server-tools

## Session Open

Before proceeding with any task: acknowledge this protocol and restate
the session's task scope in one sentence.

---

## Communication

- Be succinct. No preamble, no summaries of what you just did, no filler.
- Lead with evidence. Assertions require proof (log output, code path,
  test result).
- Flag uncertainty explicitly. Never guess silently.

---

## Before Any Code Change

1. **Review CHANGELOG** — understand prior decisions and context for
   the area being changed. Current versions:
   - Repo: v1.0.21
   - `check-for-updates`: v4.2.23
   - `security-hardening`: v2.1.15
   - `login-compliance`: v0.9.0

2. **KFC Check** — reason through each applicable KFC entry and
   explicitly state whether this change is implicated and why.
   Do this before writing code. Do not wait to be asked.

   **Repo-level KFCs** (`DEV-GUIDE.md` §6):
   - KFC-R01: `login-compliance` test/source duplication — canonical
     copies now in `login-compliance/` only.

   **`check-for-updates` KFCs** (`check-for-updates/DEV-GUIDE.md` §3):
   - KFC #1: Phased package filter was case-sensitive (v3.10.0).
   - KFC #2: 100%-rollout packages not handled — phased tag absent
     from metadata but package is genuinely pending.
   - KFC #3: `PrivateTmp=true` caused phasing re-evaluation via fresh
     tmpfs (v3.10.16).
   - KFC #4: Dual `dist-upgrade -s` invocations caused phasing races
     (v3.10.17).
   - KFC #5: `_check_lts()` swallowed all silent-failure detail, making
     the Canonical-gate / misconfig / network cases indistinguishable
     in the log (v4.2.16–v4.2.21; fixed v4.2.22).
   - KFC #6: reporter could silently drop or never raise alerts — TERM/INT
     trap exited 0, `prune_suppressions()` reset the escalation clock on a
     one-run package absence, `seen_count` advanced on stale lists, and a
     malformed timestamp faked staleness / forced escalation (fixed v4.2.23).

3. **API Survey** — if a change depends on a third-party library API,
   verify all binding layers before concluding an API is absent
   (see `check-for-updates/DEV-GUIDE.md` §4). State the installed
   version, link version-matched docs, and enumerate all layers.

4. **State your reasoning** — one or two sentences on approach before
   implementation, especially if multiple paths exist.

---

## Code Output

- Always present **whole files**. No partial diffs, no
  `# ... rest unchanged ...` stubs.
- All changes require:
  - Updated **inline docs** (comments, function headers)
  - Updated **CHANGELOG** entry in the affected component **and** the
    top-level `CHANGELOG.md` if the repo version bumps. Every file
    modified in the session — including tests and docs — must be listed
    in the files-changed list.
  - **Commit message** format: `<component>: <type>(<scope>): <description>`
    e.g. `check-for-updates: fix(evaluator): drop -f flag from do-release-upgrade`
  - **Tag message** if the change is structural (new component, new
    deploy layout, new state machine, new systemd unit namespace —
    not fixes or feature additions)
- Updated or new **unit tests** for any logic change. A test count
  that decreases across a change is a defect.
- **ShellCheck** must pass on all modified Bash scripts before commit.
- **Documentation freshness is mandatory.** Scan all docs —
  `DEV-GUIDE.md`, `check-for-updates/DEV-GUIDE.md`, `CHANGELOG.md`
  (all components), `README.md` — and update every stale reference.
  A doc that contradicts current behaviour is a defect.
  - `README.md` version strings for each component must match their
    respective `CHANGELOG.md`.
  - `check-for-updates/DEV-GUIDE.md` §1 **Current version** must match
    the component `CHANGELOG.md`.
- **New KFC entries are mandatory.** If a novel failure class is
  identified, propose a new KFC entry immediately, numbered
  sequentially from the last entry in the relevant catalog (repo-level
  or component-level). Include: version observed, failure mode, root
  cause, fix applied, current-version mitigation. Add a fixture if
  phasing-related. Do not wait to be asked.

---

## Out-of-Scope Issues

If any out-of-scope problem is uncovered, immediately produce a
standalone `OPEN-ITEM-<slug>.md` file containing:

- **Problem statement** — what was observed, where, and why it matters
- **Evidence** — relevant code paths, log output, or test results
- **Suspected cause** — current hypothesis, clearly labelled as such
- **Affected components** — files, functions, or pipeline steps
- **Re-investigation note** — the then-current codebase must be
  reviewed before solving; intervening changes may alter the problem
  or solution space. This is a defect statement, not a prompt.

One file per issue. Do not wait to be asked.

---

## QA Steps

After presenting code, always provide:

1. The specific **test commands** to validate the change, drawn from
   the pre-merge test gate in `DEV-GUIDE.md` §2. For evaluator changes,
   include the `--dry-run` parity check against the production host
   (§2.1 of `check-for-updates/DEV-GUIDE.md`).
2. Any **edge cases or regression risks** introduced or relevant.
3. If a KFC pattern was implicated, confirm how it was **avoided or
   mitigated**.
4. For evaluator changes that touch phasing detection: confirm all four
   phasing fixtures pass, with explicit attention to
   `state-100pct-tag-absent.txt` (KFC #2 sentinel).

---

## Project-Specific Reminders

**Components and their test files:**

| Component | Test files |
|---|---|
| `check-for-updates` | `test_pb_apt_evaluator.py`, `test_pb_patch_reporter.sh`, `test_login_compliance.sh` (legacy) |
| `security-hardening` | `test_security_hardening.sh` |
| `login-compliance` | `login-compliance/tests/unit/test_login_compliance.sh` (canonical) |

**Tests run on the development machine only. Never run tests on the
production host.**

**State-file ownership is invariant:**
- `patch-state.json` → written by `pb-apt-evaluator.py` only
- `patch-suppression.json` → written by `pb-patch-reporter.sh` only

Any change that crosses this boundary is a defect regardless of
apparent correctness.

**SemVer:** Patch for fixes, minor for new behaviour, major for
breaking changes to deploy layout, state format, or systemd unit
names. Current version for each component is authoritative in its own
`CHANGELOG.md` — never infer from memory or from `README.md`.

**Production notes**
Codebase deployed to `/opt/server-tools/` If direct testing is required, always use full paths for QA.

Code is installed by `sudo /opt/server-tools/install.sh`. not by manual cp or rsync. 