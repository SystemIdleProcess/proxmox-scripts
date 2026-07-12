#!/bin/bash
# =============================================================================
# pve-dkms-autofix.sh
# Fixes the DKMS auto-rebuild timing issue on Proxmox VE.
#
# PROBLEM:
# When a new Proxmox kernel is installed via apt, the DKMS post-install hook
# fires BEFORE kernel headers are available. DKMS checks for headers, finds
# nothing, and silently skips the rebuild. You reboot into the new kernel
# with no DKMS-managed drivers (NVIDIA, r8152, etc.) and things break.
#
# SOLUTION:
# This script installs an apt Dpkg::Post-Invoke hook that runs AFTER all
# packages are installed. It:
#   1. Finds all installed Proxmox kernels
#   2. Ensures matching headers are installed for each
#   3. Triggers 'dkms autoinstall' for any kernel that has headers but
#      is missing DKMS modules
#
# This covers ALL DKMS-registered drivers (NVIDIA, r8152, Coral TPU,
# i915-sriov, etc.) — not just one specific driver.
#
# It also patches any DKMS-registered modules missing AUTOINSTALL="yes"
# in their dkms.conf, which is required for dkms autoinstall to work.
#
# USAGE:
#   sudo bash pve-dkms-autofix.sh
#
# Run once. The hook persists across reboots and apt updates.
# Safe to re-run — it will update the hook to the latest version.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -eq 0 ]] || error "Please run as root: sudo bash $0"

APT_HOOK_FILE="/etc/apt/apt.conf.d/99-auto-proxmox-headers"
CURRENT_KERNEL="$(uname -r)"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║        DKMS Auto-Rebuild Fix for Proxmox VE            ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# =============================================================================
# STEP 1: Install the apt hook
# =============================================================================
info "Installing apt hook at $APT_HOOK_FILE ..."

cat > "$APT_HOOK_FILE" << 'EOF'
Dpkg::Post-Invoke {
    "for kver in $(dpkg -l 'proxmox-kernel-*' 2>/dev/null | awk '/^ii/{print $2}' | grep -v 'headers\\|dbgsym' | sed 's/proxmox-kernel-//'); do apt-get install -y proxmox-headers-$kver 2>/dev/null || true; if [ -d /lib/modules/$kver/build/include ]; then dkms autoinstall --kernelver $kver 2>/dev/null || true; fi; done";
};
EOF

info "apt hook installed."

# =============================================================================
# STEP 2: Fix any DKMS modules missing AUTOINSTALL
# =============================================================================
info "Checking DKMS modules for AUTOINSTALL flag..."

