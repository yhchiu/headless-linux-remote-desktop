#!/usr/bin/env bash
# Ubuntu 26.04 (Resolute) GNOME Wayland Remote Login for headless VMs.
# Uses the GNOME Remote Desktop SYSTEM service, not xrdp or Desktop Sharing.
set -Eeuo pipefail

SCRIPT_VERSION='1.0.0'
DESKTOP_PACKAGE='minimal'
SKIP_CREDENTIALS=false
STATUS_ONLY=false
GRD_USER='gnome-remote-desktop'
GRD_HOME=''
GRD_DIR=''
TLS_CERT=''
TLS_KEY=''

usage() {
  cat <<'HELP'
Usage: sudo bash ubuntu2604-gnome-rdp-setup.sh [OPTIONS]

Install GNOME Remote Login (Wayland RDP, port 3389) on a headless Ubuntu
26.04 LTS Server/Minimal VM. A physical monitor and GPU passthrough are
not required. The setup uses GDM and system-wide GNOME Remote Desktop.

Options:
  --desktop minimal|full     Ubuntu GNOME package set (default: minimal)
  --skip-credentials         Retain previously configured RDP gateway login
                             (for repeat runs only; does NOT create one)
  --status                   Show GNOME RDP and service status, then exit
  -V, --version              Print version and exit
  -h, --help                 Show help and exit

Examples:
  sudo bash ubuntu2604-gnome-rdp-setup.sh
  sudo bash ubuntu2604-gnome-rdp-setup.sh --desktop full
  sudo bash ubuntu2604-gnome-rdp-setup.sh --skip-credentials
  sudo bash ubuntu2604-gnome-rdp-setup.sh --status

Authentication has TWO steps:
  1. An independent GNOME RDP gateway username/password set interactively.
  2. A real Linux account + password at the GDM graphical login screen.

Security:
  - Gateway credentials are prompted by grdctl via /dev/tty, not CLI args.
  - No firewall rules, router mappings, Tailscale, or Linux users are created.
  - Restrict TCP 3389 to a trusted VPN/Tailnet; never expose RDP publicly.
  - RDP TLS uses a self-signed certificate by default.
  - Disconnect to preserve a session. Logging out or rebooting ends it.
HELP
}

log() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --desktop)
      (($# >= 2)) || die 'Missing value for --desktop.'
      DESKTOP_PACKAGE="${2,,}"
      shift 2
      ;;
    --desktop=*) DESKTOP_PACKAGE="${1#*=}"; DESKTOP_PACKAGE="${DESKTOP_PACKAGE,,}"; shift ;;
    --skip-credentials) SKIP_CREDENTIALS=true; shift ;;
    --status) STATUS_ONLY=true; shift ;;
    -V|--version) printf '%s\n' "$SCRIPT_VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)." ;;
  esac
done
case "$DESKTOP_PACKAGE" in minimal|full) ;; *) die "Invalid --desktop: $DESKTOP_PACKAGE (minimal|full)." ;; esac

(( EUID == 0 )) || die 'Run as root using sudo.'
[[ -r /etc/os-release ]] || die 'Cannot read /etc/os-release.'
# /etc/os-release assigns VERSION. Read the needed fields in a subshell so
# that value cannot replace SCRIPT_VERSION.
mapfile -t _os_release < <(
  # shellcheck disable=SC1091
  . /etc/os-release
  printf '%s\n' "${ID-}" "${VERSION_ID-}" "${PRETTY_NAME-}"
)
ID="${_os_release[0]:-}"
VERSION_ID="${_os_release[1]:-}"
PRETTY_NAME="${_os_release[2]:-}"
unset _os_release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 26.04 ]] || \
  die "Ubuntu 26.04 LTS is required; found ${PRETTY_NAME:-unknown}."
command -v systemctl >/dev/null || die 'systemd is required.'

show_status() {
  log 'GNOME Remote Login configuration:'
  if command -v grdctl >/dev/null 2>&1; then
    grdctl --system status || warn 'Unable to retrieve GNOME Remote Desktop status.'
  else
    warn 'grdctl is not installed.'
  fi
  for unit in gdm3.service gnome-remote-desktop.service; do
    printf '%-35s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"
  done
  if command -v ss >/dev/null 2>&1; then
    ss -lntp '( sport = :3389 )' || true
  fi
}

if "$STATUS_ONLY"; then
  show_status
  exit 0
fi

command -v apt-get >/dev/null || die 'apt-get is required.'

# Fail before changing the host if a competing RDP daemon is running.
if systemctl is-active --quiet xrdp.service; then
  die 'xrdp is running on this host. Stop and disable it before configuring GNOME RDP.'
fi
if command -v ss >/dev/null 2>&1; then
  if ss -H -lntp '( sport = :3389 )' 2>/dev/null | grep -q . && \
     ! systemctl is-active --quiet gnome-remote-desktop.service; then
    die 'TCP 3389 is already in use. Resolve the port conflict before continuing.'
  fi
fi
if systemctl is-active --quiet lightdm.service || systemctl is-active --quiet sddm.service; then
  die 'Another display manager is active (LightDM/SDDM); this setup requires GDM.'
fi

trap 'printf "\n[ERROR] Setup failed near line %d. Check the output above.\n" "$LINENO" >&2' ERR
export DEBIAN_FRONTEND=noninteractive

if [[ "$DESKTOP_PACKAGE" == minimal ]]; then
  meta_pkg='ubuntu-desktop-minimal'
else
  meta_pkg='ubuntu-desktop'
