#!/usr/bin/env bash

# Copyright (c) 2026 SystemIdleProcess
# Author: SystemIdleProcess
# Framework license: MIT | https://github.com/community-scripts/core/blob/main/LICENSE
# Source: https://github.com/openclaw/openclaw

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y git
msg_ok "Installed Dependencies"

NODE_VERSION="24" setup_nodejs

msg_info "Installing OpenClaw"
npm_version=$(npm --version)
npm_options=(--global --prefix /usr/local --engine-strict)
if [[ "$(printf '%s\n' 11.16.0 "$npm_version" | sort -V | head -n 1)" == 11.16.0 ]]; then
  npm_options+=(--dangerously-allow-all-scripts=false --allow-scripts=openclaw)
fi
$STD npm install "${npm_options[@]}" openclaw@latest
msg_ok "Installed OpenClaw"

msg_info "Configuring OpenClaw"
useradd --system --user-group --home-dir /var/lib/openclaw --shell /usr/sbin/nologin openclaw
install -d -o openclaw -g openclaw -m 700 /var/lib/openclaw /var/lib/openclaw/.openclaw
gateway_token=$(openssl rand -hex 32)
install -o openclaw -g openclaw -m 600 /dev/null /var/lib/openclaw/.openclaw/openclaw.json
cat <<EOF >/var/lib/openclaw/.openclaw/openclaw.json
{
  "gateway": {
    "mode": "local",
    "bind": "loopback",
    "port": 18789,
    "auth": { "mode": "token", "token": "$gateway_token" }
  },
  "update": { "auto": { "enabled": false } }
}
EOF
unset gateway_token
msg_ok "Configured OpenClaw"

msg_info "Starting OpenClaw"
cat <<'EOF' >/etc/systemd/system/openclaw.service
[Unit]
Description=OpenClaw Gateway
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=openclaw
Group=openclaw
WorkingDirectory=/var/lib/openclaw
Environment=HOME=/var/lib/openclaw
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=OPENCLAW_SUPERVISOR_MODE=external
Environment=OPENCLAW_NO_AUTO_UPDATE=1
ExecStart=/usr/local/bin/openclaw gateway run --port 18789
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now openclaw
$STD curl -fsS --retry 30 --retry-delay 2 --retry-connrefused --max-time 5 http://127.0.0.1:18789/healthz
msg_ok "Started OpenClaw"

motd_ssh
customize
cleanup_lxc
