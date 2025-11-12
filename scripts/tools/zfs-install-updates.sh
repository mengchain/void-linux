#!/bin/bash
# filepath: zfs-install-updates.sh
# ZFS/Kernel Update Installation with ZFSBootMenu Support
# Performs the actual package updates with safety measures

set -euo pipefail

# Configuration
CONFIG_FILE="/etc/zfs-update.conf"
LOG_FILE="/var/log/zfs-install-updates-$(date +%Y%m%d-%H%M%S).log"

# Global variables for package tracking
ZFS_PACKAGES=""
DRACUT_PACKAGES=""
KERNEL_PACKAGES=""
FIRMWARE_PACKAGES=""
ALL_PACKAGES=""
KERNEL_UPDATED=false
ZFS_UPDATED=false
DRACUT_UPDATED=false

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
    ZBM_COUNT=${ZBM_COUNT:-0}
    DRACUT_COUNT=${DRACUT_COUNT:-0}
    KERNEL_COUNT=${KERNEL_COUNT:-0}
    FIRMWARE_COUNT=${FIRMWARE_COUNT:-0}
    
    info "Configuration loaded successfully"
    log "System type: $([ "$ZFSBOOTMENU" = true ] && echo "ZFSBootMenu" || echo "Traditional")"
    log "Updates to install: $TOTAL_UPDATES packages (ZFS: $ZFS_COUNT, ZBM: $ZBM_COUNT, Dracut: $DRACUT_COUNT, Kernel: $KERNEL_COUNT, Firmware: $FIRMWARE_COUNT)"
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
    
    local zfs_packages dracut_packages kernel_packages firmware_packages all_packages
    
    # Get list of ZFS packages to update - match patterns from Script 1
    zfs_packages=$(xbps-install -un 2>/dev/null | grep -E "^zfs-[0-9]" | awk '{print $1}' | tr '\n' ' ' || true)
    
    # Check for ZFSBootMenu packages - try multiple patterns like Script 1
    local zbm_packages
    zbm_packages=$(xbps-install -un 2>/dev/null | grep -E "^zfsbootmenu-[0-9]" | awk '{print $1}' | tr '\n' ' ' || true)
    if [ -z "$zbm_packages" ]; then
        # Try without hyphen in case package name is just 'zfsbootmenu'
        zbm_packages=$(xbps-install -un 2>/dev/null | grep -E "^zfsbootmenu[[:space:]]" | awk '{print $1}' | tr '\n' ' ' || true)
    fi
    
    # Combine ZFS and ZBM packages
    zfs_packages="$zfs_packages $zbm_packages"
    zfs_packages=$(echo "$zfs_packages" | xargs) # trim whitespace
    
    # Get list of dracut packages to update
    dracut_packages=$(xbps-install -un 2>/dev/null | grep -E "^dracut-" | awk '{print $1}' | tr '\n' ' ' || true)
    
    # Get list of kernel packages to update (match Script 1 pattern)
    kernel_packages=$(xbps-install -un 2>/dev/null | grep -E "^linux[0-9]+\.[0-9]+-[0-9]" | awk '{print $1}' | tr '\n' ' ' || true)
    
    # Get firmware packages
    firmware_packages=$(xbps-install -un 2>/dev/null | grep -E "^linux-firmware-[0-9]" | awk '{print $1}' | tr '\n' ' ' || true)
    
    all_packages="$zfs_packages $dracut_packages $kernel_packages $firmware_packages"
    
    # Trim whitespace
    all_packages=$(echo "$all_packages" | xargs)
    
    if [ -z "$all_packages" ]; then
        warning "No packages found for installation (packages may have been updated since pre-checks)"
        return 1
    fi
    
    # Export for global use
    ZFS_PACKAGES="$zfs_packages"
    DRACUT_PACKAGES="$dracut_packages"
    KERNEL_PACKAGES="$kernel_packages"
    FIRMWARE_PACKAGES="$firmware_packages"
    ALL_PACKAGES="$all_packages"
    
    info "Packages to install:"
    [ -n "$zfs_packages" ] && log "  ZFS/ZBM: $zfs_packages"
    [ -n "$dracut_packages" ] && log "  Dracut: $dracut_packages"
    [ -n "$kernel_packages" ] && log "  Kernel: $kernel_packages"
    [ -n "$firmware_packages" ] && log "  Firmware: $firmware_packages"
    
    return 0
}

