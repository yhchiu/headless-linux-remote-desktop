#!/usr/bin/env bash
# Debian 13 (Trixie) headless desktop installer: xrdp or KasmVNC.
# Supported X11 desktops: xfce (default), mate, cinnamon, kde.
set -Eeuo pipefail

SCRIPT_VERSION='1.1.0'
DESKTOP='xfce'
SERVER='xrdp'
KASM_USER=''
KASM_PACKAGE=''
KASM_SHA256=''
KASM_VERSION='1.5.2'
KASM_DISPLAY='1'
KASM_TMP_DIR=''
trap 'if [[ -n "${KASM_TMP_DIR:-}" ]]; then rm -rf -- "$KASM_TMP_DIR"; fi' EXIT
SESMAN='/etc/xrdp/sesman.ini'
LAUNCHER='/etc/xrdp/debian13-desktop-session.sh'
BACKUP='/etc/xrdp/sesman.ini.before-debian13-xrdp-setup'

usage() {
  cat <<'EOF'
Usage: sudo bash debian13-remote-desktop-setup.sh [OPTIONS]

Installs an X11 desktop on Debian 13 Minimal/Server, using either xrdp or
KasmVNC. Defaults to xrdp + XFCE for backward compatibility.

Options:
  -d, --desktop NAME        xfce (default), mate, cinnamon, kde
  -s, --server NAME         xrdp (default), kasmvnc
  -u, --user LOGIN          Linux account that owns the KasmVNC desktop
                            (default: $SUDO_USER if non-root)
      --kasm-package PATH   Install a locally supplied Debian 13 KasmVNC .deb
      --kasm-sha256 HEX     Expected SHA-256 for --kasm-package
  -V, --version             Print script version
  -h, --help                Show help

Examples:
  sudo bash debian13-remote-desktop-setup.sh
  sudo bash debian13-remote-desktop-setup.sh --desktop mate
  sudo bash debian13-remote-desktop-setup.sh --server kasmvnc --user dev
  sudo bash debian13-remote-desktop-setup.sh -s kasmvnc -d kde -u dev

xrdp:   Linux password, RDP client, default TCP 3389. Uses an Xorg session.
KasmVNC: Separate KasmVNC web login; HTTPS on TCP 8444 (display :1).
         On first install you will be prompted for a KasmVNC password.
         Creates a per-user TLS certificate and a persistent user service.

Security:
  - Does not open firewall ports, create Linux users, or install Tailscale.
  - Restrict both remote desktop servers to Tailscale/VPN clients.
  - KasmVNC TLS uses a self-signed certificate (browser warning expected).
  - KasmVNC uses a separate display and cannot be opened with mstsc.
  - If both servers are installed, they create DIFFERENT desktop sessions.

KasmVNC is not in Debian's standard APT repos. By default this script
locates an exact Debian Trixie asset from official KasmVNC v1.5.2 GitHub
releases and verifies the GitHub-provided SHA-256 digest. It never installs
Bookworm packages as an implicit fallback. If that asset is unavailable,
use --kasm-package with a tested Debian 13 build.
EOF
}

log() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    -d|--desktop|-s|--server|-u|--user|--kasm-package|--kasm-sha256)
      (($# >= 2)) || die "Missing value for $1."
      case "$1" in
        -d|--desktop) DESKTOP="${2,,}" ;;
        -s|--server) SERVER="${2,,}" ;;
        -u|--user) KASM_USER="$2" ;;
        --kasm-package) KASM_PACKAGE="$2" ;;
        --kasm-sha256) KASM_SHA256="${2,,}" ;;
      esac
      shift 2
      ;;
    --desktop=*) DESKTOP="${1#*=}"; DESKTOP="${DESKTOP,,}"; shift ;;
    --server=*) SERVER="${1#*=}"; SERVER="${SERVER,,}"; shift ;;
    --user=*) KASM_USER="${1#*=}"; shift ;;
    --kasm-package=*) KASM_PACKAGE="${1#*=}"; shift ;;
    --kasm-sha256=*) KASM_SHA256="${1#*=}"; KASM_SHA256="${KASM_SHA256,,}"; shift ;;
    -V|--version) printf '%s\n' "$SCRIPT_VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
done

