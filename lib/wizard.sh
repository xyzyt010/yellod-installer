#!/usr/bin/env bash
# Step-by-step terminal wizard for the Yellod installer (whiptail GUI).
# Sets the WIZ_*/shared globals used by apply.sh.
#
# Keys:  Up/Down = move   Space = toggle   Enter = confirm / next step
#
# Every dialog reads its keys from the controlling terminal (/dev/tty), so
# the wizard also works when the script itself arrives on stdin
# (curl ... | sudo bash): install.sh re-attaches /dev/tty before running it.

has_tty() {
  [ -e /dev/tty ] && ( : < /dev/tty ) 2>/dev/null
}

wiz_need_whiptail() {
  command -v whiptail >/dev/null 2>&1 || apt_install whiptail
}

# ---------------------------------------------------------------- welcome
wiz_welcome() {
  whiptail --title "Yellod setup - step 1/7" --msgbox "Welcome to the Yellod server setup.

Detected system:
    OS:   ${DISTRO_PRETTY}
    Arch: ${ARCH} (${ARCH_TAG})

This wizard will install and configure:
  - Yellod Downloader (YouTube -> MP3/MP4 web app)
  - QuicShare       (self-hosted file sharing server)

You will choose which HDD/SSD (or folder) stores the data, which
ports to use, and whether to get a public-access guide.

Everything runs as an unprivileged service user with hardened
systemd units.

----
Keys:  Up/Down = move   Space = toggle   Enter = next
----

Press Enter to continue." 24 78 </dev/tty
}

