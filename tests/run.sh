#!/usr/bin/env bash
# Safe, non-destructive checks. Never runs installers with valid install args.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

scripts=(
  scripts/debian13-remote-desktop-setup.sh
  scripts/ubuntu2604-gnome-rdp-setup.sh
)
for script in "${scripts[@]}"; do
  echo "Checking $script"
  bash -n "$script"
  bash "$script" --help >/dev/null
  [[ "$(bash "$script" --version)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Failed version check: $script" >&2
    exit 1
  }
  if bash "$script" --this-option-must-not-exist >/dev/null 2>&1; then
    echo "Expected error on unknown argument: $script" >&2
    exit 1
  fi
done
for desktop in invalid ' '; do
  if bash scripts/ubuntu2604-gnome-rdp-setup.sh --desktop "$desktop" >/dev/null 2>&1; then
    echo 'Expected Ubuntu installer to reject invalid --desktop' >&2
    exit 1
  fi
done
for server in invalid; do
  if bash scripts/debian13-remote-desktop-setup.sh --server "$server" >/dev/null 2>&1; then
    echo 'Expected Debian installer to reject invalid --server' >&2
    exit 1
  fi
done
shopt -s nullglob
for regression in tests/regression/*.sh; do
  echo "Running $regression"
  bash "$regression"
done
printf 'All smoke and regression checks passed. No system changes were made.\n'
