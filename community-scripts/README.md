# Custom community-scripts installers

Personal LXC scripts using the official community-scripts engine. These are maintained here, not official community-scripts releases.

## MCPHub

Two scripts, following the official pattern:

- [`ct/mcphub.sh`](ct/mcphub.sh): container defaults and `update_script`.
- [`install/mcphub-install.sh`](install/mcphub-install.sh): application installation inside the LXC.

The installer uses the official `fetch_and_deploy_gh_release` helper to download MCPHub's latest GitHub source release, then runs its locked pnpm install and build. Node.js 22, pnpm 10.12.4 (specified by MCPHub's package metadata), and uv/uvx are installed through the shared helpers. No Docker, cloned application repository, separate management script, or custom version tracking is used.

Defaults: unprivileged Debian 13, 2 CPU cores, 4 GiB RAM, 16 GiB disk. These are allocations, not measured minimums. arm64 is left undecided because the native build has not been verified on that architecture; the framework can ask rather than claiming support.

### Install from this branch

Run in the **Proxmox host root shell**:

```bash
export COMMUNITY_SCRIPTS_URL="https://raw.githubusercontent.com/SystemIdleProcess/proxmox-scripts/feat/mcphub-lxc/community-scripts"
bash -c "$(curl -fsSL "$COMMUNITY_SCRIPTS_URL/ct/mcphub.sh")"
```

Both lines are required. `COMMUNITY_SCRIPTS_URL` selects the custom script base, including the nested `community-scripts` folder. The framework records this origin in the LXC's `update` command. Shared engine code comes from official `community-scripts/core`; `COMMUNITY_SCRIPTS_CORE_DIR` and `COMMUNITY_SCRIPTS_CORE_URL` remain available as documented upstream overrides.

The default script origin is this repository's `main/community-scripts`; use the branch override until merged. For local-checkout testing, explicitly set the same scripts URL: the upstream Git origin detection expects a scripts checkout with its own `.git` directory. Our nested folder has none, so the explicit override ensures updates stay on the selected branch rather than defaulting to main.

### After installation

- Open `http://<LXC-IP>:3000`, replacing `<LXC-IP>` with the address reported by the installer.
- Username: `admin`. Initial password: `ADMIN_PASSWORD` in `/opt/mcphub/.env`, readable locally as root. Change it through the dashboard after login.
- MCPHub runs as root inside the unprivileged LXC, following the community-scripts service convention. Configured stdio tools inherit that service's privileges.
- State and caches live in `/opt/mcphub/data` and `/opt/mcphub/home`; secrets live in `/opt/mcphub/.env`. Back up the LXC, including the persistent credential-encryption key. Never paste that file into chat or Git.
- MCP endpoints require bearer authentication. Add backends and create client keys in the dashboard. No service credentials, backends, DNS, or reverse proxy are preconfigured. Use HTTPS for access across untrusted networks.
- Binaries on the Hermes machine are not automatically available in this LXC; install them there or connect to their HTTP MCP endpoints.

### Update

Run `update` **inside the MCPHub LXC**. The framework checks for a newer GitHub release, stops the service, preserves `.env` with `create_backup`/`restore_backup`, retains `data` and `home` with `CLEAN_INSTALL_KEEP`, rebuilds the application, and restarts the service. Running it again without a newer release does not rebuild.

This is the standard update flow, not automatic rollback. A failed download or build after the service stops may leave it stopped; inspect the local error/log, rerun after resolving the cause, or restore your pre-update Proxmox backup. The shared helper tracks an incomplete update so it can be retried. Its temporary configuration backup is consumed on restore; it is not a durable recovery archive.

For diagnostics, use `systemctl status mcphub --no-pager` and `journalctl -u mcphub -n 100 --no-pager`. Redact logs before sharing.

### Guide references and validation

- [Official CT template](https://community-scripts.org/docs/contribution/templates_ct/appname)
- [Official install template](https://community-scripts.org/docs/contribution/templates_install/appname-install)
- [Coding rules](https://community-scripts.org/docs/contribution/guide)
- [Fork and branch testing](https://community-scripts.org/docs/contribution/fork_setup)
- [Source-origin guide](https://github.com/community-scripts/DevScripts/blob/main/docs/guides/source-origin.md)
- Comparable npm-based scripts: [OmniRoute CT](https://github.com/community-scripts/ProxmoxVE/blob/main/ct/omniroute.sh) and [installer](https://github.com/community-scripts/ProxmoxVE/blob/main/install/omniroute-install.sh).

MCPHub's Node/pnpm versions and build sequence come from its `package.json`, Dockerfile, and npm publishing workflow. Source-release build and local gateway smoke checks are development validation only. A complete Proxmox LXC install, reboot, and actual update still require testing. Earlier testing of the published npm package alone does not establish this source installer works end to end.
