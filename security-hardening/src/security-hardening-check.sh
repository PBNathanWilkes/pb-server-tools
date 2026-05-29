#!/usr/bin/env bash
# security-hardening-check.sh — Check security hardening status and email a report (HTML)
# Executed via systemd timers (cron no longer used). Requires: mailx (s-nail/bsd-mailx), msmtp (or other MTA)
# v2.1.15
#
# DISTRIBUTION COMPATIBILITY:
# Primary: Ubuntu Server (all versions with systemd)
# Compatible: Debian, Raspberry Pi OS, Linux Mint (Debian-based distributions)
# Portable: RHEL/CentOS/Fedora, SUSE (see inline comments for command equivalents)
# Note: Raspberry Pi OS-specific considerations are noted throughout the script
#
# VERSION HISTORY (for maintainers):
# v2.1.15 - Bugfix: Password Policy check now verifies both libpam-pwquality installed and pwquality.conf present; Sudo logging check now scans /etc/sudoers.d/ drop-in files (not only /etc/sudoers)
# v2.1.14 - Bugfix: Fix cleanup() to use if-then instead of && chain; && returning false triggered ERR trap under set -e on second EXIT trap call
# v2.1.13 - Bugfix: Remove pkill block entirely; KillMode=process in service file makes it redundant and it caused set -e to trigger exit 1 under systemd
# v2.1.10 - Final polish: align header version, remove unused vars, ShellCheck clean
# v2.1.5 - Documentation: Added Linux variant equivalents for all Ubuntu-specific commands (RHEL/Fedora/SUSE/Raspberry Pi OS)
# v2.1.4 - Improvement: Show full directory path when cert.pem is not found in Let's Encrypt certificates
# v2.1.3 - Bugfix: Fixed syntax errors in wc -l count calculations (lines 718, 841)
# v2.1.2 - Improvement: Show all Let's Encrypt certificates and report if any directories are missing cert.pem
# v2.1.1 - Bugfix: Fixed ERR trap errors in Account Security and Sudo Configuration checks
# v2.1.0 - Feature: Display crontab schedule in console, log, and email report
# v2.0.0 - Feature: Added 4 new security checks (Password Policy, Account Security, File Permissions, Sudo Config)
# v1.0.8 - Improvement: Display check details on console (UFW rules, open ports, etc.)
# v1.0.7 - Improvement: List individual UFW rules in Firewall section
# v1.0.6 - Improvement: List all TCP and UDP ports individually in Open Ports section
# v1.0.5 - Bugfix: Fixed all check functions to use @@N@@ placeholder consistently
# v1.0.4 - Bugfix: Fixed newline handling using @@N@@ placeholder to prevent parsing issues
# v1.0.3 - Bugfix: Fixed remaining $'\n' in HTML email output (string concatenations and printf)
# v1.0.2 - Bugfix: Fixed console output displaying literal $'\n' characters
# v1.0.1 - Bugfix: Fixed newline rendering in HTML email output; Changed monthly recipient to golan.sharon
# v1.0.0 - Initial release: security hardening checks with --validate and --monthly modes

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly VERSION="2.1.14"
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly PATH="/usr/sbin:/usr/bin:/sbin:/bin"
HOSTNAME="$(/bin/hostname --fqdn 2>/dev/null || /bin/hostname)"
readonly HOSTNAME

# Logging
readonly LOGDIR="/backup/security-logs"
DATE_TAG="$(/bin/date +%Y%m%d_%s)"
readonly DATE_TAG
LOGFILE_BASENAME="${DATE_TAG}-${HOSTNAME}-security-hardening.log"
readonly LOGFILE_BASENAME
LOG_FILE=""

# Email settings
readonly FROM_EMAIL='PB web server <no-reply@pbhcorp.com>'
readonly RECIPIENTS_NORMAL='nathan.wilkes@pbhcorp.com'
readonly RECIPIENTS_VALIDATE='nathan.wilkes@pbhcorp.com'
readonly RECIPIENTS_MONTHLY='nathan.wilkes@pbhcorp.com golan.sharon@pbhcorp.com'
readonly SUBJECT_PREFIX="[${HOSTNAME}]"

# Runtime options
VALIDATE=false
MONTHLY=false
ADDITIONAL_RECIPIENT=""

# Colors for terminal output
readonly C_CYAN=$'\033[0;36m'
readonly C_RESET=$'\033[0m'

# =============================================================================
# TRAPS & CLEANUP
# =============================================================================
EMAIL_HTML_FILE=""

cleanup() {
    if [[ -n "${EMAIL_HTML_FILE:-}" && -f "$EMAIL_HTML_FILE" ]]; then
        rm -f "$EMAIL_HTML_FILE"
        EMAIL_HTML_FILE=""
    fi
}

trap 'printf "[%s] ERROR on line %s (exit %s)@@N@@" "$(date +"%F %T")" "$LINENO" "$?" >&2' ERR
trap cleanup EXIT

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================
log() {
    local timestamp
    timestamp="$(date +'%Y-%m-%d %H:%M:%S')"
    local line="[${timestamp}] $*"
    
    if [[ -t 1 ]]; then
        printf "%s\n" "$line"
    else
        printf "%s\n" "$line"
    fi
    
    [[ -n "${LOG_FILE:-}" ]] && printf "%s\n" "$line" >> "$LOG_FILE"
}

