#!/usr/bin/env bash
# Terminal wizard widgets for the Yellod installer - whiptail-style look.
#
# The pages are drawn like a classic full-screen dialog GUI: blue
# background, a centered box with the title in the top border, highlighted
# rows and <buttons>, exactly like the whiptail dialogs the installer used
# before - but with one consistent, predictable keyboard model:
#
#   Up/Down      move the highlight
#   Space        select / deselect the highlighted option
#   Enter        continue / confirm (activates the focused button)
#   Tab          move the focus between the list and the buttons
#   Esc          quit (asks for confirmation first)
#
# Pages that can go back show a < Back > button next to < Continue >.
#
# Pages are drawn on the controlling terminal (/dev/tty, fd 8) and read
# keys from it byte-for-byte, so the same keys work on every machine and
# when the installer itself arrived on stdin (curl ... | bash).

TUI_ROWS=24
TUI_COLS=80
TUI_BOX_W=86
TUI_INNER_W=84
TUI_U8="false"
TUI_COLORS="1"
TUI_OPENED="false"
TUI_STTY_SAVED=""
TUI_FLASH=""
TUI_KEY=""
TUI_CHAR=""
TUI_RESULT=""
TUI_BACK=""
TUI_ALLOW_BACK="0"
TUI_FOCUS=""
TUI_ROW=""
TUI_PADDED=""
TUI_PREV_EXIT_CMD=""
TUI_FATAL_MSG=""

# ------------------------------------------------------------------ setup
tui_open() {
  [ -e /dev/tty ] || die "No controlling terminal for the setup wizard."
  if [ "$TUI_OPENED" != "true" ]; then
    exec 8<>/dev/tty || die "Cannot open /dev/tty for the setup wizard."
    TUI_STTY_SAVED="$(stty -g <&8 2>/dev/null || true)"
    [ -n "$TUI_STTY_SAVED" ] || die "No usable terminal for the setup wizard."
    stty -echo -icanon min 1 time 0 <&8 2>/dev/null || true
    TUI_OPENED="true"
    # Keep any EXIT trap that was already installed (e.g. the bootstrap
    # cleanup in install.sh) and chain it after our own cleanup.
    local t
    t="$(trap -p EXIT || true)"
    case "$t" in
      "trap -- '"*"' EXIT")
        TUI_PREV_EXIT_CMD="${t#trap -- \'}"
        TUI_PREV_EXIT_CMD="${TUI_PREV_EXIT_CMD%\' EXIT}"
        ;;
      *) TUI_PREV_EXIT_CMD="" ;;
    esac
    trap 'tui_close; if [ -n "$TUI_FATAL_MSG" ]; then printf "[fail] %s\n" "$TUI_FATAL_MSG" >&2; fi; if [ -n "$TUI_PREV_EXIT_CMD" ]; then eval "$TUI_PREV_EXIT_CMD"; TUI_PREV_EXIT_CMD=""; fi' EXIT
    trap 'tui_close; printf "\n[info] Setup cancelled.\n" >&2; exit 130' INT TERM HUP
    printf '\033[0m\033[2J\033[H\033[?25l' >&8
  fi
  tui_colors
  tui_dims
}

# Leave the dialog screen, restore the terminal and clear the screen so the
# next output (installer log lines) starts on a clean, normally-coloured
# terminal - the same effect as closing a whiptail dialog.
tui_close() {
  if [ "$TUI_OPENED" = "true" ]; then
    stty "$TUI_STTY_SAVED" <&8 2>/dev/null || true
    printf '\033[0m\033[2J\033[H\033[?25h' >&8 2>/dev/null || true
    TUI_OPENED="false"
    # Close the terminal fd. Must be a plain redirection-only exec: any
    # trailing redirection here (e.g. 2>/dev/null) would be applied
    # permanently to the shell and swallow all later stderr output.
    exec 8>&-
  fi
  return 0
}

# Abort the whole installer from inside the wizard. The message is printed
# *after* the dialog screen is closed (see the EXIT trap in tui_open).
tui_fatal() {
  TUI_FATAL_MSG="$1"
  exit 1
}

tui_colors() {
  local loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  case "$loc" in
    *UTF-8*|*utf8*|*UTF8*) TUI_U8="true" ;;
  esac
  if [ -n "${NO_COLOR:-}" ]; then
    TUI_COLORS="0"
    TUI_LINE=""; TUI_TITLE=""; TUI_SEL=""; TUI_DIM=""; TUI_ERR=""
  else
    TUI_COLORS="1"
    TUI_LINE=$'\033[0m\033[44m\033[37m'   # reset + blue background + light-gray text
    TUI_TITLE=$'\033[1;37m'                # bold white (titles)
    TUI_SEL=$'\033[47m\033[30m'            # highlighted row / focused button
    TUI_DIM=$'\033[2m'                     # dimmed helper text
    TUI_ERR=$'\033[1;31m'                  # errors
  fi
  if [ "$TUI_U8" = "true" ]; then
    TUI_TL="┌"; TUI_TR="┐"; TUI_BL="└"; TUI_BR="┘"
    TUI_H="─"; TUI_V="│"; TUI_LT="┤"; TUI_RT="├"
  else
    TUI_TL="+"; TUI_TR="+"; TUI_BL="+"; TUI_BR="+"
    TUI_H="-"; TUI_V="|"; TUI_LT="["; TUI_RT="]"
  fi
}

