#!/usr/bin/env python3
# check-for-updates — APT package evaluation component for check-for-updates v4.2
#
# Writes /var/lib/pb-maintenance/patch-state.json (schema 2) atomically.
# Phasing detection: apt_pkg.DepCache.phasing_applied() (native, in-process).
# Fallback: apt-cache policy subprocess (only if phasing_applied() raises).
#
# v4.2.23 — Fix: _evaluate() no longer advances seen_count (the cross-run
#            confirmation clock) when apt-get update failed and the package
#            lists are stale.  A candidate observed only in stale data could
#            previously graduate to "confirmed" (seen_count >= 2) on evidence
#            the evaluator itself flagged as untrustworthy, and a security
#            update released during the apt-failure window was effectively
#            invisible to the confirmation gate.  Candidates now carry a
#            ``stale`` flag.  See KFC #6.
# v4.2.22 — Fix: _check_lts() now logs the tool's exit code and stderr when no
#            upgrade string is found, so the operator can distinguish three silent
#            failure modes: (a) Canonical upgrade path not yet open in
#            meta-release-lts (normal between an LTS initial release and .1);
#            (b) /etc/update-manager/release-upgrades absent or Prompt=never;
#            (c) changelogs.ubuntu.com unreachable.  Exception path logs the
#            exception rather than swallowing it silently.  See KFC #5.
# v4.2.16 — Fix: _check_lts() now calls `do-release-upgrade -c` without
#            `-f DistUpgradeViewNonInteractive`. On Ubuntu 24.04+ the -f flag
#            suppresses all output, causing lts_upgrade_available to always be
#            false. Removed defunct check-new-release/check-new-release-gtk
#            paths (no longer present on Ubuntu 24.04+). Added LANG/LC_ALL=C
#            to prevent localised output from breaking the version regex.
# v4.2.12
# v4.2.11
#
# Usage:
#   pb-apt-evaluator.py [--mode check|validate|monthly] [--dry-run]
#
# Exit codes:
#   0 — success (state file written, or --dry-run JSON to stdout)
#   1 — infrastructure failure (flock timeout, apt lock timeout, cache open failure,
#       state file write failure); caller must not proceed to reporter

import argparse
import fcntl
import json
import logging
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VERSION = "4.2.23"
SCRIPT_NAME = os.path.basename(__file__)

STATE_DIR      = "/var/lib/pb-maintenance"
STATE_FILE     = os.path.join(STATE_DIR, "patch-state.json")
STATE_LOCK     = os.path.join(STATE_DIR, "patch-state.json.lock")
APT_STAMP      = "/var/lib/apt/lists/pb-last-update"
LOG_DIR        = "/backup/patch-logs"
SCHEMA_VERSION = 2

APT_LOCK_TIMEOUT_S       = 300   # 5 min total across all lock probes
APT_LOCK_RETRY_S         = 30
STATE_FLOCK_TIMEOUT_S    = 30
APT_GET_UPDATE_TIMEOUT_S = 180

# Both locks that apt-get update acquires; must be free before we invoke it.
# /var/lib/apt/lists/lock is held by apt-daily.service during its update pass,
# which fires in a randomised window around 06:00 and 18:00 (UTC).  Checking
# only dpkg/lock-frontend (as in ≤4.2.10) allowed a TOCTOU window where the
# lists lock was still held, causing apt-get update to exit non-zero and
# setting apt_update_failed=true in the state file.
APT_LOCK_PATHS = (
    "/var/lib/dpkg/lock-frontend",
    "/var/lib/apt/lists/lock",
)

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------
def _setup_logging() -> logging.Logger:
    fmt = "[%(asctime)s] %(message)s"
    datefmt = "%Y-%m-%d %H:%M:%S"
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(logging.Formatter(fmt, datefmt))
    logger = logging.getLogger(SCRIPT_NAME)
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    return logger

log = _setup_logging()


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def _tty() -> bool:
    return sys.stdout.isatty()


def _log_info(msg: str) -> None:
    log.info(msg)


# ---------------------------------------------------------------------------
# File-path display (TTY only)
# ---------------------------------------------------------------------------
def _display_paths(log_file: str) -> None:
    if not _tty():
        return
    lines = [
        f"Script        : {SCRIPT_NAME} v{VERSION}",
        f"State file    : {STATE_FILE}",
        f"apt stamp     : {APT_STAMP}",
        f"Log file      : {log_file}",
    ]
    for line in lines:
        _log_info(line)


