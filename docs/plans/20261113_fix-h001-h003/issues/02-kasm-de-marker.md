# H-002: KasmVNC never receives the desktop-selected marker

## What went wrong

The Debian installer writes `~/.vnc/xstartup` and `kasmvnc.yaml`, enables
linger, and starts `kasmvncserver@:1.service`. Official KasmVNC 1.5.2
`vncserver` calls `ConfigureDeToRun()` before it uses xstartup.
`shouldPromptUserToSelectDe()` is true when `~/.vnc/.de-was-selected` is
absent, even if xstartup is already present. It then executes
`/usr/lib/kasmvncserver/select-de.sh`.

Under the systemd user service there is no terminal. `select-de.sh`
exits 2, the unit restarts, port 8444 never listens, and the installer
exits before printing SUCCESS. Creating the empty marker by hand and
starting the unit again launches the xstartup the installer wrote.
This happened on two Debian 13 guests.

`select-de.sh --select-de XFCE` is the wrong fix. That path rewrites
xstartup (`exec xfce4-session`) and drops the installer's
`dbus-launch ... startxfce4` session. `--select-de manual` would keep
xstartup and touch the marker, but it still shells out to the helper
for something that is only an existence check (`-e` on the marker).

## Fix

After the managed xstartup is written and checked with `sh -n`, create
`~/.vnc/.de-was-selected` as the target user with `touch`. Do not call
`select-de.sh`. A later start sees the marker and keeps the managed
xstartup. Repeating the installer just refreshes the same empty file.

## Test

`tests/regression/h002-kasm-de-marker.sh` stubs `systemctl --user start`
so it fails the way `vncserver` does when the marker is missing. The
installer must exit 0, print SUCCESS, leave the dbus-launch xstartup in
place, and never execute `select-de.sh`.
