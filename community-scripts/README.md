# Custom community-scripts installers

This directory is reserved for personal application LXC installers built on the official [community-scripts engine](https://github.com/community-scripts/core). These are custom scripts maintained in this repository, not official community-scripts releases.

**No application installers or updaters have been implemented yet.**

## Layout

```text
community-scripts/
├── ct/          # Proxmox host entry scripts: container defaults and application update logic
└── install/     # Application installation performed inside the new LXC
```

Each application will have a matching `ct/<app>.sh` and `install/<app>-install.sh`. The LXC entry script runs on the Proxmox host; the framework runs the application installer inside the container.

## Sources

- `COMMUNITY_SCRIPTS_URL` must point to this directory's raw-content base: `https://raw.githubusercontent.com/SystemIdleProcess/proxmox-scripts/main/community-scripts`.
- `COMMUNITY_SCRIPTS_CORE_URL` selects the official shared engine. Choose and verify a tested upstream revision when implementing the first installer; do not copy the shared engine into this repository.
- Application installation and update logic belongs here. Application packages or images should come from the application's published distribution.

Before publishing an installer, verify both initial installation and the generated in-container `update` command use this repository's nested scripts path. No working installer or updater is implied by these conventions alone.

See the upstream [script-origin guide](https://github.com/community-scripts/ProxmoxVED/blob/main/docs/guides/source-origin.md) for source overrides.
