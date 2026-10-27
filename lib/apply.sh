#!/usr/bin/env bash
# Install / update actions for the Yellod installer.

# --------------------------------------------------------------------- deps
# Components discovered/reused by ensure_deps (used by the unit renderer):
YTDLP_BIN=""
YTDLP_MANAGED="false"
JS_RUNTIME_NAME=""
ARIA2_PRESENT="false"
TOR_PRESENT="false"
TOR_ENABLED="false"
TOR_UNIT_LINES=""
COMPONENT_NOTES=()

ensure_deps() {
  local pkgs=(curl ca-certificates tar gzip unzip)
  if app_selected downloader; then
    pkgs+=(ffmpeg)
    if command -v aria2c >/dev/null 2>&1; then
      ARIA2_PRESENT="true"
      ok "aria2c already installed, reusing it"
    else
      pkgs+=(aria2)
    fi
  fi
  apt_install_missing "${pkgs[@]}"
  [ "$ARIA2_PRESENT" = "true" ] || ARIA2_PRESENT="$(command -v aria2c >/dev/null 2>&1 && echo true || echo false)"

  if app_selected downloader; then
    ensure_ytdlp
    ensure_js_runtime
    setup_proxy
  fi
}

# yt-dlp: reuse any existing installation (system package, pipx, snap,
# manually downloaded binary); only fetch the standalone binary when the
# machine has none.
ensure_ytdlp() {
  local found p
  found="$(command -v yt-dlp 2>/dev/null || true)"
  if [ -z "$found" ]; then
    for p in /usr/local/bin/yt-dlp /usr/bin/yt-dlp /snap/bin/yt-dlp "$HOME/.local/bin/yt-dlp"; do
      if [ -x "$p" ]; then found="$p"; break; fi
    done
  fi

  if [ -n "$found" ]; then
    YTDLP_BIN="$found"
    YTDLP_MANAGED="false"
    local ver
    ver="$("$found" --version 2>/dev/null | head -n1 || true)"
    ok "yt-dlp already installed, reusing ${found}${ver:+ (v${ver})}"
    COMPONENT_NOTES+=("yt-dlp reused (${found})")
    return 0
  fi

  info "Installing yt-dlp (standalone binary)..."
  local asset="yt-dlp_linux"
  [ "$ARCH" = "aarch64" ] && asset="yt-dlp_linux_aarch64"
  run curl -fL --retry 3 -o /usr/local/bin/yt-dlp \
    "https://github.com/yt-dlp/yt-dlp/releases/latest/download/${asset}"
  run chmod 0755 /usr/local/bin/yt-dlp
  YTDLP_BIN="/usr/local/bin/yt-dlp"
  YTDLP_MANAGED="true"
  ok "yt-dlp installed (/usr/local/bin/yt-dlp)"
  COMPONENT_NOTES+=("yt-dlp installed")
}

# yt-dlp needs a JavaScript runtime for YouTube. If the machine already has
# deno, node or bun, that one is reused - nothing new is downloaded.
ensure_js_runtime() {
  local rt
  for rt in deno node bun; do
    if command -v "$rt" >/dev/null 2>&1; then
      JS_RUNTIME_NAME="$rt"
      ok "JavaScript runtime already installed, reusing: ${rt}"
      COMPONENT_NOTES+=("JS runtime reused (${rt})")
      return 0
    fi
  done

  info "Installing deno (JavaScript runtime yt-dlp uses for YouTube)..."
  if run sh -c 'curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/usr/local sh -s -- -y'; then
    JS_RUNTIME_NAME="deno"
    COMPONENT_NOTES+=("deno installed")
  else
    warn "deno install failed - yt-dlp still works for many sites; install node or deno later if YouTube complains."
    COMPONENT_NOTES+=("JS runtime missing")
  fi
}

# Tor is only used as a fallback when a site blocks this server (mode
# "auto"), or always when the user chose that. An existing Tor installation
# is reused as-is; otherwise it is installed as a normal dependency.
setup_proxy() {
  PROXY_URL=""
  case "${PROXY_MODE:-auto}" in
    never|off|none|direct) PROXY_MODE="never"; return 0 ;;
    always|on|tor)         PROXY_MODE="always" ;;
    *)                     PROXY_MODE="auto" ;;
  esac

  if command -v tor >/dev/null 2>&1; then
    TOR_PRESENT="true"
    ok "Tor already installed, reusing it ($(command -v tor))"
    COMPONENT_NOTES+=("Tor reused")
  else
    info "Installing Tor (used only when a site blocks this server)..."
    apt_install_missing tor
    COMPONENT_NOTES+=("Tor installed")
  fi
  TOR_ENABLED="true"
  PROXY_URL="socks5h://127.0.0.1:9050"

  if have_systemd; then
    run systemctl enable --now tor.service || warn "Could not start tor.service - the downloader will fall back to direct."
    TOR_UNIT_LINES="After=tor.service