tui_size() {
  local sz
  sz="$(stty size <&8 2>/dev/null || true)"
  TUI_ROWS="${sz%% *}"
  TUI_COLS="${sz##* }"
  case "$TUI_ROWS" in ''|*[!0-9]*) TUI_ROWS=24 ;; esac
  case "$TUI_COLS" in ''|*[!0-9]*) TUI_COLS=80 ;; esac
  if [ "$TUI_ROWS" -lt 10 ]; then TUI_ROWS=10; fi
  if [ "$TUI_COLS" -lt 30 ]; then TUI_COLS=30; fi
  if [ "$TUI_COLS" -gt 120 ]; then TUI_COLS=120; fi
}

tui_dims() {
  tui_size
  TUI_BOX_W=$((TUI_COLS - 4))
  if [ "$TUI_BOX_W" -gt 86 ]; then TUI_BOX_W=86; fi
  if [ "$TUI_BOX_W" -lt 40 ]; then TUI_BOX_W=40; fi
  TUI_INNER_W=$((TUI_BOX_W - 2))
}

# ------------------------------------------------------------------ keys
# Reads one key from the terminal into TUI_KEY. Arrow keys arrive as
# ESC [ A/B/C/D; a bare ESC is told apart from an escape sequence with a
# short follow-up timeout. Text characters land in TUI_CHAR with TUI_KEY=CHAR.
tui_read_key() {
  local k k1 k2 _
  TUI_KEY=""; TUI_CHAR=""
  if ! IFS= read -rsn1 -u 8 k; then
    TUI_KEY="EOF"
    return 0
  fi
  case "$k" in
    $'\r'|$'\n'|'')  TUI_KEY="ENTER" ;;
    $'\t')           TUI_KEY="TAB" ;;
    $'\x7f'|$'\x08') TUI_KEY="BACKSPACE" ;;
    $'\x15')         TUI_KEY="CLEAR" ;;
    $'\x1b')
      if ! IFS= read -rsn1 -t 0.05 -u 8 k1; then TUI_KEY="ESC"; return 0; fi
      case "$k1" in
        '['|'O')
          if ! IFS= read -rsn1 -t 0.05 -u 8 k2; then TUI_KEY="ESC"; return 0; fi
          case "$k2" in
            A) TUI_KEY="UP" ;;
            B) TUI_KEY="DOWN" ;;
            C) TUI_KEY="RIGHT" ;;
            D) TUI_KEY="LEFT" ;;
            H) TUI_KEY="HOME" ;;
            F) TUI_KEY="END" ;;
            Z) TUI_KEY="BACKTAB" ;;
            5|6|1|4)
              IFS= read -rsn1 -t 0.05 -u 8 _ || true
              case "$k2" in
                5) TUI_KEY="PGUP" ;;
                6) TUI_KEY="PGDN" ;;
                1) TUI_KEY="HOME" ;;
                4) TUI_KEY="END" ;;
              esac
              ;;
            *) TUI_KEY="ESC" ;;
          esac
          ;;
        *) TUI_KEY="ESC" ;;
      esac
      ;;
    ' ') TUI_KEY="SPACE" ;;
    *) TUI_KEY="CHAR"; TUI_CHAR="$k" ;;
  esac
  return 0
}

# ------------------------------------------------------------- utilities
tui_rep() { # char count -> char repeated count times
  local ch="$1" c="$2" s=""
  printf -v s '%*s' "$c" ''
  printf '%s' "${s// /$ch}"
}

tui_padto() { # plain-text width -> TUI_PADDED (padded/truncated to width)
  local t="$1" w="$2" pad
  if [ "$w" -lt 1 ]; then w=1; fi
  if [ "${#t}" -gt "$w" ]; then t="${t:0:$w}"; fi
  printf -v pad '%*s' "$((w - ${#t}))" ''
  TUI_PADDED="$t$pad"
}