create_installation_snapshot() {
    if [ "$POOLS_EXIST" != "true" ]; then
        info "No ZFS pools - skipping installation snapshot"
        return 0
    fi
    
    info "Creating pre-installation snapshot for rollback protection..."
    
    local install_snapshot_name install_snapshot_count install_failed_count dataset
    
    install_snapshot_name="pre-install-$(date +%Y%m%d-%H%M%S)"
    install_snapshot_count=0
    install_failed_count=0
    
    # Create snapshots for all datasets before any changes
    for dataset in $(zfs list -H -o name -t filesystem,volume 2>/dev/null || true); do
        if zfs snapshot "${dataset}@${install_snapshot_name}" 2>/dev/null; then
            ((install_snapshot_count++))
            log "Created installation snapshot: ${dataset}@${install_snapshot_name}"
        else
            ((install_failed_count++))
            warning "Failed to create installation snapshot for $dataset"
        fi
    done
    
    if [ $install_snapshot_count -gt 0 ]; then
        success "Created $install_snapshot_count installation snapshots"
        
        # Save this snapshot name for rollback script
        echo "INSTALL_SNAPSHOT_NAME=\"$install_snapshot_name\"" >> "$CONFIG_FILE"
        echo "SNAPSHOT_NAME=\"$install_snapshot_name\"" >> "$CONFIG_FILE"
        
        info "Installation snapshot name saved for potential rollback"
    else
        warning "No installation snapshots created"
    fi
    
    if [ $install_failed_count -gt 0 ]; then
        warning "$install_failed_count installation snapshots failed to create"
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
    local pool_datasets dataset mountpoint
    
    info "Checking what's using pool $pool..."
    
    # Get all datasets in the pool
    pool_datasets=$(zfs list -H -o name -r "$pool" 2>/dev/null || echo "$pool")
    
    for dataset in $pool_datasets; do
        mountpoint=$(zfs get -H -o value mountpoint "$dataset" 2>/dev/null || echo "none")
        if [ "$mountpoint" != "none" ] && [ -d "$mountpoint" ]; then
            if command -v lsof >/dev/null 2>&1; then
                lsof +D "$mountpoint" 2>/dev/null | head -10 | tee -a "$LOG_FILE" || true
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
    
    local all_pools boot_pools root_pools pool
    all_pools=$(zpool list -H -o name 2>/dev/null || echo "")
    
    if [ -z "$all_pools" ]; then
        info "No ZFS pools found to export"
        return 0
    fi
    
    # For ZBM systems, handle boot pools specially - match Script 1 logic
    if [ "$ZFSBOOTMENU" = true ]; then
        boot_pools=${BOOT_POOLS:-}
        root_pools=""
        
        # Separate boot and root pools
        for pool in $all_pools; do
            if [[ " $boot_pools " == *" $pool "* ]]; then
                continue  # Skip boot pools for now
            else
                root_pools="$root_pools $pool"
            fi
        done
        
        # Export root pools first
        if [ -n "$(echo $root_pools | xargs)" ]; then
            info "Exporting root pools first: $root_pools"
            for pool in $root_pools; do
                if [ -n "$pool" ]; then
                    export_single_pool "$pool" "root"
                fi
            done
        fi
        
        # Export boot pools last (more critical)
        if [ -n "$boot_pools" ]; then
            info "Exporting boot pools: $boot_pools"
            for pool in $boot_pools; do
                export_single_pool "$pool" "boot"
            done
        fi
    else
        # Traditional system - export all pools
        for pool in $all_pools; do
            export_single_pool "$pool" "regular"
        done
    fi
    
    # Save exported pools list
    echo "$all_pools" > "$BACKUP_DIR/exported-pools.txt"
    success "All pools exported successfully"
}

