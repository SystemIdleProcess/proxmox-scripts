#!/usr/bin/env bash
_CS_DEFAULT_URL="https://raw.githubusercontent.com/SystemIdleProcess/proxmox-scripts/main/community-scripts"
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")

# Copyright (c) 2026 SystemIdleProcess
# Author: SystemIdleProcess
# Framework license: MIT | https://github.com/community-scripts/core/blob/main/LICENSE
# Source: https://github.com/samanhappy/mcphub

APP="MCPHub"
var_tags="${var_tags:-ai;mcp;gateway}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-24}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
#var_arm64="${var_arm64:-no}" # Native dependencies have not been verified on arm64.
var_unprivileged="${var_unprivileged:-1}"

export var_mcphub_storage="${var_mcphub_storage:-}"
export var_mcphub_pgvector="${var_mcphub_pgvector:-}"

header_info "$APP"
variables
color
catch_errors

case "$(detect_lxc_platform)" in
pve | incus)
  if [[ -z "$var_mcphub_storage" ]]; then
    var_mcphub_storage=$(prompt_select "MCPHub storage (file-based or local PostgreSQL):" 1 30 "file" "postgresql")
  fi
  var_mcphub_storage="${var_mcphub_storage,,}"
  case "$var_mcphub_storage" in
  file | postgresql) ;;
  *)
    msg_error "var_mcphub_storage must be file or postgresql"
    exit 64
    ;;
  esac
  if [[ "$var_mcphub_storage" == postgresql && -z "$var_mcphub_pgvector" ]]; then
    if prompt_confirm "Install pgvector for optional Smart Routing? An embedding provider is still required." "n" 30; then
      var_mcphub_pgvector=yes
    else
      var_mcphub_pgvector=no
    fi
  fi
  var_mcphub_pgvector="${var_mcphub_pgvector:-no}"
  var_mcphub_pgvector="${var_mcphub_pgvector,,}"
  case "$var_mcphub_pgvector" in
  yes | no) ;;
  *)
    msg_error "var_mcphub_pgvector must be yes or no"
    exit 64
    ;;
  esac
  if [[ "$var_mcphub_storage" == file && "$var_mcphub_pgvector" == yes ]]; then
    msg_error "pgvector requires var_mcphub_storage=postgresql"
    exit 64
  fi
  ;;
esac

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -f /opt/mcphub/package.json || ! -f /etc/systemd/system/mcphub.service ]]; then
    msg_error "No ${APP} Installation Found!"
    exit 1
  fi

  if check_for_gh_release "mcphub" "samanhappy/mcphub"; then
    NODE_VERSION="22" NODE_MODULE="pnpm@10.12.4" setup_nodejs

    msg_info "Stopping MCPHub"
    systemctl stop mcphub
    msg_ok "Stopped MCPHub"

    create_backup /opt/mcphub/.env
    CLEAN_INSTALL=1 CLEAN_INSTALL_KEEP="data home" fetch_and_deploy_gh_release "mcphub" "samanhappy/mcphub" "tarball" "$CHECK_UPDATE_RELEASE"
    restore_backup

    msg_info "Building MCPHub"
    cd /opt/mcphub || exit 1
    $STD pnpm install --frozen-lockfile
    $STD npm pkg set "version=${CHECK_UPDATE_RELEASE#v}"
    $STD pnpm build
    msg_ok "Built MCPHub"

    msg_info "Starting MCPHub"
    systemctl start mcphub
    msg_ok "Started MCPHub"
    msg_ok "Updated successfully!"
  fi
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:3000${CL}"
echo -e "${INFO}${YW}Initial admin password: /opt/mcphub/.env (ADMIN_PASSWORD)${CL}"
