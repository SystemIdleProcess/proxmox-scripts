#!/bin/bash
# =============================================================================
# r8152-setup.sh
# Pulls latest Realtek r8152 driver from GitHub, registers it with DKMS,
# and builds it for a target kernel — so you can reboot into it ready to go.
#
# Run this while booted into a working kernel WITH network access.
# Usage: sudo bash r8152-setup.sh
# =============================================================================

set -euo pipefail

# --- Colors for output -------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Must be root ------------------------------------------------------------
[[ $EUID -eq 0 ]] || error "Please run as root: sudo bash $0"

# --- Config ------------------------------------------------------------------
REPO_URL="https://github.com/wget/realtek-r8152-linux"
SRC_DIR="/usr/src/r8152-realtek"
DKMS_NAME="r8152-realtek"

# =============================================================================
# STEP 1: Detect driver version from the repo
# =============================================================================
info "Fetching latest driver version from GitHub..."
DRIVER_VERSION=$(curl -fsSL "https://api.github.com/repos/wget/realtek-r8152-linux/releases/latest" \
    | grep '"tag_name"' \
    | sed 's/.*"v\([^"]*\)".*/\1/')

[[ -n "$DRIVER_VERSION" ]] || error "Could not detect driver version from GitHub. Check your network."
info "Latest driver version: $DRIVER_VERSION"

# =============================================================================
# STEP 2: Ask which kernel to target
# =============================================================================
echo ""
echo "Available installed kernels:"
echo "-----------------------------"
mapfile -t KERNELS < <(ls /lib/modules/)
for i in "${!KERNELS[@]}"; do
    TAGS=""
    [[ "${KERNELS[$i]}" == "$(uname -r)" ]] && TAGS+=" (current)"
    # Check if r8152 driver is already built for this kernel
    if find "/lib/modules/${KERNELS[$i]}" -name "r8152.ko*" 2>/dev/null | grep -q .; then
        TAGS+=" ${GREEN}[r8152 installed]${NC}"
    else
        TAGS+=" ${RED}[r8152 missing]${NC}"
    fi
    printf "  %d) %s" $((i + 1)) "${KERNELS[$i]}"
    echo -e "$TAGS"
done
echo ""

read -rp "Enter a number or kernel version, or press Enter for current [$(uname -r)]: " SELECTION
SELECTION="${SELECTION:-$(uname -r)}"

