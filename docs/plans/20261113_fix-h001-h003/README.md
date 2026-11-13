# Fix H-001, H-002, and H-003

Investigation notes for the three installer bugs found on real Debian 13
and Ubuntu 26.04 guests. Each bug is one commit. The notes are the
decision record; the regression tests are the check that matters.

## Test approach

The repository already runs non-destructive smoke tests from `make check`
(`tests/run.sh`: `bash -n`, `--help`, `--version`, and rejected arguments).
A real desktop session needs a VM, so these bugs are covered with sandbox
tests instead of integration or end-to-end tests.

`tests/regression/*.sh` re-executes each installer in a throwaway mount
namespace. Package tools, `systemctl`, and account lookups are stubbed.
`/etc/os-release` is replaced with the guest text that triggered the bug.
Nothing is installed on the host. `make check` runs the smoke tests and
then every regression script.

## Commits

1. `fix(debian)` — H-001, script version clobbered by `/etc/os-release`.
2. `fix(kasmvnc)` — H-002, missing `~/.vnc/.de-was-selected`.
3. `fix(ubuntu)` — H-003, gateway credentials stay stale until restart.

Issue notes:

- `issues/01-script-version.md`
- `issues/02-kasm-de-marker.md`
- `issues/03-grd-credential-reload.md`
