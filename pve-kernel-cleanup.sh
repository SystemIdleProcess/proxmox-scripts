#!/bin/bash
# =============================================================================
# pve-kernel-cleanup.sh
# Finds and removes orphaned /lib/modules directories that no longer have
# a matching installed kernel package. Safe — never touches the running kernel
# or any kernel with an installed package.
#
# Usage: sudo bash pve-kernel-cleanup.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -eq 0 ]] || error "Please run as root: sudo bash $0"

RUNNING_KERNEL="$(uname -r)"
info "Running kernel: $RUNNING_KERNEL"
echo ""

# --- Build list of kernels that have installed packages ----------------------
mapfile -t INSTALLED_KERNELS < <(
    dpkg --list 2>/dev/null \
    | grep -E '(proxmox-kernel|pve-kernel)-[0-9].*-pve' \
    | grep '^ii' \
    | awk '{print $2}' \
    | sed -E 's/(proxmox-kernel|pve-kernel)-//; s/-(signed|dbgsym)//' \
    | sort -uV
)

# Safety: if package detection returned nothing, every kernel except the
# running one would look orphaned. Bail out rather than risk removing a
# kernel that is actually installed.
[[ ${#INSTALLED_KERNELS[@]} -gt 0 ]] || \
    error "No installed kernel packages detected — refusing to continue. Check 'dpkg --list | grep kernel' manually."

# --- Build list of /lib/modules directories ----------------------------------
mapfile -t MODULE_DIRS < <(ls /lib/modules/)

# --- Find orphans ------------------------------------------------------------
ORPHANS=()
for dir in "${MODULE_DIRS[@]}"; do
    # Never touch the running kernel
    [[ "$dir" == "$RUNNING_KERNEL" ]] && continue

    # Check if any installed package matches this directory
    MATCH=false
    for pkg in "${INSTALLED_KERNELS[@]}"; do
        if [[ "$dir" == "$pkg" ]]; then
            MATCH=true
            break
        fi
    done

    if [[ "$MATCH" == false ]]; then
        ORPHANS+=("$dir")
    fi
done

# --- Report ------------------------------------------------------------------
echo "Installed kernel packages:"
echo "-----------------------------"
for k in "${INSTALLED_KERNELS[@]}"; do
    MARKER=""
    [[ "$k" == "$RUNNING_KERNEL" ]] && MARKER=" (running)"
    echo -e "  ${GREEN}✔${NC} $k$MARKER"
done
echo ""

if [[ ${#ORPHANS[@]} -eq 0 ]]; then
    info "No orphaned /lib/modules directories found. Nothing to clean up."
    exit 0
fi

echo "Orphaned /lib/modules directories (no matching package):"
echo "-----------------------------"
TOTAL_SIZE=0
for orphan in "${ORPHANS[@]}"; do
    SIZE=$(du -sh "/lib/modules/$orphan" 2>/dev/null | awk '{print $1}' || true)
    SIZE_BYTES=$(du -sb "/lib/modules/$orphan" 2>/dev/null | awk '{print $1}' || true)
    SIZE="${SIZE:-?}"
    TOTAL_SIZE=$((TOTAL_SIZE + ${SIZE_BYTES:-0}))
    echo -e "  ${RED}✘${NC} /lib/modules/$orphan  ($SIZE)"
done
TOTAL_HUMAN=$(numfmt --to=iec "$TOTAL_SIZE" 2>/dev/null || echo "${TOTAL_SIZE} bytes")
echo ""
echo "Total reclaimable space: $TOTAL_HUMAN"
echo ""

# --- Confirm -----------------------------------------------------------------
read -rp "Remove these ${#ORPHANS[@]} orphaned directories? [y/N]: " CONFIRM
if [[ "${CONFIRM,,}" != "y" ]]; then
    info "Cancelled. Nothing was removed."
    exit 0
fi

# --- Remove ------------------------------------------------------------------
for orphan in "${ORPHANS[@]}"; do
    info "Removing /lib/modules/$orphan ..."
    rm -rf "/lib/modules/$orphan"
done

# --- Refresh bootloader ------------------------------------------------------
info "Refreshing bootloader..."
proxmox-boot-tool refresh

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} Cleanup complete. ${#ORPHANS[@]} orphaned directories removed.${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "Remaining kernels in /lib/modules:"
ls -lha /lib/modules/