# ---------------------------------------------------------------- apps
wiz_apps() {
  local sel
  sel=$(whiptail --title "Yellod setup - step 2/7" --checklist \
    "What should be installed?

Up/Down = move   Space = toggle   Enter = continue" 16 76 4 \
    "downloader" "Yellod Downloader - media downloader web app" ON \
    "quicshare"  "QuicShare - file sharing server (uploads/downloads)" ON \
    3>&1 1>&2 2>&3 </dev/tty) || die "Setup cancelled."
  APPS="$(printf '%s' "$sel" | tr -d '"')"
  [ -n "$APPS" ] || die "Nothing selected - aborting."
}

# ---------------------------------------------------------------- storage
wiz_storage() {
  whiptail --title "Yellod setup - step 3/7" --msgbox \
    "Where should your data live?

Block devices detected on this machine:

$(lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT 2>/dev/null || echo '(lsblk unavailable)')

Tip: to use a brand-new disk, format and mount it first
(e.g.  mkfs.ext4 /dev/sdX1  and  mount /dev/sdX1 /mnt/data),
then pick that mount point here.

Press Enter to choose the folder." 26 90 </dev/tty

  local -a menu=() mounts=()
  local i=1 mp size state
  while IFS= read -r mp; do
    [ -n "$mp" ] || continue
    case "$mp" in
      /boot*|/snap*|/run*|/sys*|/proc*|/dev*|/var/lib/docker*) continue ;;
    esac
    size="$(df -h --output=avail "$mp" 2>/dev/null | tail -n1 | tr -d ' ')"
    state="OFF"
    [ "$i" -eq 1 ] && state="ON"
    local label="$mp"
    if [ "$mp" = "/" ]; then
      label="/  (system disk)"
    fi
    menu+=("m$i" "$label  (${size:-?} free)" "$state")
    mounts[$i]="$mp"
    i=$((i + 1))
  done < <(lsblk -o MOUNTPOINT -n -p 2>/dev/null | awk 'NF' | sort -u)
  menu+=("default" "/srv/yellod (recommended if unsure)" "OFF")
  menu+=("custom"  "Custom path / other mount point..." "OFF")

  local choice
  choice=$(whiptail --title "Yellod setup - step 3/7" --radiolist \
    "Select the disk/mount that should hold the data:

Up/Down = move   Enter = confirm" 22 84 12 \
    "${menu[@]}" 3>&1 1>&2 2>&3 </dev/tty) || die "Setup cancelled."

  case "$choice" in
    m*)       DATA_ROOT="${mounts[${choice#m}]%/}/yellod" ;;
    default)  DATA_ROOT="/srv/yellod" ;;
    custom)
      DATA_ROOT=$(whiptail --title "Yellod setup - step 3/7" --inputbox \
        "Full path of the folder where data will be stored
(must be on a mounted disk).
Type a path, then press Enter:" 12 72 "/srv/yellod" \
        3>&1 1>&2 2>&3 </dev/tty) || die "Setup cancelled."
      ;;
    *) die "Setup cancelled." ;;
  esac

  case "$DATA_ROOT" in
    /*) : ;;
    *) die "Data folder must be an absolute path (got: $DATA_ROOT)" ;;
  esac

  if [ "$DRY_RUN" != "true" ]; then
    if ! mkdir -p "$DATA_ROOT" 2>/dev/null || ! : > "$DATA_ROOT/.yellod-write-test" 2>/dev/null; then
      die "Cannot write to $DATA_ROOT - please pick another location."
    fi
    rm -f "$DATA_ROOT/.yellod-write-test"
  fi
}

# ---------------------------------------------------------------- ports
wiz_ports() {
  local val
  if app_selected downloader; then
    val=$(whiptail --title "Yellod setup - step 4/7" --inputbox \
      "Downloader web port (it listens on localhost only; expose it
through a tunnel or reverse proxy for remote use).
Type a port number, then press Enter:" 12 74 "5555" \
      3>&1 1>&2 2>&3 </dev/tty) || die "Setup cancelled."
    validate_port "$val" || die "Invalid downloader port: $val"
    DL_PORT="$val"
    DL_BIND_MODE="localhost"
  fi

  if app_selected quicshare; then
    val=$(whiptail --title "Yellod setup - step 4/7" --inputbox \
      "QuicShare port (443 is the standard HTTPS port).
Type a port number, then press Enter:" 11 72 "443" \
      3>&1 1>&2 2>&3 </dev/tty) || die "Setup cancelled."
    validate_port "$val" || die "Invalid QuicShare port: $val"
    QS_PORT="$val"

    local mode
    mode=$(whiptail --title "Yellod setup - step 4/7" --radiolist \
      "How should QuicShare be reachable?

Up/Down = move   Enter = confirm" 16 78 3 \
      "all"       "All interfaces - other devices / internet via tunnel (recommended for sharing)" ON \
      "localhost" "Localhost only - this machine only" OFF \
      3>&1 1>&2 2>&3 </dev/tty) || die "Setup cancelled."
    QS_BIND_MODE="${mode:-all}"

    QS_HOSTNAME=$(whiptail --title "Yellod setup - step 4/7" --inputbox \
      "Hostname or IP people will use to reach QuicShare
(used for the TLS certificate; can be changed later).
Type it, then press Enter:" 12 74 \
      "$(hostname -f 2>/dev/null || hostname)" \
      3>&1 1>&2 2>&3 </dev/tty) || die "Setup cancelled."
  fi
}

# ---------------------------------------------------------------- proxy
# Only asked when the downloader is selected. "auto" is the useful default:
# try a direct connection first and only route through Tor when the site
# blocks this server. Tor is reused if already installed, otherwise it is
# installed as a normal dependency.
wiz_proxy() {
  PROXY_MODE="auto"
  if ! app_selected downloader; then
    PROXY_MODE="never"
    return 0
  fi
  local choice
  choice=$(whiptail --title "Yellod setup - step 5/7" --radiolist \
    "How should the downloader reach sites like YouTube?\n\nMost connections work directly. On blocked servers/regions the\ndownloader can fall back to Tor - nothing else changes. Tor is\ninstalled once and reused if it is already on this machine.\n\nUp/Down = move   Enter = confirm" 18 80 3 \
    "auto"   "Auto - direct first, fall back to Tor when a site blocks us (recommended)" ON \
    "always" "Always use Tor for every download" OFF \
    "never"  "Never use a proxy - direct connections only" OFF \
    3>&1 1>&2 2>&3 </dev/tty) || die "Setup cancelled."
  PROXY_MODE="${choice:-auto}"
}

# ---------------------------------------------------------------- expose
wiz_expose() {
  TUNNEL_GUIDE="no"
  if app_selected quicshare && [ "$QS_BIND_MODE" = "all" ]; then
    if whiptail --title "Yellod setup - step 6/7" --yesno \
      "Expose QuicShare to the internet with a Cloudflare Tunnel?

No ports need to be opened on your router - a step-by-step guide
will be printed at the end of the installation.

(You can also skip this and use a tunnel/reverse proxy of your choice.)

Enter = Yes (get the guide)      Esc = No" 16 78 </dev/tty; then
      TUNNEL_GUIDE="yes"
    else
      TUNNEL_GUIDE="no"
    fi
  fi
}

# ---------------------------------------------------------------- summary
wiz_summary() {
  local txt dl_line qs_line route_line
  dl_line="disabled"
  qs_line="disabled"
  app_selected downloader && dl_line="http://127.0.0.1:${DL_PORT}  (localhost only)"
  app_selected quicshare && qs_line="https://${QS_HOSTNAME}:${QS_PORT}  (bind: ${QS_BIND_MODE})"
  route_line="-"
  if app_selected downloader; then
    case "${PROXY_MODE:-auto}" in
      auto)   route_line="auto - direct first, Tor fallback when blocked" ;;
      always) route_line="always through Tor" ;;
      never)  route_line="direct only" ;;
    esac
  fi

  txt="Please review:

  Apps:         ${APPS}
  Data folder:  ${DATA_ROOT}

  Downloader:   ${dl_line}
  QuicShare:    ${qs_line}
  Proxy route:  ${route_line}

  Tunnel guide: ${TUNNEL_GUIDE}
  Service user: ${SVC_USER}

Enter = install and turn services on now.
Esc   = abort"

  whiptail --title "Yellod setup - step 7/7" --yesno "$txt" 24 80 </dev/tty \
    || die "Aborted by user."
}

wiz_run() {
  wiz_need_whiptail
  wiz_welcome
  wiz_apps
  wiz_storage
  wiz_ports
  wiz_proxy
  wiz_expose
  wiz_summary
}
