#!/usr/bin/env bash
# H-001: generated markers must use the installer version, not os-release VERSION.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=tests/lib/sandbox.sh
source "$SCRIPT_DIR/../lib/sandbox.sh"

DEBIAN_SCRIPT="$REPO_ROOT/scripts/debian13-remote-desktop-setup.sh"
UBUNTU_SCRIPT="$REPO_ROOT/scripts/ubuntu2604-gnome-rdp-setup.sh"

assert_eq "$(bash "$DEBIAN_SCRIPT" --version)" '1.1.0' 'debian --version'
assert_eq "$(bash "$UBUNTU_SCRIPT" --version)" '1.0.0' 'ubuntu --version'

# A top-level source runs in the installer shell and overwrites VERSION.
assert_no_toplevel_os_release() {
  local file="$1"
  if grep -nE '^(\.|source)[[:space:]]+/etc/os-release([[:space:]]|$)' "$file"; then
    echo "Top-level /etc/os-release source in $file overwrites the script version." >&2
    exit 1
  fi
}
assert_no_toplevel_os_release "$DEBIAN_SCRIPT"
assert_no_toplevel_os_release "$UBUNTU_SCRIPT"

debian_version="$(sed -n "s/^SCRIPT_VERSION='\\([^']*\\)'/\\1/p" "$DEBIAN_SCRIPT")"
assert_eq "$debian_version" '1.1.0' 'debian SCRIPT_VERSION assignment'

sandbox_reexec_if_needed "$@"

work="$(mktemp -d)"
stub="$work/bin"
mkdir -p "$stub"
sandbox_write_executable "$stub/apt-get" <<'EOF'
#!/bin/bash
exit 0
EOF
sandbox_write_executable "$stub/systemctl" <<'EOF'
#!/bin/bash
exit 0
EOF
sandbox_write_executable "$stub/loginctl" <<'EOF'
#!/bin/bash
exit 0
EOF
sandbox_write_executable "$stub/usermod" <<'EOF'
#!/bin/bash
exit 0
EOF
sandbox_write_executable "$stub/runuser" <<'EOF'
#!/bin/bash
while (($#)); do
  case "$1" in
    -u) shift 2 ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
exec "$@"
EOF
sandbox_write_executable "$stub/dpkg-deb" <<'EOF'
#!/bin/bash
field="${3:-}"
case "$field" in
  Package) printf '%s\n' kasmvncserver ;;
  Architecture) dpkg --print-architecture ;;
  *) exit 1 ;;
esac
EOF
sandbox_write_executable "$stub/openssl" <<'EOF'
#!/bin/bash
key='' crt='' prev=''
for arg in "$@"; do
  if [[ "$prev" == -keyout ]]; then key="$arg"; fi
  if [[ "$prev" == -out ]]; then crt="$arg"; fi
  prev="$arg"
done
[[ -n "$key" && -n "$crt" ]] || exit 1
printf 'KEY\n' > "$key"
printf 'CRT\n' > "$crt"
EOF
sandbox_write_executable "$stub/kasmvncserver" <<'EOF'
#!/bin/bash
exit 0
EOF
sandbox_write_executable "$stub/kasmvncpasswd" <<'EOF'
#!/bin/bash
echo 'kasmvncpasswd should not run when .kasmpasswd exists' >&2
exit 1
EOF
sandbox_write_executable "$stub/id" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == -u && "${2:-}" == hlrdkasm ]]; then
  printf '%s\n' 1001
  exit 0
fi
exec /usr/bin/id "$@"
EOF
home="$work/home/hlrdkasm"
mkdir -p "$home"
printf 'web-password\n' > "$home/.kasmpasswd"
sandbox_write_executable "$stub/getent" <<EOF
#!/bin/bash
if [[ "\${1:-}" == passwd && "\${2:-}" == hlrdkasm ]]; then
  printf '%s\n' 'hlrdkasm:x:1001:1001::$home:/bin/bash'
  exit 0
fi
exec /usr/bin/getent "\$@"
EOF

export PATH="$stub:$PATH"
sandbox_overlay_usr_bin
sandbox_use_fake_etc <<'EOF'
NAME="Debian GNU/Linux"
VERSION="13 (trixie)"
VERSION_ID="13"
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
ID=debian
EOF
mkdir -p /etc/xrdp /etc/X11
cat > /etc/xrdp/sesman.ini <<'EOF'
[Security]
AllowRootLogin=true
[Sessions]
KillDisconnected=true
Policy=UBC
[Globals]
DefaultWindowManager=startwm.sh
EOF
printf '%s\n' '#!/bin/sh' 'exit 0' > /etc/X11/Xsession
chmod 0755 /etc/X11/Xsession
mount -t tmpfs tmpfs /usr/lib/systemd/user
touch /usr/lib/systemd/user/kasmvncserver@.service

run_installer() {
  local output rc
  set +e
  output="$("$@" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    printf '%s\n' "$output" >&2
    echo "installer failed: $*" >&2
    exit 1
  fi
  printf '%s\n' "$output"
}

run_installer bash "$DEBIAN_SCRIPT" --server xrdp --desktop xfce >/dev/null
launcher=/etc/xrdp/debian13-desktop-session.sh
assert_contains "$launcher" "# Managed by debian13-remote-desktop-setup.sh v${debian_version}."
assert_not_contains "$launcher" 'trixie'
assert_not_contains "$launcher" 'v13'
assert_contains "$launcher" "export XDG_CURRENT_DESKTOP='XFCE'"
assert_contains "$launcher" 'exec /etc/X11/Xsession /usr/bin/startxfce4'

pkg="$work/kasm.deb"
printf 'not-a-real-package\n' > "$pkg"
sha="$(sha256sum "$pkg")"
sha="${sha%% *}"
run_installer bash "$DEBIAN_SCRIPT" \
  --server kasmvnc --user hlrdkasm --desktop xfce \
  --kasm-package "$pkg" --kasm-sha256 "$sha" >/dev/null
xstartup="$home/.vnc/xstartup"
yaml="$home/.vnc/kasmvnc.yaml"
assert_contains "$xstartup" "# Managed by debian13-remote-desktop-setup.sh v${debian_version} (desktop: xfce)."
assert_contains "$yaml" "# Managed by debian13-remote-desktop-setup.sh v${debian_version}."
assert_not_contains "$xstartup" 'trixie'
assert_not_contains "$yaml" 'trixie'
assert_contains "$xstartup" 'exec /usr/bin/dbus-launch --exit-with-session /usr/bin/startxfce4'

cat > /etc/os-release <<'EOF'
NAME="Ubuntu"
VERSION="26.04 LTS (Resolute Raccoon)"
VERSION_ID="26.04"
PRETTY_NAME="Ubuntu 26.04 LTS"
ID=ubuntu
EOF
run_installer bash "$UBUNTU_SCRIPT" --status >/dev/null

echo 'H-001 script version markers passed.'
