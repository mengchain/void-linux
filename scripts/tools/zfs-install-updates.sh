#!/bin/bash
# filepath: zfs-install-updates.sh
# ZFS/Kernel Update Installation with ZFSBootMenu Support
# Performs the actual package updates with safety measures

set -euo pipefail

# Configuration
CONFIG_FILE="/etc/zfs-update.conf"
LOG_FILE="/var/log/zfs-install-updates-$(date +%Y%m%d-%H%M%S).log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

success() {
    log "${GREEN}✓ $1${NC}"
}

warning() {
    log "${YELLOW}⚠ WARNING: $1${NC}"
}

error() {
    log "${RED}✗ ERROR: $1${NC}"
}

info() {
    log "${BLUE}ℹ INFO: $1${NC}"
}

header() {
    echo ""
    log "${BOLD}${CYAN}=========================================="
    log "$1"
    log "==========================================${NC}"
    echo ""
}

error_exit() {
    error "$1"
    log "Update failed. Check logs and consider running rollback script."
    cleanup
    exit 1
}

cleanup() {
    info "Performing cleanup operations..."
    # Re-import any exported pools
    zpool import -a 2>/dev/null || true
}

trap cleanup EXIT

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        error_exit "Configuration file not found. Run zfs-pre-checks.sh first."
    fi
    
    source "$CONFIG_FILE"
    
    if [ -z "${BACKUP_DIR:-}" ]; then
        error_exit "Invalid configuration. Run zfs-pre-checks.sh again."
    fi
    
    if [ "${UPDATES_AVAILABLE:-false}" != "true" ]; then
        info "No updates available according to pre-checks"
        exit 0
    fi
    
    # Set defaults for variables that might not exist
    ZFSBOOTMENU=${ZFSBOOTMENU:-false}
    POOLS_EXIST=${POOLS_EXIST:-false}
    TOTAL_UPDATES=${TOTAL_UPDATES:-0}
    ZFS_COUNT=${ZFS_COUNT:-0}
    DRACUT_COUNT=${DRACUT_COUNT:-0}
    KERNEL_COUNT=${KERNEL_COUNT:-0}
    FIRMWARE_COUNT=${FIRMWARE_COUNT:-0}
    DKMS_COUNT=${DKMS_COUNT:-0}
    DKMS_AVAILABLE=${DKMS_AVAILABLE:-false}
    
    info "Configuration loaded successfully"
    log "System type: $([ "$ZFSBOOTMENU" = true ] && echo "ZFSBootMenu" || echo "Traditional")"
    log "Updates to install: $TOTAL_UPDATES packages (ZFS: $ZFS_COUNT, Dracut: $DRACUT_COUNT, Kernel: $KERNEL_COUNT, Firmware: $FIRMWARE_COUNT, DKMS: $DKMS_COUNT)"
    log "Backup directory: $BACKUP_DIR"
}

check_prerequisites() {
    info "Checking prerequisites..."
    
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root"
    fi
    
    if [ ! -d "$BACKUP_DIR" ]; then
        error_exit "Backup directory not found. Run zfs-pre-checks.sh first."
    fi
    
    # Verify ZFS is still working (only if pools exist)
    if [ "$POOLS_EXIST" = "true" ]; then
        if ! zpool list >/dev/null 2>&1; then
            error_exit "Cannot access ZFS pools. Check ZFS status."
        fi
    fi
    
    # Check if another package manager is running
    if pgrep -f "xbps-install" >/dev/null 2>&1; then
        error_exit "Another xbps-install process is running. Wait for completion."
    fi
    
    success "Prerequisites check passed"
}