FIXED_COUNT=0
for conf in /usr/src/*/dkms.conf; do
    [[ -f "$conf" ]] || continue
    if ! grep -qi 'AUTOINSTALL' "$conf"; then
        MODULE_DIR="$(dirname "$conf")"
        MODULE_NAME="$(basename "$MODULE_DIR")"
        warn "  $MODULE_NAME — missing AUTOINSTALL, adding it..."
        echo 'AUTOINSTALL="yes"' >> "$conf"
        FIXED_COUNT=$((FIXED_COUNT + 1))
    fi
done

if [[ $FIXED_COUNT -eq 0 ]]; then
    info "All DKMS modules already have AUTOINSTALL set."
else
    info "Fixed $FIXED_COUNT module(s)."
fi

# =============================================================================
# STEP 3: Ensure headers are present for all installed kernels
# =============================================================================
info "Checking kernel headers..."

mapfile -t INSTALLED_KERNELS < <(
    dpkg --list 2>/dev/null \
    | grep -E '(proxmox-kernel|pve-kernel)-[0-9].*-pve' \
    | grep '^ii' \
    | awk '{print $2}' \
    | sed -E 's/(proxmox-kernel|pve-kernel)-//; s/-(signed|dbgsym)//' \
    | sort -uV
)

HEADERS_INSTALLED=0
for kver in "${INSTALLED_KERNELS[@]}"; do
    HEADERS_PKG="proxmox-headers-${kver}"
    if dpkg -l "$HEADERS_PKG" 2>/dev/null | grep -q '^ii'; then
        echo -e "  ${GREEN}✔${NC} $kver — headers present"
    else
        warn "  $kver — headers missing, installing..."
        apt-get install -y "$HEADERS_PKG" 2>/dev/null || warn "    Could not install $HEADERS_PKG"
        HEADERS_INSTALLED=$((HEADERS_INSTALLED + 1))
    fi
done

# =============================================================================
# STEP 4: Build DKMS modules for any kernel that's missing them
# =============================================================================
info "Checking DKMS module status across all kernels..."

REBUILDS_NEEDED=false
for kver in "${INSTALLED_KERNELS[@]}"; do
    # Skip if no headers (can't build)
    [[ -d "/lib/modules/$kver/build/include" ]] || continue

    # Get list of DKMS modules that are registered but not installed for this kernel
    MISSING_MODULES=()
    while IFS= read -r line; do
        # dkms status output format: "module/version, kernel, arch: status"
        MODULE_SLUG=$(echo "$line" | awk -F',' '{print $1}' | xargs)
        STATUS=$(echo "$line" | awk -F': ' '{print $NF}' | xargs)

        # We want modules in 'added' or 'built' state (not yet 'installed')
        if [[ "$STATUS" != "installed" && "$STATUS" != "installed"* ]]; then
            MISSING_MODULES+=("$MODULE_SLUG")
        fi
    done < <(dkms status -k "$kver" 2>/dev/null)

    # Also check for modules registered but with no entry at all for this kernel
    while IFS= read -r line; do
        MODULE_SLUG=$(echo "$line" | awk -F',' '{print $1}' | xargs)
        if ! dkms status "$MODULE_SLUG" -k "$kver" 2>/dev/null | grep -q "installed"; then
            # Only add if not already in the list
            if [[ ! " ${MISSING_MODULES[*]:-} " =~ " $MODULE_SLUG " ]]; then
                MISSING_MODULES+=("$MODULE_SLUG")
            fi
        fi
    done < <(dkms status 2>/dev/null | awk -F',' '{print $1}' | sort -u)

    if [[ ${#MISSING_MODULES[@]} -gt 0 ]]; then
        REBUILDS_NEEDED=true
        for mod in "${MISSING_MODULES[@]}"; do
            warn "  $mod not installed for $kver — building..."
            dkms install "$mod" -k "$kver" --force 2>&1 | tail -3
        done
        # Update initramfs after building
        info "  Updating initramfs for $kver ..."
        update-initramfs -u -k "$kver"
    else
        echo -e "  ${GREEN}✔${NC} $kver — all DKMS modules installed"
    fi
done

if [[ "$REBUILDS_NEEDED" == false ]]; then
    info "All DKMS modules are built for all kernels."
fi

# =============================================================================
# STEP 5: Summary
# =============================================================================
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""
info "Current kernel: $CURRENT_KERNEL"
echo ""

echo "DKMS module status:"
echo "-----------------------------"
dkms status
echo ""

echo "apt hook:"
if [[ -f "$APT_HOOK_FILE" ]]; then
    echo -e "  ${GREEN}✔ Active${NC} ($APT_HOOK_FILE)"
else
    echo -e "  ${RED}✘ Not found${NC}"
fi
echo ""

echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""
echo "What this fixed:"
echo "  • apt hook ensures headers are installed for every new kernel"
echo "  • apt hook triggers 'dkms autoinstall' AFTER headers are ready"
echo "  • All DKMS modules have AUTOINSTALL=yes for future kernel installs"
echo "  • Any missing module builds for installed kernels were rebuilt now"
echo ""
echo "Going forward, 'apt full-upgrade' will automatically handle"
echo "headers + DKMS rebuilds for all registered drivers."
echo ""