Wants=tor.service"
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

# YouTube bot-walls most Tor exit IPs. The downloader works around a blocked
# exit by asking Tor for a fresh circuit (SIGNAL NEWNYM over the local control
# socket), which is group-restricted to `debian-tor` on Debian/Ubuntu. Without
# this grant the app still runs - it just cannot rotate and keeps retrying the
# same (possibly flagged) circuit, so every failure here is non-fatal.
ensure_tor_control_access() {
  case "${PROXY_MODE:-auto}" in
    never|off|none|direct) return 0 ;;
  esac
  getent group debian-tor >/dev/null 2>&1 || return 0
  if id -nG "$SVC_USER" 2>/dev/null | tr ' ' '\n' | grep -qx debian-tor; then
    return 0
  fi

  info "Allowing '$SVC_USER' to rotate Tor circuits (joining group debian-tor)..."
  if run usermod -aG debian-tor "$SVC_USER"; then
    COMPONENT_NOTES+=("Tor circuit rotation access (debian-tor group)")
  else
    warn "Could not add '$SVC_USER' to debian-tor - circuit rotation on blocked exits will be unavailable."
  fi
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
      "DATA_DOWNLOADER=$DATA_DOWNLOADER" \
      "PROXY_URL=$PROXY_URL" "PROXY_MODE=${PROXY_MODE:-never}" \
      "YTDLP_BIN=$YTDLP_BIN" "TOR_UNIT=$TOR_UNIT_LINES"
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
  if app_selected downloader; then
    case "${PROXY_MODE:-never}" in
      auto)   echo " Proxy route   : auto (direct first, Tor fallback when blocked)" ;;
      always) echo " Proxy route   : always through Tor" ;;
      never)  echo " Proxy route   : direct only (no proxy)" ;;
    esac
  fi
  if [ "${#COMPONENT_NOTES[@]}" -gt 0 ]; then
    local n
    echo " Components    :"
    for n in "${COMPONENT_NOTES[@]}"; do echo "                 - ${n}"; done
  fi
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
  ensure_tor_control_access
  ensure_dirs
  install_app_binaries
  install_services
  health_check
  print_final_summary
}

# ------------------------------------------------------------ update flow
# --update keeps the settings of the existing installation (data folder,
# ports, service user, bind addresses) by reading them back from the
# installed systemd units, refreshes dependencies (reusing what exists),
# replaces the binaries, and rolls back if the new version does not come up.
detect_installed_apps() {
  APPS=""
  [ -e /etc/systemd/system/yellod-downloader.service ] && APPS="${APPS}downloader "
  [ -e /etc/systemd/system/yellod-quicshare.service ] && APPS="${APPS}quicshare "
  APPS="${APPS% }"
}

load_settings_from_units() {
  local dl=/etc/systemd/system/yellod-downloader.service
  local qs=/etc/systemd/system/yellod-quicshare.service
  local out data bind listen

  if app_selected downloader; then
    out="$(unit_env "$dl" DOWNLOADER_OUTPUT_DIR)"
    if [ -n "$out" ]; then
      DATA_ROOT="$(dirname "$(dirname "$out")")"
    fi
    bind="$(unit_env "$dl" DOWNLOADER_BIND_ADDRESS)"
    if [ -n "$bind" ]; then
      DL_PORT="${bind##*:}"
      case "${bind%%:*}" in
        127.0.0.1) DL_BIND_MODE="localhost" ;;
        *)         DL_BIND_MODE="all" ;;
      esac
    fi
    local u
    u="$(unit_value "$dl" User)"
    [ -n "$u" ] && SVC_USER="$u"
    local start
    start="$(unit_value "$dl" ExecStart)"
    if [ -n "$start" ]; then
      INSTALL_ROOT="$(dirname "$(dirname "$start")")"
    fi
    # Keep the existing proxy choice unless the user passed --proxy-mode.
    if [ "${PROXY_MODE_EXPLICIT:-false}" != "true" ]; then
      local pm
      pm="$(unit_env "$dl" DOWNLOADER_PROXY_MODE)"
      if [ -n "$pm" ]; then PROXY_MODE="$pm"; fi
    fi
  fi

  if app_selected quicshare; then
    data="$(unit_env "$qs" DATA_DIR)"
    if [ -n "$data" ]; then
      DATA_ROOT="$(dirname "$(dirname "$data")")"
    fi
    listen="$(unit_env "$qs" LISTEN_ADDR)"
    if [ -n "$listen" ]; then
      QS_PORT="${listen##*:}"
      case "${listen%%:*}" in
        127.0.0.1) QS_BIND_MODE="localhost" ;;
        *)         QS_BIND_MODE="all" ;;
      esac
    fi
    local h
    h="$(unit_env "$qs" HOSTNAME)"
    [ -n "$h" ] && QS_HOSTNAME="$h"
  fi

  # Paths used by the unit renderer (mirrors ensure_dirs).
  DATA_DOWNLOADER="$DATA_ROOT/downloader"
  DATA_QS="$DATA_ROOT/quicshare/data"

  set_binds_from_modes
  [ -n "${QS_HOSTNAME:-}" ] || QS_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
}

