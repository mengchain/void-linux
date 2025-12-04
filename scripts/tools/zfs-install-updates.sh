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

# Colors for output - FIXED: Light Blue for consistency
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;94m'      # Light Blue (bright blue)
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Standardized logging functions
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
    log "${RED}✗ ERROR: $1${NC}" >&2
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

# Error handling
error_exit() {
    error "$1"
    log "Update failed. Check logs and consider running rollback script."
    cleanup
    exit 1
}

# Cleanup function
cleanup() {
    info "Cleaning up..."
    # Remove any temporary files if created
    rm -f /tmp/zfs-update-*.tmp 2>/dev/null || true
}

# Trap errors
trap 'error_exit "Script failed at line $LINENO"' ERR

# Load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        info "Loading configuration from $CONFIG_FILE"
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        success "Configuration loaded"
    else
        warning "Configuration file not found, using defaults"
    fi
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

# Verify ZFS health before proceeding
verify_zfs_health() {
    header "Verifying ZFS Health"
    
    info "Checking ZFS module..."
    if ! lsmod | grep -q "^zfs "; then
        error_exit "ZFS module not loaded"
    fi
    success "ZFS module is loaded"
    
    info "Checking ZFS pools..."
    local pools
    pools=$(zpool list -H -o name,health 2>/dev/null || echo "")
    
    if [[ -z "$pools" ]]; then
        warning "No ZFS pools found"
    else
        while IFS=$'\t' read -r pool health; do
            [[ -z "$pool" ]] && continue
            if [[ "$health" != "ONLINE" ]]; then
                error_exit "Pool $pool is not ONLINE (current: $health)"
            fi
            success "Pool $pool is healthy"
        done <<< "$pools"
    fi
}

# Parse available updates from pre-check results
parse_updates() {
    header "Parsing Available Updates"
    
    # Read from config or use xbps-install to check
    if [[ -n "${PACKAGES_TO_UPDATE:-}" ]]; then
        ALL_PACKAGES="$PACKAGES_TO_UPDATE"
        info "Using packages from configuration"
    else
        info "Checking for updates with xbps-install..."
        local update_output
        update_output=$(xbps-install -un 2>/dev/null || echo "")
        
        if [[ -z "$update_output" ]]; then
            success "No updates available"
            exit 0
        fi
        
        # Parse package names - FIXED SIGPIPE
        ALL_PACKAGES=$(echo "$update_output" | awk '{print $1}' | tr '\n' ' ')
    fi
    
    # Categorize packages
    for pkg in $ALL_PACKAGES; do
        case "$pkg" in
            zfs|zfs-*)
                ZFS_PACKAGES="$ZFS_PACKAGES $pkg"
                ZFS_UPDATED=true
                ;;
            dracut|dracut-*)
                DRACUT_PACKAGES="$DRACUT_PACKAGES $pkg"
                DRACUT_UPDATED=true
                ;;
            linux|linux[0-9]*)
                KERNEL_PACKAGES="$KERNEL_PACKAGES $pkg"
                KERNEL_UPDATED=true
                ;;
            linux-firmware*)
                FIRMWARE_PACKAGES="$FIRMWARE_PACKAGES $pkg"
                ;;
        esac
    done
    
    # Report categorization
    if [[ -n "$ZFS_PACKAGES" ]]; then
        info "ZFS packages to update:$ZFS_PACKAGES"
    fi
    if [[ -n "$DRACUT_PACKAGES" ]]; then
        info "Dracut packages to update:$DRACUT_PACKAGES"
    fi
    if [[ -n "$KERNEL_PACKAGES" ]]; then
        info "Kernel packages to update:$KERNEL_PACKAGES"
    fi
    if [[ -n "$FIRMWARE_PACKAGES" ]]; then
        info "Firmware packages to update:$FIRMWARE_PACKAGES"
    fi
    
    success "Updates parsed and categorized"
}

