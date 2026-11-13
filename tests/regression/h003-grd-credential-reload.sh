#!/usr/bin/env bash
# H-003: new GNOME RDP gateway credentials must replace the ones in memory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=tests/lib/sandbox.sh
source "$SCRIPT_DIR/../lib/sandbox.sh"

UBUNTU_SCRIPT="$REPO_ROOT/scripts/ubuntu2604-gnome-rdp-setup.sh"
sandbox_reexec_if_needed "$@"

work="$(mktemp -d)"
stub="$work/bin"
state="$work/state"
export SANDBOX_LOG="$work/commands.log"
export SANDBOX_STATE="$state"
mkdir -p "$stub" "$state"
: > "$SANDBOX_LOG"

home="$work/home/gnome-remote-desktop"
grd_dir="$home/.local/share/gnome-remote-desktop"
mkdir -p "$grd_dir"
printf 'CERT\n' > "$grd_dir/tls.crt"
printf 'KEY\n' > "$grd_dir/tls.key"

sandbox_write_executable "$stub/apt-get" <<'EOF'
#!/bin/bash
exit 0
EOF
sandbox_write_executable "$stub/ss" <<'EOF'
#!/bin/bash
exit 0
EOF
sandbox_write_executable "$stub/chown" <<'EOF'
#!/bin/bash
exit 0
EOF
sandbox_write_executable "$stub/install" <<'EOF'
#!/bin/bash
dir=''
for arg in "$@"; do
  case "$arg" in
    -*) ;;
    *) dir="$arg" ;;
  esac
done
mkdir -p -- "$dir"
EOF
sandbox_write_executable "$stub/id" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == -gn ]]; then
  printf '%s\n' gnome-remote-desktop
  exit 0
fi
exec /usr/bin/id "$@"
EOF
sandbox_write_executable "$stub/getent" <<EOF
#!/bin/bash
if [[ "\${1:-}" == passwd && "\${2:-}" == gnome-remote-desktop ]]; then
  printf '%s\n' 'gnome-remote-desktop:x:0:0::$home:/usr/sbin/nologin'
  exit 0
fi
exec /usr/bin/getent "\$@"
EOF
sandbox_write_executable "$stub/grdctl" <<'EOF'
#!/bin/bash
echo "GRDCTL $*" >> "${SANDBOX_LOG:?}"
if [[ "$*" == *set-credentials* ]]; then
  IFS= read -r user || true
  IFS= read -r pass || true
  if [[ -z "$user" || -z "$pass" ]]; then
    echo 'grdctl received empty gateway credentials' >&2
    exit 1
  fi
  # Disk changes immediately. A running daemon keeps its old copy.
  printf '%s\n' "$user" > "${SANDBOX_STATE:?}/disk-user"
  printf '%s\n' "$pass" > "${SANDBOX_STATE}/disk-pass"
  exit 0
fi
if [[ "$*" == *status* ]]; then
  printf '%s\n' 'RDP: enabled'
  exit 0
fi
exit 0
EOF
sandbox_write_executable "$stub/systemctl" <<'EOF'
#!/bin/bash
echo "SYSTEMCTL $*" >> "${SANDBOX_LOG:?}"
state="${SANDBOX_STATE:?}"
unit=''
for arg in "$@"; do
  case "$arg" in
    *.service) unit="$arg" ;;
  esac
done
load_disk_into_daemon() {
  cp "$state/disk-user" "$state/loaded-user"
  cp "$state/disk-pass" "$state/loaded-pass"
  printf '%s\n' active > "$state/grd-active"
}
if [[ "$1" == is-active ]]; then
  case "$unit" in
    gnome-remote-desktop.service)
      [[ "$(cat "$state/grd-active")" == active ]]
      exit $?
      ;;
    gdm3.service)
      [[ -f "$state/gdm-active" ]]
      exit $?
      ;;
    *) exit 3 ;;
  esac
fi
if [[ "$*" == *restart* && "$unit" == gnome-remote-desktop.service ]]; then
  load_disk_into_daemon
  exit 0
fi
if [[ "$*" == *enable* && "$*" == *--now* ]]; then
  if [[ "$*" == *gdm3.service* ]]; then
    touch "$state/gdm-active"
  fi
  if [[ "$*" == *gnome-remote-desktop.service* && "$(cat "$state/grd-active")" != active ]]; then
    load_disk_into_daemon
  fi
