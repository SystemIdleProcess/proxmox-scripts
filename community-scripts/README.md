# Custom community-scripts installers

Personal application LXC scripts using the official [community-scripts engine](https://github.com/community-scripts/core). These are maintained here, not official community-scripts releases.

## MCPHub

Creates an **unprivileged Debian 13 LXC** and installs the published **`@samanhappy/mcphub` npm package**, initially version **1.2.4**, as a native systemd service. No Docker is installed or used.

Default allocation: **2 CPU cores, 2 GiB RAM, 16 GiB disk**. These are installer defaults, not measured minimums. MCP servers launched later need additional resources according to their workloads. amd64 and arm64 are permitted; actual LXC installs on either architecture remain unverified.

### Install from the development branch

Run in the **Proxmox host root shell**. This branch is under development; take a host/LXC recovery checkpoint appropriate to your environment first. The standard community-scripts wizard chooses the container ID, network, storage, and resources.

```bash
export COMMUNITY_SCRIPTS_URL="https://raw.githubusercontent.com/SystemIdleProcess/proxmox-scripts/feat/mcphub-lxc/community-scripts"
(
  script=$(mktemp) || exit 1
  trap 'rm -f "$script"' EXIT
  curl -fsSL "$COMMUNITY_SCRIPTS_URL/ct/mcphub.sh" -o "$script" || exit 1
  bash "$script"
)
```

The script defaults to the `main/community-scripts` base when no override is set. Until this branch is merged, use the branch override above. Installation preserves that origin in the generated `update` command; it does not silently switch a branch installation to main.

### What is installed

- Official community-scripts helpers install Node.js 22 and uv/uvx. Debian packages supply Python 3, venv support, Git, build tools, and procps, following upstream's dependency requirements.
- Published npm releases live in `/opt/mcphub/releases/`; `/opt/mcphub/current` selects the active one. No source checkout or frontend build is needed.
- A dedicated `mcphub` system user runs `mcphub.service`. Child stdio servers run with the same user's permissions.
- State: `/opt/mcphub/data/`; runtime home and npx/uvx caches: `/opt/mcphub/home/`.
- Secrets: root-readable `/opt/mcphub/.env`. It contains a random initial admin password, persistent JWT secret, and persistent credential-encryption key. Never publish this file or regenerate its encryption key on update.
- No MCP backends, service credentials, DNS names, or reverse proxies are preconfigured. Add them through the dashboard. A host-only path such as Hermes's existing Gitea binary is not available in this new LXC; that binary must be installed there or reached through an HTTP MCP endpoint.

Dashboard: `http://<LXC-IP>:3000` (replace `<LXC-IP>` with the address reported by the installer). Username: `admin`. Read `ADMIN_PASSWORD` from `.env` locally, then change it through MCPHub. Changing `.env` afterward does not reset an existing user's password.

Bearer authentication is enabled for MCP endpoints. Create a key in the dashboard, then connect clients to `/mcp`, `/mcp/<server>`, or `/mcp/<group>`. Treat the LXC address as private; put authenticated HTTPS in front before using it across untrusted networks. The installer does not expose ports on your router or configure TLS.

### Updates and recovery

Inside the **MCPHub LXC**, use the standard community-scripts command:

```bash
update
```

The installed manager resolves the latest stable npm package version, installs it into a fresh release directory **before** stopping the service, then snapshots data, runtime home, secrets, and the old release symlink into a root-readable archive under `/var/backups/mcphub/`. It switches releases atomically and checks `/health`. Failed activation attempts restore the previous release, data, and runtime home; the command still exits nonzero. Failed runtime data is retained under `/opt/mcphub/.rollback-*` for diagnosis.

To select a specific stable version (also performs a stopped backup):

```bash
/opt/mcphub/manage.sh update 1.2.4
```

A same-version update checks health without stopping or reinstalling. Updates do not automatically upgrade Node.js/uv, replace the installed management script or unit, prune old releases, or delete backups. Review script/runtime changes separately and monitor free disk space. This initial installer is for a fresh LXC, not an in-place conversion of another installation.

Diagnostics:

```bash
systemctl status mcphub --no-pager
journalctl -u mcphub -n 100 --no-pager
```

Logs and backups can contain backend credentials or sensitive tool data; inspect locally and redact before sharing. Health success proves the gateway answered, not that a configured backend works: test a useful authenticated tool call from a client separately.

For manual recovery after an automatic recovery failure: keep the LXC stopped or stop `mcphub.service`, preserve the failed data, restore the matching `data/`, `home/`, `.env`, and `current` from one snapshot, and retain the referenced release directory. Start the service and verify health and a client call. Take Proxmox backups too: these app snapshots do not contain the OS, runtime binaries, or release package directories.

### Validation status

The published npm package and its built dashboard have been inspected. Offline failure-path tests, shell syntax, ShellCheck, and the pinned engine's generated-updater contract are checked during development. See [the review record](mcphub-review.md) for actual results and remaining deployment checks.

## Layout and engine source

- `ct/mcphub.sh`: host-side container defaults and update dispatch.
- `install/mcphub-install.sh`: native application installation inside the LXC.
- `install/mcphub-manage.sh`: installed release manager, backup, and recovery.
- `tests/`: offline transaction tests and optional engine contract test.

The scripts source official `community-scripts/core` revision `4f6c2bd4dfadce266dca9ec737e8382728d753e3` by default. `COMMUNITY_SCRIPTS_CORE_URL` can override it for explicitly tested upgrades. Shared engine files are not copied into this repository.

```bash
python3 -m unittest discover -s community-scripts/tests -v
# Include the real upstream updater contract:
CS_CORE_DIR=/path/to/community-scripts-core python3 -m unittest discover -s community-scripts/tests -v
```

The optional native smoke test starts a temporary server, creates disposable credentials, verifies the dashboard and MCP authentication, and forwards a call to a fixture stdio server. It stops its process group afterward. Supply a directory containing the installed published package:

```bash
MCPHUB_PACKAGE_DIR=/path/to/node_modules/@samanhappy/mcphub python3 community-scripts/tests/smoke_mcphub.py
```