get_packages_to_install() {
    info "Getting current package lists for installation..."
    
    # Get list of ZFS packages to update (improved pattern matching)
    ZFS_PACKAGES=$(xbps-install -un 2>/dev/null | grep -E "^(zfs|zfsbootmenu)-" | awk '{print $1}' | tr '\n' ' ' || true)
    
    # Get list of dracut packages to update
    DRACUT_PACKAGES=$(xbps-install -un 2>/dev/null | grep -E "^dracut-" | awk '{print $1}' | tr '\n' ' ' || true)
    
    # Get list of kernel packages to update (improved pattern)
    KERNEL_PACKAGES=$(xbps-install -un 2>/dev/null | grep -E "^linux[0-9]+-[0-9]" | awk '{print $1}' | tr '\n' ' ' || true)
    
    # Get firmware packages
    FIRMWARE_PACKAGES=$(xbps-install -un 2>/dev/null | grep -E "^linux-firmware" | awk '{print $1}' | tr '\n' ' ' || true)
    
    # Get DKMS packages
    DKMS_PACKAGES=$(xbps-install -un 2>/dev/null | grep -E "^dkms" | awk '{print $1}' | tr '\n' ' ' || true)
    
    ALL_PACKAGES="$ZFS_PACKAGES $DRACUT_PACKAGES $KERNEL_PACKAGES $FIRMWARE_PACKAGES $DKMS_PACKAGES"
    
    # Trim whitespace
    ALL_PACKAGES=$(echo "$ALL_PACKAGES" | xargs)
    
    if [ -z "$ALL_PACKAGES" ]; then
        warning "No packages found for installation (packages may have been updated since pre-checks)"
        return 1
    fi
    
    info "Packages to install:"
    [ -n "$ZFS_PACKAGES" ] && log "  ZFS: $ZFS_PACKAGES"
    [ -n "$DRACUT_PACKAGES" ] && log "  Dracut: $DRACUT_PACKAGES"
    [ -n "$KERNEL_PACKAGES" ] && log "  Kernel: $KERNEL_PACKAGES"
    [ -n "$FIRMWARE_PACKAGES" ] && log "  Firmware: $FIRMWARE_PACKAGES"
    [ -n "$DKMS_PACKAGES" ] && log "  DKMS: $DKMS_PACKAGES"
    
    return 0
}

create_installation_snapshot() {
    if [ "$POOLS_EXIST" != "true" ]; then
        info "No ZFS pools - skipping installation snapshot"
        return 0
    fi
    
    info "Creating pre-installation snapshot for rollback protection..."
    
    INSTALL_SNAPSHOT_NAME="pre-install-$(date +%Y%m%d-%H%M%S)"
    INSTALL_SNAPSHOT_COUNT=0
    INSTALL_FAILED_COUNT=0
    
    # Create snapshots for all datasets before any changes
    for dataset in $(zfs list -H -o name -t filesystem,volume 2>/dev/null || true); do
        if zfs snapshot "${dataset}@${INSTALL_SNAPSHOT_NAME}" 2>/dev/null; then
            ((INSTALL_SNAPSHOT_COUNT++))
            log "Created installation snapshot: ${dataset}@${INSTALL_SNAPSHOT_NAME}"
        else
            ((INSTALL_FAILED_COUNT++))
            warning "Failed to create installation snapshot for $dataset"
        fi
    done
    
    if [ $INSTALL_SNAPSHOT_COUNT -gt 0 ]; then
        success "Created $INSTALL_SNAPSHOT_COUNT installation snapshots"
        
        # Save this snapshot name for rollback script
        echo "INSTALL_SNAPSHOT_NAME=\"$INSTALL_SNAPSHOT_NAME\"" >> "$CONFIG_FILE"
        echo "SNAPSHOT_NAME=\"$INSTALL_SNAPSHOT_NAME\"" >> "$CONFIG_FILE"
        
        info "Installation snapshot name saved for potential rollback"
    else
        warning "No installation snapshots created"
    fi
    
    if [ $INSTALL_FAILED_COUNT -gt 0 ]; then
        warning "$INSTALL_FAILED_COUNT installation snapshots failed to create"
    fi
}