case "$DESKTOP" in
  xfce)
    packages=(xfce4 xfce4-terminal xfce4-notifyd)
    session='/usr/bin/startxfce4'
    current_desktop='XFCE'
    desktop_session='xfce'
    ;;
  mate)
    packages=(mate-desktop-environment-core)
    session='/usr/bin/mate-session'
    current_desktop='MATE'
    desktop_session='mate'
    ;;
  cinnamon)
    packages=(cinnamon-core)
    session='/usr/bin/cinnamon-session-cinnamon'
    current_desktop='X-Cinnamon'
    desktop_session='cinnamon'
    ;;
  kde)
    packages=(kde-plasma-desktop kwin-x11 konsole)
    session='/usr/bin/startplasma-x11'
    current_desktop='KDE'
    desktop_session='plasma'
    ;;
  *) die "Unsupported desktop: $DESKTOP (xfce|mate|cinnamon|kde)." ;;
esac
case "$SERVER" in xrdp|kasmvnc) ;; *) die "Unsupported server: $SERVER (xrdp|kasmvnc)." ;; esac
[[ "$SERVER" == 'kasmvnc' || ( -z "$KASM_USER" && -z "$KASM_PACKAGE" && -z "$KASM_SHA256" ) ]] || \
  die 'KasmVNC-only options require --server kasmvnc.'
[[ -z "$KASM_SHA256" || "$KASM_SHA256" =~ ^[0-9a-f]{64}$ ]] || die 'Invalid --kasm-sha256 (expected 64 hex characters).'
[[ -z "$KASM_SHA256" || -n "$KASM_PACKAGE" ]] || die '--kasm-sha256 requires --kasm-package.'

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
[[ "${ID:-}" == 'debian' && "${VERSION_ID:-}" == '13' ]] || \
  die "Debian 13 (Trixie) is required; detected ${PRETTY_NAME:-unknown OS}."
command -v apt-get >/dev/null || die 'apt-get not found.'
command -v systemctl >/dev/null || die 'systemd is required.'

if [[ "$SERVER" == 'kasmvnc' ]]; then
  if [[ -z "$KASM_USER" ]]; then
    KASM_USER="${SUDO_USER:-}"
  fi
  [[ -n "$KASM_USER" && "$KASM_USER" != root ]] || die 'Specify a non-root user with --user LOGIN for KasmVNC.'
  # Linux account names are used only as arguments, never evaluated as shell code.
  [[ "$KASM_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die 'Invalid Linux user name.'
  getent passwd "$KASM_USER" >/dev/null || die "Linux user '$KASM_USER' does not exist. Create it first: adduser $KASM_USER"
  KASM_UID="$(id -u "$KASM_USER")"
  (( KASM_UID != 0 )) || die 'Cannot run KasmVNC as root.'
  KASM_HOME="$(getent passwd "$KASM_USER" | cut -d: -f6)"
  [[ -d "$KASM_HOME" && "$KASM_HOME" != / ]] || die "Invalid home directory for '$KASM_USER'."
  if [[ -n "$KASM_PACKAGE" ]]; then
    [[ -f "$KASM_PACKAGE" && -r "$KASM_PACKAGE" ]] || die "Cannot read local package: $KASM_PACKAGE"
    KASM_PACKAGE="$(readlink -f -- "$KASM_PACKAGE")"
  fi
fi

trap 'printf "\n[ERROR] Setup stopped at line %d; inspect the command output above.\n" "$LINENO" >&2' ERR
export DEBIAN_FRONTEND=noninteractive

install_common() {
  log "Installing ${DESKTOP^^} (X11) on Debian 13 ..."
  apt-get update
  apt-get install -y --no-install-recommends \
    dbus-x11 dbus-user-session xauth x11-xserver-utils \
    fonts-dejavu-core fonts-noto-cjk \
    "${packages[@]}"
  [[ -x "$session" ]] || die "Expected desktop executable missing: $session"
}

install_xrdp() {
  log 'Installing and configuring xrdp ...'
  apt-get install -y --no-install-recommends xrdp xorgxrdp
  [[ -x /etc/X11/Xsession ]] || die 'Missing /etc/X11/Xsession.'
  [[ -f "$SESMAN" ]] || die "Missing $SESMAN."

  local manager
  manager="$(sed -nE 's/^[[:space:]]*DefaultWindowManager[[:space:]]*=[[:space:]]*([^[:space:];#]+).*/\1/p' "$SESMAN" | head -n1)"
  case "$manager" in
    startwm.sh|/etc/xrdp/startwm.sh|"$LAUNCHER") ;;
    '') die "DefaultWindowManager missing in $SESMAN." ;;
    *) die "Custom xrdp manager '$manager' detected; refusing to replace it." ;;
  esac
  for key in DefaultWindowManager AllowRootLogin KillDisconnected Policy; do
    grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "$SESMAN" || die "Missing setting '$key' in $SESMAN."
  done
  if [[ ! -e "$BACKUP" ]]; then
    cp -p -- "$SESMAN" "$BACKUP"
  fi
  cat > "$LAUNCHER" <<EOF