# ---------------------------------------------------------------------------
# Log file initialisation
# ---------------------------------------------------------------------------
def _open_log_file() -> str:
    """Open or create a date-stamped log file. Returns the path."""
    import socket
    hostname = socket.getfqdn()
    tag = datetime.now().strftime("%Y%m%d_%s")
    basename = f"{tag}-{hostname}-update-patch.log"

    for d in [LOG_DIR, "/tmp"]:
        try:
            os.makedirs(d, exist_ok=True)
            path = os.path.join(d, basename)
            # Append-open to set up file handler
            fh = logging.FileHandler(path, mode="a")
            fh.setFormatter(logging.Formatter(
                "[%(asctime)s] %(message)s", "%Y-%m-%d %H:%M:%S"
            ))
            log.addHandler(fh)
            return path
        except OSError:
            continue
    return "/tmp/" + basename


# ---------------------------------------------------------------------------
# State-file flock
# ---------------------------------------------------------------------------
class StateLock:
    """Exclusive flock on STATE_LOCK, with timeout."""

    def __init__(self, timeout: int = STATE_FLOCK_TIMEOUT_S, shared: bool = False):
        self._timeout = timeout
        self._shared = shared
        self._fh = None

    def __enter__(self) -> "StateLock":
        os.makedirs(STATE_DIR, exist_ok=True)
        self._fh = open(STATE_LOCK, "w")
        mode = fcntl.LOCK_SH if self._shared else fcntl.LOCK_EX
        deadline = time.monotonic() + self._timeout
        while True:
            try:
                fcntl.flock(self._fh, mode | fcntl.LOCK_NB)
                return self
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    self._fh.close()
                    raise TimeoutError(
                        f"Could not acquire state-file flock within {self._timeout}s"
                    )
                time.sleep(1)

    def __exit__(self, *_) -> None:
        if self._fh:
            fcntl.flock(self._fh, fcntl.LOCK_UN)
            self._fh.close()
            self._fh = None


# ---------------------------------------------------------------------------
# APT lock acquisition — hold-through-update design
# ---------------------------------------------------------------------------
def _acquire_apt_locks() -> list:
    """
    Acquire and HOLD exclusive flocks on all APT_LOCK_PATHS.

    Returns the list of open file handles.  The caller must pass these to
    _run_apt_update() via pass_fds and release them with _release_apt_locks()
    in a finally block AFTER apt-get update exits.

    Design rationale — why we hold instead of check-and-release:
      Previous versions (≤4.2.11) acquired each lock and immediately released
      it before calling apt-get update.  This is a TOCTOU race: apt-daily.service
      can acquire /var/lib/apt/lists/lock in the gap between our release and
      apt-get update's re-acquisition, causing apt-get update to exit non-zero
      and setting apt_update_failed=true in the state file.

      By keeping the file handles open across the subprocess.run() call and
      passing them via pass_fds, the kernel keeps the flocks live until apt-get
      update exits.  apt-get update acquires the locks itself on the same open
      file descriptions (same-process upgrade, no deadlock); external processes
      (apt-daily) remain blocked for the duration.

    Raises TimeoutError if any lock cannot be acquired within APT_LOCK_TIMEOUT_S.
    """
    deadline = time.monotonic() + APT_LOCK_TIMEOUT_S
    held: list = []
    try:
        for lock_path in APT_LOCK_PATHS:
            while True:
                try:
                    fh = open(lock_path, "w")
                    fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    held.append(fh)
                    break  # this lock acquired; move to next
                except (BlockingIOError, OSError):
                    fh.close()
                    if time.monotonic() >= deadline:
                        raise TimeoutError(
                            f"APT lock {lock_path} held for > {APT_LOCK_TIMEOUT_S}s; aborting"
                        )
                    _log_info(
                        f"APT lock {lock_path} held by another process; "
                        f"retrying in {APT_LOCK_RETRY_S}s ..."
                    )
                    time.sleep(APT_LOCK_RETRY_S)
    except Exception:
        # Release any already-acquired locks before propagating
        for fh in held:
            try:
                fcntl.flock(fh, fcntl.LOCK_UN)
                fh.close()
            except OSError:
                pass
        raise
    return held