export_single_pool() {
    local pool=$1
    local pool_type=${2:-regular}
    
    info "Exporting $pool_type pool: $pool"
    
    if zpool export "$pool" 2>/dev/null; then
        success "Exported $pool"
    else
        error "Failed to export $pool"
        
        # Enhanced diagnostics for ZBM
        if [ "$ZFSBOOTMENU" = true ] && [ "$pool_type" = "boot" ]; then
            warning "Pool export failure critical for ZFSBootMenu systems"
        fi
        
        show_pool_usage "$pool"
        error_exit "Cannot export pool $pool - it's in use. Stop processes and try again."
    fi
}

show_pool_usage() {
    local pool=$1
    info "Checking what's using pool $pool..."
    
    # Get all datasets in the pool
    POOL_DATASETS=$(zfs list -H -o name -r "$pool" 2>/dev/null || echo "$pool")
    
    for dataset in $POOL_DATASETS; do
        MOUNTPOINT=$(zfs get -H -o value mountpoint "$dataset" 2>/dev/null || echo "none")
        if [ "$MOUNTPOINT" != "none" ] && [ -d "$MOUNTPOINT" ]; then
            if command -v lsof >/dev/null 2>&1; then
                lsof +D "$MOUNTPOINT" 2>/dev/null | head -10 | tee -a "$LOG_FILE" || true
            fi
        fi
    done
}

export_zfs_pools() {
    # Skip if no pools exist
    if [ "$POOLS_EXIST" != "true" ]; then
        info "No ZFS pools to export"
        return 0
    fi
    
    info "Exporting ZFS pools for safe update..."
    
    ALL_POOLS=$(zpool list -H -o name 2>/dev/null || echo "")
    
    if [ -z "$ALL_POOLS" ]; then
        info "No ZFS pools found to export"
        return 0
    fi
    
    # For ZBM systems, handle boot pools specially
    if [ "$ZFSBOOTMENU" = true ]; then
        BOOT_POOLS=${BOOT_POOLS:-}
        ROOT_POOLS=""
        
        # Separate boot and root pools
        for pool in $ALL_POOLS; do
            if [[ " $BOOT_POOLS " == *" $pool "* ]]; then
                continue  # Skip boot pools for now
            else
                ROOT_POOLS="$ROOT_POOLS $pool"
            fi
        done
        
        # Export root pools first
        if [ -n "$(echo $ROOT_POOLS | xargs)" ]; then
            info "Exporting root pools first: $ROOT_POOLS"
            for pool in $ROOT_POOLS; do
                if [ -n "$pool" ]; then
                    export_single_pool "$pool" "root"
                fi
            done
        fi
        
        # Export boot pools last (more critical)
        if [ -n "$BOOT_POOLS" ]; then
            info "Exporting boot pools: $BOOT_POOLS"
            for pool in $BOOT_POOLS; do
                export_single_pool "$pool" "boot"
            done
        fi
    else
        # Traditional system - export all pools
        for pool in $ALL_POOLS; do
            export_single_pool "$pool" "regular"
        done
    fi
    
    # Save exported pools list
    echo "$ALL_POOLS" > "$BACKUP_DIR/exported-pools.txt"
    success "All pools exported successfully"
}