# Create backup of critical files
create_backup() {
    header "Creating Backup"
    
    local backup_dir="/var/backups/zfs-update-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    
    info "Backing up to $backup_dir"
    
    # Backup ZFS configuration
    if [[ -f /etc/zfs/zpool.cache ]]; then
        cp -p /etc/zfs/zpool.cache "$backup_dir/" || warning "Failed to backup zpool.cache"
    fi
    
    if [[ -f /etc/hostid ]]; then
        cp -p /etc/hostid "$backup_dir/" || warning "Failed to backup hostid"
    fi
    
    if [[ -f /etc/zfs/zroot.key ]]; then
        cp -p /etc/zfs/zroot.key "$backup_dir/" || warning "Failed to backup encryption key"
    fi
    
    # Backup ZFSBootMenu configuration
    if [[ -f /etc/zfsbootmenu/config.yaml ]]; then
        cp -p /etc/zfsbootmenu/config.yaml "$backup_dir/" || warning "Failed to backup ZBM config"
    fi
    
    # Backup dracut configuration
    if [[ -d /etc/dracut.conf.d ]]; then
        cp -rp /etc/dracut.conf.d "$backup_dir/" || warning "Failed to backup dracut config"
    fi
    
    # Save current kernel version
    uname -r > "$backup_dir/kernel-version.txt"
    
    # Save current package versions - FIXED SIGPIPE
    local zfs_version dracut_version kernel_version
    zfs_version=$(xbps-query zfs 2>/dev/null | grep "^pkgver:" | awk '{print $2}' || echo "unknown")
    dracut_version=$(xbps-query dracut 2>/dev/null | grep "^pkgver:" | awk '{print $2}' || echo "unknown")
    kernel_version=$(xbps-query linux 2>/dev/null | grep "^pkgver:" | awk '{print $2}' || echo "unknown")
    
    cat > "$backup_dir/package-versions.txt" <<EOF
ZFS: $zfs_version
Dracut: $dracut_version
Kernel: $kernel_version
EOF
    
    success "Backup created at $backup_dir"
    echo "$backup_dir" > /tmp/zfs-update-backup.txt
}

# Perform the actual update
perform_update() {
    header "Performing System Update"
    
    if [[ -z "$ALL_PACKAGES" ]]; then
        warning "No packages to update"
        return 0
    fi
    
    info "Updating packages: $ALL_PACKAGES"
    
    # Perform update with xbps-install
    if xbps-install -yu $ALL_PACKAGES 2>&1 | tee -a "$LOG_FILE"; then
        success "Packages updated successfully"
    else
        error_exit "Package update failed"
    fi
    
    # Sync xbps
    info "Synchronizing package database..."
    xbps-install -S || warning "Failed to sync package database"
}

# Rebuild initramfs for all installed kernels
rebuild_initramfs() {
    header "Rebuilding Initramfs"
    
    if [[ "$KERNEL_UPDATED" == true ]] || [[ "$ZFS_UPDATED" == true ]] || [[ "$DRACUT_UPDATED" == true ]]; then
        info "Kernel/ZFS/Dracut updated, rebuilding initramfs for all kernels"
        
        # Get list of installed kernels - FIXED SIGPIPE
        local installed_kernels
        installed_kernels=$(ls /lib/modules/ 2>/dev/null | grep -E '^[0-9]' || echo "")
        
        if [[ -z "$installed_kernels" ]]; then
            error_exit "No kernel modules found in /lib/modules/"
        fi
        
        while IFS= read -r kernel_ver; do
            [[ -z "$kernel_ver" ]] && continue
            
            info "Rebuilding initramfs for kernel $kernel_ver"
            
            if dracut -f --kver "$kernel_ver" 2>&1 | tee -a "$LOG_FILE"; then
                success "Initramfs rebuilt for kernel $kernel_ver"
                
                # Verify initramfs was created
                if [[ ! -f "/boot/initramfs-${kernel_ver}.img" ]]; then
                    error_exit "Initramfs file not found after rebuild: /boot/initramfs-${kernel_ver}.img"
                fi
                
                # Verify ZFS module is in initramfs - FIXED SIGPIPE
                if command -v lsinitrd &>/dev/null; then
                    local initrd_content
                    initrd_content=$(lsinitrd "/boot/initramfs-${kernel_ver}.img" 2>/dev/null || echo "")
                    
                    if [[ -n "$initrd_content" ]]; then
                        if echo "$initrd_content" | grep -q "zfs.ko"; then
                            success "ZFS module verified in initramfs"
                        else
                            error_exit "ZFS module NOT found in rebuilt initramfs!"
                        fi
                    fi
                fi
            else
                error_exit "Failed to rebuild initramfs for kernel $kernel_ver"
            fi
        done <<< "$installed_kernels"
        
    else
        info "No kernel/ZFS/dracut updates, skipping initramfs rebuild"
    fi
}

