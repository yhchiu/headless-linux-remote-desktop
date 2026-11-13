# H-001: os-release overwrites the installer version

## What went wrong

Both installers set a shell variable named `VERSION` (`1.1.0` on Debian,
`1.0.0` on Ubuntu) and later source `/etc/os-release`. Debian 13's file
assigns `VERSION="13 (trixie)"`. That assignment replaces the installer
version in the same shell.

`--version` still printed `1.1.0` because it exits before the source.
The xrdp launcher, KasmVNC `xstartup`, and `kasmvnc.yaml` are written
after the source, so their managed-by lines became `v13 (trixie)`.
Ubuntu has the same collision (`VERSION="26.04 LTS (...)"`) but does not
currently write that variable into a file. The OS check uses `ID` and
`VERSION_ID` only, so installation itself still ran.

A sandbox run of the Debian installer against a Debian 13 os-release
reproduced the launcher line `v13 (trixie)` before the fix.

## Fix

Keep the installer version in `SCRIPT_VERSION`. Load only `ID`,
`VERSION_ID`, and `PRETTY_NAME` from `/etc/os-release` inside a subshell.
Renaming protects the markers even if a later edit sources the file in
the main shell. The subshell stops the rest of os-release, including its
`VERSION`, from leaking into the installer shell.

The script versions stay `1.1.0` and `1.0.0`. There is no changelog to
update. The bug was the wrong string, not a new release number.

## Test

`tests/regression/h001-script-version.sh` rejects a top-level source of
`/etc/os-release`, then runs the Debian installer in a namespace whose
os-release `VERSION` is `13 (trixie)`. The generated launcher, xstartup,
and yaml must cite `v1.1.0` and must not cite trixie. Ubuntu `--status`
must still accept a 26.04 os-release.