install_updates() {
    info "Installing ZFS and related updates..."
    
    # Update ZFS packages first
    if [ -n "${ZFS_PACKAGES:-}" ]; then
        info "Installing ZFS packages: $ZFS_PACKAGES"
        if xbps-install -y $ZFS_PACKAGES; then
            success "ZFS packages updated successfully"
        else
            error_exit "Failed to update ZFS packages"
        fi
    fi
    
    # Update DKMS packages if available
    if [ -n "${DKMS_PACKAGES:-}" ]; then
        info "Installing DKMS packages: $DKMS_PACKAGES"
        if xbps-install -y $DKMS_PACKAGES; then
            success "DKMS packages updated successfully"
        else
            warning "DKMS update failed - continuing anyway"
        fi
    fi
    
    # Update dracut packages
    if [ -n "${DRACUT_PACKAGES:-}" ]; then
        info "Installing dracut packages: $DRACUT_PACKAGES"
        if xbps-install -y $DRACUT_PACKAGES; then
            success "Dracut packages updated successfully"
        else
            error_exit "Failed to update dracut packages"
        fi
    fi
    
    # Update kernel packages
    KERNEL_UPDATED=false
    if [ -n "${KERNEL_PACKAGES:-}" ]; then
        info "Installing kernel packages: $KERNEL_PACKAGES"
        if xbps-install -y $KERNEL_PACKAGES; then
            success "Kernel packages updated successfully"
            KERNEL_UPDATED=true
        else
            error_exit "Failed to update kernel packages"
        fi
    fi
    
    # Update firmware packages
    if [ -n "${FIRMWARE_PACKAGES:-}" ]; then
        info "Installing firmware packages: $FIRMWARE_PACKAGES"
        if xbps-install -y $FIRMWARE_PACKAGES; then
            success "Firmware packages updated successfully"
        else
            warning "Firmware update failed - continuing anyway"
        fi
    fi
    
    # Save update status
    echo "KERNEL_UPDATED=$KERNEL_UPDATED" >> "$CONFIG_FILE"
    echo "DRACUT_UPDATED=$([ -n "${DRACUT_PACKAGES:-}" ] && echo "true" || echo "false")" >> "$CONFIG_FILE"
    echo "ZFS_UPDATED=$([ -n "${ZFS_PACKAGES:-}" ] && echo "true" || echo "false")" >> "$CONFIG_FILE"
    echo "DKMS_UPDATED=$([ -n "${DKMS_PACKAGES:-}" ] && echo "true" || echo "false")" >> "$CONFIG_FILE"
    
    success "Package installation completed"
}

rebuild_dkms_modules() {
    if [ "${DKMS_AVAILABLE:-false}" != "true" ]; then
        info "DKMS not available - skipping DKMS rebuild"
        return 0
    fi
    
    if [ "${KERNEL_UPDATED:-false}" = "true" ] || [ "${ZFS_UPDATED:-false}" = "true" ] || [ "${DKMS_UPDATED:-false}" = "true" ]; then
        info "Rebuilding DKMS modules for ZFS..."
        
        LATEST_KERNEL=$(ls /lib/modules 2>/dev/null | sort -V | tail -1)
        
        if [ -n "$LATEST_KERNEL" ]; then
            info "Building DKMS modules for kernel: $LATEST_KERNEL"
            
            # Remove old ZFS DKMS modules
            dkms remove zfs --all 2>/dev/null || true
            
            # Add and build ZFS modules for the new kernel
            if dkms add zfs && dkms build zfs && dkms install zfs; then
                success "DKMS ZFS modules rebuilt successfully"
            else
                error_exit "Failed to rebuild DKMS ZFS modules"
            fi
        else
            warning "Cannot determine latest kernel for DKMS rebuild"
        fi
    else
        info "No updates requiring DKMS rebuild"
    fi
}

