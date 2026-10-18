# Yellod Installer

One-command, step-by-step setup for the **Yellod server apps** on your own Linux box:

| App | What it is |
|---|---|
| [Yellod Downloader](https://github.com/xyzyt010/yellod-downloader) | Self-hosted media downloader web app (YouTube -> MP3/MP4, live queue) |
| [QuicShare](https://github.com/xyzyt010/quicshare) | Self-hosted file sharing server (rooms, uploads, HTTPS + HTTP/3, web UI) |

Everything runs as an **unprivileged service user** with **hardened systemd units**, and all data lives in the single folder you choose (or HDD/SSD you pick) during setup.

## One command

```bash
curl -fsSL https://raw.githubusercontent.com/xyzyt010/yellod-installer/main/install.sh | sudo bash
```

The wizard walks you through:

1. **Which apps** to install (Downloader, QuicShare or both)
2. **Which disk/folder** stores your data — it lists your block devices (`lsblk`) and mount points with free space so you can pick your SSD/HDD
3. **Ports** (Downloader `5555` on localhost; QuicShare `443`)
4. **Public access** — optional Cloudflare Tunnel guide so QuicShare is reachable from anywhere
5. A **summary**, then it installs everything and checks the services are healthy

After install, open the web UIs to view and manage your files — QuicShare shows exactly the files **you uploaded** (stored on your chosen disk), nothing else.

## Supported systems

| Distro | Status |
|---|---|
| Ubuntu 22.04 / 24.04 / 26.04+ | ✅ supported |
| Debian 12+ | ✅ supported |
| Fedora, Arch, Gentoo | 🚧 planned (the script detects them and tells you) |

Architectures: **x86_64** and **aarch64 (arm64)** — prebuilt binaries come from GitHub Releases; if no release matches, the installer builds from source with Rust.

## Non-interactive / automation

```bash
# defaults: both apps, /srv/yellod, ports 5555 + 443
curl -fsSL .../install.sh | sudo bash -s -- --yes

# pick a specific disk and one app
curl -fsSL .../install.sh | sudo bash -s -- --yes \
    --apps downloader --data-dir /mnt/ssd/yellod --downloader-port 6000

# see everything without changing the system
sudo bash install.sh --dry-run --yes
```

Run `install.sh --help` for all options.

## Management

```bash
# update to the latest release binaries
curl -fsSL https://raw.githubusercontent.com/xyzyt010/yellod-installer/main/install.sh | sudo bash -s -- --update

# uninstall (keeps your data)
curl -fsSL .../install.sh | sudo bash -s -- --uninstall

# uninstall and erase the data folder
curl -fsSL .../install.sh | sudo bash -s -- --uninstall --purge-data

# services
systemctl status yellod-downloader
systemctl status yellod-quicshare
journalctl -u yellod-downloader -f
journalctl -u yellod-quicshare -f
```

## What gets installed where

```
/opt/yellod/downloader/downloader     binary (read-only for the service)
/opt/yellod/quicshare/quicshare       binary
/etc/systemd/system/yellod-downloader.service
/etc/systemd/system/yellod-quicshare.service
/etc/systemd/system/aria2.service     RPC helper for the downloader
<data-dir>/downloader/                downloads + cookies.txt + db (0600/0750)
<data-dir>/quicshare/data/            db, tls, uploaded files
```

## Security model

* Dedicated unprivileged user (`yellod`, no shell, no login)
* Hardened units: `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `RestrictAddressFamilies`, and `ReadWritePaths` limited to the data folder
* QuicShare binds port 443 with only `CAP_NET_BIND_SERVICE`
* The Downloader binds to `127.0.0.1` by default — expose it through a tunnel or reverse proxy
* QuicShare only ever serves files that were uploaded through it and are recorded in its database; file paths are validated against the store root (no `..`, no absolute paths)
* The Downloader writes cookies with `0600`, never downloads playlist/extra files by accident, and deleting a job deletes its file from disk

See [docs/SECURITY.md](docs/SECURITY.md) for details and [docs/CLOUDFLARE-TUNNEL.md](docs/CLOUDFLARE-TUNNEL.md) for the public-access guide.

## Troubleshooting

* The wizard is keyboard-driven: **Up/Down** move, **Space** toggles
  checkboxes, **Enter** confirms and goes to the next step, and pressing
  Enter on the last screen starts the installation and turns the services on.
* It works the same whether you run the one-liner or download `install.sh`
  first. When started from a pipe, the installer re-attaches your terminal
  automatically so the keys always reach the wizard.
* No real terminal (from a script, cron, CI)? Run it with `--yes` for the
  non-interactive defaults.
* To watch what happened: `journalctl -u yellod-downloader -n 50` and
  `journalctl -u yellod-quicshare -n 50`.

## Requirements for building from source (fallback)

`git`, a C toolchain and Rust — the installer sets up rustup automatically if a prebuilt release is not available.

## License

MIT
