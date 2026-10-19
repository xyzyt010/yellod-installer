#!/usr/bin/env bash
# Step-by-step terminal wizard for the Yellod installer.
# Uses the small in-house TUI (lib/tui.sh) so the keys behave the same on
# every machine:
#
#   Up/Down      move the highlight
#   Enter/Space  select / deselect the highlighted option
#   Tab          jump to the Continue button (Enter there = next step)
#   Esc          quit (with a confirmation)
#
# All pages read keys from the controlling terminal (/dev/tty), so the
# wizard also works when the script itself arrived on stdin
# (curl ... | sudo bash): install.sh re-attaches /dev/tty before running it.

has_tty() {
  [ -e /dev/tty ] && ( : < /dev/tty ) 2>/dev/null
}

# ---------------------------------------------------------------- welcome
wiz_welcome() {
  tui_text_page "Yellod setup - step 1/7 - Welcome" "Welcome to the Yellod server setup.

Detected system:
    OS:   ${DISTRO_PRETTY}
    Arch: ${ARCH} (${ARCH_TAG})

This wizard will install and configure:
  - Yellod Downloader (YouTube -> MP3/MP4 web app)
  - QuicShare       (self-hosted file sharing server)

You will choose which HDD/SSD (or folder) stores the data, which
ports to use, how downloads are routed, and whether to get a
public-access guide.

Everything runs as an unprivileged service user with hardened
systemd units.

Keys:  Up/Down move    Enter/Space select    Tab goes to Continue"
}

# ---------------------------------------------------------------- apps
wiz_apps() {
  tui_checklist "Yellod setup - step 2/7 - Applications" \
    "What should be installed?

Move with Up/Down, switch the highlighted app on/off with Enter or
Space, then Tab to the Continue button and press Enter." \
    "downloader,quicshare" \
    downloader "Yellod Downloader - media downloader web app" \
    quicshare  "QuicShare - file sharing server (uploads/downloads)"
  APPS="$(printf '%s' "$TUI_RESULT" | tr ',' ' ')"
  [ -n "$APPS" ] || tui_fatal "Nothing selected - aborting."
}

# ---------------------------------------------------------------- storage
wiz_storage() {
  tui_text_page "Yellod setup - step 3/7 - Storage" \
    "Where should your data live?

Block devices detected on this machine:

$(lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT 2>/dev/null || echo '(lsblk unavailable)')

Tip: to use a brand-new disk, format and mount it first
(e.g.  mkfs.ext4 /dev/sdX1  and  mount /dev/sdX1 /mnt/data),
then pick that mount point here."

  local -a rl=()
  local -a mounts=()
  local default_tag="default"
  local i=1 mp size desc
  while IFS= read -r mp; do
    [ -n "$mp" ] || continue
    case "$mp" in
      /boot*|/snap*|/run*|/sys*|/proc*|/dev*|/var/lib/docker*) continue ;;
    esac
    size="$(df -h --output=avail "$mp" 2>/dev/null | tail -n1 | tr -d ' ')"
    desc="${size:-?} free"
    if [ "$mp" = "/" ]; then
      desc="$desc - system disk"
    fi
    rl+=("m$i|$mp" "$desc")
    mounts[i]="$mp"
    [ "$i" -eq 1 ] && default_tag="m1"
    i=$((i + 1))
  done < <(lsblk -o MOUNTPOINT -n -p 2>/dev/null | awk 'NF' | sort -u)
  rl+=("default|/srv/yellod" "recommended if unsure")
  rl+=("custom|" "Custom path / other mount point...")

  local choice
  tui_radiolist "Yellod setup - step 3/7 - Storage" \
    "Select the disk/mount that should hold the data (Up/Down moves the