rebuild_initramfs() {
    # Rebuild if kernel was updated OR if ZFS/dracut was updated
    if [ "${KERNEL_UPDATED:-false}" = "true" ] || [ "${ZFS_UPDATED:-false}" = "true" ] || [ "${DRACUT_UPDATED:-false}" = "true" ]; then
        
        if [ "${KERNEL_UPDATED:-false}" = "true" ]; then
            info "Rebuilding initramfs for updated kernel..."
        elif [ "${ZFS_UPDATED:-false}" = "true" ]; then
            info "Rebuilding initramfs for updated ZFS modules..."
        else
            info "Rebuilding initramfs for updated dracut..."
        fi
        
        LATEST_KERNEL=$(ls /lib/modules 2>/dev/null | sort -V | tail -1)
        
        if [ -z "$LATEST_KERNEL" ]; then
            error_exit "Cannot find kernel modules directory"
        fi
        
        info "Rebuilding initramfs for kernel: $LATEST_KERNEL"
        
        # Enhanced dracut for ZBM systems
        if [ "$ZFSBOOTMENU" = true ]; then
            info "Building initramfs with ZFSBootMenu optimizations..."
            
            # ZBM-specific dracut options
            DRACUT_ARGS="-f --kver $LATEST_KERNEL"
            DRACUT_ARGS="$DRACUT_ARGS --add zfs"
            
            # Only add systemd omit if not already configured otherwise
            if ! grep -q "omit_dracutmodules" /etc/dracut.conf* 2>/dev/null; then
                DRACUT_ARGS="$DRACUT_ARGS --omit systemd"
            fi
            
            if dracut $DRACUT_ARGS; then
                success "Initramfs rebuilt for ZFSBootMenu"
            else
                error_exit "Failed to rebuild initramfs for ZFSBootMenu"
            fi
        else
            # Traditional dracut
            if dracut -f --kver "$LATEST_KERNEL"; then
                success "Initramfs rebuilt successfully"
            else
                error_exit "Failed to rebuild initramfs"
            fi
        fi
    else
        info "No kernel, ZFS, or dracut updates - skipping initramfs rebuild"
    fi
}

import_single_pool() {
    local pool=$1
    local pool_type=${2:-regular}
    
    info "Importing $pool_type pool: $pool"
    
    if zpool import "$pool" 2>/dev/null; then
        success "Imported $pool"
    else
        error "Failed to import $pool"
        
        info "Available pools for import:"
        zpool import 2>&1 | tee -a "$LOG_FILE" || true
        
        # Try force import for critical boot pools
        if [ "$pool_type" = "boot" ] && [ "$ZFSBOOTMENU" = true ]; then
            warning "Attempting force import of boot pool $pool"
            if zpool import -f "$pool" 2>/dev/null; then
                warning "Force import of boot pool $pool succeeded"
            else
                error_exit "Critical: Cannot import boot pool $pool - ZFSBootMenu may not work"
            fi
        else
            error_exit "Pool import failed. Check 'zpool import' output above."
        fi
    fi
}

reimport_zfs_pools() {
    # Skip if no pools exist
    if [ "$POOLS_EXIST" != "true" ]; then
        info "No ZFS pools to re-import"
        return 0
    fi
    
    info "Re-importing ZFS pools..."
    
    if [ ! -f "$BACKUP_DIR/exported-pools.txt" ]; then
        info "No pools were exported"
        return 0
    fi
    
    EXPORTED_POOLS=$(cat "$BACKUP_DIR/exported-pools.txt")
    
    if [ "$ZFSBOOTMENU" = true ]; then
        # Import boot pools first for ZBM systems
        BOOT_POOLS=${BOOT_POOLS:-}
        
        if [ -n "$BOOT_POOLS" ]; then
            info "Re-importing boot pools first for ZFSBootMenu..."
            for pool in $BOOT_POOLS; do
                import_single_pool "$pool" "boot"
            done
        fi
        
        # Then import other pools
        for pool in $EXPORTED_POOLS; do
            if [[ " $BOOT_POOLS " != *" $pool "* ]]; then
                import_single_pool "$pool" "root"
            fi
        done
    else
        # Traditional import order
        for pool in $EXPORTED_POOLS; do
            import_single_pool "$pool" "regular"
        done
    fi
    
    success "All pools re-imported successfully"
}