install_updates() {
    info "Installing ZFS and related updates..."
    
    # Update ZFS packages first (includes ZFSBootMenu if present)
    if [ -n "${ZFS_PACKAGES:-}" ]; then
        info "Installing ZFS packages: $ZFS_PACKAGES"
        if xbps-install -y $ZFS_PACKAGES; then
            success "ZFS packages updated successfully"
            ZFS_UPDATED=true
        else
            error_exit "Failed to update ZFS packages"
        fi
    fi
    
    # Update dracut packages
    if [ -n "${DRACUT_PACKAGES:-}" ]; then
        info "Installing dracut packages: $DRACUT_PACKAGES"
        if xbps-install -y $DRACUT_PACKAGES; then
            success "Dracut packages updated successfully"
            DRACUT_UPDATED=true
        else
            error_exit "Failed to update dracut packages"
        fi
    fi
    
    # Update kernel packages
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
    echo "DRACUT_UPDATED=$DRACUT_UPDATED" >> "$CONFIG_FILE"
    echo "ZFS_UPDATED=$ZFS_UPDATED" >> "$CONFIG_FILE"
    
    success "Package installation completed"
}

rebuild_initramfs() {
    # Rebuild if kernel was updated OR if ZFS/dracut was updated
    if [ "$KERNEL_UPDATED" = "true" ] || [ "$ZFS_UPDATED" = "true" ] || [ "$DRACUT_UPDATED" = "true" ]; then
        
        local latest_kernel kernel_package
        
        if [ "$KERNEL_UPDATED" = "true" ]; then
            info "Rebuilding initramfs for updated kernel..."
        elif [ "$ZFS_UPDATED" = "true" ]; then
            info "Rebuilding initramfs for updated ZFS modules..."
        else
            info "Rebuilding initramfs for updated dracut..."
        fi
        
        latest_kernel=$(ls /lib/modules 2>/dev/null | sort -V | tail -1)
        
        if [ -z "$latest_kernel" ]; then
            error_exit "Cannot find kernel modules directory"
        fi
        
        info "Rebuilding initramfs for kernel: $latest_kernel"
        
        # Use xbps-reconfigure to respect /etc/dracut.conf.d/zfs.conf from installation script
        if [ "$ZFSBOOTMENU" = true ]; then
            info "Building initramfs with ZFSBootMenu optimizations using xbps-reconfigure..."
            
            # Extract kernel package name for reconfigure - matches installation script pattern
            kernel_package=$(echo "$latest_kernel" | sed 's/-.*$//')
            kernel_package="linux${kernel_package}"
            
            if xbps-reconfigure -f "$kernel_package" 2>/dev/null; then
                success "Initramfs rebuilt via xbps-reconfigure for ZFSBootMenu"
            else
                # Fallback to manual dracut with ZFS config from installation script
                warning "xbps-reconfigure failed, trying manual dracut..."
                local dracut_args
                dracut_args="-f --kver $latest_kernel --add zfs"
                
                # Add key file if it exists (from installation script)
                if [ -f /etc/zfs/zroot.key ]; then
                    dracut_args="$dracut_args --install /etc/zfs/zroot.key"
                fi
                
                if dracut $dracut_args; then
                    success "Initramfs rebuilt for ZFSBootMenu"
                else
                    error_exit "Failed to rebuild initramfs for ZFSBootMenu"
                fi
            fi
        else
            # Traditional dracut
            if dracut -f --kver "$latest_kernel"; then
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
    
    local exported_pools boot_pools pool
    exported_pools=$(cat "$BACKUP_DIR/exported-pools.txt")
    
    # Ensure ZFS module is loaded before import
    if ! lsmod | grep -q zfs; then
        info "Loading ZFS module before import..."
        if ! modprobe zfs; then
            error_exit "Failed to load ZFS module"
        fi
    fi
    
    # Match Script 1 logic for pool import order
    if [ "$ZFSBOOTMENU" = true ]; then
        # Import boot pools first for ZBM systems
        boot_pools=${BOOT_POOLS:-}
        
        if [ -n "$boot_pools" ]; then
            info "Re-importing boot pools first for ZFSBootMenu..."
            for pool in $boot_pools; do
                import_single_pool "$pool" "boot"
            done
        fi
        
        # Then import other pools
        for pool in $exported_pools; do
            if [[ " $boot_pools " != *" $pool "* ]]; then
                import_single_pool "$pool" "root"
            fi
        done
    else
        # Traditional import order
        for pool in $exported_pools; do
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
    
    if [ "$KERNEL_UPDATED" != "true" ] && [ "$ZFS_UPDATED" != "true" ]; then
        info "No kernel or ZFS update - skipping ZFSBootMenu regeneration"
        return 0
    fi
    
    info "Updating ZFSBootMenu for updated components..."
    
    # Check if generate-zbm command is available (CORRECTED from ZBM docs)
    if ! command -v generate-zbm >/dev/null 2>&1; then
        warning "generate-zbm command not found - trying xbps-reconfigure approach"
        
        # Try xbps-reconfigure as per installation script
        if xbps-reconfigure -f zfsbootmenu; then
            success "ZFSBootMenu regenerated via xbps-reconfigure"
            return 0
        else
            warning "ZFSBootMenu regeneration failed - manual update may be required"
            return 0
        fi
    fi
    
    # Generate new ZBM image (CORRECTED command from ZBM documentation)
    info "Generating new ZFSBootMenu EFI image..."
    
    if generate-zbm; then
        success "ZFSBootMenu image generated successfully"
    else
        error "Failed to generate ZFSBootMenu image"
        
        # Try xbps-reconfigure as fallback (matches installation script)
        warning "Attempting ZFSBootMenu regeneration via xbps-reconfigure..."
        if xbps-reconfigure -f zfsbootmenu; then
            success "ZFSBootMenu regeneration via xbps-reconfigure succeeded"
        else
            error_exit "ZFSBootMenu generation failed - boot may be broken"
        fi
    fi
    
    # Verify EFI image was created/updated (match installation script paths)
    local zbm_efi_path esp_mount
    esp_mount=${ESP_MOUNT:-/boot/efi}
    zbm_efi_path="$esp_mount/EFI/ZBM/vmlinuz.efi"
    
    if [ -f "$zbm_efi_path" ]; then
        local zbm_size
        zbm_size=$(stat -c%s "$zbm_efi_path" 2>/dev/null || stat -f --format="%s" "$zbm_efi_path" 2>/dev/null || echo "0")
        if [ "${zbm_size:-0}" -gt 1000000 ]; then  # > 1MB indicates valid EFI image
            success "ZFSBootMenu EFI image appears valid (${zbm_size} bytes)"
        else
            warning "ZFSBootMenu EFI image seems too small (${zbm_size} bytes)"
        fi
        
        # Check backup image too (matches installation script structure)
        local zbm_backup_path="$esp_mount/EFI/ZBM/vmlinuz-backup.efi"
        if [ -f "$zbm_backup_path" ]; then
            info "Backup ZFSBootMenu image also exists"
        fi
    else
        error "ZFSBootMenu EFI image not found at expected location: $zbm_efi_path"
    fi
}

