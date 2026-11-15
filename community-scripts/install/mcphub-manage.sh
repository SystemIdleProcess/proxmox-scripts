#!/usr/bin/env bash
# Installed as /opt/mcphub/manage.sh. App data and secrets never enter Git.
set -Eeuo pipefail
umask 077
APP_DIR=/opt/mcphub
BACKUP_DIR=/var/backups/mcphub
PACKAGE=@samanhappy/mcphub

wait_ready() {
  local attempt
  for ((attempt=0; attempt<60; attempt++)); do
    if systemctl is-active --quiet mcphub &&
       curl -fsS --connect-timeout 2 --max-time 3 http://127.0.0.1:3000/health >/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "MCPHub did not become healthy; inspect journalctl -u mcphub locally." >&2
  return 1
}

resolve_version() {
  local version="$1"
  if [[ "$version" == latest ]]; then
    version=$(npm view "$PACKAGE" version) || return $?
  fi
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Expected a stable npm version such as 1.2.4, or latest" >&2
    return 1
  fi
  printf '%s\n' "$version"
}

install_release() (
  # This contains public package files only. Persistent secrets stay outside it.
  umask 022
  local version="$1" release
  release=$(mktemp -d "$APP_DIR/releases/${version}-XXXXXXXX") || return $?
  chmod 755 "$release" || return $?
  npm install --prefix "$release" --omit=dev --no-audit --no-fund "$PACKAGE@$version" >&2 || return $?
  node - "$release/node_modules/$PACKAGE" "$version" <<'JS' || return $?
const fs = require('fs');
const dir = process.argv[2];
const pkg = JSON.parse(fs.readFileSync(`${dir}/package.json`, 'utf8'));
if (pkg.name !== '@samanhappy/mcphub' || pkg.version !== process.argv[3]) process.exit(1);
for (const file of ['dist/index.js', 'frontend/dist/index.html']) fs.accessSync(`${dir}/${file}`);
JS
  printf '%s\n' "$version" >"$release/version" || return $?
  printf '%s\n' "$release"
)

select_release() {
  ln -s "$1" "$APP_DIR/current.next" || return $?
  mv -Tf "$APP_DIR/current.next" "$APP_DIR/current"
}

update_app() (
  # A stopped snapshot protects against settings migrations during startup.
  local target="$1" old version release backup stage changed=0 stopped=0
  old=$(readlink -f "$APP_DIR/current")
  [[ -f "$old/version" ]] || { echo "Current release is invalid" >&2; exit 1; }
  version=$(resolve_version "$target")
  if [[ "$version" == "$(cat "$old/version")" ]]; then
    echo "MCPHub $version is already selected; checking health."
    wait_ready
    exit
  fi
  # Download and validate the new release before any service interruption.
  release=$(install_release "$version")
  install -d -m 700 "$BACKUP_DIR"
  backup=$(mktemp "$BACKUP_DIR/pre-update-XXXXXXXX.tar.gz")
  stage=$(mktemp -d "$APP_DIR/.rollback-XXXXXXXX")
  # shellcheck disable=SC2329 # Invoked by the EXIT trap.
  recover() {
    local rc=$?
    trap - EXIT
    if ((rc != 0 && stopped)); then
      echo "Update failed; restoring the previous MCPHub deployment." >&2
      if ((changed)); then
        if ! systemctl stop mcphub || ! tar -xzf "$backup" -C "$stage"; then
          echo "Automatic recovery failed. Preserve $backup for manual recovery." >&2
          exit 1
        fi
        if ! mv "$APP_DIR/data" "$stage/failed-data" ||
           ! mv "$APP_DIR/home" "$stage/failed-home" ||
           ! mv "$stage/data" "$APP_DIR/data" ||
           ! mv "$stage/home" "$APP_DIR/home" ||
           ! select_release "$old"; then
          echo "Automatic recovery failed. Preserve $stage and $backup." >&2
          exit 1
        fi
      fi
      if ! systemctl start mcphub || ! wait_ready; then
        echo "Previous deployment did not recover. Backup: $backup" >&2
        exit 1
      fi
      echo "Previous release and data restored. Backup: $backup" >&2
    fi
    # Staging can hold failed data; retain it whenever replacement was tried.
    if ((changed == 0)); then rmdir "$stage"; fi
    exit "$rc"
  }
  trap recover EXIT
  stopped=1
  systemctl stop mcphub
  tar -czf "$backup" -C "$APP_DIR" data home .env current manage.sh
  tar -tzf "$backup" >/dev/null
  select_release "$release"
  changed=1
  systemctl start mcphub
  wait_ready
  stopped=0
  rmdir "$stage"
  echo "MCPHub updated to $version. Previous release: $old"
  echo "Recovery snapshot: $backup"
)

main() {
  [[ $EUID -eq 0 ]] || { echo "Run as root inside the MCPHub LXC." >&2; return 1; }
  [[ -d "$APP_DIR/releases" && -f "$APP_DIR/.env" ]] || {
    echo "No managed MCPHub installation in $APP_DIR" >&2
    return 1
  }
  exec 9>"$APP_DIR/.manage.lock"
  flock -n 9 || { echo "Another MCPHub management operation is running." >&2; return 1; }
  case "${1:-}" in
    install)
      [[ ! -e "$APP_DIR/current" && ! -L "$APP_DIR/current" ]] || {
        echo "MCPHub is already installed; use update." >&2; return 1;
      }
      local version release
      version=$(resolve_version "${2:-1.2.4}")
      release=$(install_release "$version")
      select_release "$release"
      systemctl enable --now mcphub
      wait_ready
      ;;
    update) update_app "${2:-latest}" ;;
    *) echo "Usage: $0 install [version] | update [version|latest]" >&2; return 2 ;;
  esac
}

# Sourceable by the offline transaction tests; executing always calls main.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
