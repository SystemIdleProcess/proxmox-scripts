#!/usr/bin/env bash

# Copyright (c) 2026 SystemIdleProcess
# Author: SystemIdleProcess
# Framework license: MIT | https://github.com/community-scripts/core/blob/main/LICENSE
# Source: https://github.com/samanhappy/mcphub

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y \
  build-essential \
  git \
  procps \
  python3
msg_ok "Installed Dependencies"

NODE_VERSION="22" NODE_MODULE="pnpm@10.12.4" setup_nodejs
USE_UVX=YES setup_uv

release="${var_appversion:-$(get_latest_github_release "samanhappy/mcphub")}"
fetch_and_deploy_gh_release "mcphub" "samanhappy/mcphub" "tarball" "$release"

msg_info "Building MCPHub"
cd /opt/mcphub || exit 1
$STD pnpm install --frozen-lockfile
$STD npm pkg set "version=${release#v}"
$STD pnpm build
msg_ok "Built MCPHub"

msg_info "Configuring MCPHub"
install -d -m 700 /opt/mcphub/data /opt/mcphub/home
cat <<EOF >/opt/mcphub/.env
ADMIN_PASSWORD=$(random_password 20)
JWT_SECRET=$(openssl rand -hex 32)
MCPHUB_CREDENTIAL_ENCRYPTION_KEY=$(openssl rand -base64 32)
EOF
chmod 600 /opt/mcphub/.env
cat <<'EOF' >/opt/mcphub/data/mcp_settings.json
{"mcpServers":{},"systemConfig":{"routing":{"enableBearerAuth":true}}}
EOF
chmod 600 /opt/mcphub/data/mcp_settings.json
msg_ok "Configured MCPHub"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/mcphub.service
[Unit]
Description=MCPHub Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/mcphub
EnvironmentFile=/opt/mcphub/.env
Environment=NODE_ENV=production
Environment=PORT=3000
Environment=HOME=/opt/mcphub/home
Environment=MCPHUB_SETTING_PATH=/opt/mcphub/data/mcp_settings.json
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/node /opt/mcphub/dist/index.js
Restart=on-failure
RestartSec=5
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now mcphub
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
