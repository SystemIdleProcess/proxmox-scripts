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

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; DIM='\033[2m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
detail() { echo -e "        ${DIM}$*${NC}"; }

[[ $EUID -eq 0 ]] || error "Please run as root: sudo bash $0"

APT_HOOK_FILE="/etc/apt/apt.conf.d/99-auto-proxmox-headers"
CURRENT_KERNEL="$(uname -r)"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║           DKMS Auto-Rebuild Fix for Proxmox VE           ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
info "Running kernel: $CURRENT_KERNEL"
info "Hostname:       $(hostname)"
info "Proxmox VE:     $(pveversion 2>/dev/null | awk '{print $2}' || echo 'unknown')"
echo ""

# =============================================================================
# STEP 1: Diagnose current state
# =============================================================================
echo -e "${CYAN}── Step 1/5: Diagnosing current system state ──${NC}"
echo ""

# Check existing apt hook
if [[ -f "$APT_HOOK_FILE" ]]; then
    if grep -q 'dkms autoinstall' "$APT_HOOK_FILE"; then
        info "Existing apt hook found WITH dkms autoinstall — will update to latest version."
    else
        warn "Existing apt hook found but WITHOUT dkms autoinstall — this is the bug."
        detail "The hook installs headers but doesn't trigger DKMS to rebuild."
        detail "DKMS's own hook runs BEFORE headers exist, so rebuilds silently fail."
    fi
else
    warn "No apt hook found — headers are not auto-installed on kernel upgrades."
    detail "Without headers, DKMS cannot compile drivers for new kernels."
fi

# Check DKMS post-install hook
if [[ -x /etc/kernel/postinst.d/dkms ]]; then
    info "DKMS kernel post-install hook exists."
    if [[ -x /usr/lib/dkms/dkms_autoinstaller ]]; then
        if grep -q 'build/include' /usr/lib/dkms/dkms_autoinstaller; then
            detail "The autoinstaller checks for headers in /lib/modules/<ver>/build/include"
            detail "If headers aren't installed yet when it runs, it silently skips."
            detail "This is the root cause of the timing bug this script fixes."
        fi
    else
        warn "dkms_autoinstaller not found — DKMS auto-rebuild is completely broken."
    fi
else
    warn "DKMS kernel post-install hook missing — DKMS never runs on kernel install."
fi
echo ""

# =============================================================================
# Confirmation prompt
# =============================================================================
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
echo ""
echo "This script will:"
echo "  1. Install/update an apt hook to auto-install headers and trigger"
echo "     DKMS rebuilds on kernel upgrades"
echo "  2. Fix any DKMS modules missing the AUTOINSTALL flag"
echo "  3. Install missing kernel headers for all installed kernels"
echo "  4. Build any missing DKMS modules for all installed kernels"
echo "  5. Update initramfs for any kernels that were rebuilt"
echo ""
read -rp "Proceed? [y/N]: " CONFIRM
if [[ "${CONFIRM,,}" != "y" ]]; then
    info "Cancelled. No changes were made."
    exit 0
fi
echo ""

# =============================================================================
# STEP 2: Install the apt hook
# =============================================================================
echo -e "${CYAN}── Step 2/5: Installing corrected apt hook ──${NC}"
echo ""

cat > "$APT_HOOK_FILE" << 'EOF'
Dpkg::Post-Invoke {
    "for kver in $(dpkg -l 'proxmox-kernel-*' 2>/dev/null | awk '/^ii/{print $2}' | grep -v 'headers\\|dbgsym' | sed 's/proxmox-kernel-//'); do apt-get install -y proxmox-headers-$kver 2>/dev/null || true; if [ -d /lib/modules/$kver/build/include ]; then dkms autoinstall --kernelver $kver 2>/dev/null || true; fi; done";
};
EOF

info "apt hook written to $APT_HOOK_FILE"
detail "On future 'apt upgrade' runs:"
detail "  1. All Proxmox kernel packages are detected"
detail "  2. Matching headers are installed for each"
detail "  3. 'dkms autoinstall' is triggered AFTER headers are ready"
detail "  4. All registered DKMS modules are rebuilt for the new kernel"
echo ""

# =============================================================================
# STEP 3: Fix any DKMS modules missing AUTOINSTALL
# =============================================================================
echo -e "${CYAN}── Step 3/5: Checking DKMS module configurations ──${NC}"
echo ""