def _release_apt_locks(handles: list) -> None:
    """Release all flock handles returned by _acquire_apt_locks()."""
    for fh in handles:
        try:
            fcntl.flock(fh, fcntl.LOCK_UN)
            fh.close()
        except OSError:
            pass


# ---------------------------------------------------------------------------
# apt-get update
# ---------------------------------------------------------------------------
def _run_apt_update(lock_handles: list) -> bool:
    """
    Run apt-get update. Returns True on success, False on failure.
    Never raises.

    lock_handles — open file handles returned by _acquire_apt_locks().
    Passed to subprocess via pass_fds so the kernel keeps the flocks
    live for the duration of the apt-get update child process, closing
    the TOCTOU window between our lock check and apt-get update's own
    lock acquisition.
    """
    pass_fds = tuple(fh.fileno() for fh in lock_handles)
    env = dict(os.environ, DEBIAN_FRONTEND="noninteractive")
    try:
        result = subprocess.run(
            ["apt-get", "update"],
            capture_output=True,
            text=True,
            timeout=APT_GET_UPDATE_TIMEOUT_S,
            env=env,
            pass_fds=pass_fds,
        )
        if result.returncode == 0:
            _log_info("apt-get update completed successfully")
            return True
        _log_info(
            f"apt-get update exited {result.returncode}: "
            f"{result.stderr.strip()[:200]}"
        )
        return False
    except subprocess.TimeoutExpired:
        _log_info(f"apt-get update timed out after {APT_GET_UPDATE_TIMEOUT_S}s")
        return False
    except Exception as exc:  # pragma: no cover
        _log_info(f"apt-get update failed unexpectedly: {exc}")
        return False


def _write_apt_stamp() -> None:
    try:
        with open(APT_STAMP, "w"):
            pass
        os.chmod(APT_STAMP, 0o644)
        _log_info(f"apt stamp written: {APT_STAMP}")
    except OSError as exc:
        _log_info(f"WARN: could not write apt stamp {APT_STAMP}: {exc}")


# ---------------------------------------------------------------------------
# Phasing fallback — apt-cache policy (§4.1.1)
# ---------------------------------------------------------------------------
_POLICY_CACHE: dict[str, str] = {}


def _is_phased_via_policy_fallback(pkg_name: str, candidate_ver: str) -> bool:
    """
    Fallback used only when DepCache.phasing_applied() raises for a specific package.
    Uses anchored whitespace matching on the Version table block to avoid substring
    collisions (F8).
    """
    if not candidate_ver or candidate_ver == "(none)":
        return False

    if pkg_name not in _POLICY_CACHE:
        try:
            result = subprocess.run(
                ["apt-cache", "policy", pkg_name],
                capture_output=True,
                text=True,
                timeout=10,
            )
            _POLICY_CACHE[pkg_name] = result.stdout if result.returncode == 0 else ""
        except Exception:
            _POLICY_CACHE[pkg_name] = ""

    policy_output = _POLICY_CACHE[pkg_name]
    if not policy_output:
        # Treat unparseable/empty policy output as "not phased" so the package
        # is still surfaced to the operator rather than silently excluded.
        # (Returning False here means "not phased" → the caller keeps it.)
        return False

    pattern = re.compile(
        r"(?:^|\s)" + re.escape(candidate_ver) + r"(?:\s|$)"
    )
    in_version_table = False
    for line in policy_output.splitlines():
        if line.strip().startswith("Version table:"):
            in_version_table = True
            continue
        if not in_version_table:
            continue
        if pattern.search(line) and "(phased" in line.lower():
            return True
    return False


# ---------------------------------------------------------------------------
# Security origin detection (§4.1 — suffix match, F14)
# ---------------------------------------------------------------------------
def _is_security_update(depcache, pkg) -> bool:  # type: ignore[no-untyped-def]
    """
    Returns True if the candidate version's file list contains an archive
    matching '*-security' or bare 'security'.  Suffix match handles future
    Ubuntu release names without code changes (F14).
    """
    try:
        cand = depcache.get_candidate_ver(pkg)
        if cand is None:
            return False
        for pf, _idx in cand.file_list:
            archive = getattr(pf, "archive", "") or ""
            if archive == "security" or archive.endswith("-security"):
                return True
    except Exception:
        pass
    return False