section() {
    local title="$1"
    local bar
    bar="$(printf '%*s' "${#title}" '' | tr ' ' '=')"
    
    # Terminal output with color
    if [[ -t 1 ]]; then
        printf "\n"  # Add blank line before section
        printf "%s%s%s\n" "$C_CYAN" "$title" "$C_RESET"
        printf "%s%s%s\n" "$C_CYAN" "$bar" "$C_RESET"
    fi
    
    # Log file output
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf "\n%s\n%s\n" "$title" "$bar" >> "$LOG_FILE"
    fi
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        printf "ERROR: This script must be run as root (needed for security checks). Use sudo.@@N@@" >&2
        exit 1
    fi
}

ensure_logdir() {
    if [[ ! -d "$LOGDIR" ]]; then
        mkdir -p "$LOGDIR" 2>/dev/null || true
    fi
    
    if [[ -d "$LOGDIR" && -w "$LOGDIR" ]]; then
        LOG_FILE="${LOGDIR%/}/${LOGFILE_BASENAME}"
    else
        printf "WARN: %s not writable; falling back to /tmp@@N@@" "$LOGDIR" >&2
        LOG_FILE="/tmp/${LOGFILE_BASENAME}"
    fi
}

os_summary() {
    # Ubuntu: lsb_release (from lsb-release package)
    # RHEL/CentOS/Fedora: lsb_release (from redhat-lsb-core package, often not installed by default)
    # Raspberry Pi OS: lsb_release available, or use /etc/os-release
    # All modern distros: /etc/os-release is universal and preferred
    if command -v lsb_release >/dev/null 2>&1; then
        lsb_release -ds
    elif [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        printf "%s" "${PRETTY_NAME:-Unknown}"
    else
        printf "Unknown Linux"
    fi
}

validate_email() {
    local email="$1"
    # Basic RFC 5322 validation - checks for user@domain format
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

html_escape() {
    local text="$1"
    text="${text//&/&amp;}"
    text="${text//</&lt;}"
    text="${text//>/&gt;}"
    text="${text//\"/&quot;}"
    printf '%s' "$text"
}

# =============================================================================
# SECURITY CHECK FUNCTIONS
# =============================================================================
check_icmp_rate_limiting() {
    local status="OK"
    local details=""
    local issues=0
    
    details+="ICMP Rate Limiting:@@N@@"
    
    # sysctl: Universal across all Linux distributions
    local icmp_ratelimit icmp_ratemask
    icmp_ratelimit="$(sysctl -n net.ipv4.icmp_ratelimit 2>/dev/null || echo "unknown")"
    icmp_ratemask="$(sysctl -n net.ipv4.icmp_ratemask 2>/dev/null || echo "unknown")"
    
    details+="  net.ipv4.icmp_ratelimit: $icmp_ratelimit@@N@@"
    details+="  net.ipv4.icmp_ratemask: $icmp_ratemask@@N@@"
    
    if [[ "$icmp_ratelimit" == "0" ]] || [[ "$icmp_ratelimit" == "unknown" ]]; then
        status="WARN"
        issues=$((issues + 1))
        details+="  ⚠️  Recommended: Set icmp_ratelimit to 1000@@N@@"
    fi
    
    printf "%s|%d|%s" "$status" "$issues" "$details"
}

check_firewall() {
    local status="OK"
    local details=""
    local issues=0
    
    details+="Firewall Status:@@N@@"
    
    # Ubuntu: ufw (Uncomplicated Firewall)
    # RHEL/CentOS/Fedora: firewalld (use 'firewall-cmd --state' to check)
    # Raspberry Pi OS: ufw available via apt (Debian-based like Ubuntu)
    # Universal fallback: iptables or nftables
    if command -v ufw >/dev/null 2>&1; then
        local ufw_status
        ufw_status="$(ufw status 2>/dev/null | head -1 || echo "error")"
        details+="  UFW: $ufw_status@@N@@"
        
        if echo "$ufw_status" | grep -qi "inactive"; then
            status="WARN"
            issues=$((issues + 1))
            details+="  ⚠️  UFW is installed but inactive@@N@@"
        fi
        
        # Get active rules count
        local rule_count
        rule_count="$(ufw status numbered 2>/dev/null | grep -c '^\[' || echo "0")"
        details+="  Active rules: $rule_count@@N@@"
        
        # List UFW rules if active
        if [[ $rule_count -gt 0 ]]; then
            local ufw_rules
            ufw_rules="$(ufw status numbered 2>/dev/null | grep '^\[')"
            
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                details+="    $line@@N@@"
            done < <(echo "$ufw_rules")
        fi
    else
        details+="  UFW: Not installed@@N@@"
    fi
    
    # iptables: Universal across all Linux distributions
    # Modern distros may use nftables instead - check with 'nft list ruleset'
    if command -v iptables >/dev/null 2>&1; then
        local ipt_count
        ipt_count="$(iptables -L -n 2>/dev/null | grep -c '^ACCEPT\|^DROP\|^REJECT' || echo "0")"
        details+="  iptables rules: $ipt_count@@N@@"
        
        if [[ "$ipt_count" -eq 0 ]] && ! command -v ufw >/dev/null 2>&1; then
            status="WARN"
            issues=$((issues + 1))
            details+="  ⚠️  No firewall rules detected@@N@@"
        fi
    fi
    
    printf "%s|%d|%s" "$status" "$issues" "$details"
}

check_ssh_security() {
    local status="OK"
    local details=""
    local issues=0
    
    details+="SSH Security Configuration:@@N@@"
    
    # /etc/ssh/sshd_config: Universal location across all Linux distributions
    if [[ ! -f /etc/ssh/sshd_config ]]; then
        details+="  SSH config not found@@N@@"
        printf "%s|%d|%s" "UNKNOWN" "$issues" "$details"
        return
    fi
    
    # Check PermitRootLogin
    local root_login
    root_login="$(grep -E "^PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "not-set")"
    details+="  PermitRootLogin: $root_login@@N@@"
    
    if [[ "$root_login" == "yes" ]]; then
        status="CRITICAL"
        issues=$((issues + 1))
        details+="  🔴 CRITICAL: Root login is enabled@@N@@"
    elif [[ "$root_login" == "not-set" ]] || [[ "$root_login" == "prohibit-password" ]]; then
        if [[ "$root_login" == "prohibit-password" ]]; then
            details+="  ✓ Root login restricted to key-based auth@@N@@"
        else
            details+="  ⚠️  PermitRootLogin not explicitly set (default: prohibit-password)@@N@@"
        fi
    else
        details+="  ✓ Root login properly restricted@@N@@"
    fi
    
    # Check PasswordAuthentication
    local pwd_auth
    pwd_auth="$(grep -E "^PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "not-set")"
    details+="  PasswordAuthentication: $pwd_auth@@N@@"
    
    if [[ "$pwd_auth" == "yes" ]]; then
        status="WARN"
        issues=$((issues + 1))
        details+="  ⚠️  Password authentication is enabled (key-based recommended)@@N@@"
    elif [[ "$pwd_auth" == "no" ]]; then
        details+="  ✓ Key-based authentication enforced@@N@@"
    else
        details+="  ⚠️  PasswordAuthentication not explicitly set (default: yes)@@N@@"
    fi
    
    # Check Protocol
    local protocol
    protocol="$(grep -E "^Protocol" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "not-set")"
    if [[ "$protocol" == "not-set" ]]; then
        details+="  Protocol: 2 (default)@@N@@"
        details+="  ✓ SSH Protocol 2 in use@@N@@"
    else
        details+="  Protocol: $protocol@@N@@"
    fi
    
    printf "%s|%d|%s" "$status" "$issues" "$details"
}

check_automatic_updates() {
    local status="OK"
    local details=""
    local issues=0
    
    details+="Automatic Security Updates:@@N@@"
    
    # Ubuntu/Debian: unattended-upgrades package and /etc/apt/apt.conf.d/20auto-upgrades
    # Raspberry Pi OS: unattended-upgrades available (Debian-based, same as Ubuntu)
    # RHEL/CentOS/Fedora: yum-cron or dnf-automatic
    # SUSE: zypper-cron or YaST Online Update Configuration
    if [[ ! -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
        status="WARN"
        issues=$((issues + 1))
        details+="  ⚠️  Unattended-upgrades not configured@@N@@"
        details+="  Install: sudo apt install unattended-upgrades@@N@@"
        # RHEL/Fedora: sudo dnf install dnf-automatic && sudo systemctl enable --now dnf-automatic.timer
        # SUSE: Use YaST or install zypper-cron
    else
        local update_enabled download_enabled
        update_enabled="$(grep -E "^APT::Periodic::Update-Package-Lists" /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null | grep -oE '"[0-9]+"' | tr -d '"' || echo "0")"
        download_enabled="$(grep -E "^APT::Periodic::Unattended-Upgrade" /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null | grep -oE '"[0-9]+"' | tr -d '"' || echo "0")"
        
        details+="  Update lists enabled: $update_enabled@@N@@"
        details+="  Unattended upgrade enabled: $download_enabled@@N@@"
        
        if [[ "$update_enabled" == "1" ]] && [[ "$download_enabled" == "1" ]]; then
            details+="  ✓ Automatic updates properly configured@@N@@"
        else
            status="WARN"
            issues=$((issues + 1))
            details+="  ⚠️  Automatic updates not fully enabled@@N@@"
        fi
        
        # systemctl: Universal across distributions using systemd
        # SysV Init systems: use 'service' command or check /etc/init.d/
        if systemctl is-enabled unattended-upgrades.service >/dev/null 2>&1; then
            details+="  Service: enabled@@N@@"
        else
            status="WARN"
            issues=$((issues + 1))
            details+="  ⚠️  Service not enabled@@N@@"
        fi
    fi
    
    printf "%s|%d|%s" "$status" "$issues" "$details"
}

check_web_server_security() {
    local status="OK"
    local details=""
    local issues=0
    
    details+="Web Server Security:@@N@@"
    
    # Apache: Configuration paths vary by distribution
    # Ubuntu/Debian: /etc/apache2/
    # Raspberry Pi OS: /etc/apache2/ (Debian-based like Ubuntu)
    # RHEL/CentOS/Fedora: /etc/httpd/
    # Check Apache
    if systemctl is-active --quiet apache2 2>/dev/null; then
        details+="  Apache2: running@@N@@"
        
        # apache2ctl: Ubuntu/Debian use 'apache2ctl'
        # Raspberry Pi OS: 'apache2ctl' (same as Debian/Ubuntu)
        # RHEL/Fedora: Use 'apachectl' or 'httpd -M'
        local sec_modules
        sec_modules="$(apache2ctl -M 2>/dev/null | grep -E "security|headers|ssl" || echo "")"
        if [[ -n "$sec_modules" ]]; then
            # shellcheck disable=SC2001
            details+="  Security modules:\n$(echo "$sec_modules" | sed 's/^/    /')@@N@@"
        else
            status="WARN"
            issues=$((issues + 1))
            details+="  ⚠️  No security modules detected@@N@@"
        fi
        
        # Ubuntu/Debian: /etc/apache2/conf-enabled/security.conf
        # Raspberry Pi OS: /etc/apache2/conf-enabled/security.conf (same as Debian/Ubuntu)
        # RHEL/Fedora: /etc/httpd/conf.d/security.conf or main config
        if [[ -f /etc/apache2/conf-enabled/security.conf ]]; then
            local server_tokens server_sig
            server_tokens="$(grep -E "^ServerTokens" /etc/apache2/conf-enabled/security.conf 2>/dev/null | awk '{print $2}' || echo "not-set")"
            server_sig="$(grep -E "^ServerSignature" /etc/apache2/conf-enabled/security.conf 2>/dev/null | awk '{print $2}' || echo "not-set")"
            
            details+="  ServerTokens: $server_tokens@@N@@"
            details+="  ServerSignature: $server_sig@@N@@"
            
            if [[ "$server_tokens" != "Prod" ]]; then
                status="WARN"
                issues=$((issues + 1))
                details+="  ⚠️  ServerTokens should be 'Prod'@@N@@"
            fi
        fi
    fi
    
    # Nginx: Configuration paths vary by distribution
    # Ubuntu/Debian: /etc/nginx/
    # Raspberry Pi OS: /etc/nginx/ (same as Debian/Ubuntu)
    # RHEL/CentOS/Fedora: /etc/nginx/
    # (Usually consistent across distributions)
    if systemctl is-active --quiet nginx 2>/dev/null; then
        details+="  Nginx: running@@N@@"
        
        local server_tokens
        server_tokens="$(grep -r "server_tokens" /etc/nginx/nginx.conf /etc/nginx/sites-enabled/* 2>/dev/null | grep -v "#" | head -1 || echo "")"
        
        if [[ -n "$server_tokens" ]]; then
            details+="  server_tokens: $(echo "$server_tokens" | awk '{print $NF}' | tr -d ';')@@N@@"
            if echo "$server_tokens" | grep -q "off"; then
                details+="  ✓ Server version hiding enabled@@N@@"
            fi
        else
            status="WARN"
            issues=$((issues + 1))
            details+="  ⚠️  server_tokens not set (shows version)@@N@@"
        fi
    fi
    
    # Lighttpd: Configuration paths consistent across distributions
    # All: /etc/lighttpd/lighttpd.conf
    # Raspberry Pi OS: /etc/lighttpd/lighttpd.conf (commonly used on Pi)
    if systemctl is-active --quiet lighttpd 2>/dev/null; then
        details+="  Lighttpd: running@@N@@"
        
        local server_tag
        server_tag="$(grep "server.tag" /etc/lighttpd/lighttpd.conf 2>/dev/null || echo "")"
        
        if [[ -n "$server_tag" ]]; then
            details+="  server.tag: $(echo "$server_tag" | cut -d'"' -f2)@@N@@"
            details+="  ✓ Custom server tag configured@@N@@"
        else
            status="WARN"
            issues=$((issues + 1))
            details+="  ⚠️  server.tag not set (shows version)@@N@@"
        fi
    fi
    
    if ! systemctl is-active --quiet apache2 2>/dev/null && \
       ! systemctl is-active --quiet nginx 2>/dev/null && \
       ! systemctl is-active --quiet lighttpd 2>/dev/null; then
        details+="  No web server detected@@N@@"
        status="OK"
    fi
    
    printf "%s|%d|%s" "$status" "$issues" "$details"
}

check_ssl_certificates() {
    local status="OK"
    local details=""
    local issues=0
    
    details+="TLS/SSL Certificates:@@N@@"
    
    # Let's Encrypt: certbot installation location varies
    # Ubuntu/Debian: /etc/letsencrypt/
    # Raspberry Pi OS: /etc/letsencrypt/ (same as Debian/Ubuntu)
    # RHEL/Fedora: /etc/letsencrypt/
    # (Consistent across distributions when using certbot)
    if [[ -d /etc/letsencrypt/live ]]; then
        local cert_count
        cert_count="$(find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d | wc -l)"
        details+="  Let's Encrypt certificates: $cert_count@@N@@"
        
        if [[ $cert_count -gt 0 ]]; then
            # Check expiration of certificates
            # openssl: Universal across all Linux distributions
            local processed=0
            for cert_dir in /etc/letsencrypt/live/*/; do
                local domain
                domain="$(basename "$cert_dir")"
                
                # Skip README directory if it exists
                [[ "$domain" == "README" ]] && continue
                
                if [[ -f "${cert_dir}cert.pem" ]]; then
                    local expiry
                    expiry="$(openssl x509 -enddate -noout -in "${cert_dir}cert.pem" 2>/dev/null | cut -d= -f2 || echo "unknown")"
                    details+="    $domain: expires $expiry@@N@@"
                    processed=$((processed + 1))
                    
                    # Check if expiring soon (within 30 days)
                    if [[ "$expiry" != "unknown" ]]; then
                        local expiry_epoch
                        expiry_epoch="$(date -d "$expiry" +%s 2>/dev/null || echo "0")"
                        local now_epoch
                        now_epoch="$(date +%s)"
                        local days_left
                        days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
                        
                        if [[ $days_left -lt 30 ]]; then
                            status="WARN"
                            issues=$((issues + 1))
                            details+="      ⚠️  Expires in $days_left days@@N@@"
                        fi
                    fi
                else
                    details+="    $domain: cert.pem not found in ${cert_dir}@@N@@"
                    status="WARN"
                    issues=$((issues + 1))
                fi
            done
            
            # Report if some directories were skipped
            if [[ $processed -ne $cert_count ]]; then
                details+="  (Processed $processed out of $cert_count directories)@@N@@"
            fi
        fi
    else
        details+="  Let's Encrypt: not configured@@N@@"
    fi
    
    # System certificates: Location consistent across distributions
    # All: /etc/ssl/certs/ (though some use /etc/pki/tls/certs/ as well on RHEL)
    # Raspberry Pi OS: /etc/ssl/certs/ (Debian-based)
    if [[ -d /etc/ssl/certs ]]; then
        local cert_count
        cert_count="$(find /etc/ssl/certs -name "*.pem" -type f | wc -l)"
        details+="  System certificates in /etc/ssl/certs: $cert_count@@N@@"
    fi
    
    printf "%s|%d|%s" "$status" "$issues" "$details"
}

check_open_ports() {
    local status="OK"
    local details=""
    local issues=0
    
    details+="Open Ports and Listening Services:@@N@@"
    
    # ss: Modern replacement for netstat, available on all recent distributions
    # Raspberry Pi OS: ss available (modern Debian-based)
    # Fallback: netstat (from net-tools package) if ss not available
    # Alternative: lsof -i (requires lsof package)
    local tcp_ports
    tcp_ports="$(ss -tlnp 2>/dev/null | grep LISTEN || echo "")"
    local tcp_count
    tcp_count="$(echo "$tcp_ports" | grep -c LISTEN || echo "0")"
    
    details+="  TCP listening ports: $tcp_count@@N@@"
    
    if [[ $tcp_count -gt 0 ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            details+="    $line@@N@@"
        done < <(echo "$tcp_ports" | head -10)
        
        if [[ $tcp_count -gt 10 ]]; then
            details+="    ... and $((tcp_count - 10)) more@@N@@"
        fi
    fi
    
    # Check for common risky ports
    if echo "$tcp_ports" | grep -q ":23 "; then
        status="CRITICAL"
        issues=$((issues + 1))
        details+="  🔴 CRITICAL: Telnet (port 23) is listening@@N@@"
    fi
    
    if echo "$tcp_ports" | grep -q ":21 "; then
        status="WARN"
        issues=$((issues + 1))
        details+="  ⚠️  FTP (port 21) is listening@@N@@"
    fi
    
    # UDP ports
    local udp_ports udp_count
    udp_ports="$(ss -ulnp 2>/dev/null | grep "^UNCONN" || echo "")"
    udp_count="$(echo "$udp_ports" | grep -c "^UNCONN" || echo "0")"
    details+="  UDP listening ports: $udp_count@@N@@"
    
    if [[ $udp_count -gt 0 ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            details+="    $line@@N@@"
        done < <(echo "$udp_ports" | head -10)
        
        if [[ $udp_count -gt 10 ]]; then
            details+="    ... and $((udp_count - 10)) more@@N@@"
        fi
    fi
    
    printf "%s|%d|%s" "$status" "$issues" "$details"
}

check_apparmor() {
    local status="OK"
    local details=""
    local issues=0
    
    details+="AppArmor Status:@@N@@"
    
    # Ubuntu/Debian: AppArmor (usually pre-installed)
    # Raspberry Pi OS: AppArmor available but not enabled by default (as of Bullseye/Bookworm)
    #                  Can be enabled by adding 'apparmor=1 security=apparmor' to /boot/cmdline.txt
    # RHEL/CentOS/Fedora: SELinux is the standard (use 'sestatus' to check)
    # SUSE: AppArmor is standard
    # For SELinux equivalent: Check with 'getenforce' and 'sestatus'
    if ! command -v aa-status >/dev/null 2>&1; then
        status="WARN"
        issues=$((issues + 1))
        details+="  ⚠️  AppArmor not installed@@N@@"
        # RHEL/Fedora: Check SELinux with 'sestatus' or 'getenforce'
    else
        local aa_status
        aa_status="$(aa-status --profiled 2>/dev/null || echo "error")"
        
        details+="$(printf "%s\n" "$aa_status" | sed 's/^/  /' | sed 's/$/@@N@@/')"
        
        if echo "$aa_status" | grep -q "0 profiles are loaded"; then
            status="WARN"
            issues=$((issues + 1))
            details+="  ⚠️  No AppArmor profiles loaded@@N@@"
        elif echo "$aa_status" | grep -qi "error"; then
            status="WARN"
            issues=$((issues + 1))
            details+="  ⚠️  Unable to check AppArmor status@@N@@"
        else
            details+="  ✓ AppArmor is active@@N@@"
        fi
    fi
    
    printf "%s|%d|%s" "$status" "$issues" "$details"
}

check_fail2ban() {
    local status="OK"
    local details=""
    local issues=0
    
    details+="Intrusion Prevention (fail2ban):@@N@@"
    
    # fail2ban: Available as package on all major distributions
    # Ubuntu/Debian: apt install fail2ban
    # Raspberry Pi OS: apt install fail2ban (Debian-based, same as Ubuntu)
    # RHEL/Fedora: dnf install fail2ban (from EPEL on RHEL)
    # SUSE: zypper install fail2ban
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        status="INFO"
        details+="  Not installed (optional)@@N@@"
    else
        local f2b_status
        f2b_status="$(fail2ban-client status 2>/dev/null || echo "error")"
        
        if echo "$f2b_status" | grep -qi "error"; then
            status="WARN"
            issues=$((issues + 1))
            details+="  ⚠️  fail2ban installed but not running@@N@@"
        else
            local jail_count
            jail_count="$(echo "$f2b_status" | grep -oP "Number of jail:\s+\K[0-9]+" || echo "0")"
            details+="  Active jails: $jail_count@@N@@"
            
            if [[ $jail_count -gt 0 ]]; then
                details+="  ✓ fail2ban is active@@N@@"
                # shellcheck disable=SC2001
                details+="$(echo "$f2b_status" | sed 's/^/    /')@@N@@"
            else
                status="WARN"
                issues=$((issues + 1))
                details+="  ⚠️  fail2ban running but no jails active@@N@@"
            fi
        fi
    fi
    
    printf "%s|%d|%s" "$status" "$issues" "$details"
}

check_kernel_security() {
    local status="OK"
    local details=""
    local issues=0
    
    details+="Kernel Security Parameters:@@N@@"
    
    # sysctl: Universal across all Linux distributions
    # Configuration files locations:
    # All distros: /etc/sysctl.conf and /etc/sysctl.d/*.conf
    local params=(
        "kernel.dmesg_restrict"
        "kernel.kptr_restrict"
        "net.ipv4.conf.all.accept_source_route"
        "net.ipv4.conf.all.accept_redirects"
        "net.ipv4.conf.all.send_redirects"
        "net.ipv4.icmp_echo_ignore_broadcasts"
        "net.ipv4.tcp_syncookies"
    )
    
    for param in "${params[@]}"; do
        local value
        value="$(sysctl -n "$param" 2>/dev/null || echo "unknown")"
        details+="  $param: $value@@N@@"
    done
    
    # Check for recommended settings
    if [[ "$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null)" != "1" ]]; then
        status="WARN"
        issues=$((issues + 1))
        details+="  ⚠️  TCP SYN cookies should be enabled (protects against SYN floods)@@N@@"
    fi
    
    if [[ "$(sysctl -n net.ipv4.conf.all.accept_redirects 2>/dev/null)" != "0" ]]; then
        status="WARN"
        issues=$((issues + 1))
        details+="  ⚠️  ICMP redirects should be disabled@@N@@"
    fi
    
    printf "%s|%d|%s" "$status" "$issues" "$details"
}

check_password_policy() {
    local status="OK"
    local details=""
    local issues=0
    
    details+="Password Policy (PAM):@@N@@"
    
    # Ubuntu/Debian: libpam-pwquality package, config at /etc/security/pwquality.conf
    # Raspberry Pi OS: libpam-pwquality package (same as Debian/Ubuntu)
    # RHEL/Fedora: libpwquality package, config at /etc/security/pwquality.conf
    # SUSE: pam_pwquality, config at /etc/security/pwquality.conf
    # All use same config file location when pwquality is installed
    if dpkg -l libpam-pwquality &>/dev/null && [[ -f /etc/security/pwquality.conf ]]; then
        details+="  pwquality.conf found@@N@@"
        
        # Check key password requirements
        local minlen retry difok
        minlen="$(grep -E "^minlen" /etc/security/pwquality.conf 2>/dev/null | awk '{print $3}' || echo "not-set")"
        retry="$(grep -E "^retry" /etc/security/pwquality.conf 2>/dev/null | awk '{print $3}' || echo "not-set")"
        difok="$(grep -E "^difok" /etc/security/pwquality.conf 2>/dev/null | awk '{print $3}' || echo "not-set")"
        
        details+="    minlen: $minlen@@N@@"
        details+="    retry: $retry@@N@@"
        details+="    difok: $difok@@N@@"
        
        if [[ "$minlen" == "not-set" ]] || [[ "$minlen" -lt 12 ]]; then
            status="WARN"
            issues=$((issues + 1))
            details+="  ⚠️  Minimum password length should be 12+ characters@@N@@"
        else
            details+="  ✓ Minimum password length requirement set@@N@@"
        fi
    else
        status="WARN"
        issues=$((issues + 1))
        details+="  ⚠️  pwquality.conf not found@@N@@"
        details+="  Install: sudo apt install libpam-pwquality@@N@@"
        # Raspberry Pi OS: sudo apt install libpam-pwquality (same as Debian/Ubuntu)
        # RHEL/Fedora: sudo dnf install libpwquality
        # SUSE: sudo zypper install pam_pwquality
    fi
    
    printf "%s|%d|%s" "$status" "$issues" "$details"
}

check_account_security() {
    local status="OK"
    local details=""
    local issues=0
    
    details+="Account Security:@@N@@"
    
    # /etc/shadow and /etc/passwd: Universal across all Linux distributions
    # Check for accounts with empty passwords
    local empty_passwords
    empty_passwords="$(awk -F: '($2 == "" || $2 == "!") {print $1}' /etc/shadow 2>/dev/null | grep -v "^#" || echo "")"
    local empty_count=0
    if [[ -n "$empty_passwords" ]]; then
        empty_count="$(echo "$empty_passwords" | grep -c .)"
    fi
    
    if [[ $empty_count -gt 0 ]]; then
        # Filter out locked accounts (those with ! in password field are locked, which is OK)
        local unlocked_empty
        unlocked_empty="$(awk -F: '($2 == "") {print $1}' /etc/shadow 2>/dev/null || echo "")"
        local unlocked_count=0
        if [[ -n "$unlocked_empty" ]]; then
            unlocked_count="$(echo "$unlocked_empty" | grep -c .)"
        fi
        
        if [[ $unlocked_count -gt 0 ]]; then
            status="CRITICAL"
            issues=$((issues + 1))
            details+="  🔴 CRITICAL: $unlocked_count account(s) with empty passwords@@N@@"
            while IFS= read -r account; do
                [[ -z "$account" ]] && continue
                details+="    - $account@@N@@"
            done < <(echo "$unlocked_empty")
        else
            details+="  ✓ No accounts with empty passwords@@N@@"
        fi
    else
        details+="  ✓ No accounts with empty passwords@@N@@"
    fi
    
    # Check for multiple UID 0 accounts (should only be root)
    local uid_zero_accounts
    uid_zero_accounts="$(awk -F: '($3 == 0) {print $1}' /etc/passwd 2>/dev/null || echo "")"
    local uid_zero_count
    uid_zero_count="$(echo "$uid_zero_accounts" | wc -l | tr -d ' \n')"
    
    details+="  Accounts with UID 0: $uid_zero_count@@N@@"
    while IFS= read -r account; do
        [[ -z "$account" ]] && continue
        details+="    - $account@@N@@"
    done < <(echo "$uid_zero_accounts")
    
    if [[ $uid_zero_count -gt 1 ]]; then
        status="CRITICAL"
        issues=$((issues + 1))
        details+="  🔴 CRITICAL: Multiple accounts with UID 0 (should only be root)@@N@@"
    else
        details+="  ✓ Only root has UID 0@@N@@"
    fi
    
    printf "%s|%d|%s" "$status" "$issues" "$details"
}

check_file_permissions() {
    local status="OK"
    local details=""
    local issues=0
    
    details+="Critical File Permissions:@@N@@"
    
    # File locations: Universal across all Linux distributions
    # /etc/passwd, /etc/shadow, /etc/group, /etc/gshadow, /etc/ssh/sshd_config
    local files_to_check=(
        "/etc/passwd:644"
        "/etc/shadow:640"
        "/etc/group:644"
        "/etc/gshadow:640"
        "/etc/ssh/sshd_config:600"
    )
    
    # stat: Universal across all Linux distributions
    for file_perm in "${files_to_check[@]}"; do
        local file="${file_perm%:*}"
        local expected="${file_perm#*:}"
        
        if [[ -f "$file" ]]; then
            local actual
            actual="$(stat -c "%a" "$file" 2>/dev/null)"
            details+="  $file: $actual (expected: $expected)@@N@@"
            
            # Check if actual is more permissive than expected
            if [[ "$actual" != "$expected" ]]; then
                # Convert to decimal for comparison
                local actual_dec=$((8#$actual))
                local expected_dec=$((8#$expected))
                
                if [[ $actual_dec -gt $expected_dec ]]; then
                    status="WARN"
                    issues=$((issues + 1))
                    details+="    ⚠️  Permissions too permissive@@N@@"
                fi
            fi
        else
            details+="  $file: not found@@N@@"
        fi
    done
    
    # find: Universal across all Linux distributions
    # Check for world-writable files in critical directories
    details+="  Checking for world-writable files in /etc...@@N@@"
    local world_writable
    world_writable="$(find /etc -type f -perm -002 2>/dev/null | head -5 || echo "")"
    local ww_count
    ww_count="$(find /etc -type f -perm -002 2>/dev/null | wc -l)"
    
    if [[ $ww_count -gt 0 ]]; then
        status="WARN"
        issues=$((issues + 1))
        details+="  ⚠️  Found $ww_count world-writable file(s) in /etc@@N@@"
        
        if [[ -n "$world_writable" ]]; then
            while IFS= read -r wfile; do
                [[ -z "$wfile" ]] && continue
                details+="    - $wfile@@N@@"
            done < <(echo "$world_writable")
            
            if [[ $ww_count -gt 5 ]]; then
                details+="    ... and $((ww_count - 5)) more@@N@@"
            fi
        fi
    else
        details+="  ✓ No world-writable files in /etc@@N@@"
    fi
    
    printf "%s|%d|%s" "$status" "$issues" "$details"
}

check_sudo_configuration() {
    local status="OK"
    local details=""
    local issues=0
    
    details+="Sudo Configuration:@@N@@"
    
    # /etc/sudoers: Universal location across all Linux distributions
    # Configuration managed by visudo command (universal)
    if [[ -f /etc/sudoers ]]; then
        # Check for NOPASSWD entries (excluding comments)
        local nopasswd_entries
        nopasswd_entries="$(grep -v "^#" /etc/sudoers 2>/dev/null | grep "NOPASSWD" || echo "")"
        local nopasswd_count=0
        if [[ -n "$nopasswd_entries" ]]; then
            nopasswd_count="$(echo "$nopasswd_entries" | grep -c .)"
        fi
        
        if [[ $nopasswd_count -gt 0 ]]; then
            status="WARN"
            issues=$((issues + 1))
            details+="  ⚠️  Found $nopasswd_count NOPASSWD entry/entries@@N@@"
            
            while IFS= read -r entry; do
                [[ -z "$entry" ]] && continue
                # Trim whitespace
                entry="$(echo "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                details+="    $entry@@N@@"
            done < <(echo "$nopasswd_entries")
            
            details+="  Note: NOPASSWD allows sudo without password (security risk)@@N@@"
        else
            details+="  ✓ No NOPASSWD entries found@@N@@"
        fi
        
        # Check for overly permissive ALL=(ALL:ALL) rules
        local all_all_entries
        all_all_entries="$(grep -v "^#" /etc/sudoers 2>/dev/null | grep "ALL=(ALL:ALL)" | grep -v "^Defaults" || echo "")"
        local all_all_count=0
        if [[ -n "$all_all_entries" ]]; then
            all_all_count="$(echo "$all_all_entries" | grep -c .)"
        fi
        
        if [[ $all_all_count -gt 0 ]]; then
            details+="  Users/groups with full sudo access: $all_all_count@@N@@"
            
            while IFS= read -r entry; do
                [[ -z "$entry" ]] && continue
                entry="$(echo "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                details+="    $entry@@N@@"
            done < <(echo "$all_all_entries")
        fi
        
        # Check if sudo logging is enabled (covers /etc/sudoers and all drop-in files)
        local sudo_log
        sudo_log="$(grep -rE '^[[:space:]]*Defaults[[:space:]]+.*logfile' \
            /etc/sudoers /etc/sudoers.d/ 2>/dev/null || echo "")"

        if [[ -n "$sudo_log" ]]; then
            details+="  ✓ Sudo logging enabled: $(echo "$sudo_log" | head -1)@@N@@"
        else
            status="WARN"
            issues=$((issues + 1))
            details+="  ⚠️  Sudo logging not explicitly configured@@N@@"
            details+="  Recommendation: Add 'Defaults logfile=/var/log/sudo.log' to /etc/sudoers@@N@@"
        fi
    else
        details+="  /etc/sudoers: not found@@N@@"
    fi
    
    printf "%s|%d|%s" "$status" "$issues" "$details"
}



check_systemd_timer_schedule() {
  local details base timer_unit out
  details="systemd Timer Schedule for ${SCRIPT_NAME}:@@N@@"

  if ! command -v systemctl >/dev/null 2>&1; then
    details+=" systemctl not available; cannot query timers@@N@@"
    printf "%s" "$details"
    return 0
  fi

  base="${SYSTEMD_UNIT:-}"
  base="${base%.service}"

  if [[ -n "$base" ]]; then
    timer_unit="${base}.timer"
    out="$(systemctl list-timers --all --no-pager "$timer_unit" 2>/dev/null || true)"
    if [[ -n "$out" ]]; then
      details+="$(printf "%s" "$out" | sed 's/$/@@N@@/')"
    else
      details+=" Timer unit not found: ${timer_unit}@@N@@"
    fi
  else
    details+=" Not running under systemd (SYSTEMD_UNIT not set)@@N@@"
  fi

  details+=" Logs:@@N@@"
  details+="  journalctl -u ${SYSTEMD_UNIT:-<service>.service} -n 200 --no-pager@@N@@"
  details+=" Timers:@@N@@"
  details+="  systemctl list-timers --all --no-pager@@N@@"

  printf "%s" "$details"
}

# =============================================================================
# HTML GENERATION FUNCTIONS
# =============================================================================
html_begin() {
    cat >> "$EMAIL_HTML_FILE" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Security Hardening Report</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { 
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; 
    color: #1f2937; 
    background: #f9fafb; 
    margin: 0; 
    padding: 24px; 
  }
  .card { 
    background: #ffffff; 
    border: 1px solid #e5e7eb; 
    border-radius: 8px; 
    padding: 20px; 
    max-width: 960px; 
    margin: 0 auto; 
    box-shadow: 0 1px 2px rgba(0,0,0,.05);
  }
  h1 { 
    font-size: 20px; 
    margin: 0 0 12px; 
    color: #111827;
  }
  h2 { 
    font-size: 16px; 
    margin: 20px 0 8px; 
    color: #111827; 
  }
  .muted { 
    color: #6b7280; 
    font-size: 12px; 
  }
  .kv { 
    display: grid; 
    grid-template-columns: 180px 1fr; 
    gap: 8px 16px; 
    padding: 12px; 
    background: #f3f4f6; 
    border-radius: 6px;
    margin-bottom: 20px;
  }
  .kv div.label { 
    color: #6b7280; 
  }
  .badge { 
    display: inline-block; 
    padding: 2px 8px; 
    border-radius: 9999px; 
    font-size: 12px; 
    font-weight: 600;
  }
  .badge-ok { 
    background: #ecfdf5; 
    color: #065f46; 
    border: 1px solid #10b981; 
  }
  .badge-warn { 
    background: #fffbeb; 
    color: #92400e; 
    border: 1px solid #f59e0b; 
  }
  .badge-critical { 
    background: #fef2f2; 
    color: #991b1b; 
    border: 1px solid #ef4444; 
  }
  .badge-info { 
    background: #eff6ff; 
    color: #1e40af; 
    border: 1px solid #3b82f6; 
  }
  .check-section {
    margin: 20px 0;
    padding: 16px;
    background: #f9fafb;
    border-left: 4px solid #d1d5db;
    border-radius: 4px;
  }
  .check-section.ok {
    border-left-color: #10b981;
    background: #f0fdf4;
  }
  .check-section.warn {
    border-left-color: #f59e0b;
    background: #fffbeb;
  }
  .check-section.critical {
    border-left-color: #ef4444;
    background: #fef2f2;
  }
  pre { 
    background: #0b1020; 
    color: #e5e7eb; 
    padding: 12px; 
    border-radius: 6px; 
    overflow: auto; 
    font-size: 12px; 
    line-height: 1.4; 
    white-space: pre-wrap;
  }
  .footer { 
    margin-top: 16px; 
    color: #6b7280; 
    font-size: 12px; 
  }
  .summary-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 16px;
    margin: 20px 0;
  }
  .summary-card {
    padding: 16px;
    background: #f9fafb;
    border-radius: 8px;
    border: 1px solid #e5e7eb;
  }
  .summary-number {
    font-size: 32px;
    font-weight: 700;
    margin: 8px 0;
  }
  .summary-label {
    font-size: 14px;
    color: #6b7280;
  }
</style>
</head>
<body>
<div class="card">
HTML
}

html_end() {
    cat >> "$EMAIL_HTML_FILE" <<'HTML'
</div>
</body>
</html>
HTML
}

html_header() {
    local title="$1"
    local subtitle="$2"
    cat >> "$EMAIL_HTML_FILE" <<HTML
<h1>${title}</h1>
<div class="muted">${subtitle}</div>
HTML
}

html_kv_section() {
    local os_info kernel_version timestamp args
    
    os_info="$(os_summary)"
    kernel_version="$(uname -r)"
    timestamp="$(date +'%F %T %Z')"
    args="${*:-none}"
    
    cat >> "$EMAIL_HTML_FILE" <<HTML
<div class="kv">
  <div class="label">Host</div><div>${HOSTNAME}</div>
  <div class="label">OS</div><div>${os_info}</div>
  <div class="label">Kernel</div><div>${kernel_version}</div>
  <div class="label">Script</div><div>${SCRIPT_NAME} v${VERSION}</div>
  <div class="label">Args</div><div>${args}</div>
  <div class="label">Log file</div><div>${LOG_FILE}</div>
</div>
HTML
}

html_summary_section() {
    local total_checks="$1"
    local ok_count="$2"
    local warn_count="$3"
    local critical_count="$4"
    
    cat >> "$EMAIL_HTML_FILE" <<HTML
<h2>Security Check Summary</h2>
<div class="summary-grid">
  <div class="summary-card">
    <div class="summary-label">Total Checks</div>
    <div class="summary-number">${total_checks}</div>
  </div>
  <div class="summary-card" style="border-color: #10b981;">
    <div class="summary-label">Passed</div>
    <div class="summary-number" style="color: #10b981;">${ok_count}</div>
  </div>
  <div class="summary-card" style="border-color: #f59e0b;">
    <div class="summary-label">Warnings</div>
    <div class="summary-number" style="color: #f59e0b;">${warn_count}</div>
  </div>
  <div class="summary-card" style="border-color: #ef4444;">
    <div class="summary-label">Critical</div>
    <div class="summary-number" style="color: #ef4444;">${critical_count}</div>
  </div>
</div>
HTML
}

html_check_section() {
    local title="$1"
    local status="$2"
    local details="$3"
    
    local section_class="check-section"
    local badge_class="badge-info"
    
    case "$status" in
        OK)
            section_class="check-section ok"
            badge_class="badge-ok"
            ;;
        WARN)
            section_class="check-section warn"
            badge_class="badge-warn"
            ;;
        CRITICAL)
            section_class="check-section critical"
            badge_class="badge-critical"
            ;;
        INFO)
            badge_class="badge-info"
            ;;
    esac
    
    # Convert @@N@@ placeholders to actual newlines, then escape HTML
    local formatted_details
    formatted_details="${details//@@N@@/$'\n'}"
    local escaped_details
    escaped_details="$(html_escape "$formatted_details")"
    
    cat >> "$EMAIL_HTML_FILE" <<HTML
<div class="${section_class}">
  <h3 style="margin: 0 0 8px 0; font-size: 15px;">
    ${title}
    <span class="badge ${badge_class}">${status}</span>
  </h3>
  <pre>${escaped_details}</pre>
</div>
HTML
}

html_footer() {
    printf '<div class="footer">This message was generated by %s v%s on %s.</div>\n' \
        "$SCRIPT_NAME" "$VERSION" "$HOSTNAME" >> "$EMAIL_HTML_FILE"
}

# =============================================================================
# EMAIL SENDING
# =============================================================================
send_email() {
    local subject="$1"
    local html_body="$2"
    local recipients="$3"
    

    # Split recipients into array safely
    local -a rcpt
    # shellcheck disable=SC2086
    read -r -a rcpt <<<"$recipients"
    # mailx: Available on all distributions but may have different implementations
    # Ubuntu/Debian: install 'bsd-mailx' or 's-nail'
    # Raspberry Pi OS: install 'bsd-mailx' or 's-nail' (same as Debian/Ubuntu)
    # RHEL/Fedora: install 'mailx' package (usually s-nail)
    # Alternative: use 'mutt' or configure 'sendmail'/'postfix' directly
    if ! command -v mailx >/dev/null 2>&1; then
        printf "ERROR: mailx not installed; cannot send email.@@N@@" >&2
        return 1
    fi
    
    # Try modern -a flag first
    if mailx -a "From: ${FROM_EMAIL}" \
             -a "Content-Type: text/html; charset=UTF-8" \
             -s "$subject" \
             "${rcpt[@]}" < "$html_body" 2>>"$LOG_FILE"; then
        log "HTML email sent successfully to: $recipients"
        return 0
    fi
    
    # Fallback to -r flag for envelope sender
    local envelope_sender
    envelope_sender="$(printf "%s" "$FROM_EMAIL" | sed -E 's/.*<(.+?)>.*/\1/')"
    
    if mailx -r "$envelope_sender" \
             -a "Content-Type: text/html; charset=UTF-8" \
             -s "$subject" \
             "${rcpt[@]}" < "$html_body" 2>&1; then
        log "HTML email sent (using -r flag) to: $recipients"
        return 0
    fi
    
    log "ERROR: Failed to send email via mailx"
    return 1
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--check|--validate|--monthly] [--email ADDRESS] [--help|-h]

  --check              Check security hardening and email only if issues found.
  --validate           Always email a summary, even when all checks pass.
  --monthly            Monthly verification report (always emails, both recipients).
  --email ADDRESS      Add an additional email recipient (must be valid email format).
  --help, -h           Show this help.

Examples:
  sudo ${SCRIPT_NAME} --check
  sudo ${SCRIPT_NAME} --validate
  sudo ${SCRIPT_NAME} --monthly
  sudo ${SCRIPT_NAME} --check --email admin@example.com

Recipients:
  --check              nathan.wilkes@pbhcorp.com (only if issues found)
  --validate           nathan.wilkes@pbhcorp.com (always sends email)
  --monthly            nathan.wilkes@pbhcorp.com, golan.sharon@pbhcorp.com (always sends email)
  --email ADDRESS      Adds specified address to the recipient list for any mode
EOF
}

parse_arguments() {
    # If no arguments provided, show help and exit
    if [[ $# -eq 0 ]]; then
        show_help
        trap - ERR  # Disable error trap before intentional exit
        exit 1
    fi
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check)
                shift
                ;;
            --validate)
                VALIDATE=true
                shift
                ;;
            --monthly)
                MONTHLY=true
                shift
                ;;
            --email)
                if [[ -z "${2:-}" ]]; then
                    printf "ERROR: --email requires an email address argument\n@@N@@" >&2
                    show_help
                    trap - ERR
                    exit 1
                fi
                if ! validate_email "$2"; then
                    printf "ERROR: Invalid email address format: %s\n@@N@@" "$2" >&2
                    show_help
                    trap - ERR
                    exit 1
                fi
                ADDITIONAL_RECIPIENT="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                trap - ERR  # Disable error trap before intentional exit
                exit 0
                ;;
            *)
                printf "ERROR: Unknown option: %s\n@@N@@" "$1" >&2
                show_help
                trap - ERR  # Disable error trap before intentional exit
                exit 1
                ;;
        esac
    done
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================
main() {
    local original_args="$*"
    
    parse_arguments "$@"
    require_root
    ensure_logdir
    
    umask 027
    EMAIL_HTML_FILE="$(mktemp -t security-hardening-report.XXXXXX.html)"
    
    # Start logging
    section "Security Hardening Check Started"
    log "Host           : $HOSTNAME"
    log "OS             : $(os_summary)"
    log "Kernel         : $(uname -r)"
    log "Script         : $SCRIPT_NAME v$VERSION"
    log "Args           : ${original_args:-none}"
    log "Log file       : $LOG_FILE"
    log "Timestamp      : $(date +'%F %T %Z')"
    
    # Display crontab schedule
    section "systemd Timer Schedule"
    local timer_schedule
  timer_schedule="$(check_systemd_timer_schedule)"
  local display_timer="${timer_schedule//@@N@@/$'
'}"
  printf "%s
" "$display_timer"
  printf "%s
" "$display_timer" >> "$LOG_FILE"
    
    # Initialize HTML report
    html_begin
    html_header "Security Hardening Report — $HOSTNAME" "$(date +'%F %T %Z')"
    html_kv_section "$original_args"
    
    # Add crontab schedule to HTML
    cat >> "$EMAIL_HTML_FILE" <<HTML
<div style="margin: 20px 0; padding: 16px; background: #f9fafb; border-left: 4px solid #3b82f6; border-radius: 4px;">
  <h3 style="margin: 0 0 8px 0; font-size: 15px; color: #1e40af;">🕒 systemd Timer Schedule</h3>
  <pre style="margin: 0;">${display_timer}</pre>
</div>
HTML
    
    # Run security checks
    local total_checks=0
    local ok_count=0
    local warn_count=0
    local critical_count=0
    local total_issues=0
    
    # Array to store check results
    declare -A check_results
    declare -A check_details
    # ICMP Rate Limiting
    section "Checking ICMP Rate Limiting"
    local result
    result="$(check_icmp_rate_limiting)"
    IFS='|' read -r status issues details <<< "$result"
    check_results["ICMP Rate Limiting"]="$status"
    check_details["ICMP Rate Limiting"]="$details"
    total_checks=$((total_checks + 1))
    total_issues=$((total_issues + issues))
    log "ICMP Rate Limiting: $status ($issues issue(s))"
    # Convert @@N@@ to newlines for display and logging
    local display_details="${details//@@N@@/$'\n'}"
    printf "%s\n" "$display_details" >> "$LOG_FILE"
    if [[ -t 1 ]]; then
        printf "%s\n" "$display_details"
    fi
    
    # Firewall
    section "Checking Firewall Configuration"
    result="$(check_firewall)"
    IFS='|' read -r status issues details <<< "$result"
    check_results["Firewall"]="$status"
    check_details["Firewall"]="$details"
    total_checks=$((total_checks + 1))
    total_issues=$((total_issues + issues))
    log "Firewall: $status ($issues issue(s))"
    # Convert @@N@@ to newlines for display and logging
    local display_details="${details//@@N@@/$'\n'}"
    printf "%s\n" "$display_details" >> "$LOG_FILE"
    if [[ -t 1 ]]; then
        printf "%s\n" "$display_details"
    fi
    
    # SSH Security
    section "Checking SSH Security"
    result="$(check_ssh_security)"
    IFS='|' read -r status issues details <<< "$result"
    check_results["SSH Security"]="$status"
    check_details["SSH Security"]="$details"
    total_checks=$((total_checks + 1))
    total_issues=$((total_issues + issues))
    log "SSH Security: $status ($issues issue(s))"
    # Convert @@N@@ to newlines for display and logging
    local display_details="${details//@@N@@/$'\n'}"
    printf "%s\n" "$display_details" >> "$LOG_FILE"
    if [[ -t 1 ]]; then
        printf "%s\n" "$display_details"
    fi
    
    # Automatic Updates
    section "Checking Automatic Updates"
    result="$(check_automatic_updates)"
    IFS='|' read -r status issues details <<< "$result"
    check_results["Automatic Updates"]="$status"
    check_details["Automatic Updates"]="$details"
    total_checks=$((total_checks + 1))
    total_issues=$((total_issues + issues))
    log "Automatic Updates: $status ($issues issue(s))"
    # Convert @@N@@ to newlines for display and logging
    local display_details="${details//@@N@@/$'\n'}"
    printf "%s\n" "$display_details" >> "$LOG_FILE"
    if [[ -t 1 ]]; then
        printf "%s\n" "$display_details"
    fi
    
    # Web Server Security
    section "Checking Web Server Security"
    result="$(check_web_server_security)"
    IFS='|' read -r status issues details <<< "$result"
    check_results["Web Server Security"]="$status"
    check_details["Web Server Security"]="$details"
    total_checks=$((total_checks + 1))
    total_issues=$((total_issues + issues))
    log "Web Server Security: $status ($issues issue(s))"
    # Convert @@N@@ to newlines for display and logging
    local display_details="${details//@@N@@/$'\n'}"
    printf "%s\n" "$display_details" >> "$LOG_FILE"
    if [[ -t 1 ]]; then
        printf "%s\n" "$display_details"
    fi
    
    # SSL Certificates
    section "Checking SSL/TLS Certificates"
    result="$(check_ssl_certificates)"
    IFS='|' read -r status issues details <<< "$result"
    check_results["SSL/TLS Certificates"]="$status"
    check_details["SSL/TLS Certificates"]="$details"
    total_checks=$((total_checks + 1))
    total_issues=$((total_issues + issues))
    log "SSL/TLS Certificates: $status ($issues issue(s))"
    # Convert @@N@@ to newlines for display and logging
    local display_details="${details//@@N@@/$'\n'}"
    printf "%s\n" "$display_details" >> "$LOG_FILE"
    if [[ -t 1 ]]; then
        printf "%s\n" "$display_details"
    fi
    
    # Open Ports
    section "Checking Open Ports"
    result="$(check_open_ports)"
    IFS='|' read -r status issues details <<< "$result"
    check_results["Open Ports"]="$status"
    check_details["Open Ports"]="$details"
    total_checks=$((total_checks + 1))
    total_issues=$((total_issues + issues))
    log "Open Ports: $status ($issues issue(s))"
    # Convert @@N@@ to newlines for display and logging
    local display_details="${details//@@N@@/$'\n'}"
    printf "%s\n" "$display_details" >> "$LOG_FILE"
    if [[ -t 1 ]]; then
        printf "%s\n" "$display_details"
    fi
    
    # AppArmor
    section "Checking AppArmor"
    result="$(check_apparmor)"
    IFS='|' read -r status issues details <<< "$result"
    check_results["AppArmor"]="$status"
    check_details["AppArmor"]="$details"
    total_checks=$((total_checks + 1))
    total_issues=$((total_issues + issues))
    log "AppArmor: $status ($issues issue(s))"
    # Convert @@N@@ to newlines for display and logging
    local display_details="${details//@@N@@/$'\n'}"
    printf "%s\n" "$display_details" >> "$LOG_FILE"
    if [[ -t 1 ]]; then
        printf "%s\n" "$display_details"
    fi
    
    # Fail2ban
    section "Checking Intrusion Prevention"
    result="$(check_fail2ban)"
    IFS='|' read -r status issues details <<< "$result"
    check_results["Fail2ban"]="$status"
    check_details["Fail2ban"]="$details"
    total_checks=$((total_checks + 1))
    total_issues=$((total_issues + issues))
    log "Fail2ban: $status ($issues issue(s))"
    # Convert @@N@@ to newlines for display and logging
    local display_details="${details//@@N@@/$'\n'}"
    printf "%s\n" "$display_details" >> "$LOG_FILE"
    if [[ -t 1 ]]; then
        printf "%s\n" "$display_details"
    fi
    
    # Kernel Security
    section "Checking Kernel Security Parameters"
    result="$(check_kernel_security)"
    IFS='|' read -r status issues details <<< "$result"
    check_results["Kernel Security"]="$status"
    check_details["Kernel Security"]="$details"
    total_checks=$((total_checks + 1))
    total_issues=$((total_issues + issues))
    log "Kernel Security: $status ($issues issue(s))"
    # Convert @@N@@ to newlines for display and logging
    local display_details="${details//@@N@@/$'\n'}"
    printf "%s\n" "$display_details" >> "$LOG_FILE"
    if [[ -t 1 ]]; then
        printf "%s\n" "$display_details"
    fi
    
    # Password Policy
    section "Checking Password Policy"
    result="$(check_password_policy)"
    IFS='|' read -r status issues details <<< "$result"
    check_results["Password Policy"]="$status"
    check_details["Password Policy"]="$details"
    total_checks=$((total_checks + 1))
    total_issues=$((total_issues + issues))
    log "Password Policy: $status ($issues issue(s))"
    display_details="${details//@@N@@/$'\n'}"
    printf "%s\n" "$display_details" >> "$LOG_FILE"
    if [[ -t 1 ]]; then
        printf "%s\n" "$display_details"
    fi
    
    # Account Security
    section "Checking Account Security"
    result="$(check_account_security)"
    IFS='|' read -r status issues details <<< "$result"
    check_results["Account Security"]="$status"
    check_details["Account Security"]="$details"
    total_checks=$((total_checks + 1))
    total_issues=$((total_issues + issues))
    log "Account Security: $status ($issues issue(s))"
    display_details="${details//@@N@@/$'\n'}"
    printf "%s\n" "$display_details" >> "$LOG_FILE"
    if [[ -t 1 ]]; then
        printf "%s\n" "$display_details"
    fi
    
    # File Permissions
    section "Checking Critical File Permissions"
    result="$(check_file_permissions)"
    IFS='|' read -r status issues details <<< "$result"
    check_results["File Permissions"]="$status"
    check_details["File Permissions"]="$details"
    total_checks=$((total_checks + 1))
    total_issues=$((total_issues + issues))
    log "File Permissions: $status ($issues issue(s))"
    display_details="${details//@@N@@/$'\n'}"
    printf "%s\n" "$display_details" >> "$LOG_FILE"
    if [[ -t 1 ]]; then
        printf "%s\n" "$display_details"
    fi
    
    # Sudo Configuration
    section "Checking Sudo Configuration"
    result="$(check_sudo_configuration)"
    IFS='|' read -r status issues details <<< "$result"
    check_results["Sudo Configuration"]="$status"
    check_details["Sudo Configuration"]="$details"
    total_checks=$((total_checks + 1))
    total_issues=$((total_issues + issues))
    log "Sudo Configuration: $status ($issues issue(s))"
    display_details="${details//@@N@@/$'\n'}"
    printf "%s\n" "$display_details" >> "$LOG_FILE"
    if [[ -t 1 ]]; then
        printf "%s\n" "$display_details"
    fi
    
    # Calculate summary counts
    for check in "${!check_results[@]}"; do
        case "${check_results[$check]}" in
            OK)
                ok_count=$((ok_count + 1))
                ;;
            WARN|INFO)
                warn_count=$((warn_count + 1))
                ;;
            CRITICAL)
                critical_count=$((critical_count + 1))
                ;;
        esac
    done
    
    # Generate HTML summary
    html_summary_section "$total_checks" "$ok_count" "$warn_count" "$critical_count"
    
    # Generate HTML check sections
    for check in "ICMP Rate Limiting" "Firewall" "SSH Security" "Automatic Updates" \
                 "Web Server Security" "SSL/TLS Certificates" "Open Ports" \
                 "AppArmor" "Fail2ban" "Kernel Security" "Password Policy" \
                 "Account Security" "File Permissions" "Sudo Configuration"; do
        html_check_section "$check" "${check_results[$check]}" "${check_details[$check]}"
    done
    
    # Determine if email should be sent
    local send_email_flag=false
    local email_subject
    local email_recipients
    
    log ""
    log "=========================================="
    log "SUMMARY:"
    log "  Total checks: $total_checks"
    log "  Passed (OK): $ok_count"
    log "  Warnings: $warn_count"
    log "  Critical: $critical_count"
    log "  Total issues found: $total_issues"
    log "=========================================="
    
    if [[ "$MONTHLY" == "true" ]]; then
        # Monthly verification - always send to both recipients
        send_email_flag=true
        email_recipients="$RECIPIENTS_MONTHLY"
        
        if [[ $total_issues -gt 0 ]]; then
            if [[ $critical_count -gt 0 ]]; then
                email_subject="${SUBJECT_PREFIX} Monthly Security Check: 🔴 ${critical_count} CRITICAL + ${warn_count} warnings — ${SCRIPT_NAME} @ $(date +'%Y-%m-%d %H:%M')"
            else
                email_subject="${SUBJECT_PREFIX} Monthly Security Check: ${warn_count} warning(s) found — ${SCRIPT_NAME} @ $(date +'%Y-%m-%d %H:%M')"
            fi
        else
            email_subject="${SUBJECT_PREFIX} Monthly Security Check: all checks passed — ${SCRIPT_NAME} @ $(date +'%Y-%m-%d %H:%M')"
        fi
        log "Monthly verification mode - email to: $email_recipients"
        
    elif [[ $total_issues -gt 0 ]]; then
        send_email_flag=true
        email_recipients="$RECIPIENTS_NORMAL"
        
        if [[ $critical_count -gt 0 ]]; then
            email_subject="${SUBJECT_PREFIX} ⚠️  Security Alert: ${critical_count} CRITICAL issue(s) + ${warn_count} warnings — ${SCRIPT_NAME} @ $(date +'%Y-%m-%d %H:%M')"
        else
            email_subject="${SUBJECT_PREFIX} Security Check: ${warn_count} warning(s) found — ${SCRIPT_NAME} @ $(date +'%Y-%m-%d %H:%M')"
        fi
        
        log "Security issues found on $HOSTNAME: $total_issues total ($critical_count critical, $warn_count warnings)"
    elif [[ "$VALIDATE" == "true" ]]; then
        send_email_flag=true
        email_recipients="$RECIPIENTS_VALIDATE"
        email_subject="${SUBJECT_PREFIX} Security validation: all checks passed — ${SCRIPT_NAME} @ $(date +'%Y-%m-%d %H:%M')"
        log "All checks passed on $HOSTNAME (validation mode)"
    else
        log "All checks passed and --validate not specified; skipping email"
    fi
    
    # Add additional recipient if specified
    if [[ -n "$ADDITIONAL_RECIPIENT" ]]; then
        email_recipients="${email_recipients} ${ADDITIONAL_RECIPIENT}"
        log "Additional recipient added: $ADDITIONAL_RECIPIENT"
    fi
    
    # Send email if needed
    if [[ "$send_email_flag" == "true" ]]; then
        section "Sending Email Report"
        html_footer
        html_end
        
        send_email "$email_subject" "$EMAIL_HTML_FILE" "$email_recipients"
    fi
    
    section "Security Hardening Check Completed"
    log "Done."

    # Explicit cleanup (also runs via trap)
    cleanup
}

# =============================================================================
# SCRIPT ENTRY POINT
# =============================================================================
main "$@"

exit 0
