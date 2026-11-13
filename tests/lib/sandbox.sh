#!/usr/bin/env bash
# Helpers for installer regression tests.
#
# Each test re-executes itself in a throwaway mount namespace where it is
# root. Files written under /etc or /usr/bin stay in that namespace and
# disappear when the test exits. The host system is not modified.

sandbox_reexec_if_needed() {
  if [[ "${SANDBOX_INNER:-}" == 1 ]]; then
    return 0
  fi
  local script
  script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  if unshare --user --map-root-user --mount true 2>/dev/null; then
    exec unshare --user --map-root-user --mount \
      env SANDBOX_INNER=1 bash "$script" "$@"
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -n unshare --mount true 2>/dev/null; then
    exec sudo -n unshare --mount \
      env SANDBOX_INNER=1 bash "$script" "$@"
  fi
  echo 'A mount namespace is required (unshare --user --map-root-user --mount, or sudo -n unshare --mount).' >&2
  exit 1
}

# Replace /etc with a writable copy so a test can point os-release at a
# chosen distribution. The replacement body is read from stdin.
sandbox_use_fake_etc() {
  local body etc_save name
  body="$(cat)"
  etc_save="$(mktemp -d)"
  mount --bind /etc "$etc_save"
  mount -t tmpfs tmpfs /etc
  for name in ld.so.cache nsswitch.conf passwd group; do
    if [[ ! -e "$etc_save/$name" ]]; then
      echo "sandbox: host /etc/$name is required" >&2
      exit 1
    fi
    cp --no-preserve=ownership "$etc_save/$name" "/etc/$name"
  done
  printf '%s\n' "$body" > /etc/os-release
}

# Keep the real /usr/bin available through symlinks, then add files the
# installers check for by absolute path. CI images do not ship a desktop.
sandbox_overlay_usr_bin() {
  local real bin_path bin_name ln_bin ln_dir
  # ln may live in /bin, which disappears on a merged layout once /usr/bin
  # is covered. Ubuntu 26.04 rust-coreutils is one binary hardlinked under
  # each utility name, and it refuses to run unless that name is exactly
  # the utility (a mktemp name is rejected as "tmp"). Keep a private copy
  # whose filename is ln.
  ln_bin="$(type -P ln)"
  if [[ -z "$ln_bin" ]]; then
    echo 'sandbox: ln is not on PATH' >&2
    exit 1
  fi
  ln_dir="$(mktemp -d)"
  cp -L --no-preserve=ownership "$ln_bin" "$ln_dir/ln"
  chmod 0755 "$ln_dir/ln"
  real="$(mktemp -d)"
  mount --bind /usr/bin "$real"
  mount -t tmpfs tmpfs /usr/bin
  for bin_path in "$real"/*; do
    [[ -e "$bin_path" ]] || continue
    bin_name="${bin_path##*/}"
    "$ln_dir/ln" -s "$bin_path" "/usr/bin/$bin_name"
  done
  sandbox_install_fake_desktop_bins
}

sandbox_install_fake_desktop_bins() {
  local name
  for name in startxfce4 mate-session cinnamon-session-cinnamon startplasma-x11 dbus-launch; do
    rm -f "/usr/bin/$name"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "/usr/bin/$name"
    chmod 0755 "/usr/bin/$name"
  done
}

sandbox_write_executable() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path"
  chmod 0755 "$path"
}

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" != "$want" ]]; then
    printf '%s: got [%s], want [%s]\n' "$label" "$got" "$want" >&2
    exit 1
  fi
}

assert_contains() {
  local file="$1" needle="$2"
  if ! grep -F -q -- "$needle" "$file"; then
    printf 'Expected %s to contain: %s\n' "$file" "$needle" >&2
    printf '----- %s -----\n' "$file" >&2
    cat "$file" >&2 || true
    exit 1
  fi
}

assert_not_contains() {
  local file="$1" needle="$2"
  if grep -F -q -- "$needle" "$file"; then
    printf 'Expected %s to not contain: %s\n' "$file" "$needle" >&2
    printf '----- %s -----\n' "$file" >&2
    cat "$file" >&2 || true
    exit 1
  fi
}