# ---------------------------------------------------------------------------
# Prior-state merge helpers
# ---------------------------------------------------------------------------
def _load_prior_state(path: str) -> dict:
    """Read prior patch-state.json. Returns {} on absence or parse failure."""
    try:
        with open(path) as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return {}
        return data
    except (OSError, json.JSONDecodeError):
        return {}


def _build_prior_index(prior: dict) -> dict[tuple[str, str], dict]:
    """
    Build a lookup dict keyed on (name, architecture) from prior state.
    """
    index: dict[tuple[str, str], dict] = {}
    for p in prior.get("packages", []):
        if isinstance(p, dict) and "name" in p and "architecture" in p:
            index[(p["name"], p["architecture"])] = p
    return index


# ---------------------------------------------------------------------------
# Core evaluation
# ---------------------------------------------------------------------------
def _evaluate(prior_state: dict, apt_update_ok: bool = True) -> list:
    """
    Open apt_pkg.Cache + DepCache, enumerate upgradable non-phased candidates,
    merge with prior state, and return the list of candidate dicts (NOT the full
    state dict — the caller assembles that).

    apt_update_ok — False when the preceding apt-get update failed and the
    package lists are stale.  In that case the cross-run confirmation clock
    (seen_count) is NOT advanced: a candidate seen only in stale data must not
    graduate to "confirmed" (seen_count >= 2) on evidence the evaluator itself
    declared untrustworthy.  seen_count is held at its prior value (KFC #6).
    A per-candidate ``stale`` flag records that this observation came from
    unrefreshed lists.
    """
    import apt_pkg  # type: ignore[import]

    apt_pkg.init_config()
    apt_pkg.init_system()
    cache = apt_pkg.Cache(progress=None)
    depcache = apt_pkg.DepCache(cache)

    # Verify phasing_applied() is available (pre-deployment gate §9.4 step 1)
    if not hasattr(depcache, "phasing_applied"):
        raise RuntimeError(
            "apt_pkg.DepCache.phasing_applied() not available on this host. "
            "Run deployment verification step 1 (§9.4) and investigate before deploying."
        )

    _log_info("apt_pkg.Cache opened; scanning packages")

    now = _now_utc()
    now_iso = _iso(now)
    prior_index = _build_prior_index(prior_state)

    candidates = []
    total_scanned = 0

    for pkg in cache.packages:
        total_scanned += 1
        try:
            if not depcache.is_upgradable(pkg):
                continue
            cand_ver = depcache.get_candidate_ver(pkg)
            if cand_ver is None:
                continue
            if depcache.marked_keep(pkg):
                continue

            # Phasing detection — primary path
            try:
                if depcache.phasing_applied(pkg):
                    continue
            except Exception as exc:
                _log_info(
                    f"WARN: phasing_applied() raised for {pkg.name}: {exc}; "
                    "consulting fallback"
                )
                if _is_phased_via_policy_fallback(pkg.name, cand_ver.ver_str):
                    continue

            arch = pkg.architecture
            installed_ver = (
                pkg.current_ver.ver_str if pkg.current_ver else "(none)"
            )
            candidate_ver = cand_ver.ver_str
            is_sec = _is_security_update(depcache, pkg)

            # Determine origin string
            origin = ""
            try:
                for pf, _idx in cand_ver.file_list:
                    label = getattr(pf, "label", "") or ""
                    archive = getattr(pf, "archive", "") or ""
                    if label and archive:
                        origin = f"{label}:{archive}"
                        break
                    elif archive:
                        origin = archive
            except Exception:
                pass

            # Prior-state merge (F7 — preserve first_seen / seen_count)
            prior_entry = prior_index.get((pkg.name, arch))
            if (
                prior_entry is not None
                and prior_entry.get("candidate_version") == candidate_ver
            ):
                first_seen = prior_entry.get("first_seen", now_iso)
                prior_seen = prior_entry.get("seen_count", 0)
                # Only advance the confirmation clock on a fresh observation.
                # Stale lists (apt-get update failed) must not graduate a
                # candidate to confirmed status (KFC #6).
                seen_count = prior_seen + 1 if apt_update_ok else prior_seen
            else:
                first_seen = now_iso
                # A candidate appearing for the first time in stale data starts
                # at 0, not 1: we have no fresh evidence it is genuinely pending.
                seen_count = 1 if apt_update_ok else 0

            candidates.append(
                {
                    "name": pkg.name,
                    "architecture": arch,
                    "installed_version": installed_ver,
                    "candidate_version": candidate_ver,
                    "is_security": is_sec,
                    "origin": origin,
                    "first_seen": first_seen,
                    "last_seen": now_iso,
                    "seen_count": seen_count,
                    "stale": not apt_update_ok,
                }
            )
        except Exception as exc:
            _log_info(f"WARN: skipped {getattr(pkg, 'name', '?')}: {exc}")

    _log_info(
        f"Scanned {total_scanned} packages; "
        f"{len(candidates)} non-phased candidate(s) found"
    )
    return candidates


