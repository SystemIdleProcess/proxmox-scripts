#!/usr/bin/env bash
# Personal installer; shared functions are provided by community-scripts/core.
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing MCPHub dependencies"
$STD apt-get install -y ca-certificates curl openssl tar util-linux python3 python3-venv build-essential git procps
NODE_VERSION="22" setup_nodejs
USE_UVX=YES setup_uv
msg_ok "Installed Node.js, Python, uv/uvx and build tools"

msg_info "Configuring MCPHub"
useradd --system --user-group --home-dir /opt/mcphub/home --shell /usr/sbin/nologin mcphub
install -d -m 755 /opt/mcphub /opt/mcphub/releases
install -d -m 700 -o mcphub -g mcphub /opt/mcphub/data /opt/mcphub/home
install -d -m 700 /var/backups/mcphub
umask 077
cat >/opt/mcphub/.env <<ENV
ADMIN_PASSWORD=$(openssl rand -hex 20)
JWT_SECRET=$(openssl rand -hex 32)
MCPHUB_CREDENTIAL_ENCRYPTION_KEY=$(openssl rand -base64 32)
ENV
cat >/opt/mcphub/data/mcp_settings.json <<'JSON'
{"mcpServers":{},"systemConfig":{"routing":{"enableBearerAuth":true}}}
JSON
chown mcphub:mcphub /opt/mcphub/data/mcp_settings.json
curl -fsSL --connect-timeout 10 --max-time 60 \
  "${COMMUNITY_SCRIPTS_URL}/install/mcphub-manage.sh" -o /opt/mcphub/manage.sh
bash -n /opt/mcphub/manage.sh
chmod 700 /opt/mcphub/manage.sh
cat >/etc/systemd/system/mcphub.service <<'UNIT'
[Unit]
Description=MCPHub MCP gateway
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=mcphub
Group=mcphub
WorkingDirectory=/opt/mcphub/current/node_modules/@samanhappy/mcphub
EnvironmentFile=/opt/mcphub/.env
Environment=NODE_ENV=production
Environment=PORT=3000
Environment=HOME=/opt/mcphub/home
Environment=MCPHUB_SETTING_PATH=/opt/mcphub/data/mcp_settings.json
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/node /opt/mcphub/current/node_modules/@samanhappy/mcphub/dist/index.js
Restart=on-failure
RestartSec=5
TimeoutStopSec=60
KillMode=control-group
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/opt/mcphub/data /opt/mcphub/home

[Install]
WantedBy=multi-user.target
UNIT
chmod 644 /etc/systemd/system/mcphub.service
systemctl daemon-reload
msg_ok "Configured MCPHub"

msg_info "Installing MCPHub 1.2.4 and starting its service"
/opt/mcphub/manage.sh install 1.2.4
msg_ok "MCPHub answered its health endpoint"

motd_ssh
customize
# Preserve the custom slug and nested scripts origin in the generated updater.
write_update_entrypoint "${SCRIPT_SLUG:-systemidle-mcphub}" mcphub
cleanup_lxc
