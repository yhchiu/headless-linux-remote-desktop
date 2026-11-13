#!/usr/bin/env bash
# H-002: KasmVNC must start when the installer already wrote xstartup.
# Official vncserver runs select-de.sh unless ~/.vnc/.de-was-selected exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=tests/lib/sandbox.sh
source "$SCRIPT_DIR/../lib/sandbox.sh"

DEBIAN_SCRIPT="$REPO_ROOT/scripts/debian13-remote-desktop-setup.sh"
sandbox_reexec_if_needed "$@"

work="$(mktemp -d)"
stub="$work/bin"
export SANDBOX_LOG="$work/commands.log"
export SANDBOX_STATE="$work/state"
mkdir -p "$stub" "$SANDBOX_STATE"
: > "$SANDBOX_LOG"

sandbox_write_executable "$stub/apt-get" <<'EOF'
#!/bin/bash
exit 0
EOF
sandbox_write_executable "$stub/loginctl" <<'EOF'
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
sandbox_write_executable "$stub/select-de.sh" <<'EOF'
#!/bin/bash
echo "select-de invoked: $*" >> "${SANDBOX_LOG:?}"
exit 2
EOF
sandbox_write_executable "$stub/id" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == -u && "${2:-}" == hlrdkasm ]]; then
  printf '%s\n' 1001
  exit 0
fi
exec /usr/bin/id "$@"
EOF
sandbox_write_executable "$stub/systemctl" <<'EOF'
#!/bin/bash
echo "SYSTEMCTL $*" >> "${SANDBOX_LOG:?}"
state="${SANDBOX_STATE:?}"
if [[ "$*" == *is-active* && "$*" == *kasmvncserver* ]]; then
  if [[ -f "$state/active" ]]; then
    exit 0
  fi
  exit 3
fi
if [[ "$*" == *start* && "$*" == *kasmvncserver* ]]; then
  # Same gate as KasmVNC vncserver: a missing marker means "ask for a desktop",
  # which has no TTY under the systemd user service and aborts startup.
  if [[ ! -e "${HOME:?}/.vnc/.de-was-selected" ]]; then
    echo 'Please choose Desktop Environment to run: [1] XFCE [2] Manually edit xstartup' >&2
    echo 'Failed to execute /usr/lib/kasmvncserver/select-de.sh' >&2
    exit 1
  fi
  touch "$state/active"
  exit 0
fi
exit 0
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
mount -t tmpfs tmpfs /usr/lib/systemd/user
touch /usr/lib/systemd/user/kasmvncserver@.service

pkg="$work/kasm.deb"
printf 'not-a-real-package\n' > "$pkg"
sha="$(sha256sum "$pkg")"
sha="${sha%% *}"

set +e
output="$(bash "$DEBIAN_SCRIPT" \
  --server kasmvnc --user hlrdkasm --desktop xfce \
  --kasm-package "$pkg" --kasm-sha256 "$sha" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  printf '%s\n' "$output" >&2
  echo "KasmVNC installer failed with status $rc" >&2
  exit 1
fi
if ! grep -F -q 'SUCCESS: KasmVNC + xfce' <<<"$output"; then
  printf '%s\n' "$output" >&2
  echo 'Installer finished without SUCCESS.' >&2
  exit 1
fi
if grep -F -q 'select-de invoked' "$SANDBOX_LOG"; then
  echo 'select-de.sh ran and would replace the managed xstartup.' >&2
  cat "$SANDBOX_LOG" >&2
  exit 1
fi
marker="$home/.vnc/.de-was-selected"
if [[ ! -f "$marker" ]]; then
  echo "Missing desktop-selected marker: $marker" >&2
  exit 1
fi
assert_contains "$home/.vnc/xstartup" 'exec /usr/bin/dbus-launch --exit-with-session /usr/bin/startxfce4'
assert_contains "$home/.vnc/xstartup" 'Managed by debian13-remote-desktop-setup.sh'
if ! grep -F -q 'SYSTEMCTL --user start kasmvncserver@:1.service' "$SANDBOX_LOG"; then
  echo 'kasmvncserver user service was not started.' >&2
  cat "$SANDBOX_LOG" >&2
  exit 1
fi

echo 'H-002 KasmVNC desktop marker passed.'
