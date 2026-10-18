#!/usr/bin/env bash
# Uninstall flow for the Yellod installer.

do_uninstall() {
  local unit
  for unit in yellod-downloader.service yellod-quicshare.service aria2.service; do
    if [ -e "/etc/systemd/system/${unit}" ]; then
      info "Stopping and removing ${unit}..."
      run systemctl disable --now "$unit" || true
      run rm -f "/etc/systemd/system/${unit}"
    fi
  done
  run systemctl daemon-reload
  run rm -rf "$INSTALL_ROOT"

  [ -n "${DATA_ROOT:-}" ] || DATA_ROOT="/srv/yellod"

  if [ "${PURGE_DATA:-false}" = "true" ]; then
    if [ "$FORCE_YES" != "true" ] && has_tty; then
      printf "Type DELETE to permanently erase %s: " "$DATA_ROOT" >/dev/tty
      local answer=""
      read -r answer < /dev/tty || true
      if [ "$answer" != "DELETE" ]; then
        die "Aborted - your data is kept at ${DATA_ROOT}"
      fi
    fi
    run rm -rf "$DATA_ROOT"
    ok "Data erased (${DATA_ROOT})."
  else
    info "Application removed. Your data is kept at: ${DATA_ROOT}"
    info "Re-run with --uninstall --purge-data to erase it too."
  fi

  if id -u "$SVC_USER" >/dev/null 2>&1; then
    info "Removing service user '${SVC_USER}'..."
    run userdel "$SVC_USER" || true
  fi

  ok "Uninstall complete."
}
