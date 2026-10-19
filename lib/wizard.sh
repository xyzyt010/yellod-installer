#!/usr/bin/env bash
# Step-by-step terminal wizard for the Yellod installer.
# Uses the small in-house TUI (lib/tui.sh) so the keys behave the same on
# every machine:
#
#   Up/Down      move the highlight
#   Space        select / deselect the highlighted option
#   Enter        continue (on a focused button: activate it)
#   Tab          move the focus between the list and the buttons
#   Back button  (Tab to it, then Enter) returns to the previous step
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
  TUI_ALLOW_BACK="0"
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

Keys:  Up/Down move    Space = select    Enter = continue    Esc = quit"
}

# ---------------------------------------------------------------- apps
wiz_apps() {
  TUI_ALLOW_BACK="1"
  local def_csv
  def_csv="$(printf '%s' "${APPS:-downloader quicshare}" | tr ' ' ',')"
  tui_checklist "Yellod setup - step 2/7 - Applications" \
    "What should be installed?

Move with Up/Down, switch the highlighted app on/off with Space,
then press Enter to continue." \
    "$def_csv" \
    downloader "Yellod Downloader - media downloader web app" \
    quicshare  "QuicShare - file sharing server (uploads/downloads)"
  if [ "$TUI_BACK" = "1" ]; then return 0; fi
  APPS="$(printf '%s' "$TUI_RESULT" | sed 's/, */ /g; s/ *$//')"
  [ -n "$APPS" ] || tui_fatal "Nothing selected - aborting."
}

# ---------------------------------------------------------------- storage
wiz_storage() {
  TUI_ALLOW_BACK="1"
  TUI_BACK=""

  # The disk overview is only shown the first time the step is entered.
  if [ "${WIZ_DISK_INFO:-}" != "1" ]; then
    WIZ_DISK_INFO="1"
    tui_text_page "Yellod setup - step 3/7 - Storage" \
      "Where should your data live?

Block devices detected on this machine:

$(lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT 2>/dev/null || echo '(lsblk unavailable)')

Tip: to use a brand-new disk, format and mount it first
(e.g.  mkfs.ext4 /dev/sdX1  and  mount /dev/sdX1 /mnt/data),
then pick that mount point here."
    if [ "$TUI_BACK" = "1" ]; then return 0; fi
  fi

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
    if [ "$i" -eq 1 ]; then default_tag="m1"; fi
    i=$((i + 1))
  done < <(lsblk -o MOUNTPOINT -n -p 2>/dev/null | awk 'NF' | sort -u)
  rl+=("default|/srv/yellod" "recommended if unsure")
  rl+=("custom|" "Custom path / other mount point...")

  # Keep the previous answer when the user comes back to this step.
  if [ -n "${DATA_ROOT:-}" ]; then
    default_tag="custom"
    for i in "${!mounts[@]}"; do
      if [ "$DATA_ROOT" = "${mounts[$i]%/}/yellod" ]; then default_tag="m$i"; fi
    done
    if [ "$DATA_ROOT" = "/srv/yellod" ]; then default_tag="default"; fi
  fi

  local choice sub=0
  while :; do
    if [ "$sub" -eq 0 ]; then
      tui_radiolist "Yellod setup - step 3/7 - Storage" \
        "Select the disk/mount that should hold the data.

Move with Up/Down, select with Space, then press Enter to continue." \
        "$default_tag" "${rl[@]}"
      if [ "$TUI_BACK" = "1" ]; then return 0; fi
      choice="$TUI_RESULT"
      case "$choice" in
        m*)       DATA_ROOT="${mounts[${choice#m}]%/}/yellod" ;;
        default)  DATA_ROOT="/srv/yellod" ;;
        custom)   sub=1; continue ;;
        *)        tui_fatal "Setup cancelled." ;;
      esac
    else
      tui_input "Yellod setup - step 3/7 - Storage" \
        "Full path of the folder where data will be stored
(must be on a mounted disk)." "${DATA_ROOT:-/srv/yellod}" tui_validate_abs_path
      if [ "$TUI_BACK" = "1" ]; then sub=0; continue; fi
      DATA_ROOT="$TUI_RESULT"
    fi
    break
  done

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
  TUI_ALLOW_BACK="1"
  TUI_BACK=""
  local sub=0 nsub=0 i=0 q=""
  if app_selected downloader; then nsub=$((nsub + 1)); fi
  if app_selected quicshare; then nsub=$((nsub + 3)); fi
  [ "$nsub" -gt 0 ] || return 0

  while :; do
    # Map the sub-step index to one of the questions.
    q=""
    i=0
    if app_selected downloader; then
      if [ "$sub" -eq "$i" ]; then q="dlport"; fi
      i=$((i + 1))
    fi
    if app_selected quicshare; then
      if [ "$sub" -eq "$i" ]; then q="qsport"; fi
      i=$((i + 1))
      if [ "$sub" -eq "$i" ]; then q="qsbind"; fi
      i=$((i + 1))
      if [ "$sub" -eq "$i" ]; then q="qshost"; fi
      i=$((i + 1))
    fi

    case "$q" in
      dlport)
        tui_input "Yellod setup - step 4/7 - Ports" \
          "Downloader web port (it listens on localhost only; expose it