update_zfsbootmenu() {
    if [ "$ZFSBOOTMENU" != true ]; then
        info "Not a ZFSBootMenu system - skipping ZBM update"
        return 0
    fi
    
    if [ "${KERNEL_UPDATED:-false}" != "true" ] && [ "${ZFS_UPDATED:-false}" != "true" ]; then
        info "No kernel or ZFS update - skipping ZFSBootMenu regeneration"
        return 0
    fi
    
    info "Updating ZFSBootMenu for updated components..."
    
    # Check if zfsbootmenu command is available
    if ! command -v zfsbootmenu >/dev/null 2>&1; then
        warning "ZFSBootMenu command not found - manual update may be required"
        return 0
    fi
    
    # Generate new ZBM image
    info "Generating new ZFSBootMenu EFI image..."
    
    if zfsbootmenu -g; then
        success "ZFSBootMenu image generated successfully"
    else
        error "Failed to generate ZFSBootMenu image"
        
        # Try manual generation if config exists
        ZBM_CONFIG_FILE=${ZBM_CONFIG:-/etc/zfsbootmenu/config.yaml}
        if [ -f "$ZBM_CONFIG_FILE" ]; then
            warning "Attempting manual ZFSBootMenu generation..."
            if zfsbootmenu -c "$ZBM_CONFIG_FILE" -g; then
                success "Manual ZFSBootMenu generation succeeded"
            else
                error_exit "ZFSBootMenu generation failed - boot may be broken"
            fi
        else
            error_exit "ZFSBootMenu generation failed and no config found"
        fi
    fi
    
    # Verify EFI image was created/updated
    if [ -n "${ESP_MOUNT:-}" ] && [ -n "${ZBM_EFI_PATH:-}" ]; then
        if [ -f "$ZBM_EFI_PATH" ]; then
            ZBM_SIZE=$(stat -c%s "$ZBM_EFI_PATH" 2>/dev/null || stat -f --format="%s" "$ZBM_EFI_PATH" 2>/dev/null)
            if [ "${ZBM_SIZE:-0}" -gt 1000000 ]; then  # > 1MB indicates valid EFI image
                success "ZFSBootMenu EFI image appears valid (${ZBM_SIZE} bytes)"
            else
                warning "ZFSBootMenu EFI image seems too small (${ZBM_SIZE} bytes)"
            fi
        else
            error "ZFSBootMenu EFI image not found at expected location: $ZBM_EFI_PATH"
        fi
    fi
}

update_bootloader() {
    if [ "$ZFSBOOTMENU" = true ]; then
        update_zfsbootmenu
    else
        # Traditional bootloader update (GRUB)
        if [ "${KERNEL_UPDATED:-false}" = "true" ]; then
            info "Updating GRUB configuration..."
            
            if command -v update-grub >/dev/null 2>&1; then
                if update-grub; then
                    success "GRUB configuration updated"
                else
                    warning "GRUB update failed - you may need to update manually"
                fi
            elif command -v grub-mkconfig >/dev/null 2>&1; then
                if grub-mkconfig -o /boot/grub/grub.cfg; then
                    success "GRUB configuration updated"
                else
                    warning "GRUB update failed - you may need to update manually"
                fi
            else
                warning "No GRUB update command found"
            fi
        else
            info "No kernel update - skipping bootloader update"
        fi
    fi
}