fi
exit 0
EOF

cat > "$work/feed.py" <<'PY'
import os, pty, select, sys, time

installer, user, password = sys.argv[1:4]
extra = sys.argv[4:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", installer, *extra])
sent = False
seen = b""
deadline = time.time() + 20
while time.time() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.1)
    if ready:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            chunk = b""
        if chunk:
            seen += chunk
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            if not sent and (b"USERNAME" in seen or b"Enter the RDP" in seen):
                os.write(fd, (user + "\n" + password + "\n").encode())
                sent = True
    wpid, status = os.waitpid(pid, os.WNOHANG)
    if wpid:
        while True:
            ready, _, _ = select.select([fd], [], [], 0.05)
            if not ready:
                break
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
        if not sent:
            sys.stderr.write("credential prompt was not seen\n")
            sys.exit(2)
        sys.exit(os.waitstatus_to_exitcode(status))
sys.stderr.write("timed out waiting for the installer\n")
sys.exit(124)
PY

export PATH="$stub:$PATH"
sandbox_overlay_usr_bin
sandbox_use_fake_etc <<'EOF'
NAME="Ubuntu"
VERSION="26.04 LTS (Resolute Raccoon)"
VERSION_ID="26.04"
PRETTY_NAME="Ubuntu 26.04 LTS"
ID=ubuntu
EOF

reset_daemon() {
  local active="$1" user="$2" pass="$3"
  printf '%s\n' "$active" > "$state/grd-active"
  printf '%s\n' "$user" > "$state/loaded-user"
  printf '%s\n' "$pass" > "$state/loaded-pass"
  printf '%s\n' "$user" > "$state/disk-user"
  printf '%s\n' "$pass" > "$state/disk-pass"
  rm -f "$state/gdm-active"
  : > "$SANDBOX_LOG"
}

assert_loaded() {
  local user="$1" pass="$2"
  assert_eq "$(cat "$state/loaded-user")" "$user" 'in-memory gateway user'
  assert_eq "$(cat "$state/loaded-pass")" "$pass" 'in-memory gateway password'
}

require_restart() {
  if ! grep -F -q 'SYSTEMCTL restart gnome-remote-desktop.service' "$SANDBOX_LOG"; then
    echo 'gnome-remote-desktop was not restarted after set-credentials.' >&2
    cat "$SANDBOX_LOG" >&2
    exit 1
  fi
}

refuse_restart() {
  if grep -F -q 'SYSTEMCTL restart gnome-remote-desktop.service' "$SANDBOX_LOG"; then
    echo 'gnome-remote-desktop was restarted even though credentials were kept.' >&2
    cat "$SANDBOX_LOG" >&2
    exit 1
  fi
}

run_installer() {
  local output rc
  set +e
  output="$("$@" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    printf '%s\n' "$output" >&2
    echo "installer failed with status $rc" >&2
    exit 1
  fi
  if ! grep -F -q 'SUCCESS: Ubuntu 26.04 GNOME Remote Login (Wayland, RDP)' <<<"$output"; then
    printf '%s\n' "$output" >&2
    echo 'Installer finished without SUCCESS.' >&2
    exit 1
  fi
}

echo 'Case: running daemon must load the new gateway credentials'
reset_daemon active old-user old-pass
run_installer python3 "$work/feed.py" "$UBUNTU_SCRIPT" gateway-user gateway-secret --desktop minimal
assert_loaded gateway-user gateway-secret
require_restart
assert_eq "$(cat "$state/disk-user")" gateway-user 'on-disk gateway user'

echo 'Case: --skip-credentials must leave the running daemon alone'
reset_daemon active old-user old-pass
run_installer bash "$UBUNTU_SCRIPT" --desktop minimal --skip-credentials
assert_loaded old-user old-pass
refuse_restart

echo 'Case: first start must also load the credentials just saved'
reset_daemon inactive stale-user stale-pass
run_installer python3 "$work/feed.py" "$UBUNTU_SCRIPT" gateway-user gateway-secret --desktop minimal
assert_loaded gateway-user gateway-secret
require_restart

echo 'H-003 gateway credential reload passed.'
