#!/usr/bin/env bash
# Install / update actions for the Yellod installer.

# --------------------------------------------------------------------- deps
ensure_deps() {
  local pkgs=(curl ca-certificates tar gzip unzip)
  if app_selected downloader; then
    pkgs+=(ffmpeg aria2)
  fi
  apt_install "${pkgs[@]}"

  if app_selected downloader; then
    if ! command -v yt-dlp >/dev/null 2>&1; then
      local asset="yt-dlp_linux"
      [ "$ARCH" = "aarch64" ] && asset="yt-dlp_linux_aarch64"
      info "Installing yt-dlp (standalone binary)..."
      run curl -fL --retry 3 -o /usr/local/bin/yt-dlp \
        "https://github.com/yt-dlp/yt-dlp/releases/latest/download/${asset}"
      run chmod 0755 /usr/local/bin/yt-dlp
      ok "yt-dlp installed (/usr/local/bin/yt-dlp)"
    fi

    if ! command -v deno >/dev/null 2>&1; then
      info "Installing deno (JavaScript runtime used by yt-dlp for YouTube)..."
      if ! run sh -c 'curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/usr/local sh -s -- -y'; then
        warn "deno install failed - yt-dlp will still work for many sites."
      fi
    fi
  fi
}

# --------------------------------------------------------------------- user
ensure_user() {
  if ! id -u "$SVC_USER" >/dev/null 2>&1; then
    info "Creating unprivileged service user '${SVC_USER}'..."
    run useradd --system --user-group --home-dir "$LIB_DIR" --create-home \
      --shell /usr/sbin/nologin "$SVC_USER"
  fi
  run mkdir -p "$LIB_DIR"
  run chown -R "${SVC_USER}:${SVC_USER}" "$LIB_DIR"
}

# --------------------------------------------------------------------- dirs
ensure_dirs() {
  DATA_DOWNLOADER="$DATA_ROOT/downloader"
  DATA_QS="$DATA_ROOT/quicshare/data"

  if app_selected downloader; then
    run mkdir -p "$DATA_DOWNLOADER/downloads"
    run touch "$DATA_DOWNLOADER/cookies.txt"
    run chmod 0600 "$DATA_DOWNLOADER/cookies.txt"
  fi
  if app_selected quicshare; then
    run mkdir -p "$DATA_QS"
  fi

  run chown -R "${SVC_USER}:${SVC_USER}" "$DATA_ROOT"
  run chmod 0750 "$DATA_ROOT"
}

# ---------------------------------------------------------------- binaries
install_app_binaries() {
  if app_selected downloader; then
    if [ "$DRY_RUN" = "true" ]; then
      info "[dry-run] would install 'downloader' from ${REPO_DOWNLOADER} release (yellod-downloader-${ARCH_TAG}.tar.gz) or build from source"
    else
      install_binary "$REPO_DOWNLOADER" "yellod-downloader-${ARCH_TAG}.tar.gz" \
        "$INSTALL_ROOT/downloader" downloader
    fi
  fi
  if app_selected quicshare; then
    if [ "$DRY_RUN" = "true" ]; then
      info "[dry-run] would install 'quicshare' from ${REPO_QUICSHARE} release (quicshare-${ARCH_TAG}.tar.gz) or build from source"
    else
      install_binary "$REPO_QUICSHARE" "quicshare-${ARCH_TAG}.tar.gz" \
        "$INSTALL_ROOT/quicshare" quicshare
    fi
  fi
}

# ------------------------------------------------------------------ systemd
install_services() {
  if app_selected downloader; then
    render_unit "$SELF_DIR/units/yellod-downloader.service" \
      /etc/systemd/system/yellod-downloader.service \
      "USER=$SVC_USER" "INSTALL_ROOT=$INSTALL_ROOT" "LIB_DIR=$LIB_DIR" \
      "BIND=$DL_BIND" "OUTPUT_DIR=$DATA_DOWNLOADER/downloads" \
      "COOKIES_PATH=$DATA_DOWNLOADER/cookies.txt" \
      "DB_PATH=$DATA_DOWNLOADER/downloader.db" \
      "DATA_DOWNLOADER=$DATA_DOWNLOADER"
    render_unit "$SELF_DIR/units/aria2.service" /etc/systemd/system/aria2.service \
      "USER=$SVC_USER" "OUTPUT_DIR=$DATA_DOWNLOADER/downloads" "LIB_DIR=$LIB_DIR"
  fi
  if app_selected quicshare; then
    render_unit "$SELF_DIR/units/quicshare.service" \
      /etc/systemd/system/yellod-quicshare.service \
      "USER=$SVC_USER" "INSTALL_ROOT=$INSTALL_ROOT" \
      "BIND=$QS_BIND" "DATA_DIR=$DATA_QS" "HOSTNAME=$QS_HOSTNAME"
  fi

  run systemctl daemon-reload
  if app_selected downloader; then
    run systemctl enable --now aria2.service yellod-downloader.service
  fi
  if app_selected quicshare; then
    run systemctl enable --now yellod-quicshare.service
  fi
}