verify_basic_functionality() {
    info "Performing basic ZFS functionality verification..."
    
    # Check if ZFS module is loaded
    if lsmod | grep -q zfs; then
        success "ZFS module is loaded"
    else
        error_exit "ZFS module is not loaded after update"
    fi
    
    # Check pool status (only if pools exist)
    if [ "$POOLS_EXIST" = "true" ]; then
        if zpool status >/dev/null 2>&1; then
            success "ZFS pools are accessible"
            
            # Quick health check
            if zpool status | grep -E "(DEGRADED|FAULTED|OFFLINE|UNAVAIL)"; then
                error "Pool errors detected after update!"
                zpool status -v | tee -a "$LOG_FILE"
                error_exit "Pool errors found - check status above"
            else
                success "All pools appear healthy"
            fi
        else
            error_exit "Cannot access ZFS pools after update"
        fi
    else
        info "No ZFS pools to verify"
    fi
    
    # Verify package versions match
    info "Verifying updated package versions..."
    CURRENT_ZFS=$(modinfo zfs 2>/dev/null | grep -E "^version:" | awk '{print $2}' || echo "unknown")
    ZFS_USERLAND=$(zfs version 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
    
    log "Updated ZFS kernel module: $CURRENT_ZFS"
    log "Updated ZFS userland: $ZFS_USERLAND"
    
    if [ "$CURRENT_ZFS" != "unknown" ] && [ "$ZFS_USERLAND" != "unknown" ]; then
        if [ "$CURRENT_ZFS" = "$ZFS_USERLAND" ]; then
            success "ZFS kernel and userland versions match after update"
        else
            warning "ZFS version mismatch after update: kernel=$CURRENT_ZFS, userland=$ZFS_USERLAND"
        fi
    fi
    
    success "Basic functionality verification passed"
}

main() {
    header "ZFS UPDATE INSTALLATION"
    
    log "Starting ZFS/kernel update installation..."
    
    load_config
    check_prerequisites
    
    if ! get_packages_to_install; then
        success "No packages need updating. System may have been updated since pre-checks."
        exit 0
    fi
    
    # Enhanced confirmation for ZBM systems
    header "READY TO INSTALL UPDATES"
    
    echo "System type: $([ "$ZFSBOOTMENU" = true ] && echo "ZFSBootMenu" || echo "Traditional")"
    echo "Packages to update: $ALL_PACKAGES"
    echo ""
    echo "This will:"
    if [ "$POOLS_EXIST" = "true" ]; then
        echo "1. Create installation snapshots"
        echo "2. Export all ZFS pools"
    else
        echo "1. Skip pool operations (no pools detected)"
    fi
    echo "3. Update ZFS, dracut, and kernel packages"
    if [ "${DKMS_AVAILABLE:-false}" = "true" ]; then
        echo "4. Rebuild DKMS modules if needed"
    fi
    echo "5. Rebuild initramfs if needed"
    if [ "$ZFSBOOTMENU" = true ]; then
        echo "6. Update ZFSBootMenu EFI image"
    else
        echo "6. Update bootloader configuration"
    fi
    if [ "$POOLS_EXIST" = "true" ]; then
        echo "7. Re-import ZFS pools"
    fi
    echo ""
    read -p "Continue with installation? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Installation cancelled by user"
        exit 0
    fi
    
    # Execute installation steps
    create_installation_snapshot
    export_zfs_pools
    install_updates
    rebuild_dkms_modules
    rebuild_initramfs
    reimport_zfs_pools
    update_bootloader
    verify_basic_functionality
    
    header "INSTALLATION COMPLETED"
    
    success "ZFS/kernel updates installed successfully!"
    
    echo "System type: $([ "$ZFSBOOTMENU" = true ] && echo "ZFSBootMenu" || echo "Traditional")"
    
    if [ "${KERNEL_UPDATED:-false}" = "true" ]; then
        echo -e "${YELLOW}⚠ REBOOT REQUIRED${NC} - Kernel was updated"
        if [ "$ZFSBOOTMENU" = true ]; then
            echo -e "${BLUE}ℹ ZFSBootMenu EFI image updated${NC}"
        fi
        echo ""
        echo "Next steps:"
        echo "1. Reboot the system"
        echo "2. Run: zfs-post-update-verify.sh"
        echo "3. Then run: xbps-install -u (for other packages)"
    else
        echo -e "${GREEN}✓ No reboot required${NC}"
        echo ""
        echo "Next steps:"
        echo "1. Run: zfs-post-update-verify.sh"
        echo "2. Then run: xbps-install -u (for other packages)"
    fi
    
    echo ""
    echo "Log file: $LOG_FILE"
    echo "Backup: $BACKUP_DIR"
    
    # Save final status
    echo "INSTALLATION_COMPLETED=true" >> "$CONFIG_FILE"
    echo "INSTALLATION_DATE=\"$(date)\"" >> "$CONFIG_FILE"
    
    log "Installation completed successfully"
}

main "$@"