# Renders a row of <buttons>, centered, with the focused one highlighted.
# $1 = focused index (-1 = none), rest = labels. Result in TUI_ROW.
tui_row_buttons() {
  local sel="$1"; shift
  local -a labs=("$@")
  local plain="" rich="" seg i
  for i in "${!labs[@]}"; do
    if [ "$i" -eq "$sel" ]; then
      if [ "$TUI_COLORS" = "1" ]; then seg="< ${labs[$i]} >"; else seg="[ ${labs[$i]} ]"; fi
    else
      if [ "$TUI_COLORS" = "1" ]; then seg="< ${labs[$i]} >"; else seg="< ${labs[$i]} >"; fi
    fi
    if [ "$i" -gt 0 ]; then plain+="     "; rich+="     "; fi
    plain+="$seg"
    if [ "$i" -eq "$sel" ] && [ "$TUI_COLORS" = "1" ]; then
      rich+="${TUI_SEL}${seg}${TUI_LINE}"
    else
      rich+="$seg"
    fi
  done
  local plen="${#plain}"
  local lpad=$(((TUI_INNER_W - plen) / 2))
  local rpad
  if [ "$lpad" -lt 0 ]; then lpad=0; fi
  rpad=$((TUI_INNER_W - lpad - plen))
  if [ "$rpad" -lt 0 ]; then rpad=0; fi
  local L R
  printf -v L '%*s' "$lpad" ''
  printf -v R '%*s' "$rpad" ''
  TUI_ROW="$L$rich$R"
}

# Renders the text input line with the block cursor. $1 = value, $2 = cursor
# position. Result in TUI_ROW (styled, padded to the box inner width).
tui_row_input() {
  local value="$1" pos="$2"
  local maxv=$((TUI_INNER_W - 3))
  if [ "${#value}" -gt "$maxv" ]; then
    value="${value:0:$maxv}"
    if [ "$pos" -gt "$maxv" ]; then pos="$maxv"; fi
  fi
  local padded="${value} "
  local before="${padded:0:pos}" at="${padded:pos:1}" after="${padded:pos+1}"
  local rest=""
  printf -v rest '%*s' "$((TUI_INNER_W - ${#value} - 3))" ''
  TUI_ROW="  ${before}${TUI_SEL}${at}${TUI_LINE}${after}${rest}"
}

# Renders a plain (non-editable) text row, padded to the box inner width.
tui_row_text() { # text
  local t="$1" maxv=$((TUI_INNER_W - 3)) rest
  if [ "${#t}" -gt "$maxv" ]; then t="${t:0:$maxv}"; fi
  printf -v rest '%*s' "$((TUI_INNER_W - ${#t} - 2))" ''
  TUI_ROW="  ${t}${rest}"
}

# Cycles the button focus. $1 = current focus (content|back|continue),
# $2 = allow_back (1/0), $3 = direction (1 = forward, -1 = backward).
# Result in TUI_FOCUS.
tui_focus_cycle() {
  case "$1:$2:$3" in
    content:1:1)   TUI_FOCUS="back" ;;
    content:1:-1)  TUI_FOCUS="continue" ;;
    content:0:*)   TUI_FOCUS="continue" ;;
    back:*:1)      TUI_FOCUS="continue" ;;
    back:*:-1)     TUI_FOCUS="content" ;;
    continue:*:1)  TUI_FOCUS="content" ;;
    continue:1:-1) TUI_FOCUS="back" ;;
    *)             TUI_FOCUS="content" ;;
  esac
}

# Renders the standard navigation row: < Back > < Continue > when the page
# can go back, just < Continue > otherwise. $1 = focus. Result in TUI_ROW.
tui_row_navbuttons() {
  if [ "$TUI_ALLOW_BACK" = "1" ]; then
    case "$1" in
      back)     tui_row_buttons 0 "Back" "Continue" ;;
      continue) tui_row_buttons 1 "Back" "Continue" ;;
      *)        tui_row_buttons -1 "Back" "Continue" ;;
    esac
  else
    case "$1" in
      continue) tui_row_buttons 0 "Continue" ;;
      *)        tui_row_buttons -1 "Continue" ;;
    esac
  fi
}

# -------------------------------------------------------------- drawing
TUI_OUT=""
TUI_LINES=()
TUI_LSTYLE=()

tui_begin() { TUI_LINES=(); TUI_LSTYLE=(); }
tui_blank() { TUI_LINES+=(""); TUI_LSTYLE+=(""); }
tui_add() { TUI_LINES+=("$1"); TUI_LSTYLE+=(""); }
tui_add_sel() { TUI_LINES+=("$1"); TUI_LSTYLE+=("SEL"); }
tui_add_dim() { TUI_LINES+=("$1"); TUI_LSTYLE+=("DIM"); }
tui_add_err() { TUI_LINES+=("$1"); TUI_LSTYLE+=("ERR"); }
tui_add_raw() { TUI_LINES+=("$1"); TUI_LSTYLE+=("RAW"); }

tui_add_wrapped() { # text
  local -a lines=()
  mapfile -t lines < <(printf '%s\n' "$1" | fold -s -w "$((TUI_INNER_W - 2))")
  local l
  for l in "${lines[@]}"; do
    if [ -z "$l" ]; then tui_blank; else tui_add "  ${l}"; fi
  done
}

