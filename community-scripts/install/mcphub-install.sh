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

var_mcphub_storage="${var_mcphub_storage:-file}"
var_mcphub_pgvector="${var_mcphub_pgvector:-no}"
case "$var_mcphub_storage:$var_mcphub_pgvector" in
file:no | postgresql:no | postgresql:yes) ;;
*)
  msg_error "Invalid MCPHub storage options; choose file/no, postgresql/no or postgresql/yes"
  exit 64
  ;;
esac

msg_info "Installing Dependencies"
$STD apt install -y \
  build-essential \
  git \
  procps \
  python3
msg_ok "Installed Dependencies"

NODE_VERSION="22" NODE_MODULE="pnpm@10.12.4" setup_nodejs
USE_UVX=YES setup_uv

if [[ "$var_mcphub_storage" == postgresql ]]; then
  if [[ "$var_mcphub_pgvector" == yes ]]; then
    PG_VERSION="17" PG_MODULES="pgvector" setup_postgresql
    PG_DB_NAME="mcphub" PG_DB_USER="mcphub" PG_DB_EXTENSIONS="vector" PG_DB_CREDS_FILE="/dev/null" setup_postgresql_db
  else
    PG_VERSION="17" PG_MODULES="" setup_postgresql
    PG_DB_NAME="mcphub" PG_DB_USER="mcphub" PG_DB_CREDS_FILE="/dev/null" setup_postgresql_db
  fi
fi

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
if [[ "$var_mcphub_storage" == postgresql ]]; then
  cat <<EOF >>/opt/mcphub/.env
DB_URL=postgresql://mcphub:${PG_DB_PASS}@127.0.0.1:5432/mcphub
USE_DB=true
EOF
fi
chmod 600 /opt/mcphub/.env
cat <<'EOF' >/opt/mcphub/data/mcp_settings.json
{"mcpServers":{},"systemConfig":{"routing":{"enableBearerAuth":true}}}
EOF
chmod 600 /opt/mcphub/data/mcp_settings.json
msg_ok "Configured MCPHub"

postgresql_service=""
if [[ "$var_mcphub_storage" == postgresql ]]; then
  postgresql_service="postgresql.service"
fi

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/mcphub.service
[Unit]
Description=MCPHub Service
After=network.target ${postgresql_service}
Requires=${postgresql_service}

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