selection, Enter confirms it)." "$default_tag" "${rl[@]}"
  choice="$TUI_RESULT"

  case "$choice" in
    m*)       DATA_ROOT="${mounts[${choice#m}]%/}/yellod" ;;
    default)  DATA_ROOT="/srv/yellod" ;;
    custom)
      tui_input "Yellod setup - step 3/7 - Storage" \
        "Full path of the folder where data will be stored
(must be on a mounted disk)." "/srv/yellod" tui_validate_abs_path
      DATA_ROOT="$TUI_RESULT"
      ;;
    *) tui_fatal "Setup cancelled." ;;
  esac

  case "$DATA_ROOT" in
    /*) : ;;
    *) tui_fatal "Data folder must be an absolute path (got: $DATA_ROOT)" ;;
  esac

  if [ "$DRY_RUN" != "true" ]; then
    if ! mkdir -p "$DATA_ROOT" 2>/dev/null || ! : > "$DATA_ROOT/.yellod-write-test" 2>/dev/null; then
      tui_fatal "Cannot write to $DATA_ROOT - please pick another location."
    fi
    rm -f "$DATA_ROOT/.yellod-write-test"
  fi
}

# ---------------------------------------------------------------- ports
wiz_ports() {
  if app_selected downloader; then
    tui_input "Yellod setup - step 4/7 - Ports" \
      "Downloader web port (it listens on localhost only; expose it
through a tunnel or reverse proxy for remote use)." \
      "5555" tui_validate_port
    DL_PORT="$TUI_RESULT"
    DL_BIND_MODE="localhost"
  fi

  if app_selected quicshare; then
    tui_input "Yellod setup - step 4/7 - Ports" \
      "QuicShare port (443 is the standard HTTPS port)." \
      "443" tui_validate_port
    QS_PORT="$TUI_RESULT"

    tui_radiolist "Yellod setup - step 4/7 - Ports" \
      "How should QuicShare be reachable?" "all" \
      all       "All interfaces - other devices / internet via tunnel (recommended for sharing)" \
      localhost "Localhost only - this machine only"
    QS_BIND_MODE="$TUI_RESULT"

    tui_input "Yellod setup - step 4/7 - Ports" \
      "Hostname or IP people will use to reach QuicShare
(used for the TLS certificate; can be changed later)." \
      "$(hostname -f 2>/dev/null || hostname)" tui_validate_not_empty
    QS_HOSTNAME="$TUI_RESULT"
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
  tui_radiolist "Yellod setup - step 5/7 - Routing" \
    "How should the downloader reach sites like YouTube?

Most connections work directly. On blocked servers/regions the
downloader can fall back to Tor - nothing else changes. Tor is
installed once and reused if it is already on this machine." "auto" \
    auto   "Auto - direct first, fall back to Tor when a site blocks us (recommended)" \
    always "Always use Tor for every download" \
    never  "Never use a proxy - direct connections only"
  PROXY_MODE="$TUI_RESULT"
}

# ---------------------------------------------------------------- expose
wiz_expose() {
  TUNNEL_GUIDE="no"
  if app_selected quicshare && [ "$QS_BIND_MODE" = "all" ]; then
    tui_buttons "Yellod setup - step 6/7 - Public access" \
      "Expose QuicShare to the internet with a Cloudflare Tunnel?

No ports need to be opened on your router - a step-by-step guide
will be printed at the end of the installation.

(You can also skip this and use a tunnel/reverse proxy of your choice.)" \
      0 "Yes, get the guide" "No, skip"
    if [ "$TUI_RESULT" = "0" ]; then TUNNEL_GUIDE="yes"; fi
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

Enter = install and turn the services on now."

  tui_buttons "Yellod setup - step 7/7 - Review" "$txt" 0 \
    "Install & start" "Cancel"
  [ "$TUI_RESULT" = "0" ] || tui_fatal "Aborted by user."
}

wiz_run() {
  tui_open
  wiz_welcome
  wiz_apps
  wiz_storage
  wiz_ports
  wiz_proxy
  wiz_expose
  wiz_summary
  tui_close
}