tui_top_border() { # title
  local title="$1" pad l r block
  if [ -z "$title" ]; then
    printf '%s%s%s' "$TUI_TL" "$(tui_rep "$TUI_H" "$TUI_INNER_W")" "$TUI_TR"
    return 0
  fi
  if [ "${#title}" -gt $((TUI_INNER_W - 8)) ]; then title="${title:0:$((TUI_INNER_W - 9))}~"; fi
  if [ "$TUI_U8" = "true" ]; then
    block=" ${title} "
    pad=$((TUI_INNER_W - ${#block} - 2))
    if [ "$pad" -lt 2 ]; then pad=2; fi
    l=$((pad / 2))
    r=$((pad - l))
    printf '%s%s%s%s%s%s%s' \
      "$TUI_TL" "$(tui_rep "$TUI_H" "$l")" "$TUI_LT" \
      "${TUI_TITLE}${block}${TUI_LINE}" \
      "$TUI_RT" "$(tui_rep "$TUI_H" "$r")" "$TUI_TR"
  else
    block="[ ${title} ]"
    pad=$((TUI_INNER_W - ${#block}))
    if [ "$pad" -lt 2 ]; then pad=2; fi
    l=$((pad / 2))
    r=$((pad - l))
    printf '%s%s%s%s%s' \
      "$TUI_TL" "$(tui_rep "$TUI_H" "$l")" \
      "${TUI_TITLE}${block}${TUI_LINE}" \
      "$(tui_rep "$TUI_H" "$r")" "$TUI_TR"
  fi
}

tui_bottom_border() {
  printf '%s%s%s' "$TUI_BL" "$(tui_rep "$TUI_H" "$TUI_INNER_W")" "$TUI_BR"
}

# Draws the whole page: blue background, centered box with the title in the
# top border and the content lines inside. $1 = title.
tui_flush() {
  local title="${1:-}"
  tui_dims
  local n=${#TUI_LINES[@]}
  local box_h=$((n + 2))
  local top=$(((TUI_ROWS - box_h) / 2))
  if [ "$top" -lt 0 ]; then top=0; fi
  local bottom=$((TUI_ROWS - box_h - top))
  if [ "$bottom" -lt 0 ]; then bottom=0; fi
  local lmargin=$(((TUI_COLS - TUI_BOX_W) / 2))
  local lpad="" fill="" i line st
  printf -v lpad '%*s' "$lmargin" ''
  printf -v fill '%*s' "$TUI_COLS" ''
  TUI_OUT=""
  for ((i = 0; i < top; i++)); do
    TUI_OUT+="${TUI_LINE}${fill}"$'\033[K\n'
  done
  TUI_OUT+="${TUI_LINE}${lpad}$(tui_top_border "$title")"$'\033[K\n'
  for ((i = 0; i < n; i++)); do
    line="${TUI_LINES[$i]}"
    st="${TUI_LSTYLE[$i]}"
    if [ "$st" = "RAW" ]; then
      TUI_OUT+="${TUI_LINE}${lpad}${TUI_V}${line}${TUI_V}"$'\033[K\n'
      continue
    fi
    tui_padto "$line" "$TUI_INNER_W"
    case "$st" in
      SEL) TUI_OUT+="${TUI_LINE}${lpad}${TUI_V}${TUI_SEL}${TUI_PADDED}${TUI_LINE}${TUI_V}"$'\033[K\n' ;;
      DIM) TUI_OUT+="${TUI_LINE}${lpad}${TUI_V}${TUI_DIM}${TUI_PADDED}${TUI_LINE}${TUI_V}"$'\033[K\n' ;;
      ERR) TUI_OUT+="${TUI_LINE}${lpad}${TUI_V}${TUI_ERR}${TUI_PADDED}${TUI_LINE}${TUI_V}"$'\033[K\n' ;;
      *)   TUI_OUT+="${TUI_LINE}${lpad}${TUI_V}${TUI_PADDED}${TUI_V}"$'\033[K\n' ;;
    esac
  done
  TUI_OUT+="${TUI_LINE}${lpad}$(tui_bottom_border)"$'\033[K\n'
  for ((i = 0; i < bottom; i++)); do
    TUI_OUT+="${TUI_LINE}${fill}"$'\033[K\n'
  done
  printf '\033[H%s\033[J' "$TUI_OUT" >&8
}

# Quit confirmation (Esc anywhere). "Yes" quits the whole installer.
tui_abort_confirm() {
  local sel=0
  while :; do
    tui_begin
    tui_blank
    tui_add "  Stop the Yellod setup wizard?"
    tui_blank
    tui_row_buttons "$sel" "No, keep going" "Yes, quit setup"
    tui_add_raw "$TUI_ROW"
    tui_blank
    tui_add_dim "  Left/Right move   Enter = confirm"
    tui_flush "Quit the setup?"
    tui_read_key
    case "$TUI_KEY" in
      LEFT|RIGHT|TAB|BACKTAB|UP|DOWN) sel=$((1 - sel)) ;;
      ENTER)
        if [ "$sel" -eq 1 ]; then
          tui_fatal "Setup cancelled."
        else
          return 0
        fi
        ;;
      ESC) return 0 ;;
      EOF) tui_fatal "Terminal closed - setup cancelled." ;;
      *) ;;
    esac
  done
}

