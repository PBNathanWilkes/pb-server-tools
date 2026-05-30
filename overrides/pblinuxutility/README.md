# overrides/pblinuxutility — Host-specific systemd drop-in overrides

## Purpose

These drop-in files disable namespace-requiring sandbox directives for
the pb-maintenance services on **pblinuxutility**.  The base unit files
(under `check-for-updates/systemd/` and `security-hardening/systemd/`) are
correct and must not be modified — they work on PBWEBSRV03 and any future
host with full kernel namespace support.

## Problem

Both `pb-check-for-updates.service` and `pb-security-hardening-check.service`
(and their `-monthly` variants) fail with **exit code 226 (EXIT_NAMESPACE)**
on pblinuxutility.  Systemd exit 226 means the execution namespace requested
by the unit's sandboxing directives could not be set up before the process
started; the scripts never ran.

Root cause: pblinuxutility's kernel or container runtime does not permit
`CLONE_NEWNS` (mount namespaces) for user processes.  The directives that
require mount namespace support are:

| Directive | Requires |
|-----------|----------|
| `ProtectSystem=strict` | `CLONE_NEWNS` (re-mounts `/usr`, `/boot`, `/etc` read-only) |
| `PrivateTmp=true` | `CLONE_NEWNS` (private `/tmp` via tmpfs) |
| `ProtectKernelModules=true` | `CLONE_NEWNS` + `CAP_SYS_MODULE` restriction |
| `ProtectKernelTunables=true` | `CLONE_NEWNS` (read-only bind of `/proc/sys`, `/sys`) |

PBWEBSRV03 honours the same directives without issue, confirming this is
a host-capability difference, not a unit-file defect.

See DEV-GUIDE.md §6 KFC-R02 for the full failure catalog entry.

## Drop-ins installed

```
/etc/systemd/system/pb-check-for-updates.service.d/no-namespace.conf
/etc/systemd/system/pb-check-for-updates-monthly.service.d/no-namespace.conf
/etc/systemd/system/pb-security-hardening-check.service.d/no-namespace.conf
/etc/systemd/system/pb-security-hardening-check-monthly.service.d/no-namespace.conf
```

Each resets the four problematic directives to the empty string.
All other sandbox directives that do not require mount namespaces are
retained from the base unit:

- `NoNewPrivileges=true` — syscall-level, no namespace required
- `ProtectHome=true` — requires namespace; **retained in base but may also fail**
  on some restricted hosts. If exit 226 recurs after this fix, add
  `ProtectHome=` to the drop-ins as well (see Troubleshooting below).
- `LockPersonality=true` — `SECBIT_NO_SETUID_FIXUP`, no namespace required
- `RestrictRealtime=true` — seccomp, no namespace required
- `RestrictSUIDSGID=true` — seccomp, no namespace required
- `ProtectControlGroups=true` — cgroup namespace; fails on some containers
  (see Troubleshooting below)
- `RestrictNamespaces=true` — seccomp `clone()` filter, no namespace required

## Installation

The component `install.sh` scripts detect the hostname and install these
drop-ins automatically when run on pblinuxutility:

```bash
sudo bash /opt/server-tools/install.sh --only check-for-updates
sudo bash /opt/server-tools/install.sh --only security-hardening
```

To install manually (e.g. for a one-off fix before the next full install):

```bash
HOSTNAME="pblinuxutility"
REPO_ROOT="/opt/server-tools"   # or wherever the repo is checked out

for unit in \
  pb-check-for-updates.service \
  pb-check-for-updates-monthly.service \
  pb-security-hardening-check.service \
  pb-security-hardening-check-monthly.service
do
  dir="/etc/systemd/system/${unit}.d"
  mkdir -p "$dir"
  install -m 0644 -o root -g root \
    "${REPO_ROOT}/overrides/${HOSTNAME}/${unit}.d/no-namespace.conf" \
    "${dir}/no-namespace.conf"
done

systemctl daemon-reload
```

## Verification

After installation, confirm the effective unit no longer carries the
namespace-requiring directives:

```bash
systemctl cat pb-check-for-updates.service
systemctl cat pb-security-hardening-check.service
```

Both should show the drop-in appended with the four directives reset to
empty.  Then run one manually:

```bash
sudo systemctl start pb-check-for-updates.service
systemctl status pb-check-for-updates.service
journalctl -u pb-check-for-updates.service --no-pager -n 30
```

Expected: exit 0, journal shows normal check-for-updates output.

## Troubleshooting

If exit 226 persists after this fix, additional directives may be
unsupported on this host.  Run:

```bash
sudo journalctl -u pb-check-for-updates.service --no-pager -n 5
unshare --mount echo "mount ns OK"
unshare --uts echo "uts ns OK"
```

Common additions to the drop-in if the above fail:
- `ProtectHome=` — requires mount namespace; reset if needed
- `ProtectControlGroups=` — requires cgroup namespace; reset if needed

Do **not** add these to the source unit files — only to host-specific
drop-ins in this directory.
