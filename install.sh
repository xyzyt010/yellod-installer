#!/usr/bin/env bash
# Yellod installer - one-command, step-by-step setup for the Yellod
# server apps (Yellod Downloader + QuicShare) on Ubuntu/Debian,
# x86_64 and arm64.
#
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/xyzyt010/yellod-installer/main/install.sh)"
#   curl -fsSL <same url> | sudo bash -s -- --yes     (non-interactive)
#
set -euo pipefail

GH_OWNER="xyzyt010"
INSTALLER_REPO="yellod-installer"
TARBALL_URL="https://github.com/${GH_OWNER}/${INSTALLER_REPO}/archive/refs/heads/main.tar.gz"

# --------------------------------------------------- locate our own files
SELF_DIR=""
_src="${BASH_SOURCE[0]:-}"
if [ -n "$_src" ] && [ -f "$_src" ]; then
  _dir="$(cd "$(dirname "$_src")" && pwd)"
  if [ -d "${_dir}/lib" ]; then
    SELF_DIR="$_dir"
  fi
fi

if [ -z "$SELF_DIR" ]; then
  # Running from a pipe (curl | bash): stdin is the script itself, so the
  # wizard cannot read the keyboard from it. Fetch the rest of the repo,
  # then re-exec with the terminal attached to stdin.
  if ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq && apt-get install -y -qq curl
    fi
  fi
  command -v curl >/dev/null 2>&1 || { echo "[fail] curl is required" >&2; exit 1; }
  command -v tar  >/dev/null 2>&1 || { echo "[fail] tar is required"  >&2; exit 1; }

  TMP_SELF="$(mktemp -d /tmp/yellod-installer.XXXXXX)"
  echo "[info] Fetching installer files..."
  curl -fsSL "$TARBALL_URL" | tar -xz -C "$TMP_SELF" --strip-components=1
  SELF_DIR="$TMP_SELF"
  export YELLOD_BOOTSTRAP_TMP="$TMP_SELF"

  RAW_URL="https://raw.githubusercontent.com/${GH_OWNER}/${INSTALLER_REPO}/main/install.sh"

  # Detect the one case where the wizard cannot receive your keyboard:
  # 'curl | sudo bash' on sudo >= 1.9.14 (use_pty default) gives the piped
  # command its own private terminal, so keystrokes never reach us.
  if [ -n "${SUDO_USER:-}" ] && [ ! -t 0 ]; then
    case " $* " in
      *" --yes "*|*" -y "*|*" --update "*|*" --uninstall "*)
        : # non-interactive mode: no keyboard needed, carry on
        ;;
      *)
        parent_comm="$(cat "/proc/${PPID}/comm" 2>/dev/null || true)"
        case "$parent_comm" in
          sudo*)
            our_tty="$(stat -L -c '%d:%i' /dev/tty 2>/dev/null || echo none)"
            parent_tty="$(stat -L -c "%d:%i" "/proc/${PPID}/fd/1" 2>/dev/null || echo other)"
            if [ "$our_tty" != "$parent_tty" ]; then
              echo
              echo "[warn] Your keyboard cannot reach the setup wizard this way:"
              echo "       'curl | sudo bash' runs the script on a private terminal"
              echo "       (sudo use_pty) so no keys get through."
              echo
              echo "       Run the same installer as a normal command instead:"
              echo
              echo "         sudo bash -c \"\$(curl -fsSL ${RAW_URL})\""
              echo
              echo "       or use the copy that was just downloaded for you:"
              echo
              echo "         sudo bash ${TMP_SELF}/install.sh"
              echo
              echo "       (Want a non-interactive install from a pipe? Add --yes.)"
              exit 1
            fi
            ;;
        esac
        ;;
    esac
  fi

  if [ -e /dev/tty ] && ( : < /dev/tty ) 2>/dev/null; then
    echo "[info] Attaching your terminal and starting the wizard..."
    exec bash "${SELF_DIR}/install.sh" "$@" < /dev/tty
  fi
fi

# Clean up the bootstrap copy when the re-exec'd installer exits.
if [ -n "${YELLOD_BOOTSTRAP_TMP:-}" ]; then
  trap 'rm -rf "$YELLOD_BOOTSTRAP_TMP"' EXIT
fi

# shellcheck source=lib/common.sh
. "${SELF_DIR}/lib/common.sh"
# shellcheck source=lib/tui.sh
. "${SELF_DIR}/lib/tui.sh"
# shellcheck source=lib/wizard.sh
. "${SELF_DIR}/lib/wizard.sh"
# shellcheck source=lib/apply.sh
. "${SELF_DIR}/lib/apply.sh"
# shellcheck source=lib/uninstall.sh
. "${SELF_DIR}/lib/uninstall.sh"

# ------------------------------------------------------------- defaults
ACTION="install"
APPS=""
DATA_ROOT=""
SVC_USER="yellod"
DL_PORT="5555"
QS_PORT="443"
DL_BIND_MODE="localhost"
QS_BIND_MODE="all"
QS_HOSTNAME=""
FORCE_YES="false"
PURGE_DATA="false"
TUNNEL_GUIDE="no"
PROXY_MODE="auto"
PROXY_MODE_EXPLICIT="false"
ARCH=""
ARCH_TAG=""
DL_BIND=""
QS_BIND=""

