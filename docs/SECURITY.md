# Security model

## Runtime isolation

Both apps run as a dedicated unprivileged system user (`yellod` by default —
no shell, no password, cannot log in). Each unit is hardened:

* `NoNewPrivileges=true` — no setuid escalation ever
* `ProtectSystem=strict` + `ProtectHome=true` — the entire filesystem is
  read-only except the paths explicitly listed in `ReadWritePaths`
* `ReadWritePaths` contains **only** the chosen data folder (plus the service
  home for the downloader's JS runtime cache)
* `PrivateTmp=true`, `ProtectKernelTunables/Modules/ControlGroups`,
  `RestrictNamespaces`, `LockPersonality`, `SystemCallArchitectures=native`
* QuicShare keeps only `CAP_NET_BIND_SERVICE` to bind port 443
* `UMask=0077` — new files are never world-readable

## Data confinement

* QuicShare stores uploads as `<data>/quicshare/data/store/<room-uuid>/<file-uuid>.bin`.
  The original filename is metadata only.
* Every read, ZIP or delete validates the stored path against the store root
  and rejects absolute paths and `..` components.
* There is no filesystem browser in the web UI: it can only ever show files
  recorded in its own database — i.e. the files **you uploaded to it**.
* The Downloader writes into one folder per job inside its output directory,
  keeps **only the final media file**, and deletes a job's file when the job
  is deleted from history. Removal is limited to paths inside the output
  directory.

## Network exposure

* Downloader binds `127.0.0.1:5555` by default. Put a tunnel or an
  authenticating reverse proxy in front before exposing it.
* QuicShare listens on `0.0.0.0:443` (change with `--qs-bind 127.0.0.1`).
  Its TLS certificate is self-signed unless you front it with Cloudflare
  Tunnel (recommended) — see [CLOUDFLARE-TUNNEL.md](CLOUDFLARE-TUNNEL.md).
* Recommended public setup: Cloudflare Tunnel + Cloudflare Access policy
  (email/OTP login) so only invited people can reach the site at all.

## Cookies file

The Downloader's `cookies.txt` (YouTube session) is stored in
`<data>/downloader/cookies.txt` with mode `0600` and is only readable by the
service user. Delete it from the UI/host whenever you no longer need it.

## Updates

`install.sh --update` pulls the latest prebuilt binaries from GitHub Releases
and restarts the services. Binaries are verified against the published
SHA-256 checksums when available.

## Reporting a problem

Please open an issue on the relevant repository
([installer](https://github.com/xyzyt010/yellod-installer/issues),
[downloader](https://github.com/xyzyt010/yellod-downloader/issues),
[quicshare](https://github.com/xyzyt010/quicshare/issues)) — do **not**
include secrets, cookies or personal data.