# If they entered a number, map it to the kernel name
if [[ "$SELECTION" =~ ^[0-9]+$ ]]; then
    IDX=$((SELECTION - 1))
    [[ $IDX -ge 0 && $IDX -lt ${#KERNELS[@]} ]] || error "Invalid selection: $SELECTION. Pick 1-${#KERNELS[@]}."
    TARGET_KERNEL="${KERNELS[$IDX]}"
else
    TARGET_KERNEL="$SELECTION"
fi

# Validate the kernel exists
[[ -d "/lib/modules/$TARGET_KERNEL" ]] || error "Kernel $TARGET_KERNEL not found in /lib/modules/. Is it installed?"
info "Target kernel: $TARGET_KERNEL"

# =============================================================================
# STEP 3: Install dependencies
# =============================================================================
info "Installing build dependencies..."
apt-get install -y build-essential dkms git

# Install headers for target kernel
HEADERS_PKG="proxmox-headers-${TARGET_KERNEL}"
info "Installing kernel headers: $HEADERS_PKG"
apt-get install -y "$HEADERS_PKG" || {
    warn "Could not install $HEADERS_PKG via apt."
    warn "If headers are already present at /usr/src/linux-headers-${TARGET_KERNEL}, continuing anyway."
    [[ -d "/usr/src/linux-headers-${TARGET_KERNEL}" ]] || \
    [[ -d "/lib/modules/${TARGET_KERNEL}/build" ]] || \
        error "No headers found for $TARGET_KERNEL. Cannot build the module."
}

# =============================================================================
# STEP 4: Pull latest driver source
# =============================================================================
info "Cloning driver source from $REPO_URL ..."

FULL_SRC_DIR="${SRC_DIR}-${DRIVER_VERSION}"

if [[ -d "$FULL_SRC_DIR" ]]; then
    warn "Source directory $FULL_SRC_DIR already exists. Removing and re-cloning."
    # Remove from DKMS first if registered, to avoid conflicts
    dkms remove "${DKMS_NAME}/${DRIVER_VERSION}" --all 2>/dev/null || true
    rm -rf "$FULL_SRC_DIR"
fi

git clone "$REPO_URL" "$FULL_SRC_DIR"

# Create symlink without version suffix (some DKMS setups prefer this)
[[ -L "$SRC_DIR" ]] && rm "$SRC_DIR"
ln -sfn "$FULL_SRC_DIR" "$SRC_DIR"

# =============================================================================
# STEP 5: Write dkms.conf
# =============================================================================
info "Writing dkms.conf..."
cat > "${FULL_SRC_DIR}/dkms.conf" << EOF
PACKAGE_NAME="${DKMS_NAME}"
PACKAGE_VERSION="${DRIVER_VERSION}"
BUILT_MODULE_NAME[0]="r8152"
DEST_MODULE_LOCATION[0]="/kernel/drivers/net/usb/"
AUTOINSTALL="yes"
EOF

cat "${FULL_SRC_DIR}/dkms.conf"

# =============================================================================
# STEP 6: Install udev rules
# =============================================================================
info "Installing udev rules..."
install --group=root --owner=root --mode=0644 \
    "${FULL_SRC_DIR}/50-usb-realtek-net.rules" /etc/udev/rules.d/
udevadm control --reload-rules
udevadm trigger

# =============================================================================
# STEP 7: Register, build, and install with DKMS
# =============================================================================
info "Registering with DKMS..."
dkms add "$FULL_SRC_DIR"

info "Building driver for kernel $TARGET_KERNEL ..."
dkms build "${DKMS_NAME}/${DRIVER_VERSION}" -k "$TARGET_KERNEL"

info "Installing driver for kernel $TARGET_KERNEL ..."
dkms install "${DKMS_NAME}/${DRIVER_VERSION}" -k "$TARGET_KERNEL" --force

# =============================================================================
# STEP 8: Update initramfs for target kernel
# =============================================================================
info "Updating initramfs for $TARGET_KERNEL ..."
update-initramfs -u -k "$TARGET_KERNEL"

# =============================================================================
# STEP 9: Ensure apt auto-installs headers for future kernel upgrades
# =============================================================================
APT_HOOK_FILE="/etc/apt/apt.conf.d/99-auto-proxmox-headers"

if [[ -f "$APT_HOOK_FILE" ]]; then
    info "apt header hook found — updating to latest version..."
fi
info "Installing apt hook to auto-install headers and rebuild DKMS modules..."
cat > "$APT_HOOK_FILE" << 'EOF'
Dpkg::Post-Invoke {
    "for kver in $(dpkg -l 'proxmox-kernel-*' 2>/dev/null | awk '/^ii/{print $2}' | grep -v 'headers\\|dbgsym' | sed 's/proxmox-kernel-//'); do apt-get install -y proxmox-headers-$kver 2>/dev/null || true; if [ -d /lib/modules/$kver/build/include ]; then dkms autoinstall --kernelver $kver 2>/dev/null || true; fi; done";
};
EOF
info "apt hook installed at $APT_HOOK_FILE"
info "Headers will be auto-installed and DKMS modules auto-rebuilt on kernel upgrades."

# =============================================================================
# Done!
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} All done!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
dkms status
echo ""
echo "apt header hook:"
if [[ -f "$APT_HOOK_FILE" ]]; then
    echo -e "  ${GREEN}✔ Active${NC} ($APT_HOOK_FILE)"
else
    echo -e "  ${RED}✘ Not found${NC} ($APT_HOOK_FILE)"
fi
echo ""

if [[ "$TARGET_KERNEL" == "$(uname -r)" ]]; then
    info "Built for current kernel. Loading module now..."
    modprobe -r cdc_ncm cdc_ether r8152 2>/dev/null || true
    modprobe r8152
    modinfo r8152 | grep -E 'version|filename'
    info "Driver loaded. You're good to go."
else
    info "Driver is built and ready for kernel $TARGET_KERNEL."
    info "You can now reboot into that kernel — the driver will load automatically."
    echo ""
    read -rp "Reboot now? [y/N]: " DO_REBOOT
    if [[ "${DO_REBOOT,,}" == "y" ]]; then
        info "Rebooting..."
        reboot
    else
        info "Reboot skipped. Run 'reboot' when ready."
    fi
fi