# Regenerate ZFSBootMenu
regenerate_zfsbootmenu() {
    header "Regenerating ZFSBootMenu"
    
    # Check if ZFSBootMenu is installed
    if ! command -v generate-zbm &>/dev/null; then
        info "ZFSBootMenu not installed, skipping"
        return 0
    fi
    
    if [[ "$KERNEL_UPDATED" == true ]] || [[ "$ZFS_UPDATED" == true ]] || [[ "$DRACUT_UPDATED" == true ]]; then
        info "Critical components updated, regenerating ZFSBootMenu"
        
        # Backup existing ZBM EFI file
        local zbm_efi="/boot/efi/EFI/ZBM/vmlinuz.efi"
        if [[ -f "$zbm_efi" ]]; then
            info "Backing up existing ZFSBootMenu EFI file"
            cp -p "$zbm_efi" "$zbm_efi.backup-$(date +%Y%m%d-%H%M%S)" || warning "Failed to backup ZBM EFI file"
        fi
        
        # Generate new ZFSBootMenu
        info "Running generate-zbm..."
        if generate-zbm 2>&1 | tee -a "$LOG_FILE"; then
            success "ZFSBootMenu regenerated successfully"
            
            # Verify EFI file was created
            if [[ ! -f "$zbm_efi" ]]; then
                error_exit "ZFSBootMenu EFI file not found after generation: $zbm_efi"
            fi
            
            # Create/update backup
            if [[ -f "$zbm_efi" ]]; then
                cp -p "$zbm_efi" "/boot/efi/EFI/ZBM/vmlinuz-backup.efi" || warning "Failed to create ZBM backup"
            fi
        else
            error_exit "Failed to regenerate ZFSBootMenu"
        fi
    else
        info "No critical updates, skipping ZFSBootMenu regeneration"
    fi
}

# Verify bootloader entries
verify_bootloader() {
    header "Verifying Bootloader Entries"
    
    if command -v efibootmgr &>/dev/null; then
        info "Checking EFI boot entries..."
        
        # FIXED SIGPIPE: Capture efibootmgr output first
        local efi_entries
        efi_entries=$(efibootmgr 2>/dev/null || echo "")
        
        if [[ -n "$efi_entries" ]]; then
            if echo "$efi_entries" | grep -qi "zfsbootmenu\|ZBM"; then
                success "ZFSBootMenu found in EFI boot entries"
                
                # Display boot order
                info "Current boot order:"
                echo "$efi_entries" | grep "BootOrder" | tee -a "$LOG_FILE"
            else
                warning "ZFSBootMenu not found in EFI boot entries"
                warning "You may need to create EFI boot entries manually"
            fi
        else
            warning "Unable to read EFI boot entries"
        fi
    else
        info "efibootmgr not available, skipping EFI verification"
    fi
}

