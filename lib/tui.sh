#!/usr/bin/env bash
# Lightweight terminal wizard widgets for the Yellod installer.
#
# Why not whiptail/dialog: their key bindings are fixed (Space toggles,
# Enter submits) and vary between machines. These widgets give one
# consistent, predictable keyboard model everywhere:
#
#   Up/Down      move the highlight
#   Enter/Space  select or deselect the highlighted option (checklists)
#   a            select all / none (checklists)
#   Tab          jump to the green "Continue" row
#   Enter        on the Continue row: go to the next step
#   Esc          quit (asks for confirmation first)
#
# The page is drawn on the controlling terminal (/dev/tty, fd 8) and the
# result is printed on stdout, so pages also work when the installer
# itself arrived on stdin (curl ... | bash re-attaches the terminal).

TUI_ROWS=24
TUI_COLS=80
TUI_U8="false"
TUI_OPENED="false"
TUI_STTY_SAVED=""
TUI_FLASH=""
TUI_KEY=""
TUI_CHAR=""
TUI_PREV_EXIT_CMD=""

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
    trap 'tui_close; if [ -n "$TUI_PREV_EXIT_CMD" ]; then eval "$TUI_PREV_EXIT_CMD"; TUI_PREV_EXIT_CMD=""; fi' EXIT
    trap 'tui_close; printf "\n[info] Setup cancelled.\n" >&2; exit 130' INT TERM HUP
    printf '\033[?25l' >&8
  fi
  tui_colors
  tui_size
}

tui_close() {
  if [ "$TUI_OPENED" = "true" ]; then
    stty "$TUI_STTY_SAVED" <&8 2>/dev/null || true
    printf '\033[?25h' >&8 2>/dev/null || true
    printf '\n' >&8 2>/dev/null || true
    exec 8>&- 2>/dev/null || true
    TUI_OPENED="false"
  fi
  return 0
}

tui_colors() {
  local loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  case "$loc" in
    *UTF-8*|*utf8*|*UTF8*) TUI_U8="true" ;;
  esac
  if [ -z "${NO_COLOR:-}" ]; then
    TUI_C_RESET=$'\033[0m'
    TUI_C_BOLD=$'\033[1m'
    TUI_C_DIM=$'\033[2m'
    TUI_C_REV=$'\033[7m'
    TUI_C_CYAN=$'\033[36m'
    TUI_C_GREEN=$'\033[32m'
    TUI_C_YELLOW=$'\033[33m'
    TUI_C_RED=$'\033[31m'
  else
    TUI_C_RESET=""; TUI_C_BOLD=""; TUI_C_DIM=""; TUI_C_REV=""
    TUI_C_CYAN=""; TUI_C_GREEN=""; TUI_C_YELLOW=""; TUI_C_RED=""
  fi
}

tui_size() {
  local sz
  sz="$(stty size <&8 2>/dev/null || true)"
  TUI_ROWS="${sz%% *}"
  TUI_COLS="${sz##* }"
  case "$TUI_ROWS" in ''|*[!0-9]*) TUI_ROWS=24 ;; esac
  case "$TUI_COLS" in ''|*[!0-9]*) TUI_COLS=80 ;; esac
  [ "$TUI_ROWS" -lt 10 ] && TUI_ROWS=10
  [ "$TUI_COLS" -lt 30 ] && TUI_COLS=30
  [ "$TUI_COLS" -gt 100 ] && TUI_COLS=100
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

# ---------------------------------------------------------------- drawing
TUI_BUF=""
tui_begin() { TUI_BUF=""; }
tui_add()   { TUI_BUF="${TUI_BUF}${1}"$'\n'; }
tui_blank() { TUI_BUF="${TUI_BUF}"$'\n'; }
tui_flush() { printf '\033[H%s\033[J' "$TUI_BUF" >&8; }

tui_rule() {
  local w=$((TUI_COLS - 2)) ch="-"
  [ "$w" -lt 10 ] && w=10
  [ "$TUI_U8" = "true" ] && ch="─"
  local line
  line="$(printf -- "${ch}%.0s" $(seq 1 "$w"))"
  tui_add "${TUI_C_DIM}${line}${TUI_C_RESET}"
}

tui_header() {
  tui_add "${TUI_C_BOLD}${TUI_C_CYAN}${1}${TUI_C_RESET}"
  tui_rule
}

tui_add_wrapped() {
  local -a lines=()
  mapfile -t lines < <(printf '%s\n' "$1" | fold -s -w "$((TUI_COLS - 4))")
  local l
  for l in "${lines[@]}"; do
    if [ -z "$l" ]; then tui_blank; else tui_add "  ${l}"; fi
  done
}

