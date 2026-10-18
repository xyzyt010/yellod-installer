# Expose QuicShare to the internet with Cloudflare Tunnel

A Cloudflare Tunnel gives you `https://files.example.com` -> your box with
**no open inbound ports** and automatic HTTPS. A tunnel can serve both apps.

## 0. Prerequisites

* A domain added to a (free) Cloudflare account
* QuicShare installed and healthy: `systemctl status yellod-quicshare`

## 1. Install cloudflared

```bash
curl -fsSL https://pkg.cloudflare.com/cloudflared/install.sh | sudo bash
# alternative: download the static binary from
# https://github.com/cloudflare/cloudflared/releases (linux amd64/arm64)
```

## 2. Log in

```bash
cloudflared tunnel login
```

This opens a browser link; pick the domain you want to use. It saves a
certificate to `~/.cloudflared/cert.pem`.

## 3. Create the tunnel and DNS route

```bash
cloudflared tunnel create yellod
cloudflared tunnel route dns yellod files.example.com
```

Note the tunnel ID printed by `create` — the credentials file is
`~/.cloudflared/<TUNNEL-ID>.json`.

## 4. Configure ingress

Create `/etc/cloudflared/config.yml`:

```yaml
tunnel: yellod
credentials-file: /root/.cloudflared/<TUNNEL-ID>.json

ingress:
  # QuicShare (self-signed cert on the origin, so noTLSVerify)
  - hostname: files.example.com
    service: https://localhost:443
    originRequest:
      noTLSVerify: true

  # Optional: the Yellod Downloader as well
  - hostname: media.example.com
    service: http://localhost:5555

  - service: http_status:404
```

## 5. Run it as a service

```bash
sudo cloudflared service install
sudo systemctl enable --now cloudflared
```

Open `https://files.example.com` from anywhere. 

## 6. (Recommended) Require authentication

Add a **Cloudflare Access** application for `files.example.com` in the
Cloudflare dashboard (Zero Trust -> Access -> Applications) with a policy
like "emails in my list" or "one-time PIN". This puts a login wall in front
of the site, so only people you invite can reach it at all.

## Troubleshooting

* `cloudflared tunnel info yellod` — tunnel status
* `journalctl -u cloudflared -f` — connector logs
* HTTP 502 from Cloudflare: check `systemctl status yellod-quicshare` and
  that `service:` in the config matches the actual listen port
* If you use HTTP/3 through the tunnel, Cloudflare terminates QUIC at the
  edge; the connector talks HTTP/2 to your origin — nothing to configure.