# ----------------------------------------------------------------- pager
tui_text_page() { # title body
  local title="$1" body="$2" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/yellod-tui.XXXXXX")"
  printf '%s\n' "$body" >"$tmp"
  tui_pager "$title" "$tmp"
  rm -f "$tmp"
}

tui_pager() { # title file
  TUI_BACK=""
  local title="$1" file="$2"
  local -a content=()
  mapfile -t content <"$file" 2>/dev/null || true
  local total="${#content[@]}" offset=0 page maxoff i ind focus="content" chrome
  while :; do
    tui_dims
    chrome=10
    if [ "$TUI_ALLOW_BACK" = "1" ]; then chrome=11; fi
    page=$((TUI_ROWS - chrome))
    if [ "$page" -lt 3 ]; then page=3; fi
    maxoff=$((total - page))
    if [ "$maxoff" -lt 0 ]; then maxoff=0; fi
    if [ "$offset" -gt "$maxoff" ]; then offset="$maxoff"; fi

    tui_begin
    for ((i = offset; i < offset + page && i < total; i++)); do
      tui_add "  ${content[$i]}"
    done
    tui_blank
    ind=""
    if [ "$offset" -gt 0 ]; then ind="^ more above"; fi
    if [ "$offset" -lt "$maxoff" ]; then ind="${ind:+$ind   }v more below"; fi
    tui_add_dim "  ${ind}"
    if [ "$TUI_ALLOW_BACK" = "1" ]; then
      tui_row_navbuttons "$focus"
      tui_add_raw "$TUI_ROW"
    fi
    tui_add_dim "  Up/Down scroll   PgUp/PgDn   Enter = continue   Esc = quit"
    tui_flush "$title"

    tui_read_key
    case "$TUI_KEY" in
      UP|PGUP|DOWN|PGDN)
        if [ "$focus" = "content" ]; then
          case "$TUI_KEY" in
            UP) offset=$((offset - 1)); if [ "$offset" -lt 0 ]; then offset=0; fi ;;
            DOWN) offset=$((offset + 1)); if [ "$offset" -gt "$maxoff" ]; then offset="$maxoff"; fi ;;
            PGUP) offset=$((offset - page)); if [ "$offset" -lt 0 ]; then offset=0; fi ;;
            PGDN) offset=$((offset + page)); if [ "$offset" -gt "$maxoff" ]; then offset="$maxoff"; fi ;;
          esac
        fi
        ;;
      TAB)
        if [ "$TUI_ALLOW_BACK" = "1" ]; then tui_focus_cycle "$focus" 1 1; focus="$TUI_FOCUS"; fi
        ;;
      BACKTAB)
        if [ "$TUI_ALLOW_BACK" = "1" ]; then tui_focus_cycle "$focus" 1 -1; focus="$TUI_FOCUS"; fi
        ;;
      LEFT)
        if [ "$focus" != "content" ]; then tui_focus_cycle "$focus" 1 -1; focus="$TUI_FOCUS"; fi
        ;;
      RIGHT)
        if [ "$focus" != "content" ]; then tui_focus_cycle "$focus" 1 1; focus="$TUI_FOCUS"; fi
        ;;
      ENTER)
        if [ "$focus" = "back" ]; then TUI_BACK="1"; fi
        return 0
        ;;
      ESC) tui_abort_confirm ;;
      EOF) tui_fatal "Terminal closed - setup cancelled." ;;
      *) ;;
    esac
  done
}

