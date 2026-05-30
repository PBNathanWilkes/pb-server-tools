#!/usr/bin/env bash
# install.sh — Bootstrap and deploy all pb-server-tools components
#
# Run from the repo root as:
#   sudo bash install.sh [--only <component>]
#
# Components (installed in dependency order):
#   check-for-updates   patch monitoring + systemd timers
#   security-hardening  security posture checks + systemd timers
#   login-compliance    login-time banner check
#   server-sanity       read-only infrastructure sanity check
#
# Options:
#   --only <component>  Install a single named component only
#   --help, -h          Show this help
#
# Each component's install.sh is independently runnable; this script
# is a convenience wrapper that handles prerequisites and ordering.

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf '\n[pb-server-tools] %s\n' "$*"; }
ok()    { printf '  OK  %s\n' "$*"; }
die()   { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Must run as root: sudo bash install.sh"
}

show_help() {
  cat <<EOF
Usage: sudo bash install.sh [--only <component>]

Components:
  check-for-updates    Patch monitoring (systemd timers, email reports)
  security-hardening   Security posture checks (systemd timers, email reports)
  login-compliance     Login-time banner (manual .bashrc step required)
  server-sanity        Read-only infrastructure sanity check

Options:
  --only <component>   Install only the named component
  --help, -h           Show this help

Run with no arguments to install all components in order.
EOF
}

# ---------------------------------------------------------------------------
# Step 1 — System-level prerequisites
#
# Each component install.sh also checks its own prerequisites; this step
# installs missing packages up front so failures are reported at the start
# rather than mid-way through deployment.
# ---------------------------------------------------------------------------
install_prereqs() {
  info "Installing system prerequisites"

  local missing=()
  local packages=(
    jq
    msmtp
    s-nail
    openssl
    python3
    python3-apt
    python3-pytest
    ufw
    iproute2
  )

  for pkg in "${packages[@]}"; do
    # Map package name to binary name where they differ
    local bin="$pkg"
    case "$pkg" in
      s-nail)      bin="mailx" ;;
      iproute2)    bin="ss" ;;
      python3-apt) bin="" ;;    # checked via python3 import below
      python3-pytest) bin="" ;; # checked via python3 import below
    esac

    if [[ -n "$bin" ]]; then
      command -v "$bin" >/dev/null 2>&1 || missing+=("$pkg")
    fi
  done

  # python3-apt and python3-pytest need import checks
  python3 -B -c "import apt_pkg" 2>/dev/null || missing+=("python3-apt")
  python3 -B -c "import pytest"  2>/dev/null || missing+=("python3-pytest")

  if [[ ${#missing[@]} -gt 0 ]]; then
    info "Installing missing packages: ${missing[*]}"
    apt-get update -qq
    apt-get install -y "${missing[@]}"
    ok "packages installed: ${missing[*]}"
  else
    ok "all prerequisites already present"
  fi
}

# ---------------------------------------------------------------------------
# Step 2 — Ensure log directories exist
# ---------------------------------------------------------------------------
ensure_log_dirs() {
  info "Ensuring log directories"

  local dirs=(
    /backup/patch-logs
    /backup/security-logs
  )
  local d
  for d in "${dirs[@]}"; do
    if [[ ! -d "$d" ]]; then
      mkdir -p "$d"
      chmod 0750 "$d"
      ok "created ${d}"
    else
      ok "exists  ${d}"
    fi
  done
}

# ---------------------------------------------------------------------------
# Component installer
# ---------------------------------------------------------------------------
run_component() {
  local component="$1"
  local component_dir="${SCRIPT_DIR}/${component}"

  [[ -d "$component_dir" ]] \
    || die "Component directory not found: ${component_dir}"
  [[ -f "${component_dir}/install.sh" ]] \
    || die "No install.sh found in: ${component_dir}"

  info "Installing component: ${component}"
  bash "${component_dir}/install.sh"
  ok "${component} installed"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
ONLY_COMPONENT=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --only)
        [[ -n "${2:-}" ]] || die "--only requires a component name"
        ONLY_COMPONENT="$2"
        shift 2
        ;;
      --help|-h)
        show_help
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  require_root

  if [[ -n "$ONLY_COMPONENT" ]]; then
    install_prereqs
    run_component "$ONLY_COMPONENT"
  else
    install_prereqs
    ensure_log_dirs
    run_component "check-for-updates"
    run_component "security-hardening"
    run_component "login-compliance"
    run_component "server-sanity"
  fi

  printf '\n[pb-server-tools] All components installed successfully.\n'
  printf '\nNext steps:\n'
  printf '  1. Verify msmtp config: sudo msmtp --serverinfo --host=<smtp-host>\n'
  printf '  2. Run a manual check: sudo /usr/local/libexec/pb-maintenance/check-for-updates.sh --validate\n'
  printf '  3. Run a manual check: sudo /usr/local/libexec/pb-maintenance/security-hardening-check.sh --validate\n'
  printf '  4. Add login-compliance snippet to ~/.bashrc (printed during login-compliance install)\n'
  printf '  5. Confirm timers: systemctl list-timers --all --no-pager\n'
  printf '  6. Run sanity check: sudo server-sanity-check\n'
}

main "$@"