tui_hint() { tui_add "${TUI_C_DIM}  ${1}${TUI_C_RESET}"; }

tui_flash_line() {
  if [ -n "$TUI_FLASH" ]; then
    tui_add "${TUI_C_RED}  ${TUI_FLASH}${TUI_C_RESET}"
  fi
}

# Quit confirmation (Esc anywhere). "Yes" quits the whole installer.
tui_abort_confirm() {
  local sel=0
  while :; do
    tui_size
    tui_begin
    tui_header "Quit the setup?"
    tui_blank
    tui_add "  Stop the Yellod setup wizard?"
    tui_blank
    tui_buttons_row "$sel" "No, keep going" "Yes, quit setup"
    tui_blank
    tui_rule
    tui_hint "Left/Right choose   Enter = confirm"
    tui_flush
    tui_read_key
    case "$TUI_KEY" in
      LEFT|RIGHT|TAB|UP|DOWN) sel=$((1 - sel)) ;;
      ENTER|SPACE)
        if [ "$sel" -eq 1 ]; then die "Setup cancelled."; else return 0; fi
        ;;
      ESC) return 0 ;;
      EOF) die "Terminal closed - setup cancelled." ;;
      *) ;;
    esac
  done
}

tui_buttons_row() {
  local sel="$1"; shift
  local -a labels=("$@")
  local row="  " i
  for i in "${!labels[@]}"; do
    if [ "$i" -eq "$sel" ]; then
      row+="${TUI_C_REV}${TUI_C_BOLD} [ ${labels[$i]} ] ${TUI_C_RESET} "
    else
      row+="  [ ${labels[$i]} ]  "
    fi
  done
  row="${row:0:$((TUI_COLS + 20))}"
  tui_add "$row"
}

# ----------------------------------------------------------------- pager
tui_text_page() { # title body
  local title="$1" body="$2" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/yellod-tui.XXXXXX")"
  printf '%s\n' "$body" > "$tmp"
  tui_pager "$title" "$tmp"
  rm -f "$tmp"
}

tui_pager() { # title file
  local title="$1" file="$2"
  local -a content=()
  mapfile -t content < "$file" 2>/dev/null || true
  local total="${#content[@]}" offset=0 page maxoff i tui_hint_string
  while :; do
    tui_size
    page=$((TUI_ROWS - 7))
    [ "$page" -lt 3 ] && page=3
    maxoff=$((total - page))
    [ "$maxoff" -lt 0 ] && maxoff=0
    [ "$offset" -gt "$maxoff" ] && offset="$maxoff"

    tui_begin
    tui_header "$title"
    tui_blank
    for ((i = offset; i < offset + page && i < total; i++)); do
      tui_add "  ${content[$i]}"
    done
    tui_blank
    if [ "$offset" -gt 0 ] || [ "$offset" -lt "$maxoff" ]; then
      tui_hint_string=""
      [ "$offset" -gt 0 ] && tui_hint_string="^ more above"
      [ "$offset" -lt "$maxoff" ] && tui_hint_string="${tui_hint_string:+$tui_hint_string   }v more below"
      tui_add "${TUI_C_YELLOW}  ${tui_hint_string}${TUI_C_RESET}"
    fi
    tui_rule
    tui_hint "Up/Down scroll   PgUp/PgDn   Enter = continue   Esc = quit"
    tui_flush

    tui_read_key
    case "$TUI_KEY" in
      UP) offset=$((offset - 1)); [ "$offset" -lt 0 ] && offset=0 ;;
      DOWN) offset=$((offset + 1)); [ "$offset" -gt "$maxoff" ] && offset="$maxoff" ;;
      PGUP) offset=$((offset - page)); [ "$offset" -lt 0 ] && offset=0 ;;
      PGDN) offset=$((offset + page)); [ "$offset" -gt "$maxoff" ] && offset="$maxoff" ;;
      ENTER|TAB|SPACE|RIGHT) return 0 ;;
      ESC) tui_abort_confirm ;;
      EOF) die "Terminal closed - setup cancelled." ;;
      *) ;;
    esac
  done
}