#!/bin/sh
# Managed by debian13-remote-desktop-setup.sh v$SCRIPT_VERSION.
# xrdp users share a default X11 desktop: $DESKTOP.
[ ! -r /etc/profile ] || . /etc/profile
[ ! -r "\$HOME/.profile" ] || . "\$HOME/.profile"
unset WAYLAND_DISPLAY
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP='$current_desktop'
export DESKTOP_SESSION='$desktop_session'
EOF
  if [[ "$DESKTOP" == kde ]]; then
    printf '%s\n' 'export KDE_FULL_SESSION=true' >> "$LAUNCHER"
  fi
  printf 'exec /etc/X11/Xsession %s\n' "$session" >> "$LAUNCHER"
  chmod 0755 "$LAUNCHER"
  sh -n "$LAUNCHER"
  sed -i -E \
    -e "s|^[[:space:]]*DefaultWindowManager[[:space:]]*=.*$|DefaultWindowManager=$LAUNCHER|" \
    -e 's/^[[:space:]]*AllowRootLogin[[:space:]]*=.*$/AllowRootLogin=false/' \
    -e 's/^[[:space:]]*KillDisconnected[[:space:]]*=.*$/KillDisconnected=false/' \
    -e 's/^[[:space:]]*Policy[[:space:]]*=.*$/Policy=Default/' \
    "$SESMAN"

  if [[ -e /etc/xrdp/key.pem && "$(readlink -f /etc/xrdp/key.pem)" == /etc/ssl/private/* ]]; then
    if getent passwd xrdp >/dev/null && getent group ssl-cert >/dev/null; then
      usermod -aG ssl-cert xrdp
    fi
  fi
  systemctl enable --now xrdp-sesman.service xrdp.service
  systemctl restart xrdp-sesman.service xrdp.service
  systemctl is-active --quiet xrdp.service || die 'xrdp is not running.'
  systemctl is-active --quiet xrdp-sesman.service || die 'xrdp-sesman is not running.'

  printf '\nSUCCESS: xrdp + %s\n' "$DESKTOP"
  printf 'Connect with RDP to your Tailscale IP on TCP 3389 (select Xorg).\n'
  printf 'Log in using an existing non-root Linux user and its password.\n'
  printf 'Logs: journalctl -u xrdp -u xrdp-sesman -b -n 100\n'
  warn 'The firewall was NOT modified. Restrict TCP 3389 to your Tailnet.'
}

kasm_fetch_package() {
  local api_json asset_info filename download_url digest
  KASM_TMP_DIR="$(mktemp -d)"
  log "Finding official Debian 13 (${KASM_VERSION}) KasmVNC package ..."
  api_json="$KASM_TMP_DIR/release.json"
  curl --fail --silent --show-error --location --retry 3 --proto '=https' \
    "https://api.github.com/repos/kasmtech/KasmVNC/releases/tags/v${KASM_VERSION}" \
    -o "$api_json" || die 'Unable to retrieve KasmVNC GitHub release information.'

  asset_info="$(python3 - "$api_json" "$KASM_VERSION" "$(dpkg --print-architecture)" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
version, arch = sys.argv[2:]
pattern = re.compile(r'^kasmvncserver_(?:debian_)?trixie_' + re.escape(version) + '_' + re.escape(arch) + r'\.deb$')
assets = [a for a in data.get('assets', []) if pattern.fullmatch(a.get('name', ''))]
if len(assets) != 1:
    sys.exit(2)
a = assets[0]
url = a.get('browser_download_url', '')
digest = a.get('digest') or ''
if not url.startswith('https://github.com/kasmtech/KasmVNC/releases/download/') or not digest.startswith('sha256:'):
    sys.exit(3)
hash_value = digest[len('sha256:'):]
if not re.fullmatch(r'[0-9a-fA-F]{64}', hash_value):
    sys.exit(4)
print(url + '\t' + hash_value.lower())
PY
)" || die "No uniquely matching, checksum-equipped Debian 13 ${KASM_VERSION} asset found for $(dpkg --print-architecture). Use --kasm-package with an officially built Trixie .deb."
  IFS=$'\t' read -r download_url digest <<< "$asset_info"
  filename="${download_url##*/}"
  KASM_PACKAGE="$KASM_TMP_DIR/$filename"
  curl --fail --silent --show-error --location --retry 3 --proto '=https' \
    "$download_url" -o "$KASM_PACKAGE" || die 'Could not download the KasmVNC package.'
  printf '%s  %s\n' "$digest" "$KASM_PACKAGE" | sha256sum --check --status || die 'KasmVNC SHA-256 verification failed.'
  log "Verified official package: $filename"
}