usage() {
  cat <<'EOF'
Yellod installer - portable setup for the Yellod server apps
(Yellod Downloader + QuicShare) on Ubuntu/Debian, x86_64 & arm64.

Usage:
  install.sh [options]

Examples:
  install.sh --yes
  install.sh --yes --apps downloader --data-dir /mnt/ssd/yellod
  install.sh --yes --apps downloader,quicshare --quicshare-port 8443

Options:
  --apps LIST           comma-separated: downloader,quicshare (default: ask)
  --data-dir PATH       where all data is stored (default: /srv/yellod)
  --user NAME           service user (default: yellod)
  --downloader-port N   downloader port (default: 5555, localhost)
  --download-bind ADDR 127.0.0.1 (default) or 0.0.0.0
  --quicshare-port N    QuicShare port (default: 443)
  --qs-bind ADDR        0.0.0.0 (default) or 127.0.0.1
  --hostname NAME       hostname for the QuicShare TLS certificate
  --proxy-mode MODE     auto (default: direct first, Tor fallback) | always | never
  --no-tor              same as --proxy-mode never (no Tor installed/used)
  --tunnel-guide        print the Cloudflare Tunnel guide after install
  --yes, -y             non-interactive (uses defaults / given options)
  --dry-run             show what would be done, change nothing
  --update              update installed apps to the latest release
  --uninstall           remove the apps (data kept unless --purge-data)
  --purge-data          with --uninstall: also erase the data folder
  -h, --help            this help

Without flags, a step-by-step wizard asks you what to install, which
SSD/HDD (or folder) stores your data, and which ports to use.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apps)            APPS="$(printf '%s' "${2:-}" | tr ',' ' ')"; shift 2 ;;
    --data-dir)        DATA_ROOT="${2:-}"; shift 2 ;;
    --user)            SVC_USER="${2:-}"; shift 2 ;;
    --downloader-port) DL_PORT="${2:-}"; shift 2 ;;
    --download-bind)   DL_BIND_MODE="${2:-}"; shift 2 ;;
    --quicshare-port)  QS_PORT="${2:-}"; shift 2 ;;
    --qs-bind)         QS_BIND_MODE="${2:-}"; shift 2 ;;
    --hostname)        QS_HOSTNAME="${2:-}"; shift 2 ;;
    --proxy-mode)      PROXY_MODE="${2:-}"; PROXY_MODE_EXPLICIT="true"; shift 2 ;;
    --no-tor)          PROXY_MODE="never"; PROXY_MODE_EXPLICIT="true"; shift ;;
    --tunnel-guide)    TUNNEL_GUIDE="yes"; shift ;;
    --yes|-y)          FORCE_YES="true"; shift ;;
    --dry-run)         DRY_RUN="true"; shift ;;
    --update)          ACTION="update"; shift ;;
    --uninstall)       ACTION="uninstall"; shift ;;
    --purge-data)      PURGE_DATA="true"; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

set_binds_from_modes() {
  case "$DL_BIND_MODE" in
    localhost|127.0.0.1|local) DL_BIND="127.0.0.1:${DL_PORT}" ;;
    *)                         DL_BIND="0.0.0.0:${DL_PORT}" ;;
  esac
  case "$QS_BIND_MODE" in
    localhost|127.0.0.1|local) QS_BIND="127.0.0.1:${QS_PORT}" ;;
    *)                         QS_BIND="0.0.0.0:${QS_PORT}" ;;
  esac
  [ -n "$QS_HOSTNAME" ] || QS_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
}

validate_options() {
  validate_port "$DL_PORT" || die "Invalid --downloader-port: ${DL_PORT}"
  validate_port "$QS_PORT" || die "Invalid --quicshare-port: ${QS_PORT}"
  case "$DATA_ROOT" in
    ""|/*) : ;;
    *) die "--data-dir must be an absolute path (got: ${DATA_ROOT})" ;;
  esac
  case "$PROXY_MODE" in
    auto|always|never|on|off|tor|direct|none) : ;;
    *) die "Invalid --proxy-mode: ${PROXY_MODE} (auto|always|never)" ;;
  esac
}

main() {
  need_root
  detect_distro
  ARCH="$(detect_arch)"
  ARCH_TAG="linux-${ARCH}"
  export ARCH ARCH_TAG

  have_systemd || die "This installer requires systemd (not found)."

  case "$ACTION" in
    uninstall) do_uninstall; exit 0 ;;
    update)    do_update;    exit 0 ;;
  esac

  validate_options

  if [ -z "$APPS" ]; then
    if [ "$FORCE_YES" = "true" ]; then
      APPS="downloader quicshare"
      info "Non-interactive mode: installing both apps with defaults."
    elif has_tty; then
      wiz_run
    else
      die "No terminal available for the wizard. Re-run with --yes (non-interactive) or from an interactive terminal."
    fi
  fi

  # Normalize / validate the app list.
  local a normalized=""
  for a in $APPS; do
    case "$a" in
      downloader) normalized="${normalized} downloader" ;;
      quicshare)  normalized="${normalized} quicshare" ;;
      *) die "Unknown app: ${a} (allowed: downloader,quicshare)" ;;
    esac
  done
  APPS="${normalized# }"
  [ -n "$APPS" ] || die "No apps selected."

  [ -n "$DATA_ROOT" ] || DATA_ROOT="/srv/yellod"
  set_binds_from_modes

  do_install
}

main "$@"