# ------------------------------------------------------------- checklist
# tui_checklist TITLE INTRO DEFAULT_TAGS TAG DESC [TAG DESC ...]
# TAG may be "tag|label" to show a friendly label instead of the tag.
# Up/Down move the highlight, Space switches the highlighted option on/off,
# Enter continues, Tab reaches the Back button. Result in TUI_RESULT;
# going back is reported in TUI_BACK.
tui_checklist() {
  TUI_RESULT=""; TUI_BACK=""
  local title="$1" intro="$2" default_csv="$3"; shift 3
  local -a tags=() labels=() descs=() checked=()
  local t d
  while [ "$#" -ge 2 ]; do
    t="$1"; d="$2"; shift 2
    case "$t" in
      *"|"*) tags+=("${t%%|*}"); labels+=("${t#*|}") ;;
      *)     tags+=("$t");        labels+=("$t") ;;
    esac
    descs+=("$d")
  done
  local n=${#tags[@]}
  [ "$n" -gt 0 ] || tui_fatal "tui_checklist: no options"
  local idx=0 focus="content" i tabhint
  for i in "${!tags[@]}"; do
    case " ${default_csv//,/ } " in
      *" ${tags[$i]} "*) checked[i]=1 ;;
      *)                 checked[i]=0 ;;
    esac
  done

  local mark pt plain sel_list sel_count
  while :; do
    tui_dims
    tui_begin
    if [ -n "$intro" ]; then tui_add_wrapped "$intro"; fi
    tui_blank
    for i in "${!tags[@]}"; do
      if [ "${checked[$i]}" = "1" ]; then mark="[X]"; else mark="[ ]"; fi
      pt=""
      if [ "$idx" -eq "$i" ] && [ "$focus" = "content" ] && [ "$TUI_COLORS" != "1" ]; then pt=">"; fi
      if [ -n "${labels[$i]}" ]; then
        plain="$(printf '%s  %s %-12s %s' "$pt" "$mark" "${labels[$i]}" "${descs[$i]}")"
      else
        plain="$(printf '%s  %s %s' "$pt" "$mark" "${descs[$i]}")"
      fi
      if [ "$idx" -eq "$i" ] && [ "$focus" = "content" ]; then
        tui_add_sel "$plain"
      else
        tui_add "$plain"
      fi
    done
    sel_list=""
    sel_count=0
    for i in "${!tags[@]}"; do
      if [ "${checked[$i]}" = "1" ]; then sel_list+="${labels[$i]}, "; sel_count=$((sel_count + 1)); fi
    done
    sel_list="${sel_list%, }"
    tui_blank
    tui_row_navbuttons "$focus"
    tui_add_raw "$TUI_ROW"
    tui_blank
    if [ "$TUI_FLASH" = "1" ]; then
      tui_add_err "  Select at least one option with Space, then continue."
    fi
    [ -n "$sel_list" ] || sel_list="nothing selected yet"
    tui_add_dim "  chosen: ${sel_list}"
    if [ "$TUI_ALLOW_BACK" = "1" ]; then tabhint="Tab = Back / Continue"; else tabhint="Tab = Continue"; fi
    tui_add_dim "  Up/Down move   Space = select   Enter = continue"
    tui_add_dim "  ${tabhint}   Esc = quit"
    tui_flush "$title"

    tui_read_key
    TUI_FLASH=""
    case "$TUI_KEY" in
      UP)
        if [ "$focus" = "content" ]; then
          idx=$((idx - 1))
          if [ "$idx" -lt 0 ]; then idx=$((n - 1)); fi
        fi
        ;;
      DOWN)
        if [ "$focus" = "content" ]; then
          idx=$((idx + 1))
          if [ "$idx" -ge "$n" ]; then idx=0; fi
        fi
        ;;
      TAB) tui_focus_cycle "$focus" "$TUI_ALLOW_BACK" 1; focus="$TUI_FOCUS" ;;
      BACKTAB) tui_focus_cycle "$focus" "$TUI_ALLOW_BACK" -1; focus="$TUI_FOCUS" ;;
      LEFT)
        if [ "$focus" != "content" ]; then tui_focus_cycle "$focus" "$TUI_ALLOW_BACK" -1; focus="$TUI_FOCUS"; fi
        ;;
      RIGHT)
        if [ "$focus" != "content" ]; then tui_focus_cycle "$focus" "$TUI_ALLOW_BACK" 1; focus="$TUI_FOCUS"; fi
        ;;
      SPACE)
        if [ "$focus" = "content" ]; then
          if [ "${checked[$idx]}" = "1" ]; then checked[idx]=0; else checked[idx]=1; fi
        fi
        ;;
      ENTER)
        if [ "$focus" = "back" ]; then
          TUI_BACK="1"
          return 0
        fi
        if [ "$sel_count" -gt 0 ]; then
          TUI_RESULT="$sel_list"
          return 0
        fi
        TUI_FLASH="1"
        ;;
      ESC) tui_abort_confirm ;;
      EOF) tui_fatal "Terminal closed - setup cancelled." ;;
      *) ;;
    esac
  done
}