backup_app_binaries() {
  local bin
  for bin in "$INSTALL_ROOT/downloader/downloader" "$INSTALL_ROOT/quicshare/quicshare"; do
    if [ -x "$bin" ] && [ "$DRY_RUN" != "true" ]; then
      cp -f "$bin" "${bin}.prev"
    fi
  done
}

rollback_app() {
  local bin="$1" unit="$2"
  if [ -x "${bin}.prev" ]; then
    warn "New ${bin##*/} did not come up - rolling back to the previous version."
    run install -m 0755 "${bin}.prev" "$bin"
    run systemctl restart "$unit"
    rm -f "${bin}.prev"
  else
    warn "New ${bin##*/} did not come up and there is no backup to roll back to."
  fi
}

wait_downloader_up() {
  local tries="${1:-20}"
  while [ "$tries" -gt 0 ]; do
    if curl -fsS --max-time 3 "http://127.0.0.1:${DL_PORT}/healthz" >/dev/null 2>&1; then return 0; fi
    tries=$((tries - 1))
    sleep 1
  done
  return 1
}

wait_quicshare_up() {
  local tries="${1:-20}"
  while [ "$tries" -gt 0 ]; do
    if curl -fsSk --max-time 3 "https://127.0.0.1:${QS_PORT}/api/health" >/dev/null 2>&1; then return 0; fi
    tries=$((tries - 1))
    sleep 1
  done
  return 1
}

update_ytdlp() {
  app_selected downloader || return 0
  if pkg_installed yt-dlp; then
    info "yt-dlp is the system package - upgrading via apt if a newer one exists..."
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade yt-dlp
  elif [ -n "$YTDLP_BIN" ]; then
    # Standalone/pipx installs of yt-dlp can update themselves in place.
    info "Updating yt-dlp (self-update at ${YTDLP_BIN})..."
    run sh -c "\"${YTDLP_BIN}\" -U >/dev/null 2>&1 || true"
  fi
}

do_update() {
  detect_installed_apps
  if [ -z "$APPS" ]; then
    warn "Nothing seems installed (no Yellod systemd units found)."
    warn "Run the installer first:  sudo bash -c \"\$(curl -fsSL ${GH_URL}/${REPO_INSTALLER}/raw/main/install.sh)\""
    return 1
  fi

  info "Updating: ${APPS// /, }"
  load_settings_from_units
  ensure_deps
  ensure_tor_control_access
  backup_app_binaries

  local dl_bin="$INSTALL_ROOT/downloader/downloader"
  local qs_bin="$INSTALL_ROOT/quicshare/quicshare"

  if [ "$DRY_RUN" = "true" ]; then
    app_selected downloader && info "[dry-run] would re-install the latest downloader release and restart it"
    app_selected quicshare && info "[dry-run] would re-install the latest quicshare release and restart it"
  else
    install_app_binaries
  fi

  install_services

  if [ "$DRY_RUN" != "true" ]; then
    if app_selected downloader; then
      run systemctl restart yellod-downloader.service
      if wait_downloader_up 20; then
        ok "Yellod Downloader updated and healthy."
        rm -f "${dl_bin}.prev"
      else
        rollback_app "$dl_bin" yellod-downloader.service
      fi
    fi
    if app_selected quicshare; then
      run systemctl restart yellod-quicshare.service
      if wait_quicshare_up 20; then
        ok "QuicShare updated and healthy."
        rm -f "${qs_bin}.prev"
      else
        rollback_app "$qs_bin" yellod-quicshare.service
      fi
    fi
  fi

  update_ytdlp

  ok "Update complete."
}