# Verify ZFS module compatibility
verify_zfs_module() {
    header "Verifying ZFS Module Compatibility"
    
    local current_kernel
    current_kernel=$(uname -r)
    
    info "Current running kernel: $current_kernel"
    
    # Check if ZFS module exists for current kernel
    local zfs_module="/lib/modules/$current_kernel/extra/zfs/zfs.ko"
    
    if [[ -f "$zfs_module" ]]; then
        success "ZFS module exists for current kernel"
    else
        warning "ZFS module not found for current kernel: $zfs_module"
        warning "You may need to reboot to load the updated kernel/ZFS module"
    fi
    
    # Try to reload ZFS module if updated
    if [[ "$ZFS_UPDATED" == true ]]; then
        info "ZFS was updated, attempting to reload module..."
        
        # Check if any ZFS pools are imported
        local pools
        pools=$(zpool list -H -o name 2>/dev/null || echo "")
        
        if [[ -n "$pools" ]]; then
            warning "ZFS pools are imported, cannot safely reload module"
            warning "A reboot is recommended to use the updated ZFS module"
        else
            info "No pools imported, attempting module reload..."
            if rmmod zfs 2>/dev/null && modprobe zfs 2>/dev/null; then
                success "ZFS module reloaded successfully"
            else
                warning "Failed to reload ZFS module, reboot recommended"
            fi
        fi
    fi
}

# Post-update verification
post_update_verification() {
    header "Post-Update Verification"
    
    # Verify critical files exist
    local critical_files=(
        "/etc/zfs/zpool.cache"
        "/etc/hostid"
    )
    
    for file in "${critical_files[@]}"; do
        if [[ -f "$file" ]]; then
            success "Critical file exists: $file"
        else
            error "Critical file missing: $file"
        fi
    done
    
    # Verify ZFS services
    info "Checking ZFS services..."
    for service in zfs-import zfs-mount zfs-zed; do
        local sv_status
        sv_status=$(sv status "$service" 2>/dev/null || echo "not found")
        
        if echo "$sv_status" | grep -q "run"; then
            success "Service $service is running"
        else
            warning "Service $service may need attention"
        fi
    done
    
    # Check for any broken symlinks in /boot
    info "Checking for broken symlinks in /boot..."
    local broken_links
    broken_links=$(find /boot -xtype l 2>/dev/null || echo "")
    
    if [[ -n "$broken_links" ]]; then
        warning "Broken symlinks found in /boot:"
        echo "$broken_links" | tee -a "$LOG_FILE"
    else
        success "No broken symlinks in /boot"
    fi
}

# Generate update summary
generate_summary() {
    header "Update Summary"
    
    info "Update completed at: $(date '+%Y-%m-%d %H:%M:%S')"
    info "Log file: $LOG_FILE"
    
    if [[ -f /tmp/zfs-update-backup.txt ]]; then
        local backup_dir
        backup_dir=$(cat /tmp/zfs-update-backup.txt)
        info "Backup location: $backup_dir"
    fi
    
    if [[ "$KERNEL_UPDATED" == true ]]; then
        warning "Kernel was updated - REBOOT REQUIRED"
    fi
    
    if [[ "$ZFS_UPDATED" == true ]]; then
        warning "ZFS was updated - REBOOT RECOMMENDED"
    fi
    
    success "System update completed successfully"
    
    echo ""
    info "Next steps:"
    info "1. Review this summary and log file"
    info "2. Run zfs-post-update-verify.sh to verify the update"
    if [[ "$KERNEL_UPDATED" == true ]] || [[ "$ZFS_UPDATED" == true ]]; then
        info "3. Reboot the system when ready"
    fi
    echo ""
}

# Main execution
main() {
    header "ZFS/Kernel Update Installation"
    
    check_root
    load_config
    verify_zfs_health
    parse_updates
    create_backup
    perform_update
    rebuild_initramfs
    regenerate_zfsbootmenu
    verify_bootloader
    verify_zfs_module
    post_update_verification
    generate_summary
    
    success "Update process completed successfully"
    
    # Cleanup
    cleanup
    
    exit 0
}

# Run main function
main "$@"
