#!/usr/bin/env bash
# Step-by-step terminal wizard for the Yellod installer (whiptail GUI).
# Sets the WIZ_*/shared globals used by apply.sh.

has_tty() {
  [ -e /dev/tty ] && ( : < /dev/tty ) 2>/dev/null
}

wiz_need_whiptail() {
  command -v whiptail >/dev/null 2>&1 || apt_install whiptail
}

wiz_welcome() {
  whiptail --title "Yellod setup" --msgbox "Welcome to the Yellod server setup.

Detected system:
    OS:   ${DISTRO_PRETTY}
    Arch: ${ARCH} (${ARCH_TAG})

This wizard will install and configure:
  - Yellod Downloader (YouTube -> MP3/MP4 web app)
  - QuicShare       (self-hosted file sharing server)

You will choose which HDD/SSD (or folder) stores the data, which
ports to use, and whether to get a public-access guide.

Everything runs as an unprivileged service user with hardened
systemd units." 22 76
}

wiz_apps() {
  local sel
  sel=$(whiptail --title "Apps" --checklist \
    "Step 1/5 - Which apps should be installed?" 16 72 4 \
    "downloader" "Yellod Downloader - media downloader web app" ON \
    "quicshare"  "QuicShare - file sharing server (uploads/downloads)" ON \
    3>&1 1>&2 2>&3) || die "Setup cancelled."
  APPS="$(printf '%s' "$sel" | tr -d '"')"
  [ -n "$APPS" ] || die "Nothing selected - aborting."
}

wiz_storage() {
  whiptail --title "Storage" --scrolltext --msgbox \
    "Step 2/5 - Choose where downloaded files and uploads are stored.

Block devices detected on this machine:

$(lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT 2>/dev/null || echo '(lsblk unavailable)')

Tip: to use a brand-new disk, format and mount it first
(e.g.  mkfs.ext4 /dev/sdX1  and  mount /dev/sdX1 /mnt/data),
then pick that mount point here." 26 90

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
    menu+=("m$i" "$mp  (${size:-?} free)" "$state")
    mounts[$i]="$mp"
    i=$((i + 1))
  done < <(lsblk -o MOUNTPOINT -n -p 2>/dev/null | awk 'NF' | sort -u)
  menu+=("default" "/srv/yellod (recommended if unsure)" "OFF")
  menu+=("custom"  "Custom path / other mount point..." "OFF")

  local choice
  choice=$(whiptail --title "Storage" --radiolist \
    "Step 2/5 - Select the disk/mount that should hold the data:" 22 84 12 \
    "${menu[@]}" 3>&1 1>&2 2>&3) || die "Setup cancelled."

  case "$choice" in
    m*)       DATA_ROOT="${mounts[${choice#m}]}/yellod" ;;
    default)  DATA_ROOT="/srv/yellod" ;;
    custom)
      DATA_ROOT=$(whiptail --title "Storage" --inputbox \
        "Full path of the folder where data will be stored
(must be on a mounted disk):" 11 72 "/srv/yellod" \
        3>&1 1>&2 2>&3) || die "Setup cancelled."
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

wiz_ports() {
  local val
  if app_selected downloader; then
    val=$(whiptail --title "Ports" --inputbox \
      "Downloader web port (it listens on localhost only; expose it
through a tunnel or reverse proxy for remote use):" 11 72 "5555" \
      3>&1 1>&2 2>&3) || die "Setup cancelled."
    validate_port "$val" || die "Invalid downloader port: $val"
    DL_PORT="$val"
    DL_BIND_MODE="localhost"
  fi

  if app_selected quicshare; then
    val=$(whiptail --title "Ports" --inputbox \
      "QuicShare port (443 is the standard HTTPS port):" 10 72 "443" \
      3>&1 1>&2 2>&3) || die "Setup cancelled."
    validate_port "$val" || die "Invalid QuicShare port: $val"
    QS_PORT="$val"

    local mode
    mode=$(whiptail --title "QuicShare network" --radiolist \
      "Step 3/5 - How should QuicShare be reachable?" 16 78 3 \
      "all"       "All interfaces - other devices / internet via tunnel (recommended for sharing)" ON \
      "localhost" "Localhost only - this machine only" OFF \
      3>&1 1>&2 2>&3) || die "Setup cancelled."
    QS_BIND_MODE="${mode:-all}"

    QS_HOSTNAME=$(whiptail --title "Hostname" --inputbox \
      "Hostname or IP people will use to reach QuicShare
(used for the TLS certificate; change later if needed):" 11 72 \
      "$(hostname -f 2>/dev/null || hostname)" \
      3>&1 1>&2 2>&3) || die "Setup cancelled."
  fi
}

wiz_expose() {
  TUNNEL_GUIDE="no"
  if app_selected quicshare && [ "$QS_BIND_MODE" = "all" ]; then
    if whiptail --title "Public access" --yesno \
      "Step 4/5 - Expose QuicShare to the internet with a Cloudflare Tunnel?

No ports need to be opened on your router - a step-by-step guide
will be printed at the end of the installation.

(You can also skip this and use a tunnel/reverse proxy of your choice.)" \
      15 78; then
      TUNNEL_GUIDE="yes"
    fi
  fi
}

wiz_summary() {
  local txt dl_line qs_line
  dl_line="disabled"
  qs_line="disabled"
  app_selected downloader && dl_line="http://127.0.0.1:${DL_PORT}  (localhost only)"
  app_selected quicshare && qs_line="https://${QS_HOSTNAME}:${QS_PORT}  (bind: ${QS_BIND_MODE})"

  txt="Step 5/5 - Please review:

  Apps:         ${APPS}
  Data folder:  ${DATA_ROOT}

  Downloader:   ${dl_line}
  QuicShare:    ${qs_line}

  Tunnel guide: ${TUNNEL_GUIDE}
  Service user: ${SVC_USER}

After installation, open the web UI(s) above to view and manage
your files. Proceed?"

  whiptail --title "Confirm" --yesno "$txt" 22 80 || die "Aborted by user."
}

wiz_run() {
  wiz_need_whiptail
  wiz_welcome
  wiz_apps
  wiz_storage
  wiz_ports
  wiz_expose
  wiz_summary
}