# ------------------------------------------------------------- checklist
# tui_checklist TITLE INTRO DEFAULT_TAGS TAG DESC [TAG DESC ...]
# Up/Down move, Enter/Space toggles the highlighted option, Tab jumps to
# the Continue row; Enter there goes on. Prints the chosen tags.
tui_checklist() {
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
  [ "$n" -gt 0 ] || die "tui_checklist: no options"
  local idx=0 cont="$n" i
  for i in "${!tags[@]}"; do
    case " ${default_csv//,/ } " in
      *" ${tags[$i]} "*) checked[i]=1 ;;
      *)                 checked[i]=0 ;;
    esac
  done

  local mark pt plain sel_list sel_count
  while :; do
    tui_size
    tui_begin
    tui_header "$title"
    [ -n "$intro" ] && tui_add_wrapped "$intro"
    tui_blank
    for i in "${!tags[@]}"; do
      [ "${checked[$i]}" = "1" ] && mark="[x]" || mark="[ ]"
      [ "$idx" -eq "$i" ] && pt=">" || pt=" "
      if [ -n "${labels[$i]}" ]; then
        plain="$(printf '%s %s %-12s %s' "$pt" "$mark" "${labels[$i]}" "${descs[$i]}")"
      else
        plain="$(printf '%s %s %s' "$pt" "$mark" "${descs[$i]}")"
      fi
      plain="${plain:0:$((TUI_COLS - 1))}"
      if [ "$idx" -eq "$i" ]; then
        tui_add "${TUI_C_REV}${plain}${TUI_C_RESET}"
      else
        tui_add "$plain"
      fi
    done
    sel_list=""
    sel_count=0
    for i in "${!tags[@]}"; do
      if [ "${checked[$i]}" = "1" ]; then sel_list+="${tags[$i]} "; sel_count=$((sel_count + 1)); fi
    done
    sel_list="${sel_list% }"
    [ -n "$sel_list" ] || sel_list="nothing selected yet"
    [ "$idx" -eq "$cont" ] && pt=">" || pt=" "
    plain="$(printf '%s Continue ->   (%s)' "$pt" "$sel_list")"
    plain="${plain:0:$((TUI_COLS - 1))}"
    if [ "$idx" -eq "$cont" ]; then
      tui_add "${TUI_C_REV}${TUI_C_BOLD}${plain}${TUI_C_RESET}"
    else
      tui_add "${TUI_C_GREEN}${plain}${TUI_C_RESET}"
    fi
    tui_blank
    tui_flash_line
    tui_rule
    tui_hint "Enter/Space = select   a = all/none   Tab = Continue   Esc = quit"
    tui_flush

    tui_read_key
    TUI_FLASH=""
    case "$TUI_KEY" in
      UP) idx=$((idx - 1)); [ "$idx" -lt 0 ] && idx="$cont" ;;
      DOWN) idx=$((idx + 1)); [ "$idx" -gt "$cont" ] && idx=0 ;;
      TAB) idx="$cont" ;;
      ENTER|SPACE)
        if [ "$idx" -eq "$cont" ]; then
          if [ "$sel_count" -gt 0 ]; then
            printf '%s\n' "$sel_list"
            return 0
          fi
          TUI_FLASH="Select at least one option (Enter or Space), then continue."
        else
          if [ "${checked[$idx]}" = "1" ]; then checked[idx]=0; else checked[idx]=1; fi
        fi
        ;;
      CHAR)
        if [ "$TUI_CHAR" = "a" ] || [ "$TUI_CHAR" = "A" ]; then
          local all=1
          for i in "${!tags[@]}"; do [ "${checked[$i]}" = "1" ] || all=0; done
          for i in "${!tags[@]}"; do
            if [ "$all" -eq 1 ]; then checked[i]=0; else checked[i]=1; fi
          done
        fi
        ;;
      ESC) tui_abort_confirm ;;
      EOF) die "Terminal closed - setup cancelled." ;;
      *) ;;
    esac
  done
}

