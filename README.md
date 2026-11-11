# Headless Linux Remote Desktop Setup

Bash installers for persistent remote GUI sessions on **headless Linux virtual machines**. Intended for private networks such as Tailscale, with no physical monitor or GPU passthrough required.

- **Debian 13 (Trixie):** xrdp or KasmVNC, with XFCE, MATE, Cinnamon, or KDE Plasma (X11).
- **Ubuntu 26.04 LTS (Resolute):** GNOME Remote Desktop **Remote Login** (Wayland/RDP), integrated with GDM.

Each installer checks the OS release and refuses unsupported distributions. The scripts do not install Tailscale, create network port-forwarding rules, open firewall ports, or create Linux accounts.

## Quick start

Clone or extract this repository on the target VM. Execute only the script matching your operating system.

### Debian 13 — xrdp (XFCE by default)

```bash
sudo bash scripts/debian13-remote-desktop-setup.sh
```

Pick a different desktop:

```bash
sudo bash scripts/debian13-remote-desktop-setup.sh --server xrdp --desktop mate
sudo bash scripts/debian13-remote-desktop-setup.sh --server xrdp --desktop cinnamon
sudo bash scripts/debian13-remote-desktop-setup.sh --server xrdp --desktop kde
```

Connect with an RDP client, e.g. on Windows:

```powershell
mstsc /v:100.x.y.z
```

Choose the **Xorg** session at the xrdp login screen and use an existing, non-root Linux account with a password.

### Debian 13 — KasmVNC (browser-based HTTPS)

```bash
sudo bash scripts/debian13-remote-desktop-setup.sh --server kasmvnc --user dev
```

Optional desktop selection:

```bash
sudo bash scripts/debian13-remote-desktop-setup.sh --server kasmvnc --desktop kde --user dev
```

KasmVNC requires a non-root Linux user (`--user`, or the sudo caller). The script prompts for a separate web login password on initial setup and creates a persistent user service. Access the browser UI at:

```text
https://100.x.y.z:8444/
```

A self-signed TLS certificate produces a browser warning. The service uses a separate desktop display, **not** the same GUI session as xrdp.

**KasmVNC package policy:** The Debian script looks for an **exact Debian 13/Trixie** release asset for its pinned KasmVNC version, and verifies the asset's published SHA-256. It deliberately will **not** install a Debian 12/Bookworm package as a fallback. If the matching Trixie asset is unavailable, use a verified local Debian 13 build:

```bash
sudo bash scripts/debian13-remote-desktop-setup.sh \
  --server kasmvnc --user dev \
  --kasm-package /path/to/kasmvncserver_trixie_VERSION_amd64.deb \
  --kasm-sha256 YOUR_64_CHARACTER_SHA256
```

