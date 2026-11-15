#!/usr/bin/env bash
# Personal installer; uses the official community-scripts engine (MIT).
# Source: https://github.com/samanhappy/mcphub
export COMMUNITY_SCRIPTS_URL="${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/SystemIdleProcess/proxmox-scripts/main/community-scripts}"
export COMMUNITY_SCRIPTS_CORE_URL="${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/4f6c2bd4dfadce266dca9ec737e8382728d753e3}"
# A custom slug prevents official app advisories from targeting this installer.
export SCRIPT_SLUG="systemidle-mcphub"
_cs_boot=$(mktemp) || exit 1
if ! curl -fsSL --connect-timeout 10 --max-time 60 "${COMMUNITY_SCRIPTS_CORE_URL}/core/build.func" -o "$_cs_boot"; then
  rm -f "$_cs_boot"
  exit 1
fi
# shellcheck disable=SC1090
source "$_cs_boot"
rm -f "$_cs_boot"

APP="MCPHub"
var_tags="${var_tags:-ai;mcp;gateway}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-16}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_arm64="${var_arm64:-yes}"
var_unprivileged="${var_unprivileged:-1}"
header_info "$APP"
variables
color
catch_errors

update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -x /opt/mcphub/manage.sh ]]; then
    msg_error "No managed MCPHub installation found in /opt/mcphub"
    exit 1
  fi
  # Use the installed manager, so a routine app update never silently replaces
  # locally reviewed management code. Script changes can be applied separately.
  /opt/mcphub/manage.sh update
  exit
}

start
build_container
description
msg_ok "MCPHub setup completed"
echo "Dashboard: http://${IP}:3000"
echo "Initial admin password: /opt/mcphub/.env inside the LXC (ADMIN_PASSWORD)."
echo "MCP clients: create a bearer key in the dashboard, then connect to /mcp."