# ------------------------------------------------------------------- health
health_check() {
  [ "$DRY_RUN" = "true" ] && return 0

  local tries
  if app_selected downloader; then
    tries=20
    info "Waiting for Yellod Downloader to come up..."
    while [ "$tries" -gt 0 ]; do
      if curl -fsS --max-time 3 "http://127.0.0.1:${DL_PORT}/healthz" >/dev/null 2>&1; then
        ok "Yellod Downloader is up."
        break
      fi
      tries=$((tries - 1))
      sleep 1
    done
    if [ "$tries" -eq 0 ]; then
      warn "Downloader did not answer on port ${DL_PORT} yet."
      warn "Check logs with:  journalctl -u yellod-downloader -n 50 --no-pager"
    fi
  fi

  if app_selected quicshare; then
    tries=20
    info "Waiting for QuicShare to come up..."
    while [ "$tries" -gt 0 ]; do
      if curl -fsSk --max-time 3 "https://127.0.0.1:${QS_PORT}/api/health" >/dev/null 2>&1; then
        ok "QuicShare is up."
        break
      fi
      tries=$((tries - 1))
      sleep 1
    done
    if [ "$tries" -eq 0 ]; then
      warn "QuicShare did not answer on port ${QS_PORT} yet."
      warn "Check logs with:  journalctl -u yellod-quicshare -n 50 --no-pager"
    fi
  fi
}

# ------------------------------------------------------------------ summary
print_final_summary() {
  echo
  echo "============================================================"
  echo " Yellod setup complete"
  echo "============================================================"
  if app_selected downloader; then
    echo " Downloader UI : http://127.0.0.1:${DL_PORT}   (this machine only)"
    echo "   - paste a link, pick MP3/MP4, watch live progress"
    echo "   - deleting a job in History also deletes its file from disk"
    echo "   - optional: upload cookies.txt in the UI for age-restricted videos"
  fi
  if app_selected quicshare; then
    echo " QuicShare UI  : https://${QS_HOSTNAME}:${QS_PORT}   (self-signed certificate)"
    echo "   - create rooms, upload files, download from anywhere"
    echo "   - only uploaded files are ever visible - nothing else on the disk"
    echo "   - what YOU view in the UI: your uploaded files on your SSD/HDD"
  fi
  echo
  echo " Data folder   : ${DATA_ROOT}"
  echo " Service user  : ${SVC_USER}   (unprivileged, hardened systemd units)"
  echo
  echo " Logs      : journalctl -u yellod-downloader -f"
  app_selected quicshare && echo "             journalctl -u yellod-quicshare -f"
  echo " Update    : curl -fsSL ${GH_URL}/${REPO_INSTALLER}/raw/main/install.sh | sudo bash -s -- --update"
  echo " Uninstall : curl -fsSL ${GH_URL}/${REPO_INSTALLER}/raw/main/install.sh | sudo bash -s -- --uninstall"
  echo "             (add --purge-data to also erase ${DATA_ROOT})"
  echo "============================================================"

  if [ "$TUNNEL_GUIDE" = "yes" ]; then
    echo
    echo "--- Cloudflare Tunnel guide (expose QuicShare to the internet) ---"
    echo " Full guide: ${GH_URL}/${REPO_INSTALLER}/blob/main/docs/CLOUDFLARE-TUNNEL.md"
    echo
    echo " 1) Install cloudflared:"
    echo "      curl -fsSL https://pkg.cloudflare.com/cloudflared/install.sh | sudo bash"
    echo "    (or download the binary from https://github.com/cloudflare/cloudflared/releases)"
    echo " 2) Log in (opens a browser link, needs your Cloudflare account):"
    echo "      cloudflared tunnel login"
    echo " 3) Create a tunnel and route your domain:"
    echo "      cloudflared tunnel create yellod"
    echo "      cloudflared tunnel route dns yellod files.example.com"
    echo " 4) Point it at QuicShare (config at /etc/cloudflared/config.yml):"
    echo "      tunnel: yellod"
    echo "      credentials-file: /root/.cloudflared/<tunnel-id>.json"
    echo "      ingress:"
    echo "        - hostname: files.example.com"
    echo "          service: https://localhost:${QS_PORT}"
    echo "          originRequest:"
    echo "            noTLSVerify: true"
    echo "        - service: http_status:404"
    echo " 5) Run it as a service:"
    echo "      sudo cloudflared service install"
    echo "      sudo systemctl enable --now cloudflared"
    echo
    echo " Then open https://files.example.com from anywhere."
  fi
}

# -------------------------------------------------------------------- flows
do_install() {
  ensure_deps
  ensure_user
  ensure_dirs
  install_app_binaries
  install_services
  health_check
  print_final_summary
}

do_update() {
  local updated="false"

  if [ -e /etc/systemd/system/yellod-downloader.service ]; then
    info "Updating Yellod Downloader..."
    if [ "$DRY_RUN" = "true" ]; then
      info "[dry-run] would re-install the latest downloader release"
    else
      install_binary "$REPO_DOWNLOADER" "yellod-downloader-${ARCH_TAG}.tar.gz" \
        "$INSTALL_ROOT/downloader" downloader
    fi
    run systemctl restart yellod-downloader.service
    updated="true"
  fi

  if [ -e /etc/systemd/system/yellod-quicshare.service ]; then
    info "Updating QuicShare..."
    if [ "$DRY_RUN" = "true" ]; then
      info "[dry-run] would re-install the latest quicshare release"
    else
      install_binary "$REPO_QUICSHARE" "quicshare-${ARCH_TAG}.tar.gz" \
        "$INSTALL_ROOT/quicshare" quicshare
    fi
    run systemctl restart yellod-quicshare.service
    updated="true"
  fi

  if command -v yt-dlp >/dev/null 2>&1; then
    info "Updating yt-dlp..."
    run sh -c 'yt-dlp -U >/dev/null 2>&1 || true'
  fi

  if [ "$updated" = "false" ]; then
    warn "Nothing seems installed (no Yellod systemd units found)."
    warn "Run the installer first:  sudo bash -c \"\$(curl -fsSL ${GH_URL}/${REPO_INSTALLER}/raw/main/install.sh)\""
    return 1
  fi

  ok "Update complete."
}