# ---------------------------------------------------------------------------
# Reboot + LTS checks
# ---------------------------------------------------------------------------
def _check_reboot() -> tuple[bool, list[str]]:
    required = os.path.exists("/var/run/reboot-required")
    pkgs: list[str] = []
    if required:
        try:
            with open("/var/run/reboot-required.pkgs") as f:
                pkgs = [line.strip() for line in f if line.strip()]
        except OSError:
            pass
    return required, pkgs


def _check_lts() -> tuple[bool, str | None]:
    """Returns (lts_available, version_string_or_None).

    Uses ``do-release-upgrade -c`` without ``-f DistUpgradeViewNonInteractive``.

    On Ubuntu 24.04+, ``check-new-release`` and ``check-new-release-gtk`` no
    longer exist; they were removed when ubuntu-release-upgrader was refactored.
    The ``-f DistUpgradeViewNonInteractive`` flag suppresses all stdout/stderr
    output on Ubuntu 24.04+ (do-release-upgrade exits 1 silently), so the
    regex below never matched and ``lts_upgrade_available`` was always ``false``.

    ``do-release-upgrade -c`` (check-only, no ``-f``) prints
    ``New release '26.04 LTS' available.`` on stdout when an LTS upgrade
    exists and the ``/etc/update-manager/release-upgrades`` ``Prompt`` key is
    set to ``lts`` (Ubuntu Server default).  It exits 0 on a hit and 1 with no
    output when no upgrade is available.

    LANG/LC_ALL=C prevents localised output from breaking the regex.

    When no upgrade string is found, the tool's stderr and exit code are logged
    at INFO level so the operator can distinguish three silent-failure modes:
      (a) Canonical has not yet opened the upgrade path in meta-release-lts
          (normal between an LTS initial release and its .1 point release);
      (b) /etc/update-manager/release-upgrades absent or Prompt=never;
      (c) changelogs.ubuntu.com unreachable.
    """
    result = None
    try:
        result = subprocess.run(
            ["do-release-upgrade", "-c"],
            capture_output=True,
            text=True,
            timeout=45,
            stdin=subprocess.DEVNULL,
            env=dict(os.environ, LANG="C", LC_ALL="C"),
        )
        output = result.stdout + result.stderr
    except Exception as exc:
        _log_info(f"WARN: LTS check: do-release-upgrade raised: {exc}")
        return False, None

    m = re.search(r"New release '?(\d+\.\d+)", output)
    if m:
        return True, m.group(1)

    # No upgrade string found.  Log the tool's exit code and any stderr so the
    # operator can distinguish a Canonical-side gate (upgrade path not yet open
    # in meta-release-lts) from a local misconfiguration or network failure.
    detail = result.stderr.strip()[:200] if result.stderr.strip() else "(no output)"
    _log_info(
        f"LTS check: no upgrade available "
        f"(do-release-upgrade -c exited {result.returncode}; {detail})"
    )
    return False, None