through a tunnel or reverse proxy for remote use)." \
          "${DL_PORT:-5555}" tui_validate_port
        ;;
      qsport)
        tui_input "Yellod setup - step 4/7 - Ports" \
          "QuicShare port (443 is the standard HTTPS port)." \
          "${QS_PORT:-443}" tui_validate_port
        ;;
      qsbind)
        tui_radiolist "Yellod setup - step 4/7 - Ports" \
          "How should QuicShare be reachable?" "${QS_BIND_MODE:-all}" \
          all       "All interfaces - other devices / internet via tunnel (recommended for sharing)" \
          localhost "Localhost only - this machine only"
        ;;
      qshost)
        tui_input "Yellod setup - step 4/7 - Ports" \
          "Hostname or IP people will use to reach QuicShare
(used for the TLS certificate; can be changed later)." \
          "${QS_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}" tui_validate_not_empty
        ;;
      *) return 0 ;;
    esac

    if [ "$TUI_BACK" = "1" ]; then
      sub=$((sub - 1))
      if [ "$sub" -lt 0 ]; then
        TUI_BACK="1"
        return 0
      fi
      continue
    fi

    case "$q" in
      dlport)
        DL_PORT="$TUI_RESULT"
        DL_BIND_MODE="localhost"
        ;;
      qsport) QS_PORT="$TUI_RESULT" ;;
      qsbind) QS_BIND_MODE="$TUI_RESULT" ;;
      qshost) QS_HOSTNAME="$TUI_RESULT" ;;
    esac

    sub=$((sub + 1))
    if [ "$sub" -ge "$nsub" ]; then break; fi
  done
}

# ---------------------------------------------------------------- proxy
# Only asked when the downloader is selected. "auto" is the useful default:
# try a direct connection first and only route through Tor when the site
# blocks this server. Tor is reused if already installed, otherwise it is
# installed as a normal dependency.
wiz_proxy() {
  TUI_ALLOW_BACK="1"
  TUI_BACK=""
  if ! app_selected downloader; then
    PROXY_MODE="never"
    return 0
  fi
  local def="auto"
  if [ "${WIZ_PROXY_USER:-}" = "1" ]; then def="${PROXY_MODE:-auto}"; fi
  tui_radiolist "Yellod setup - step 5/7 - Routing" \
    "How should the downloader reach sites like YouTube?

Most connections work directly. On blocked servers/regions the
downloader can fall back to Tor - nothing else changes. Tor is
installed once and reused if it is already on this machine." "$def" \
    auto   "Auto - direct first, fall back to Tor when a site blocks us (recommended)" \
    always "Always use Tor for every download" \
    never  "Never use a proxy - direct connections only"
  if [ "$TUI_BACK" = "1" ]; then return 0; fi
  WIZ_PROXY_USER="1"
  PROXY_MODE="$TUI_RESULT"
}

# ---------------------------------------------------------------- expose
wiz_expose() {
  TUI_ALLOW_BACK="1"
  TUI_BACK=""
  if app_selected quicshare && [ "$QS_BIND_MODE" = "all" ]; then
    local def=0
    if [ "${TUNNEL_GUIDE:-yes}" = "no" ]; then def=1; fi
    tui_buttons "Yellod setup - step 6/7 - Public access" \
      "Expose QuicShare to the internet with a Cloudflare Tunnel?

No ports need to be opened on your router - a step-by-step guide
will be printed at the end of the installation.

(You can also skip this and use a tunnel/reverse proxy of your choice.)" \
      "$def" "Yes, get the guide" "No, skip"
    if [ "$TUI_BACK" = "1" ]; then return 0; fi
    if [ "$TUI_RESULT" = "0" ]; then TUNNEL_GUIDE="yes"; else TUNNEL_GUIDE="no"; fi
  else
    TUNNEL_GUIDE="no"
  fi
}

# ---------------------------------------------------------------- summary
wiz_summary() {
  TUI_ALLOW_BACK="1"
  TUI_BACK=""
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
    "Install & start"
}

# ------------------------------------------------------------- navigation
# Which steps are actually shown for the current answers? Steps that are
# skipped are jumped over when going back, so Back never lands on a page
# that would immediately bounce forward again.
wiz_step_applicable() {
  case "$1" in
    5) app_selected downloader ;;
    6) app_selected quicshare && [ "$QS_BIND_MODE" = "all" ] ;;
    *) return 0 ;;
  esac
}

wiz_prev_step() { # N -> the step to return to (1 = welcome)
  local s=$(($1 - 1))
  if [ "$s" -lt 2 ]; then
    printf '1'
    return 0
  fi
  while [ "$s" -ge 2 ]; do
    if wiz_step_applicable "$s"; then
      printf '%s' "$s"
      return 0
    fi
    s=$((s - 1))
  done
  printf '2'
}

wiz_run() {
  local step=1
  tui_open
  while :; do
    case "$step" in
      1)
        wiz_welcome
        step=2
        ;;
      2)
        wiz_apps
        if [ "$TUI_BACK" = "1" ]; then step=1; else step=3; fi
        ;;
      3)
        wiz_storage
        if [ "$TUI_BACK" = "1" ]; then step="$(wiz_prev_step 3)"; else step=4; fi
        ;;
      4)
        wiz_ports
        if [ "$TUI_BACK" = "1" ]; then step="$(wiz_prev_step 4)"; else step=5; fi
        ;;
      5)
        wiz_proxy
        if [ "$TUI_BACK" = "1" ]; then step="$(wiz_prev_step 5)"; else step=6; fi
        ;;
      6)
        wiz_expose
        if [ "$TUI_BACK" = "1" ]; then step="$(wiz_prev_step 6)"; else step=7; fi
        ;;
      7)
        wiz_summary
        if [ "$TUI_BACK" = "1" ]; then step="$(wiz_prev_step 7)"; else break; fi
        ;;
      *) break ;;
    esac
  done
  tui_close
}
