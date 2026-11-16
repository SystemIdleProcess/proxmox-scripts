# Custom community-scripts installers

Personal LXC scripts using the official community-scripts engine. These are maintained here, not official community-scripts releases.

## MCPHub

Two scripts, following the official pattern:

- [`ct/mcphub.sh`](ct/mcphub.sh): container defaults and `update_script`.
- [`install/mcphub-install.sh`](install/mcphub-install.sh): application installation inside the LXC.

The installer uses the official `fetch_and_deploy_gh_release` helper to download MCPHub's latest GitHub source release, then runs its locked pnpm install and build. Node.js 22, pnpm 10.12.4 (specified by MCPHub's package metadata), and uv/uvx are installed through the shared helpers. No Docker, cloned application repository, separate management script, or custom version tracking is used.

Defaults: unprivileged Debian 13, 2 CPU cores, 4 GiB RAM, 24 GiB disk. These are allocations, not measured minimums. arm64 is left undecided because the native build has not been verified on that architecture; the framework can ask rather than claiming support.

### Install

Run in the **Proxmox host root shell**:

```bash
export COMMUNITY_SCRIPTS_URL="https://raw.githubusercontent.com/SystemIdleProcess/proxmox-scripts/main/community-scripts"
bash -c "$(curl -fsSL "$COMMUNITY_SCRIPTS_URL/ct/mcphub.sh")"
```

Both lines are required. `COMMUNITY_SCRIPTS_URL` selects the custom script base, including the nested `community-scripts` folder. The framework records this origin in the LXC's `update` command. Shared engine code comes from official `community-scripts/core`; `COMMUNITY_SCRIPTS_CORE_DIR` and `COMMUNITY_SCRIPTS_CORE_URL` remain available as documented upstream overrides.

To test the storage-options branch before merging, use `COMMUNITY_SCRIPTS_URL="https://raw.githubusercontent.com/SystemIdleProcess/proxmox-scripts/feat/mcphub-storage-options/community-scripts"` instead. The default script origin is this repository's `main/community-scripts`. For local-checkout testing, explicitly set the same scripts URL: the upstream Git origin detection expects a scripts checkout with its own `.git` directory. Our nested folder has none, so the explicit override ensures updates stay on the selected branch rather than defaulting to main.

### Storage choices and unattended installation

The host script collects these choices before the container wizard, using the official `prompt_select` and `prompt_confirm` helpers:

| Variable | Values | Default when unset, empty, timed out, or unattended |
|---|---|---|
| `var_mcphub_storage` | `file`, `postgresql` | `file` |
| `var_mcphub_pgvector` | `yes`, `no` | `no` |

The storage menu waits up to 30 seconds; the pgvector question is asked only for PostgreSQL and also defaults after 30 seconds. Explicit preset values bypass the corresponding prompt. Invalid preset values, including `file` with pgvector `yes`, stop with an error rather than silently changing the request. The choices are exported to the installer. Updates do not prompt or switch storage backends.

For a fully unattended local PostgreSQL + pgvector install **from this development branch**, run on the host:

```bash
export COMMUNITY_SCRIPTS_URL="https://raw.githubusercontent.com/SystemIdleProcess/proxmox-scripts/feat/mcphub-storage-options/community-scripts"
var_mcphub_storage=postgresql var_mcphub_pgvector=yes mode=default \
  bash -c "$(curl -fsSL "$COMMUNITY_SCRIPTS_URL/ct/mcphub.sh")"
```

For interactive branch testing, use the same exported URL and omit the three preset assignments. `mode=default` selects the framework's unattended/default container settings, not only the app choices. To use file-based storage explicitly, set `var_mcphub_storage=file var_mcphub_pgvector=no` instead.

PostgreSQL selection installs local PostgreSQL 17 through `setup_postgresql`, creates an app-owned database with `setup_postgresql_db`, generates a database password, and writes `DB_URL` and `USE_DB=true` into the root-readable `.env`. No external database is offered and the application database role is not granted superuser. The generated MCPHub service requires PostgreSQL on boot. Existing installs are not migrated by `update`; reinstall into a fresh LXC to test a different selection.

With pgvector selected, `PG_MODULES="pgvector"` installs the package and `PG_DB_EXTENSIONS="vector"` enables the extension. Smart Routing remains disabled by default. Configure the embedding provider and model, then enable Smart Routing through the MCPHub dashboard. The installer adds no Smart Routing or embedding-provider entries to `.env`.

### After installation

- Open `http://<LXC-IP>:3000`, replacing `<LXC-IP>` with the address reported by the installer.
- Username: `admin`. Initial password: `ADMIN_PASSWORD` in `/opt/mcphub/.env`, readable locally as root. Change it through the dashboard after login.
- MCPHub runs as root inside the unprivileged LXC, following the community-scripts service convention. Configured stdio tools inherit that service's privileges.
- State and caches live in `/opt/mcphub/data` and `/opt/mcphub/home`; secrets live in `/opt/mcphub/.env`. Back up the LXC, including the persistent credential-encryption key. Never paste that file into chat or Git.
- MCP endpoints require bearer authentication. Add backends and create client keys in the dashboard. No service credentials, backends, DNS, or reverse proxy are preconfigured. Use HTTPS for access across untrusted networks.
- Binaries on the Hermes machine are not automatically available in this LXC; install them there or connect to their HTTP MCP endpoints.

### Update

Run `update` **inside the MCPHub LXC**. The framework checks for a newer GitHub release, stops the service, preserves `.env` with `create_backup`/`restore_backup`, retains `data` and `home` with `CLEAN_INSTALL_KEEP`, rebuilds the application, and restarts the service. Running it again without a newer release does not rebuild.

This is the standard update flow, not automatic rollback. A failed download or build after the service stops may leave it stopped; inspect the local error/log, rerun after resolving the cause, or restore your pre-update Proxmox backup. The shared helper tracks an incomplete update so it can be retried. Database mode keeps PostgreSQL data outside the app directory; the configuration backup is not a database backup. Include PostgreSQL and the credential-encryption key in your recovery plan. Its temporary configuration backup is consumed on restore; it is not a durable recovery archive.

For diagnostics, use `systemctl status mcphub --no-pager` and `journalctl -u mcphub -n 100 --no-pager`. Redact logs before sharing.

### Guide references and validation

- [Official CT template](https://community-scripts.org/docs/contribution/templates_ct/appname)
- [Official install template](https://community-scripts.org/docs/contribution/templates_install/appname-install)
- [Coding rules](https://community-scripts.org/docs/contribution/guide)
- [Fork and branch testing](https://community-scripts.org/docs/contribution/fork_setup)
- [Source-origin guide](https://github.com/community-scripts/DevScripts/blob/main/docs/guides/source-origin.md)
- Comparable npm-based scripts: [OmniRoute CT](https://github.com/community-scripts/ProxmoxVE/blob/main/ct/omniroute.sh) and [installer](https://github.com/community-scripts/ProxmoxVE/blob/main/install/omniroute-install.sh).

MCPHub's Node/pnpm versions and build sequence come from its `package.json`, Dockerfile, and npm publishing workflow. Source-release build and local gateway smoke checks are development validation only. The branch installer was subsequently reported to complete successfully on Proxmox, with a Home Assistant MCP connected and working. That report covers the original file-based installation. The PostgreSQL/pgvector paths and generated service dependencies have been checked with isolated framework stubs, not a real LXC provisioning run. The real prompt helpers were exercised with preset, interactive and timeout/default inputs. Reboot persistence and an actual application update remain unverified.
