#!/usr/bin/env bash
_CS_DEFAULT_URL="https://raw.githubusercontent.com/SystemIdleProcess/proxmox-scripts/main/community-scripts"
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")

# Copyright (c) 2026 SystemIdleProcess
# Author: SystemIdleProcess
# Framework license: MIT | https://github.com/community-scripts/core/blob/main/LICENSE
# Source: https://github.com/openclaw/openclaw

APP="OpenClaw"
var_tags="${var_tags:-ai;gateway}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-24}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -x /usr/local/bin/openclaw || ! -f /etc/systemd/system/openclaw.service ]]; then
    msg_error "No ${APP} Installation Found!"
    exit 1
  fi

  local installed latest npm_version
  local -a npm_options=(--global --prefix /usr/local --engine-strict)
  installed=$(node -p 'require("/usr/local/lib/node_modules/openclaw/package.json").version')
  latest=$(npm view openclaw@latest version)
  if [[ "$latest" == "$installed" ]]; then
    msg_ok "OpenClaw is already at the current stable version"
    exit 0
  fi
  if [[ "$(printf '%s\n' "$installed" "$latest" | sort -V | tail -n 1)" != "$latest" ]]; then
    msg_error "Installed version $installed is newer than stable $latest"
    exit 1
  fi

  NODE_VERSION="24" setup_nodejs
  npm_version=$(npm --version)
  if [[ "$(printf '%s\n' 11.16.0 "$npm_version" | sort -V | head -n 1)" == 11.16.0 ]]; then
    npm_options+=(--dangerously-allow-all-scripts=false --allow-scripts=openclaw)
  fi

  msg_info "Updating OpenClaw to $latest"
  $STD npm install "${npm_options[@]}" "openclaw@$latest"
  systemctl try-restart openclaw
  msg_ok "Updated OpenClaw to $latest"
  exit 0
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${INFO}${YW}OpenClaw is installed. Complete these steps in the LXC console as root:${CL}"
echo -e "1. Switch to the OpenClaw user: ${BGN}runuser --login --shell /bin/bash openclaw${CL}"
echo -e "2. Run onboarding: ${BGN}/usr/local/bin/openclaw onboard --no-install-daemon${CL}"
echo "   Choose Local to host the gateway in this LXC."
echo -e "3. Type ${BGN}exit${CL} to return to root, then run: ${BGN}systemctl enable --now openclaw${CL}"
