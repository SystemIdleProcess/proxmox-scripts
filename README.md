# Proxmox Scripts

A collection of utility scripts for Proxmox VE hosts.

---

## pve-dkms-autofix.sh

Fixes a timing bug in Proxmox where DKMS modules (NVIDIA, r8152, Coral TPU, etc.) fail to auto-rebuild on kernel updates. The DKMS post-install hook runs before kernel headers are available, so the rebuild silently skips. This script installs an apt hook that ensures headers are installed first, then triggers `dkms autoinstall` — so all DKMS-managed drivers survive kernel upgrades automatically. Run once per host.

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/SystemIdleProcess/proxmox-scripts/main/pve-dkms-autofix.sh)"
```

---

## pve-r8152-setup.sh

Pulls the latest Realtek r8152 USB Ethernet driver from [wget/realtek-r8152-linux](https://github.com/wget/realtek-r8152-linux), registers it with DKMS, and builds it for a target kernel. Lists installed kernels with driver status, lets you select by number, and asks for confirmation before making any changes. Also installs the DKMS auto-rebuild hook from `pve-dkms-autofix.sh`.

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/SystemIdleProcess/proxmox-scripts/main/pve-r8152-setup.sh)"
```

---

## pve-kernel-cleanup.sh

Finds and removes orphaned `/lib/modules` directories left behind by previously uninstalled kernels. Shows a summary of what's safe to remove with disk usage, asks for confirmation before deleting anything, and refreshes the bootloader afterward. Never touches the running kernel or any kernel with an installed package.

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/SystemIdleProcess/proxmox-scripts/main/pve-kernel-cleanup.sh)"
```