# ---------------------------------------------------------------------------
# Atomic state-file write
# ---------------------------------------------------------------------------
def _write_state(state: dict, path: str) -> None:
    """Write state to path atomically (tmp + rename)."""
    tmp = path + ".tmp"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)
        f.write("\n")
    os.rename(tmp, path)
    _log_info(f"State file written: {path}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog=SCRIPT_NAME,
        description="APT package evaluator — writes patch-state.json",
    )
    parser.add_argument(
        "--mode",
        choices=["check", "validate", "monthly"],
        default="check",
        help="Execution mode (all modes have identical evaluator behaviour in v4.2)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Evaluate and print JSON to stdout; do not write state file or apt stamp",
    )
    args = parser.parse_args(argv)

    log_file = _open_log_file()
    _display_paths(log_file)
    _log_info(f"Mode: {args.mode} {'[dry-run]' if args.dry_run else ''}")

    if os.geteuid() != 0:
        _log_info("ERROR: must run as root (needed for apt-get update and apt_pkg.Cache)")
        return 1

    # --- Acquire state-file flock ---
    flock_mode_shared = args.dry_run  # dry-run holds shared lock for prior-state read
    try:
        state_lock_cm = StateLock(
            timeout=STATE_FLOCK_TIMEOUT_S, shared=flock_mode_shared
        )
        with state_lock_cm:
            # --- Read prior state for first_seen / seen_count merge ---
            prior_state = _load_prior_state(STATE_FILE)
            prior_schema = prior_state.get("schema")
            if prior_state and prior_schema != SCHEMA_VERSION:
                _log_info(
                    f"Prior state file has schema {prior_schema}; "
                    "resetting (schema mismatch)"
                )
                prior_state = {}

            if not args.dry_run:
                # --- Acquire and HOLD APT locks through apt-get update ---
                try:
                    apt_lock_handles = _acquire_apt_locks()
                except TimeoutError as exc:
                    _log_info(f"ERROR: {exc}")
                    return 1

                # --- apt-get update (locks held via pass_fds) ---
                try:
                    apt_update_ok = _run_apt_update(apt_lock_handles)
                finally:
                    _release_apt_locks(apt_lock_handles)
                if apt_update_ok:
                    _write_apt_stamp()
                else:
                    _log_info(
                        "WARN: apt-get update failed; proceeding with stale lists. "
                        "apt_update_failed will be set in state file."
                    )
            else:
                # dry-run: skip apt-get update; rely on existing package lists
                apt_update_ok = True
                _log_info("dry-run: skipping apt-get update")

            # --- Open apt cache + evaluate ---
            try:
                candidates = _evaluate(prior_state, apt_update_ok=apt_update_ok)
            except ImportError:
                _log_info(
                    "ERROR: python3-apt not available; install with: "
                    "apt install python3-apt"
                )
                return 1
            except RuntimeError as exc:
                _log_info(f"ERROR: {exc}")
                return 1

            # --- Reboot + LTS ---
            reboot_required, reboot_pkgs = _check_reboot()
            if reboot_required:
                _log_info(
                    f"Reboot required ({len(reboot_pkgs)} package(s))"
                )

            try:
                lts_available, lts_version = _check_lts()
            except Exception as exc:
                _log_info(f"WARN: LTS check failed: {exc}")
                lts_available, lts_version = False, None

            now_iso = _iso(_now_utc())
            state = {
                "schema": SCHEMA_VERSION,
                "evaluated_at": now_iso,
                "apt_updated_at": now_iso if apt_update_ok else None,
                "apt_update_failed": not apt_update_ok,
                "reboot_required": reboot_required,
                "reboot_packages": reboot_pkgs,
                "lts_upgrade_available": lts_available,
                "lts_upgrade_version": lts_version,
                "packages": candidates,
            }

            confirmed = [p for p in candidates if p["seen_count"] >= 2]
            unconfirmed = [p for p in candidates if p["seen_count"] < 2]
            _log_info(
                f"pb-apt-evaluator: {len(candidates)} candidate(s) found, "
                f"{len(confirmed)} confirmed pending (seen ≥2 runs), "
                f"{len(unconfirmed)} unconfirmed"
            )

            if args.dry_run:
                print(json.dumps(state, indent=2))
                return 0

            # --- Write state file (atomic) ---
            try:
                _write_state(state, STATE_FILE)
                os.chmod(STATE_FILE, 0o644)
            except OSError as exc:
                _log_info(f"ERROR: could not write state file {STATE_FILE}: {exc}")
                return 1

    except TimeoutError as exc:
        _log_info(f"ERROR: {exc}")
        return 1

    _log_info("pb-apt-evaluator complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