# ------------------------------------------------------------- radiolist
# tui_radiolist TITLE INTRO DEFAULT_TAG TAG DESC [TAG DESC ...]
# Up/Down move the selection (it follows the highlight); Enter chooses and
# continues. Prints the chosen tag.
tui_radiolist() {
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
  [ "$n" -gt 0 ] || die "tui_radiolist: no options"
  local idx=0 i
  for i in "${!tags[@]}"; do
    [ "${tags[$i]}" = "$default_tag" ] && idx="$i"
  done

  local mark pt plain
  while :; do
    tui_size
    tui_begin
    tui_header "$title"
    [ -n "$intro" ] && tui_add_wrapped "$intro"
    tui_blank
    for i in "${!tags[@]}"; do
      [ "$i" -eq "$idx" ] && mark="(o)" || mark="( )"
      [ "$i" -eq "$idx" ] && pt=">" || pt=" "
      if [ -n "${labels[$i]}" ]; then
        plain="$(printf '%s %s %-12s %s' "$pt" "$mark" "${labels[$i]}" "${descs[$i]}")"
      else
        plain="$(printf '%s %s %s' "$pt" "$mark" "${descs[$i]}")"
      fi
      plain="${plain:0:$((TUI_COLS - 1))}"
      if [ "$i" -eq "$idx" ]; then
        tui_add "${TUI_C_REV}${plain}${TUI_C_RESET}"
      else
        tui_add "$plain"
      fi
    done
    tui_blank
    tui_rule
    tui_hint "Up/Down move (the highlighted choice is selected)   Enter = continue   Esc = quit"
    tui_flush

    tui_read_key
    case "$TUI_KEY" in
      UP|LEFT) idx=$(((idx + n - 1) % n)) ;;
      DOWN|RIGHT) idx=$(((idx + 1) % n)) ;;
      ENTER|SPACE|TAB) printf '%s\n' "${tags[$idx]}"; return 0 ;;
      ESC) tui_abort_confirm ;;
      EOF) die "Terminal closed - setup cancelled." ;;
      *) ;;
    esac
  done
}

# ------------------------------------------------------------ input box
# tui_input TITLE INTRO DEFAULT [VALIDATOR]
# VALIDATOR is a function name; it prints an error message when the value
# is not acceptable (or nothing when it is fine).
tui_input() {
  local title="$1" intro="$2" value="$3" validator="${4:-}"
  local pos=${#value} before at after err
  while :; do
    tui_size
    tui_begin
    tui_header "$title"
    [ -n "$intro" ] && tui_add_wrapped "$intro"
    tui_blank
    before="${value:0:pos}"
    at="${value:pos:1}"
    [ -n "$at" ] || at=" "
    after="${value:pos+1}"
    tui_add "  ${before}${TUI_C_REV}${at}${TUI_C_RESET}${after}"
    tui_blank
    tui_flash_line
    tui_rule
    tui_hint "Type the value   Enter = confirm   Esc = quit"
    tui_flush
    TUI_FLASH=""

    tui_read_key
    case "$TUI_KEY" in
      ENTER)
        err=""
        if [ -n "$validator" ]; then
          err="$("$validator" "$value" 2>/dev/null || true)"
        fi
        if [ -n "$err" ]; then
          TUI_FLASH="$err"
        else
          printf '%s\n' "$value"
          return 0
        fi
        ;;
      CHAR) value="${value:0:pos}${TUI_CHAR}${value:pos}"; pos=$((pos + 1)) ;;
      SPACE) value="${value:0:pos} ${value:pos}"; pos=$((pos + 1)) ;;
      BACKSPACE)
        if [ "$pos" -gt 0 ]; then
          value="${value:0:pos-1}${value:pos}"
          pos=$((pos - 1))
        fi
        ;;
      CLEAR) value=""; pos=0 ;;
      LEFT) [ "$pos" -gt 0 ] && pos=$((pos - 1)) ;;
      RIGHT) [ "$pos" -lt "${#value}" ] && pos=$((pos + 1)) ;;
      HOME) pos=0 ;;
      END) pos=${#value} ;;
      ESC) tui_abort_confirm ;;
      EOF) die "Terminal closed - setup cancelled." ;;
      *) ;;
    esac
  done
}

# --------------------------------------------------------------- buttons
# tui_buttons TITLE INTRO DEFAULT_INDEX LABEL [LABEL ...]
# Left/Right/Tab move, Enter confirms. Prints the chosen index.
tui_buttons() {
  local title="$1" intro="$2" def="$3"; shift 3
  local -a labels=("$@")
  local n=${#labels[@]}
  [ "$n" -gt 0 ] || die "tui_buttons: no buttons"
  local sel="$def"
  while :; do
    tui_size
    tui_begin
    tui_header "$title"
    [ -n "$intro" ] && tui_add_wrapped "$intro"
    tui_blank
    tui_buttons_row "$sel" "${labels[@]}"
    tui_blank
    tui_rule
    tui_hint "Left/Right choose   Enter = confirm   Esc = quit"
    tui_flush

    tui_read_key
    case "$TUI_KEY" in
      LEFT|UP) sel=$(((sel + n - 1) % n)) ;;
      RIGHT|DOWN|TAB) sel=$(((sel + 1) % n)) ;;
      ENTER|SPACE) printf '%s\n' "$sel"; return 0 ;;
      ESC) tui_abort_confirm ;;
      EOF) die "Terminal closed - setup cancelled." ;;
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