The local package must be a compatible `kasmvncserver` package with the correct architecture. Consult the [KasmVNC release assets](https://github.com/kasmtech/KasmVNC/releases) and [official installation documentation](https://docs.kasmvnc.com/docs/install/).

### Ubuntu 26.04 — GNOME Remote Login (Wayland RDP)

```bash
sudo bash scripts/ubuntu2604-gnome-rdp-setup.sh
```

Installs `ubuntu-desktop-minimal` by default; to install the complete Ubuntu GNOME package set instead:

```bash
sudo bash scripts/ubuntu2604-gnome-rdp-setup.sh --desktop full
```

The installer configures **system-wide GNOME Remote Login**, **not Desktop Sharing**, and **not xrdp**. You must have an interactive terminal for the one-time RDP gateway credential prompt.

After installation, ensure the real Linux login user also has a password:

```bash
sudo passwd dev
```

Connect using an RDP client (e.g. `mstsc /v:100.x.y.z`). Authentication is **two-stage**:

1. Enter the **GNOME RDP gateway** username and password you created during setup.
2. At the GDM login screen, enter the **actual Ubuntu Linux account** and password.

No auto-login, physical display, or pre-existing graphical user session is needed. To check configuration and services:

```bash
sudo bash scripts/ubuntu2604-gnome-rdp-setup.sh --status
```

To rerun the setup without rotating previously configured gateway credentials:

```bash
sudo bash scripts/ubuntu2604-gnome-rdp-setup.sh --skip-credentials
```

**Important:** `--skip-credentials` does not create or validate gateway credentials. Use it only after successful setup. To change the gateway credentials, run the installer without that flag. The script reuses existing TLS certificate/key files and does not automatically renew them. GDM is enabled and the default systemd target is set to `graphical.target`; that is necessary for login services even on a monitorless VM. A fresh server installation should be rebooted after setup.

For upstream reference, see [Canonical's Ubuntu 26.04 RDP guide](https://ubuntu.com/aws/docs/aws-how-to/instances/launch-ubuntu-desktop/) and [GNOME's Remote Desktop configuration](https://github.com/GNOME/gnome-remote-desktop/blob/main/docs/configuration.md).

## Feature comparison

| Feature | Debian 13 + xrdp | Debian 13 + KasmVNC | Ubuntu 26.04 + GNOME Remote Login |
| --- | --- | --- | --- |
| Client | RDP / FreeRDP | Modern web browser | RDP / FreeRDP |
| Default TCP port | 3389 | 8444 (`:1` display) | 3389 |
| Session type | Independent Xorg desktop | Independent Xvnc desktop | GDM-launched Wayland desktop |
| Desktop choices | XFCE, MATE, Cinnamon, KDE | XFCE, MATE, Cinnamon, KDE | GNOME |
| Boot-time access | Yes | Yes, persistent user service | Yes, system Remote Login |
| Login credentials | Linux account | Separate KasmVNC web account | Gateway credentials, then Linux account |
| Keeps GUI apps on disconnect | Normally yes | Normally yes | Normally yes |
| Requires GPU passthrough | No | No | No |
| Requires a physical monitor | No | No | No |

Disconnecting is not logging out. A reboot or graphical logout terminates running GUI applications. For long-running CLI agents and builds, prefer `tmux` or a systemd service independent of the desktop session.

## Security and networking

- **Use Tailscale/WireGuard or a private LAN.** Restrict inbound TCP **3389** (RDP) and **8444** (KasmVNC) using the host firewall and network ACLs. Do not forward these ports to the public Internet.
- Scripts intentionally **do not alter UFW/nftables/iptables** to avoid locking out SSH. A firewall with an allow rule on `tailscale0` is not secure by itself if a separate permissive interface rule also exists.
- GNOME RDP gateway credentials and Linux account credentials are different authentication steps. Do not pass a gateway password on a command line, in shell history, or through automation logs.
- TLS certificates are self-signed. RDP clients/browsers may show a certificate warning until you configure a trusted certificate or pin the expected certificate.
- xrdp and KasmVNC may be installed on the same Debian host, but their GUI sessions are **different**. Simultaneous full desktops under one Linux account can conflict via D-Bus/settings; prefer separate accounts when testing both.
- GNOME Remote Login and xrdp should not share TCP 3389. The Ubuntu script refuses to proceed if xrdp is active.
- Keep SSH and the KVM console usable as an out-of-band recovery path.

## Diagnostics

**Debian xrdp**

```bash
sudo systemctl status xrdp xrdp-sesman
sudo journalctl -u xrdp -u xrdp-sesman -b -n 100 --no-pager
ss -lntp | grep ':3389'
```

**Debian KasmVNC** (replace `dev` and the UID with your actual account)

```bash
id -u dev
loginctl show-user dev -p Linger
sudo -u dev env XDG_RUNTIME_DIR=/run/user/$(id -u dev) \
  systemctl --user status 'kasmvncserver@:1.service'
```

**Ubuntu GNOME RDP**

```bash
sudo grdctl --system status
sudo systemctl status gdm3 gnome-remote-desktop
sudo journalctl -u gdm3 -u gnome-remote-desktop -b -n 100 --no-pager
ss -lntp | grep ':3389'
```

Possible GNOME issues:

- **No RDP listener:** inspect `gnome-remote-desktop` status and the gateway credential configuration; inspect GDM service state.
- **RDP connects but no GNOME login:** check GDM and the GNOME Remote Desktop journal. The graphical login stage requires an actual Linux password, not an SSH-only account.
- **Authentication fails after reboot:** inspect the system journal for TPM/credential-store errors. Systems without TPM may show an expected GKeyFile fallback message, but credential persistence problems have also been reported on some TPM-equipped Ubuntu 26.04 hosts.
- **Port occupied:** disable an existing xrdp server before enabling GNOME Remote Login.
- **Client disconnects after initial login:** some RDP clients have trouble with GNOME's server redirection. Try a current FreeRDP or Windows client and inspect the GRD logs.
- **Desktop appears software-rendered:** a headless KVM guest without GPU passthrough may use Mesa/llvmpipe for 3D rendering. This is expected for some configurations and separate from RDP encoding capability.

## Repository layout

```text
headless-linux-remote-desktop/
├── README.md
├── LICENSE
├── Makefile
├── .gitignore
├── .github/workflows/check.yml
├── scripts/
│   ├── debian13-remote-desktop-setup.sh
│   └── ubuntu2604-gnome-rdp-setup.sh
└── tests/
    └── run.sh
```

## Development and verification

```bash
make check
```

This performs Bash syntax checks and non-destructive CLI smoke tests. The GitHub Actions workflow runs the same checks. Actual installation and desktop-login behavior require **real Debian 13 and Ubuntu 26.04 VMs** with network access; they are not covered by these smoke tests.

## License

This project is licensed under the GNU General Public License v3 (GPL v3).

Copyright (C) Yu-Hsiung Chiu

