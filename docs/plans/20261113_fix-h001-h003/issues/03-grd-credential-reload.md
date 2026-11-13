# H-003: new gateway credentials stay out of the running daemon

## What went wrong

On a second Ubuntu installer run, `grdctl --system rdp set-credentials`
rewrites the on-disk gateway login (the headless GKeyFile,
`credentials.ini`). `gnome-remote-desktop` reads that file when the
process starts. It does not watch the file, and `grdctl` does not reload
a daemon that is already running.

The installer then calls `systemctl enable --now gnome-remote-desktop`.
`enable --now` starts an inactive unit, but it does not restart an
active one. After the rerun the service pid was unchanged: the old
gateway login still passed NLA, and the new login failed until
`systemctl restart gnome-remote-desktop` was run by hand.

`--skip-credentials` does not write a new login. Restarting in that case
would drop live sessions for no reason.

## Fix

Remember when this run actually called `set-credentials`. After GDM and
GNOME Remote Desktop have been enabled, restart
`gnome-remote-desktop` only in that case. The restart loads the file
that was just written, on a machine where the daemon was already up and
on a first install (the extra restart happens before any client is
connected). `--skip-credentials` still does not restart it.

GDM is not restarted. It does not hold the gateway password.

## Test

`tests/regression/h003-grd-credential-reload.sh` stubs `grdctl` so
`set-credentials` updates only the on-disk copy, and stubs `systemctl`
so an active daemon reloads that copy only on `restart`. One case
rotates credentials under an active daemon, one reruns with
`--skip-credentials`, and one starts from an inactive daemon.