FIXED_COUNT=0
TOTAL_MODULES=0
for conf in /usr/src/*/dkms.conf; do
    [[ -f "$conf" ]] || continue
    TOTAL_MODULES=$((TOTAL_MODULES + 1))
    MODULE_DIR="$(dirname "$conf")"
    MODULE_NAME="$(basename "$MODULE_DIR")"

    if grep -qi 'AUTOINSTALL.*yes' "$conf"; then
        echo -e "  ${GREEN}✔${NC} $MODULE_NAME — AUTOINSTALL=yes"
    elif grep -qi 'AUTOINSTALL' "$conf"; then
        warn "  $MODULE_NAME — AUTOINSTALL present but not set to 'yes', fixing..."
        sed -i '/AUTOINSTALL/d' "$conf"
        echo 'AUTOINSTALL="yes"' >> "$conf"
        FIXED_COUNT=$((FIXED_COUNT + 1))
    else
        warn "  $MODULE_NAME — AUTOINSTALL missing, adding..."
        detail "'dkms autoinstall' ignores modules without this flag."
        echo 'AUTOINSTALL="yes"' >> "$conf"
        FIXED_COUNT=$((FIXED_COUNT + 1))
    fi
done

if [[ $TOTAL_MODULES -eq 0 ]]; then
    warn "No DKMS modules found in /usr/src/. Nothing to rebuild."
else
    if [[ $FIXED_COUNT -eq 0 ]]; then
        info "All $TOTAL_MODULES module(s) correctly configured."
    else
        info "Fixed $FIXED_COUNT of $TOTAL_MODULES module(s)."
    fi
fi
echo ""

# =============================================================================
# STEP 4: Ensure headers are present for all installed kernels
# =============================================================================
echo -e "${CYAN}── Step 4/5: Checking kernel headers ──${NC}"
echo ""

mapfile -t INSTALLED_KERNELS < <(
    dpkg --list 2>/dev/null \
    | grep -E '(proxmox-kernel|pve-kernel)-[0-9].*-pve' \
    | grep '^ii' \
    | awk '{print $2}' \
    | sed -E 's/(proxmox-kernel|pve-kernel)-//; s/-(signed|dbgsym)//' \
    | sort -uV
)

info "Found ${#INSTALLED_KERNELS[@]} installed kernel(s):"
HEADERS_INSTALLED=0
for kver in "${INSTALLED_KERNELS[@]}"; do
    MARKER=""
    [[ "$kver" == "$CURRENT_KERNEL" ]] && MARKER=" (running)"

    HEADERS_PKG="proxmox-headers-${kver}"
    if dpkg -l "$HEADERS_PKG" 2>/dev/null | grep -q '^ii'; then
        echo -e "  ${GREEN}✔${NC} $kver$MARKER — headers present"
    else
        warn "  $kver$MARKER — headers missing, installing..."
        if apt-get install -y "$HEADERS_PKG" 2>/dev/null; then
            info "    Installed $HEADERS_PKG"
            HEADERS_INSTALLED=$((HEADERS_INSTALLED + 1))
        else
            warn "    Could not install $HEADERS_PKG — DKMS build will be skipped for this kernel."
        fi
    fi
done

if [[ $HEADERS_INSTALLED -gt 0 ]]; then
    info "Installed headers for $HEADERS_INSTALLED kernel(s)."
fi
echo ""

# =============================================================================
# STEP 5: Build DKMS modules for any kernel that's missing them
# =============================================================================
echo -e "${CYAN}── Step 5/5: Building missing DKMS modules ──${NC}"
echo ""

# First, show what DKMS modules are registered
ALL_MODULES=$(dkms status 2>/dev/null | awk -F',' '{print $1}' | sort -u)
if [[ -n "$ALL_MODULES" ]]; then
    info "Registered DKMS modules:"
    while IFS= read -r mod; do
        echo -e "  • $mod"
    done <<< "$ALL_MODULES"
    echo ""
else
    warn "No DKMS modules registered. Nothing to build."
    echo ""
fi

REBUILDS_NEEDED=false
TOTAL_REBUILT=0
for kver in "${INSTALLED_KERNELS[@]}"; do
    MARKER=""
    [[ "$kver" == "$CURRENT_KERNEL" ]] && MARKER=" (running)"

    # Skip if no headers (can't build)
    if [[ ! -d "/lib/modules/$kver/build/include" ]]; then
        warn "$kver$MARKER — no headers, skipping."
        continue
    fi

    # Get list of DKMS modules that are registered but not installed for this kernel
    MISSING_MODULES=()
    while IFS= read -r line; do
        MODULE_SLUG=$(echo "$line" | awk -F',' '{print $1}' | xargs)
        STATUS=$(echo "$line" | awk -F': ' '{print $NF}' | xargs)

        if [[ "$STATUS" != "installed" && "$STATUS" != "installed"* ]]; then
            MISSING_MODULES+=("$MODULE_SLUG")
        fi
    done < <(dkms status -k "$kver" 2>/dev/null)

    # Also check for modules registered but with no entry at all for this kernel
    while IFS= read -r line; do
        MODULE_SLUG=$(echo "$line" | awk -F',' '{print $1}' | xargs)
        if ! dkms status "$MODULE_SLUG" -k "$kver" 2>/dev/null | grep -q "installed"; then
            if [[ ! " ${MISSING_MODULES[*]:-} " =~ " $MODULE_SLUG " ]]; then
                MISSING_MODULES+=("$MODULE_SLUG")
            fi
        fi
    done < <(dkms status 2>/dev/null | awk -F',' '{print $1}' | sort -u)

    if [[ ${#MISSING_MODULES[@]} -gt 0 ]]; then
        REBUILDS_NEEDED=true
        for mod in "${MISSING_MODULES[@]}"; do
            warn "$kver$MARKER — $mod not installed, building..."
            if dkms install "$mod" -k "$kver" --force 2>&1 | tee /tmp/dkms-build-$$.log | tail -5; then
                if dkms status "$mod" -k "$kver" 2>/dev/null | grep -q "installed"; then
                    info "  $mod built and installed successfully for $kver"
                    TOTAL_REBUILT=$((TOTAL_REBUILT + 1))
                else
                    warn "  $mod build may have failed — check: dkms status"
                    detail "Build log: /tmp/dkms-build-$$.log"
                fi
            else
                warn "  $mod build failed for $kver"
                detail "Build log: /tmp/dkms-build-$$.log"
            fi
        done
        info "Updating initramfs for $kver ..."
        update-initramfs -u -k "$kver" 2>&1 | grep -v "^$" | head -5
        echo ""
    else
        echo -e "  ${GREEN}✔${NC} $kver$MARKER — all DKMS modules installed"
    fi
done

echo ""

# =============================================================================
# Summary
# =============================================================================
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                         Summary                          ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

echo "  Running kernel:  $CURRENT_KERNEL"
echo "  Hostname:        $(hostname)"
echo ""

echo "  apt hook:"
if [[ -f "$APT_HOOK_FILE" ]]; then
    echo -e "    ${GREEN}✔ Active${NC} — headers + DKMS autoinstall on kernel upgrades"
else
    echo -e "    ${RED}✘ Not found${NC}"
fi
echo ""

echo "  DKMS modules:"
echo "  ─────────────────────────────────────────────────"
dkms status 2>/dev/null | while IFS= read -r line; do
    if echo "$line" | grep -q "installed"; then
        echo -e "    ${GREEN}✔${NC} $line"
    elif echo "$line" | grep -q "added"; then
        echo -e "    ${YELLOW}○${NC} $line  ${DIM}(registered but not built)${NC}"
    else
        echo -e "    ${RED}✘${NC} $line"
    fi
done
echo ""

if [[ "$REBUILDS_NEEDED" == true ]]; then
    echo -e "  ${GREEN}Completed $TOTAL_REBUILT DKMS build(s) across missing kernels.${NC}"
    echo ""
fi

echo "  What was done:"
echo "    • Installed apt hook to auto-install headers on kernel upgrades"
echo "    • apt hook triggers 'dkms autoinstall' AFTER headers are ready"
if [[ $FIXED_COUNT -gt 0 ]]; then
    echo "    • Fixed AUTOINSTALL flag on $FIXED_COUNT DKMS module(s)"
fi
if [[ $HEADERS_INSTALLED -gt 0 ]]; then
    echo "    • Installed missing headers for $HEADERS_INSTALLED kernel(s)"
fi
if [[ $TOTAL_REBUILT -gt 0 ]]; then
    echo "    • Completed $TOTAL_REBUILT DKMS build(s) for missing kernels"
fi
echo ""
echo "  Going forward, 'apt full-upgrade' will automatically handle"
echo "  headers + DKMS rebuilds for all registered drivers."
echo ""
