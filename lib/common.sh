#!/usr/bin/env bash
# Shared helpers for the Yellod installer. Sourced by install.sh.

set -euo pipefail

# ---------------------------------------------------------------- constants
REPO_OWNER="xyzyt010"
REPO_DOWNLOADER="yellod-downloader"
REPO_QUICSHARE="quicshare"
REPO_INSTALLER="yellod-installer"

GH_URL="https://github.com/${REPO_OWNER}"
INSTALL_ROOT="/opt/yellod"
LIB_DIR="/var/lib/yellod"

# ------------------------------------------------------------------ logging
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET="\033[0m"; C_INFO="\033[36m"; C_OK="\033[32m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_BOLD="\033[1m"
else
  C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_BOLD=""
fi

info()  { printf "${C_INFO}[info]${C_RESET} %s\n" "$*" >&2; }
ok()    { printf "${C_OK}[ ok ]${C_RESET} %s\n" "$*" >&2; }
warn()  { printf "${C_WARN}[warn]${C_RESET} %s\n" "$*" >&2; }
die()   { printf "${C_ERR}[fail]${C_RESET} %s\n" "$*" >&2; exit 1; }

# DRY_RUN support: run() executes a mutating command, or just prints it.
DRY_RUN="${DRY_RUN:-false}"
run() {
  if [ "$DRY_RUN" = "true" ]; then
    printf "${C_WARN}[dry-run]${C_RESET} %s\n" "$*" >&2
  else
    "$@"
  fi
}

# ---------------------------------------------------------------- detection
need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Please run as root:  curl -fsSL ${GH_URL}/${REPO_INSTALLER}/raw/main/install.sh | sudo bash"
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) die "Unsupported CPU architecture: $(uname -m) (supported: x86_64, aarch64)" ;;
  esac
}

detect_distro() {
  [ -r /etc/os-release ] || die "Cannot read /etc/os-release — unsupported OS"
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-unknown}"
  DISTRO_LIKE="${ID_LIKE:-}"
  DISTRO_PRETTY="${PRETTY_NAME:-$DISTRO_ID}"
  DISTRO_FAMILY=""
  case "$DISTRO_ID $DISTRO_LIKE" in
    *ubuntu*|*debian*) DISTRO_FAMILY="debian" ;;
    *fedora*|*rhel*)   DISTRO_FAMILY="redhat" ;;
    *arch*)            DISTRO_FAMILY="arch" ;;
    *gentoo*)          DISTRO_FAMILY="gentoo" ;;
  esac
  case "$DISTRO_FAMILY" in
    debian) : ;;
    redhat|arch|gentoo)
      die "Detected ${DISTRO_PRETTY}. This release supports Ubuntu/Debian (x86_64 & arm64) only. Fedora / Arch / Gentoo support is planned — please open an issue if you want it sooner." ;;
    *) die "Unsupported distribution: ${DISTRO_PRETTY}" ;;
  esac
}

have_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

# ---------------------------------------------------------------------- apt
APT_UPDATED=false
apt_update_once() {
  if [ "$APT_UPDATED" != "true" ]; then
    info "Updating apt package lists..."
    run apt-get update -qq
    APT_UPDATED=true
  fi
}

apt_install() {
  apt_update_once
  info "Installing packages: $*"
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
}

# ----------------------------------------------------------- release binary
# fetch_binary <repo> <asset> <dest_dir> <binary_name>
# Downloads https://github.com/<owner>/<repo>/releases/latest/download/<asset>
# verifies the .sha256 when available and extracts into dest_dir.
fetch_binary() {
  local repo="$1" asset="$2" dest="$3" bin="$4"
  local url="${GH_URL}/${repo}/releases/latest/download/${asset}"
  local tmp
  tmp="$(mktemp -d)"

  info "Downloading ${repo} (${asset})..."
  if ! curl -fL --retry 3 --connect-timeout 20 -o "$tmp/${asset}" "$url"; then
    rm -rf "$tmp"
    return 1
  fi

  if curl -fsL -o "$tmp/${asset}.sha256" "${url}.sha256" 2>/dev/null; then
    if (cd "$tmp" && sha256sum -c "${asset}.sha256" >/dev/null 2>&1); then
      ok "Checksum verified for ${asset}"
    else
      warn "Checksum verification failed for ${asset} — aborting"
      rm -rf "$tmp"
      return 1
    fi
  else
    warn "No checksum published for ${asset}, skipping verification"
  fi

  run mkdir -p "$dest"
  tar -xzf "$tmp/${asset}" -C "$tmp"
  [ -f "$tmp/${bin}" ] || { warn "Archive did not contain '${bin}'"; rm -rf "$tmp"; return 1; }
  run install -m 0755 "$tmp/${bin}" "$dest/${bin}"
  rm -rf "$tmp"
  ok "Installed ${bin} to ${dest}/${bin}"
}

# --------------------------------------------------------- build from source
build_from_source() {
  local repo="$1" bin="$2" dest="$3"
  warn "Falling back to building ${repo} from source (this takes a few minutes)..."

  command -v git >/dev/null 2>&1 || apt_install git
  if ! command -v cargo >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
    info "Installing Rust toolchain..."
    curl -fsSL https://sh.rustup.rs | run sh -s -- -y --profile minimal
  fi
  # shellcheck disable=SC1091
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

  local tmp
  tmp="$(mktemp -d)"
  run git clone --depth 1 "${GH_URL}/${repo}.git" "$tmp/src"
  ( cd "$tmp/src" && run cargo build --release )
  run install -m 0755 "$tmp/src/target/release/${bin}" "$dest/${bin}"
  rm -rf "$tmp"
  ok "Built and installed ${bin} from source"
}

# install_binary <repo> <asset> <dest_dir> <binary_name>
install_binary() {
  local repo="$1" asset="$2" dest="$3" bin="$4"
  if ! fetch_binary "$repo" "$asset" "$dest" "$bin"; then
    build_from_source "$repo" "$bin" "$dest"
  fi
}

# ---------------------------------------------------------------- systemd
render_unit() {
  # render_unit <template_file> <output_file> KEY=VALUE [KEY=VALUE ...]
  local template="$1" output="$2"; shift 2
  local content
  content="$(cat "$template")"
  local kv key value
  for kv in "$@"; do
    key="${kv%%=*}"
    value="${kv#*=}"
    content="${content//@@${key}@@/${value}}"
  done
  if ! printf '%s\n' "$content" | grep -q "@@"; then
    if [ "$DRY_RUN" = "true" ]; then
      printf "${C_WARN}[dry-run]${C_RESET} write systemd unit %s\n" "$output" >&2
    else
      printf '%s\n' "$content" > "$output"
    fi
  else
    warn "Unresolved placeholders in unit ${output}: $(printf '%s\n' "$content" | grep -o '@@[A-Z_]*@@' | sort -u | tr '\n' ' ')"
    return 1
  fi
}

# ---------------------------------------------------------------- misc
require_utility() {
  command -v "$1" >/dev/null 2>&1 || apt_install "$2"
}

app_selected() {
  case " ${APPS:-} " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

confirm_default_yes() {
  # used only in non-whiptail contexts; the wizard handles interactivity
  return 0
}

summary_line() {
  printf "  %-22s %s\n" "$1" "$2"
}