# ------------------------------------------------------------- radiolist
# tui_radiolist TITLE INTRO DEFAULT_TAG TAG DESC [TAG DESC ...]
# TAG may be "tag|label" to show a friendly label instead of the tag.
# Up/Down move the highlight, Space selects the highlighted entry, Enter
# continues. Tab reaches the Back button. Result in TUI_RESULT; going back
# is reported in TUI_BACK.
tui_radiolist() {
  TUI_RESULT=""; TUI_BACK=""
  local title="$1" intro="$2" default_tag="$3"; shift 3
  local -a tags=() labels=() descs=()
  local t d
  while [ "$#" -ge 2 ]; do
    t="$1"; d="$2"; shift 2
    case "$t" in
      *"|"*) tags+=("${t%%|*}"); labels+=("${t#*|}") ;;
      *)     tags+=("$t");        labels+=("$t") ;;
    esac
    descs+=("$d")
  done
  local n=${#tags[@]}
  [ "$n" -gt 0 ] || tui_fatal "tui_radiolist: no options"
  local chosen=0 idx=0 i focus="content" tabhint
  for i in "${!tags[@]}"; do
    if [ "${tags[$i]}" = "$default_tag" ]; then chosen="$i"; fi
  done
  idx="$chosen"

  local mark pt plain
  while :; do
    tui_dims
    tui_begin
    if [ -n "$intro" ]; then tui_add_wrapped "$intro"; fi
    tui_blank
    for i in "${!tags[@]}"; do
      if [ "$i" -eq "$chosen" ]; then mark="(*)"; else mark="( )"; fi
      pt=""
      if [ "$i" -eq "$idx" ] && [ "$focus" = "content" ] && [ "$TUI_COLORS" != "1" ]; then pt=">"; fi
      if [ -n "${labels[$i]}" ]; then
        plain="$(printf '%s  %s %-12s %s' "$pt" "$mark" "${labels[$i]}" "${descs[$i]}")"
      else
        plain="$(printf '%s  %s %s' "$pt" "$mark" "${descs[$i]}")"
      fi
      if [ "$i" -eq "$idx" ] && [ "$focus" = "content" ]; then
        tui_add_sel "$plain"
      else
        tui_add "$plain"
      fi
    done
    tui_blank
    tui_row_navbuttons "$focus"
    tui_add_raw "$TUI_ROW"
    tui_blank
    if [ "$TUI_ALLOW_BACK" = "1" ]; then tabhint="Tab = Back / Continue"; else tabhint="Tab = Continue"; fi
    tui_add_dim "  Up/Down move   Space = select   Enter = continue"
    tui_add_dim "  ${tabhint}   Esc = quit"
    tui_flush "$title"

    tui_read_key
    case "$TUI_KEY" in
      UP)
        if [ "$focus" = "content" ]; then idx=$(((idx + n - 1) % n)); fi
        ;;
      DOWN)
        if [ "$focus" = "content" ]; then idx=$(((idx + 1) % n)); fi
        ;;
      SPACE)
        if [ "$focus" = "content" ]; then chosen="$idx"; fi
        ;;
      TAB) tui_focus_cycle "$focus" "$TUI_ALLOW_BACK" 1; focus="$TUI_FOCUS" ;;
      BACKTAB) tui_focus_cycle "$focus" "$TUI_ALLOW_BACK" -1; focus="$TUI_FOCUS" ;;
      LEFT)
        if [ "$focus" != "content" ]; then tui_focus_cycle "$focus" "$TUI_ALLOW_BACK" -1; focus="$TUI_FOCUS"; fi
        ;;
      RIGHT)
        if [ "$focus" != "content" ]; then tui_focus_cycle "$focus" "$TUI_ALLOW_BACK" 1; focus="$TUI_FOCUS"; fi
        ;;
      ENTER)
        if [ "$focus" = "back" ]; then
          TUI_BACK="1"
          return 0
        fi
        TUI_RESULT="${tags[$chosen]}"
        return 0
        ;;
      ESC) tui_abort_confirm ;;
      EOF) tui_fatal "Terminal closed - setup cancelled." ;;
      *) ;;
    esac
  done
}

