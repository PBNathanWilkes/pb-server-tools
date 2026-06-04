# pb-server-tools

Ubuntu server management scripts for Premium Brands (PBH) infrastructure.
Consolidates patch monitoring, security posture checks, and login compliance
into a single repo with a unified install script.

**Platform:** Ubuntu 24.04 Noble (primary). Compatible with Ubuntu 22.04 LTS.

---

## Quick start (new server build)

The repo lives on WSL. Copy it to the prod box, then run the installer there.

```bash
# On WSL — copy to prod (adjust path and host as needed)
rsync -av --exclude='.git' /mnt/c/path/to/pb-server-tools/ pbwebsrv03:/opt/pb-server-tools/

# On the prod box
cd /opt/pb-server-tools
sudo bash install.sh
```

The top-level `install.sh` will:
1. Install all missing system packages (`apt-get`)
2. Create log directories (`/backup/patch-logs`, `/backup/security-logs`)
3. Run each component's test suite — aborts on any failure
4. Deploy all components to production paths
5. Register and start all systemd timers

To install a single component:
```bash
sudo bash install.sh --only security-hardening
```

---

## Components

### check-for-updates

Patch monitoring daemon. Evaluates pending APT updates using
`apt_pkg.DepCache` (no text scraping), stores state in JSON, and emails
HTML reports. Excludes phased updates. Confirms changes across runs
before alerting (seen_count ≥ 2 gate).

- **Script:** `/usr/local/libexec/pb-maintenance/check-for-updates.sh`
- **Timers:** `pb-check-for-updates.timer` (daily), `pb-check-for-updates-monthly.timer`
- **State:** `/var/lib/pb-maintenance/patch-state.json`
- **Logs:** `/backup/patch-logs/`
- **Version:** v4.2.23

### security-hardening

Security posture checks covering: ICMP rate limiting, UFW firewall,
SSH configuration, automatic updates, web server headers, TLS certificate
expiry, open ports, AppArmor, fail2ban, kernel sysctl parameters, password
policy, account security, file permissions, and sudo configuration.
Emails an HTML report with per-check status badges.

- **Script:** `/usr/local/libexec/pb-maintenance/security-hardening-check.sh`
- **Timers:** `pb-security-hardening-check.timer` (weekly), `pb-security-hardening-check-monthly.timer`
- **Logs:** `/backup/security-logs/`
- **Version:** v2.1.25

### login-compliance

Login-time banner check. Prints a one-line summary on every interactive
login:

```
[login-check] Email=✔ OK  Sent=✔ OK  Patches=✔ OK
```

Checks: email stack (mailx + msmtp), recent successful email send (msmtp
log), and pending APT updates. Patch result is cached (TTL 1 hour) and
invalidated when `check-for-updates` refreshes APT lists.

- **Script:** `/usr/local/bin/login-compliance-check.sh`
- **Activation:** `.bashrc` snippet (printed during install; added manually)
- **Version:** v0.9.0

### server-sanity

Read-only infrastructure sanity check. Verifies the health of all managed
services (email stack, Email DNS Monitor, Balena Monitor, SharePoint Export,
Server Tools) with colour-coded pass/fail/warn output. Runs in under 5 seconds.

When run with `--email-on-failure`, emails the full report to `EMAIL_PRIMARY`
(from `/etc/balena-monitor/config`) if any check fails.  The
`pb-server-sanity-check.timer` schedules this daily at 08:00 as an automated
watchdog.

- **Script:** `/usr/local/bin/server-sanity-check`
- **Timer:** `pb-server-sanity-check.timer` (daily 08:00)
- **Version:** v1.1.0

---

## Production layout

```
/usr/local/libexec/pb-maintenance/
  check-for-updates.sh          0750 root:root
  pb-apt-evaluator.py           0750 root:root
  pb-patch-reporter.sh          0750 root:root
  security-hardening-check.sh   0750 root:root

/usr/local/bin/
  login-compliance-check.sh     0755 root:root

/var/lib/pb-maintenance/
  patch-state.json              written by pb-apt-evaluator.py only
  patch-suppression.json        written by pb-patch-reporter.sh only
  patch-state.json.lock         0644 root:root
  patch-suppression.json.lock   0644 root:root

/etc/systemd/system/
  pb-check-for-updates.service/.timer
  pb-check-for-updates-monthly.service/.timer
  pb-security-hardening-check.service/.timer
  pb-security-hardening-check-monthly.service/.timer

/backup/patch-logs/             0750 root:root
/backup/security-logs/          0750 root:root
```

---

## Prerequisites (installed automatically)

| Package | Purpose |
|---|---|
| `jq` | JSON parsing in shell scripts |
| `msmtp` | SMTP relay (sendmail shim) |
| `s-nail` | Provides `mailx` command |
| `openssl` | TLS certificate inspection |
| `python3` | APT evaluator |
| `python3-apt` | Native apt_pkg bindings |
| `python3-pytest` | Python unit test runner |
| `ufw` | Firewall (checked by security-hardening) |
| `iproute2` | Provides `ss` (socket statistics) |

**msmtp must be configured separately** before the email-sending components
will work. See `/etc/msmtprc` — the scripts expect a system-wide default
account. Test with:
```bash
echo "test" | msmtp --debug nathan.wilkes@pbhcorp.com
```

---

## Post-install verification

```bash
# Confirm timers are scheduled
systemctl list-timers --all --no-pager | grep pb-

# Validate patch monitor (sends email)
sudo /usr/local/libexec/pb-maintenance/check-for-updates.sh --validate

# Validate security hardening (sends email)
sudo /usr/local/libexec/pb-maintenance/security-hardening-check.sh --validate

# Test login check manually
/usr/local/bin/login-compliance-check.sh
```

---

## Development

See [DEV-GUIDE.md](DEV-GUIDE.md) for conventions, test gates, and release
process. Each component also has its own `DEV-GUIDE.md` for component-specific
guidance.

**Tests run on the development machine only. Never run tests on the production host.**

```bash
# Run all component tests without deploying
bash check-for-updates/tests/unit/test_pb_patch_reporter.sh
bash check-for-updates/tests/unit/test_login_compliance.sh
python3 -m pytest check-for-updates/tests/unit/test_pb_apt_evaluator.py -v
bash security-hardening/tests/unit/test_security_hardening.sh
bash login-compliance/tests/unit/test_login_compliance.sh
```