fi

log "Installing Ubuntu GNOME (${DESKTOP_PACKAGE}) + GNOME Remote Desktop ..."
apt-get update
apt-get install -y "$meta_pkg" gnome-remote-desktop gdm3 openssl ca-certificates

command -v grdctl >/dev/null || die 'grdctl not found after installing GNOME Remote Desktop.'
getent passwd "$GRD_USER" >/dev/null || die "Missing system user '$GRD_USER'."
GRD_HOME="$(getent passwd "$GRD_USER" | cut -d: -f6)"
[[ -n "$GRD_HOME" && "$GRD_HOME" == /* && "$GRD_HOME" != / ]] || die 'Invalid GNOME Remote Desktop service home.'
GRD_DIR="$GRD_HOME/.local/share/gnome-remote-desktop"
TLS_CERT="$GRD_DIR/tls.crt"
TLS_KEY="$GRD_DIR/tls.key"

# Only GNOME Remote Desktop's service user may access its private TLS key.
GRD_GROUP="$(id -gn "$GRD_USER")"
install -d -m 0700 -o "$GRD_USER" -g "$GRD_GROUP" "$GRD_HOME/.local"
install -d -m 0700 -o "$GRD_USER" -g "$GRD_GROUP" "$GRD_HOME/.local/share"
install -d -m 0700 -o "$GRD_USER" -g "$GRD_GROUP" "$GRD_DIR"
if [[ -L "$TLS_CERT" || -L "$TLS_KEY" ]]; then
  die 'TLS file symlink detected. Refusing to follow it.'
fi
if [[ ! -e "$TLS_CERT" && ! -e "$TLS_KEY" ]]; then
  log 'Generating a self-signed GNOME RDP certificate ...'
  runuser -u "$GRD_USER" -- openssl req \
    -x509 -newkey rsa:3072 -sha256 -days 1095 -noenc \
    -subj '/CN=GNOME-Remote-Desktop' \
    -keyout "$TLS_KEY" -out "$TLS_CERT"
elif [[ ! -s "$TLS_CERT" || ! -s "$TLS_KEY" ]]; then
  die 'Incomplete TLS pair found. Restore both TLS files or remove both before rerunning.'
else
  log 'Reusing existing GNOME RDP TLS certificate and private key.'
fi
chown "$GRD_USER:$GRD_GROUP" "$TLS_CERT" "$TLS_KEY"
chmod 0644 "$TLS_CERT"
chmod 0600 "$TLS_KEY"

log 'Configuring the system-wide GNOME Remote Login server ...'
grdctl --system rdp set-tls-key "$TLS_KEY"
grdctl --system rdp set-tls-cert "$TLS_CERT"
grdctl --system rdp set-auth-methods credentials

# True only when this run wrote a new gateway login. --skip-credentials
# must not bounce a daemon that is still using the saved password.
credentials_updated=false
if ! "$SKIP_CREDENTIALS"; then
  [[ -t 0 || -t 2 ]] || die 'Gateway credential setup requires an interactive TTY.'
  [[ -r /dev/tty ]] || die 'No controlling TTY available for gateway credential setup.'
  log 'Enter the RDP gateway USERNAME and PASSWORD when prompted by grdctl.'
  log 'This is separate from the real Linux login password at the GDM screen.'
  # Do not place the password in process arguments, environment, shell history,
  # or a temporary file. GNOME 50 grdctl prompts interactively via stdin.
  grdctl --system rdp set-credentials </dev/tty
  credentials_updated=true
else
  warn 'Skipping gateway credential setup; existing credentials must already be configured.'
fi

grdctl --system rdp enable

# GDM must start for headless system Remote Login even without a monitor.
# graphical.target ensures the display manager is started on future boots.
log 'Enabling GDM and GNOME Remote Desktop ...'
systemctl set-default graphical.target
systemctl enable --now gdm3.service
systemctl enable --now gnome-remote-desktop.service
if "$credentials_updated"; then
  # grdctl writes the gateway password to disk. A daemon that is already
  # running keeps the previous password in memory until it is restarted.
  log 'Restarting GNOME Remote Desktop so the new gateway credentials take effect ...'
  systemctl restart gnome-remote-desktop.service
fi
systemctl is-active --quiet gdm3.service || die 'GDM is not running.'
systemctl is-active --quiet gnome-remote-desktop.service || die 'GNOME Remote Desktop is not running.'

log 'Setup completed. Service status:'
show_status

printf '\nSUCCESS: Ubuntu 26.04 GNOME Remote Login (Wayland, RDP)\n'
printf 'RDP address: <tailscale-ip>:3389 (Windows: mstsc /v:<tailscale-ip>)\n'
printf 'Login step 1: GNOME RDP gateway credentials.\n'
printf 'Login step 2: existing Ubuntu user + Linux password at the GDM login screen.\n'
printf 'Your Ubuntu user must have a password (set with: sudo passwd <user>).\n'
printf 'Logs: sudo journalctl -u gnome-remote-desktop -u gdm3 -b -n 100 --no-pager\n'
if command -v tailscale >/dev/null 2>&1; then
  TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  [[ -z "$TS_IP" ]] || printf 'Tailscale endpoint: %s:3389\n' "$TS_IP"
fi
warn 'Firewall and Tailscale were NOT modified. Restrict TCP 3389 to trusted Tailnet/VPN clients.'
warn 'A self-signed TLS certificate triggers a one-time client certificate warning.'
warn 'If this is a fresh Desktop installation, reboot after preserving SSH/console access.'