update_bootloader() {
    if [ "$ZFSBOOTMENU" = true ]; then
        update_zfsbootmenu
    else
        # Traditional bootloader update (GRUB)
        if [ "$KERNEL_UPDATED" = "true" ]; then
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
    
    local current_zfs zfs_userland
    
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
    
    # Verify package versions match (improved detection like Script 1)
    info "Verifying updated package versions..."
    current_zfs=$(modinfo zfs 2>/dev/null | grep -E "^version:" | awk '{print $2}' || echo "unknown")
    zfs_userland=$(zfs version 2>/dev/null | grep -E "^zfs-" | head -1 | awk '{print $2}' || echo "unknown")
    
    # Fallback to alternative zfs version detection
    if [ "$zfs_userland" = "unknown" ]; then
        zfs_userland=$(zfs version 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
    fi
    
    log "Updated ZFS kernel module: $current_zfs"
    log "Updated ZFS userland: $zfs_userland"
    
    if [ "$current_zfs" != "unknown" ] && [ "$zfs_userland" != "unknown" ]; then
        if [ "$current_zfs" = "$zfs_userland" ]; then
            success "ZFS kernel and userland versions match after update"
        else
            warning "ZFS version mismatch after update: kernel=$current_zfs, userland=$zfs_userland"
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
    echo "4. Rebuild initramfs if needed"
    if [ "$ZFSBOOTMENU" = true ]; then
        echo "5. Update ZFSBootMenu EFI image"
    else
        echo "5. Update bootloader configuration"
    fi
    if [ "$POOLS_EXIST" = "true" ]; then
        echo "6. Re-import ZFS pools"
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
    rebuild_initramfs
    reimport_zfs_pools
    update_bootloader
    verify_basic_functionality
    
    header "INSTALLATION COMPLETED"
    
    success "ZFS/kernel updates installed successfully!"
    
    echo "System type: $([ "$ZFSBOOTMENU" = true ] && echo "ZFSBootMenu" || echo "Traditional")"
    
    if [ "$KERNEL_UPDATED" = "true" ]; then
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