kasm_user_command() {
  # runuser creates a fresh login context including the target user's HOME.
  runuser -u "$KASM_USER" -- env HOME="$KASM_HOME" "$@"
}

kasm_user_systemctl() {
  kasm_user_command env \
    XDG_RUNTIME_DIR="/run/user/$KASM_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$KASM_UID/bus" \
    systemctl --user "$@"
}

install_kasmvnc() {
  local pkg_name pkg_arch vncdir xstartup yaml crt key marker active
  log 'Installing KasmVNC dependencies ...'
  apt-get install -y --no-install-recommends curl ca-certificates python3 openssl
  if [[ -z "$KASM_PACKAGE" ]]; then
    kasm_fetch_package
  else
    if [[ -n "$KASM_SHA256" ]]; then
      printf '%s  %s\n' "$KASM_SHA256" "$KASM_PACKAGE" | sha256sum --check --status || die 'Local package SHA-256 mismatch.'
    else
      warn 'Local .deb supplied without checksum: trusting the operator-provided local file.'
    fi
  fi
  pkg_name="$(dpkg-deb -f "$KASM_PACKAGE" Package)"
  pkg_arch="$(dpkg-deb -f "$KASM_PACKAGE" Architecture)"
  [[ "$pkg_name" == kasmvncserver ]] || die "Wrong package name: $pkg_name"
  [[ "$pkg_arch" == "$(dpkg --print-architecture)" ]] || die "Wrong package architecture: $pkg_arch"
  apt-get install -y --no-install-recommends "$KASM_PACKAGE"
  command -v kasmvncserver >/dev/null || die 'KasmVNC vncserver binary missing after installation.'
  command -v kasmvncpasswd >/dev/null || die 'KasmVNC password utility missing after installation.'

  vncdir="$KASM_HOME/.vnc"
  xstartup="$vncdir/xstartup"
  yaml="$vncdir/kasmvnc.yaml"
  crt="$vncdir/debian13-kasmvnc.crt"
  key="$vncdir/debian13-kasmvnc.key"
  marker='Managed by debian13-remote-desktop-setup.sh'
  for file in "$xstartup" "$yaml"; do
    if [[ -e "$file" ]] && ! grep -Fq "$marker" "$file"; then
      die "Existing custom KasmVNC config '$file' detected; refusing to overwrite. Back up/move it and retry."
    fi
  done
  # All home-directory writes happen as the target user (not root).
  # This avoids a privileged write following a user-controlled symlink.
  [[ ! -L "$vncdir" ]] || die "Refusing symlinked KasmVNC directory: $vncdir"
  kasm_user_command mkdir -p -- "$vncdir"
  kasm_user_command chmod 0700 "$vncdir"

  # Separate TLS certificate for this OS account; no need to grant access to
  # Debian's global ssl-cert group (which can read other private keys).
  if [[ ! -s "$crt" || ! -s "$key" ]]; then
    log "Creating a per-user self-signed TLS certificate for $KASM_USER ..."
    kasm_user_command openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 \
      -nodes -subj '/CN=KasmVNC-Tailscale' -keyout "$key" -out "$crt"
    kasm_user_command chmod 0600 "$key"
    kasm_user_command chmod 0644 "$crt"
  fi

  # Standalone Xvnc session, independent from xrdp's /etc/X11/Xsession.
  kasm_user_command tee "$xstartup" >/dev/null <<EOF
#!/bin/sh
# $marker v$SCRIPT_VERSION (desktop: $DESKTOP).
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
unset WAYLAND_DISPLAY
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP='$current_desktop'
export DESKTOP_SESSION='$desktop_session'
EOF
  if [[ "$DESKTOP" == kde ]]; then
    printf '%s\n' 'export KDE_FULL_SESSION=true' | kasm_user_command tee -a "$xstartup" >/dev/null
  fi
  printf 'exec /usr/bin/dbus-launch --exit-with-session %s\n' "$session" | kasm_user_command tee -a "$xstartup" >/dev/null
  kasm_user_command chmod 0755 "$xstartup"
  sh -n "$xstartup"
  # vncserver runs select-de.sh when this marker is missing, even if xstartup
  # already exists. That helper needs a TTY and would replace this file.
  # Do not call select-de.sh --select-de; touching the marker is enough.
  kasm_user_command touch -- "$vncdir/.de-was-selected"

  # Per-user YAML takes precedence over /etc/kasmvnc/kasmvnc.yaml.
  # Default network.websocket_port=auto => 8443 + display number (:1 = 8444).
  kasm_user_command tee "$yaml" >/dev/null <<EOF
# $marker v$SCRIPT_VERSION.
network:
  protocol: http
  interface: 0.0.0.0
  ssl:
    pem_certificate: '$crt'
    pem_key: '$key'
    require_ssl: true
EOF
  kasm_user_command chmod 0600 "$yaml"

  # Keep KasmVNC credentials separate from Linux login credentials.
  # Never pass passwords in CLI args, environment variables, or files in /tmp.
  if [[ ! -s "$KASM_HOME/.kasmpasswd" ]]; then
    [[ -t 0 ]] || die "Initial KasmVNC password requires a terminal. Run: sudo -u '$KASM_USER' vncpasswd -u '$KASM_USER' -w -r; then rerun the setup."
    log "Set a KasmVNC WEB password for '${KASM_USER}' (independent from Linux password)."
    kasm_user_command kasmvncpasswd -u "$KASM_USER" -w -r
  else
    log 'Existing KasmVNC password file found; leaving credentials untouched.'
  fi

  [[ -f /usr/lib/systemd/user/kasmvncserver@.service || -f /lib/systemd/user/kasmvncserver@.service ]] || \
    die 'Official KasmVNC user systemd unit was not installed.'
  log "Enabling persistent KasmVNC :${KASM_DISPLAY} user service for $KASM_USER ..."
  loginctl enable-linger "$KASM_USER"
  systemctl start "user@${KASM_UID}.service"
  kasm_user_systemctl daemon-reload
  active=0
  if kasm_user_systemctl is-active --quiet "kasmvncserver@:${KASM_DISPLAY}.service"; then
    active=1
  fi
  kasm_user_systemctl enable "kasmvncserver@:${KASM_DISPLAY}.service"
  if (( active )); then
    warn "KasmVNC session :${KASM_DISPLAY} is already active. Not restarting (to preserve running GUI apps)."
    warn "To apply a changed desktop, log out and restart the user's KasmVNC service explicitly."
  else
    kasm_user_systemctl start "kasmvncserver@:${KASM_DISPLAY}.service"
    kasm_user_systemctl is-active --quiet "kasmvncserver@:${KASM_DISPLAY}.service" || \
      die 'KasmVNC service failed to start. Check its user journal.'
  fi
  printf '\nSUCCESS: KasmVNC + %s\n' "$DESKTOP"
  printf 'Operating system user: %s\n' "$KASM_USER"
  printf 'KasmVNC web account: %s (separate web password)\n' "$KASM_USER"
  printf 'Connect using Chrome/Edge/Firefox: https://<tailscale-ip>:%d/\n' "$((8443 + KASM_DISPLAY))"
  printf 'User service: kasmvncserver@:%s.service\n' "$KASM_DISPLAY"
  printf "Logs: sudo -u %s env XDG_RUNTIME_DIR=/run/user/%s systemctl --user status 'kasmvncserver@:%s.service'\n" "$KASM_USER" "$KASM_UID" "$KASM_DISPLAY"
  warn 'Self-signed HTTPS cert: the browser will display a certificate warning.'
  warn "Firewall was NOT changed. Restrict TCP $((8443 + KASM_DISPLAY)) to your Tailnet."
  warn 'KasmVNC is browser-only and does NOT accept standard VNC/RDP viewers.'
}

install_common
case "$SERVER" in
  xrdp) install_xrdp ;;
  kasmvnc) install_kasmvnc ;;
esac
if command -v tailscale >/dev/null 2>&1; then
  ts_ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  if [[ -n "$ts_ip" ]]; then
    case "$SERVER" in
      xrdp) printf 'Tailscale RDP endpoint: %s:3389\n' "$ts_ip" ;;
      kasmvnc) printf 'Tailscale KasmVNC endpoint: https://%s:%d/\n' "$ts_ip" "$((8443+KASM_DISPLAY))" ;;
    esac
  fi
fi
warn 'Disconnect without logging out to keep running GUI applications alive.'