# ------------------------------------------------------------ input box
# tui_input TITLE INTRO DEFAULT [VALIDATOR]
# VALIDATOR is a function name; it prints an error message when the value
# is not acceptable (or nothing when it is fine). Enter confirms, Tab
# reaches the Back button. Result in TUI_RESULT; going back in TUI_BACK.
tui_input() {
  TUI_RESULT=""; TUI_BACK=""
  local title="$1" intro="$2" value="$3" validator="${4:-}"
  local pos=${#value} focus="content" err tabhint
  while :; do
    tui_dims
    tui_begin
    if [ -n "$intro" ]; then tui_add_wrapped "$intro"; fi
    tui_blank
    if [ "$focus" = "content" ]; then
      tui_row_input "$value" "$pos"
    else
      tui_row_text "$value"
    fi
    tui_add_raw "$TUI_ROW"
    if [ -n "$TUI_FLASH" ]; then
      tui_blank
      tui_add_err "  ${TUI_FLASH}"
    fi
    tui_blank
    tui_row_navbuttons "$focus"
    tui_add_raw "$TUI_ROW"
    tui_blank
    if [ "$TUI_ALLOW_BACK" = "1" ]; then tabhint="Tab = Back / Continue"; else tabhint="Tab = Continue"; fi
    tui_add_dim "  Type the value   Enter = confirm"
    tui_add_dim "  ${tabhint}   Esc = quit"
    tui_flush "$title"
    TUI_FLASH=""

    tui_read_key
    case "$TUI_KEY" in
      ENTER)
        if [ "$focus" = "back" ]; then
          TUI_BACK="1"
          return 0
        fi
        err=""
        if [ -n "$validator" ]; then
          err="$("$validator" "$value" 2>/dev/null || true)"
        fi
        if [ -n "$err" ]; then
          TUI_FLASH="$err"
        else
          TUI_RESULT="$value"
          return 0
        fi
        ;;
      CHAR)
        if [ "$focus" = "content" ]; then value="${value:0:pos}${TUI_CHAR}${value:pos}"; pos=$((pos + 1)); fi
        ;;
      SPACE)
        if [ "$focus" = "content" ]; then value="${value:0:pos} ${value:pos}"; pos=$((pos + 1)); fi
        ;;
      BACKSPACE)
        if [ "$focus" = "content" ] && [ "$pos" -gt 0 ]; then
          value="${value:0:pos-1}${value:pos}"
          pos=$((pos - 1))
        fi
        ;;
      CLEAR)
        if [ "$focus" = "content" ]; then value=""; pos=0; fi
        ;;
      LEFT)
        if [ "$focus" = "content" ]; then
          if [ "$pos" -gt 0 ]; then pos=$((pos - 1)); fi
        else
          tui_focus_cycle "$focus" "$TUI_ALLOW_BACK" -1; focus="$TUI_FOCUS"
        fi
        ;;
      RIGHT)
        if [ "$focus" = "content" ]; then
          if [ "$pos" -lt "${#value}" ]; then pos=$((pos + 1)); fi
        else
          tui_focus_cycle "$focus" "$TUI_ALLOW_BACK" 1; focus="$TUI_FOCUS"
        fi
        ;;
      HOME)
        if [ "$focus" = "content" ]; then pos=0; fi
        ;;
      END)
        if [ "$focus" = "content" ]; then pos=${#value}; fi
        ;;
      TAB) tui_focus_cycle "$focus" "$TUI_ALLOW_BACK" 1; focus="$TUI_FOCUS" ;;
      BACKTAB) tui_focus_cycle "$focus" "$TUI_ALLOW_BACK" -1; focus="$TUI_FOCUS" ;;
      ESC) tui_abort_confirm ;;
      EOF) tui_fatal "Terminal closed - setup cancelled." ;;
      *) ;;
    esac
  done
}

# --------------------------------------------------------------- buttons
# tui_buttons TITLE INTRO DEFAULT_INDEX LABEL [LABEL ...]
# Left/Right/Tab move the focus, Enter activates the focused button. With
# TUI_ALLOW_BACK=1 a < Back > button is added in front; activating it sets
# TUI_BACK. Result (chosen index) in TUI_RESULT.
tui_buttons() {
  TUI_RESULT=""; TUI_BACK=""
  local title="$1" intro="$2" def="$3"; shift 3
  local -a labels=("$@") disp=()
  local n=${#labels[@]}
  [ "$n" -gt 0 ] || tui_fatal "tui_buttons: no buttons"
  local off=0 total bsel
  if [ "$TUI_ALLOW_BACK" = "1" ]; then
    disp=("Back" "${labels[@]}")
    off=1
  else
    disp=("${labels[@]}")
  fi
  total=${#disp[@]}
  bsel=$((off + def))

  while :; do
    tui_dims
    tui_begin
    if [ -n "$intro" ]; then tui_add_wrapped "$intro"; fi
    tui_blank
    tui_row_buttons "$bsel" "${disp[@]}"
    tui_add_raw "$TUI_ROW"
    tui_blank
    tui_add_dim "  Left/Right move   Enter = confirm   Esc = quit"
    tui_flush "$title"

    tui_read_key
    case "$TUI_KEY" in
      LEFT|UP|BACKTAB) bsel=$(((bsel + total - 1) % total)) ;;
      RIGHT|DOWN|TAB) bsel=$(((bsel + 1) % total)) ;;
      ENTER)
        if [ "$off" -eq 1 ] && [ "$bsel" -eq 0 ]; then
          TUI_BACK="1"
          return 0
        fi
        TUI_RESULT=$((bsel - off))
        return 0
        ;;
      ESC) tui_abort_confirm ;;
      EOF) tui_fatal "Terminal closed - setup cancelled." ;;
      *) ;;
    esac
  done
}

# ------------------------------------------------------------ validators
tui_validate_port() {
  validate_port "$1" || printf 'Please enter a number between 1 and 65535.'
}

tui_validate_abs_path() {
  case "$1" in
    /*) : ;;
    *) printf 'The folder must be an absolute path (start with /).' ;;
  esac
}

tui_validate_not_empty() {
  [ -n "$1" ] || printf 'This field cannot be empty.'
}
