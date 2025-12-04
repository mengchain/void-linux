#!/bin/bash
# filepath: zfs-install-updates.sh
# ZFS/Kernel Update Installation with ZFSBootMenu Support
# Performs the actual package updates with comprehensive backup and safety measures
# 
# References:
# - OpenZFS Administration Guide: https://openzfs.github.io/openzfs-docs/
# - ZFS Best Practices: https://openzfs.github.io/openzfs-docs/Performance%20and%20Tuning/Workload%20Tuning.html
# - ZFSBootMenu Documentation: https://docs.zfsbootmenu.org/
# - Void Linux Handbook: https://docs.voidlinux.org/
# - XBPS Package Manager: https://docs.voidlinux.org/xbps/index.html

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

# Global backup state
BACKUP_DIR=""
BACKUP_COMPLETED=false
SNAPSHOTS_CREATED=false

# Colors for output - Consistent with other scripts
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[1;94m'      # Light Blue (bright blue)
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

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

# ============================================================================
# COMPREHENSIVE BACKUP CREATION
# Best Practices Reference:
# - OpenZFS: Snapshots are atomic, space-efficient backups
# - Void Linux: Keep multiple backup generations
# - ZFSBootMenu: Always backup ESP before modifications
# ============================================================================

create_backup() {
    header "Creating Comprehensive Backup"
    
    local backup_dir="/var/backups/zfs-update-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    
    info "Backing up to $backup_dir"
    
    # Export BACKUP_DIR for other functions and rollback script
    export BACKUP_DIR="$backup_dir"
    echo "BACKUP_DIR=$backup_dir" >> "$CONFIG_FILE"
    
    # ========================================
    # CRITICAL ZFS STATE BACKUPS
    # Best Practice: Always backup ZFS metadata before modifications
    # Reference: OpenZFS Admin Guide - Backup and Recovery
    # ========================================
    
    info "=== Backing Up ZFS State ==="
    
    # 1. ZFS Dataset List (REQUIRED FOR ROLLBACK)
    info "Backing up ZFS dataset list..."
    if zfs list -H -o name -t filesystem > "$backup_dir/zfs-datasets.txt" 2>/dev/null; then
        local dataset_count
        dataset_count=$(wc -l < "$backup_dir/zfs-datasets.txt")
        success "Dataset list saved: $dataset_count datasets"
    else
        warning "Failed to backup ZFS dataset list"
    fi
    
    # 2. Pool List (REQUIRED FOR ROLLBACK)
    info "Backing up pool list..."
    if zpool list -H -o name > "$backup_dir/zpool-list.txt" 2>/dev/null; then
        local pool_count
        pool_count=$(wc -l < "$backup_dir/zpool-list.txt")
        success "Pool list saved: $pool_count pools"
        
        # Copy to exported-pools.txt for rollback consistency
        cp "$backup_dir/zpool-list.txt" "$backup_dir/exported-pools.txt"
        success "Exported pools list saved"
    else
        warning "Failed to backup pool list"
    fi
    
    # 3. Detailed pool status with full configuration
    info "Backing up detailed pool status..."
    if zpool status > "$backup_dir/zpool-status-full.txt" 2>/dev/null; then
        success "Pool status saved"
    fi
    
    # 4. Pool properties for all pools
    info "Backing up pool properties..."
    while IFS= read -r pool; do
        [[ -z "$pool" ]] && continue
        zpool get all "$pool" > "$backup_dir/zpool-properties-${pool}.txt" 2>/dev/null || true
    done < "$backup_dir/zpool-list.txt"
    
    # 5. Dataset properties for all filesystems
    info "Backing up dataset properties..."
    zfs get all > "$backup_dir/zfs-properties-all.txt" 2>/dev/null || true
    
    # 6. ZFS configuration files
    if [[ -f /etc/zfs/zpool.cache ]]; then
        info "Backing up zpool.cache..."
        cp -p /etc/zfs/zpool.cache "$backup_dir/" || warning "Failed to backup zpool.cache"
        success "zpool.cache backed up"
    fi
    
    if [[ -f /etc/hostid ]]; then
        info "Backing up hostid..."
        cp -p /etc/hostid "$backup_dir/" || warning "Failed to backup hostid"
        success "hostid backed up"
    fi
    
    if [[ -f /etc/zfs/zroot.key ]]; then
        info "Backing up encryption key..."
        cp -p /etc/zfs/zroot.key "$backup_dir/" || warning "Failed to backup encryption key"
        success "Encryption key backed up"
    fi
    
    # ========================================
    # CREATE ZFS SNAPSHOTS (CRITICAL!)
    # Best Practice: Atomic snapshots before any system modification
    # Reference: OpenZFS Snapshots - https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Snapshot.html
    # Snapshots are:
    # - Atomic (taken instantly)
    # - Space-efficient (only store changed blocks)
    # - Can be rolled back atomically
    # ========================================
    
    info "=== Creating ZFS Snapshots for Rollback ==="
    
    local snapshot_name="pre-update-$(date +%Y%m%d-%H%M%S)"
    info "Snapshot name: $snapshot_name"
    
    # Get all ZFS filesystems - FIXED SIGPIPE
    local datasets
    datasets=$(zfs list -H -o name -t filesystem 2>/dev/null || echo "")
    
    if [[ -z "$datasets" ]]; then
        warning "No ZFS datasets found - skipping snapshot creation"
        SNAPSHOTS_CREATED=false
    else
        local snapshot_count=0
        local failed_count=0
        
        # Create snapshots for each dataset
        while IFS= read -r dataset; do
            [[ -z "$dataset" ]] && continue
            
            info "Creating snapshot: $dataset@$snapshot_name"
            
            # Create snapshot (atomic operation)
            if zfs snapshot "$dataset@$snapshot_name" 2>&1 | tee -a "$LOG_FILE"; then
                success "Created: $dataset@$snapshot_name"
                ((snapshot_count++))
            else
                error "Failed to create snapshot for: $dataset"
                ((failed_count++))
            fi
        done <<< "$datasets"
        
        if [[ $snapshot_count -gt 0 ]]; then
            success "Created $snapshot_count ZFS snapshot(s)"
            SNAPSHOTS_CREATED=true
            
            # Save snapshot name to config for rollback
            echo "SNAPSHOT_NAME=$snapshot_name" >> "$CONFIG_FILE"
            echo "INSTALL_SNAPSHOT_NAME=$snapshot_name" >> "$CONFIG_FILE"
            
            # Save snapshot list for rollback verification
            zfs list -t snapshot -H -o name | grep "@$snapshot_name" > "$backup_dir/created-snapshots.txt"
            
            info "Snapshot list saved to: created-snapshots.txt"
        else
            error "No snapshots were created!"
            SNAPSHOTS_CREATED=false
            
            if [[ $failed_count -gt 0 ]]; then
                error "Failed to create $failed_count snapshot(s)"
                error "Rollback will NOT be possible without snapshots!"
                error "Aborting update for safety"
                error_exit "Snapshot creation failed - cannot proceed safely"
            fi
        fi
    fi
    
    # ========================================
    # PACKAGE STATE BACKUP
    # Best Practice: Record exact package versions for downgrade
    # Reference: XBPS Package Manager - https://docs.voidlinux.org/xbps/
    # ========================================
    
    info "=== Backing Up Package State ==="
    
    # Save current package versions (CORRECT FILENAME FOR ROLLBACK)
    info "Backing up installed packages..."
    if xbps-query -l 2>/dev/null > "$backup_dir/installed-packages.txt"; then
        success "Package list saved: installed-packages.txt"
        
        # Also create detailed version info for reference
        xbps-query -l | awk '{print $1, $2}' > "$backup_dir/package-versions.txt"
        
        # Count packages
        local pkg_count
        pkg_count=$(wc -l < "$backup_dir/installed-packages.txt")
        info "Backed up $pkg_count packages"
    else
        error "Failed to backup package list"
        error_exit "Cannot proceed without package backup"
    fi
    
    # Backup package repository configuration
    if [[ -d /etc/xbps.d ]]; then
        info "Backing up XBPS configuration..."
        cp -rp /etc/xbps.d "$backup_dir/xbps.d-backup" || warning "Failed to backup XBPS config"
    fi
    
    # ========================================
    # SYSTEM CONFIGURATION BACKUPS
    # Best Practice: Backup all boot-critical configuration
    # ========================================
    
    info "=== Backing Up System Configuration ==="
    
    # 1. fstab (REQUIRED FOR ROLLBACK)
    if [[ -f /etc/fstab ]]; then
        info "Backing up fstab..."
        cp -p /etc/fstab "$backup_dir/fstab" || warning "Failed to backup fstab"
        success "fstab backed up"
    fi
    
    # 2. Dracut configuration (CORRECT DIRECTORY NAME)
    # Reference: Dracut - https://www.kernel.org/pub/linux/utils/boot/dracut/dracut.html
    if [[ -d /etc/dracut.conf.d ]]; then
        info "Backing up dracut configuration..."
        if cp -rp /etc/dracut.conf.d "$backup_dir/dracut.conf.d-backup"; then
            local dracut_files
            dracut_files=$(find "$backup_dir/dracut.conf.d-backup" -type f | wc -l)
            success "Dracut config backed up: $dracut_files files"
        else
            warning "Failed to backup dracut configuration"
        fi
    fi
    
    # Save main dracut.conf if exists
    if [[ -f /etc/dracut.conf ]]; then
        cp -p /etc/dracut.conf "$backup_dir/dracut.conf" 2>/dev/null || true
        success "Main dracut.conf backed up"
    fi
    
    # 3. ZFSBootMenu configuration (CORRECT FILENAME)
    # Reference: ZFSBootMenu - https://docs.zfsbootmenu.org/en/latest/general/online-configuration.html
    if [[ -f /etc/zfsbootmenu/config.yaml ]]; then
        info "Backing up ZFSBootMenu configuration..."
        if cp -p /etc/zfsbootmenu/config.yaml "$backup_dir/zfsbootmenu-config.yaml"; then
            success "ZBM config backed up: zfsbootmenu-config.yaml"
        else
            warning "Failed to backup ZFSBootMenu config"
        fi
    fi
    
    # 4. Module configuration
    if [[ -d /etc/modprobe.d ]]; then
        info "Backing up module configuration..."
        cp -rp /etc/modprobe.d "$backup_dir/modprobe.d-backup" 2>/dev/null || true
    fi
    
    # ========================================
    # ESP / BOOT PARTITION BACKUP
    # Best Practice: Always backup ESP before bootloader changes
    # Reference: ZFSBootMenu ESP Management
    # ========================================
    
    if command -v generate-zbm &>/dev/null && [[ -d /boot/efi ]]; then
        info "=== Backing Up ESP (Boot Partition) ==="
        
        info "This may take a moment for complete ESP backup..."
        mkdir -p "$backup_dir/esp-complete-backup"
        
        # Calculate ESP size for user info
        local esp_size
        esp_size=$(du -sh /boot/efi 2>/dev/null | awk '{print $1}')
        info "ESP size: $esp_size"
        
        if cp -r /boot/efi/* "$backup_dir/esp-complete-backup/" 2>&1 | tee -a "$LOG_FILE"; then
            success "ESP completely backed up: esp-complete-backup/"
            
            # Verify critical files were backed up
            if [[ -f "$backup_dir/esp-complete-backup/EFI/ZBM/vmlinuz.efi" ]]; then
                success "ZBM EFI image verified in backup"
            else
                warning "ZBM EFI image not found in backup"
            fi
            
            # Verify backup EFI image
            if [[ -f "$backup_dir/esp-complete-backup/EFI/ZBM/vmlinuz-backup.efi" ]]; then
                info "ZBM backup EFI image also backed up"
            fi
        else
            warning "ESP backup may be incomplete"
            warning "Check log for details: $LOG_FILE"
        fi
        
        # Create ESP file list for verification
        find /boot/efi -type f > "$backup_dir/esp-file-list.txt" 2>/dev/null || true
        local esp_file_count
        esp_file_count=$(wc -l < "$backup_dir/esp-file-list.txt")
        info "ESP file count: $esp_file_count files"
    fi
    
    # ========================================
    # KERNEL AND BOOT STATE
    # Best Practice: Track kernel versions for rollback
    # ========================================
    
    info "=== Backing Up Kernel and Boot State ==="
    
    # Save current kernel version
    info "Saving current kernel version..."
    uname -r > "$backup_dir/kernel-version.txt"
    local current_kernel
    current_kernel=$(cat "$backup_dir/kernel-version.txt")
    success "Current kernel: $current_kernel"
    
    # List installed kernels
    info "Listing installed kernels..."
    if ls /lib/modules/ > "$backup_dir/installed-kernels.txt" 2>/dev/null; then
        local kernel_count
        kernel_count=$(wc -l < "$backup_dir/installed-kernels.txt")
        info "Installed kernels: $kernel_count"
    fi
    
    # Backup current initramfs metadata
    if [[ -f "/boot/initramfs-${current_kernel}.img" ]]; then
        info "Recording current initramfs..."
        ls -lh "/boot/initramfs-${current_kernel}.img" > "$backup_dir/initramfs-info.txt"
        
        # Also check if ZFS is in current initramfs
        if command -v lsinitrd &>/dev/null; then
            local initrd_check
            initrd_check=$(lsinitrd "/boot/initramfs-${current_kernel}.img" 2>/dev/null | grep -c "zfs" || echo "0")
            echo "ZFS modules in current initramfs: $initrd_check" >> "$backup_dir/initramfs-info.txt"
        fi
        
        success "Initramfs info saved"
    fi
    
    # Backup /boot directory listing
    if [[ -d /boot ]]; then
        info "Creating /boot file list..."
        ls -lR /boot > "$backup_dir/boot-contents.txt" 2>/dev/null || true
    fi
    
    # ========================================
    # BOOT CONFIGURATION
    # ========================================
    
    # EFI boot entries
    if command -v efibootmgr &>/dev/null; then
        info "Backing up EFI boot entries..."
        if efibootmgr > "$backup_dir/efi-boot-entries.txt" 2>/dev/null; then
            success "EFI boot entries saved"
        else
            warning "Failed to backup EFI entries"
        fi
    fi
    
    # Save boot order
    if command -v efibootmgr &>/dev/null; then
        local boot_order
        boot_order=$(efibootmgr 2>/dev/null | grep "BootOrder" || echo "")
        if [[ -n "$boot_order" ]]; then
            echo "$boot_order" > "$backup_dir/boot-order.txt"
            info "Boot order saved"
        fi
    fi
    
    # ========================================
    # SYSTEM STATE SNAPSHOT
    # ========================================
    
    info "=== Capturing System State ==="
    
    # Loaded kernel modules
    lsmod > "$backup_dir/loaded-modules.txt" 2>/dev/null || true
    
    # ZFS module version
    if modinfo zfs &>/dev/null; then
        modinfo zfs > "$backup_dir/zfs-module-info.txt" 2>/dev/null || true
    fi
    
    # Disk layout
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT > "$backup_dir/disk-layout.txt" 2>/dev/null || true
    
    # Memory info
    free -h > "$backup_dir/memory-info.txt" 2>/dev/null || true
    
    # ========================================
    # FINAL BACKUP VALIDATION & MANIFEST
    # ========================================
    
    info "=== Validating Backup Completeness ==="
    
    # Create comprehensive backup manifest
    cat > "$backup_dir/BACKUP_MANIFEST.txt" << EOF
================================================================================
ZFS UPDATE BACKUP MANIFEST
================================================================================
Date: $(date '+%Y-%m-%d %H:%M:%S')
Kernel: $(uname -r)
Hostname: $(hostname)
Backup Directory: $backup_dir

================================================================================
ZFS STATE BACKUPS
================================================================================
Dataset list:           $([ -f "$backup_dir/zfs-datasets.txt" ] && echo "YES ($(wc -l < "$backup_dir/zfs-datasets.txt") datasets)" || echo "NO")
Pool list:              $([ -f "$backup_dir/zpool-list.txt" ] && echo "YES ($(wc -l < "$backup_dir/zpool-list.txt") pools)" || echo "NO")
Exported pools list:    $([ -f "$backup_dir/exported-pools.txt" ] && echo "YES" || echo "NO")
Pool status:            $([ -f "$backup_dir/zpool-status-full.txt" ] && echo "YES" || echo "NO")
ZFS properties:         $([ -f "$backup_dir/zfs-properties-all.txt" ] && echo "YES" || echo "NO")
zpool.cache:            $([ -f "$backup_dir/zpool.cache" ] && echo "YES" || echo "NO")
hostid:                 $([ -f "$backup_dir/hostid" ] && echo "YES" || echo "NO")
Encryption key:         $([ -f "$backup_dir/zroot.key" ] && echo "YES" || echo "NO")

ZFS Snapshots:          $([ -f "$backup_dir/created-snapshots.txt" ] && echo "YES - $(wc -l < "$backup_dir/created-snapshots.txt") snapshots" || echo "NO")
Snapshot name:          $(grep "SNAPSHOT_NAME=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo "NONE")

================================================================================
SYSTEM CONFIGURATION BACKUPS
================================================================================
fstab:                  $([ -f "$backup_dir/fstab" ] && echo "YES" || echo "NO")
dracut.conf.d:          $([ -d "$backup_dir/dracut.conf.d-backup" ] && echo "YES ($(find "$backup_dir/dracut.conf.d-backup" -type f 2>/dev/null | wc -l) files)" || echo "NO")
dracut.conf:            $([ -f "$backup_dir/dracut.conf" ] && echo "YES" || echo "NO")
ZBM config:             $([ -f "$backup_dir/zfsbootmenu-config.yaml" ] && echo "YES" || echo "NO")
modprobe.d:             $([ -d "$backup_dir/modprobe.d-backup" ] && echo "YES" || echo "NO")
XBPS config:            $([ -d "$backup_dir/xbps.d-backup" ] && echo "YES" || echo "NO")

================================================================================
PACKAGE STATE BACKUPS
================================================================================
Package list:           $([ -f "$backup_dir/installed-packages.txt" ] && echo "YES ($(wc -l < "$backup_dir/installed-packages.txt") packages)" || echo "NO")
Package versions:       $([ -f "$backup_dir/package-versions.txt" ] && echo "YES" || echo "NO")

================================================================================
BOOT FILES BACKUPS
================================================================================
ESP backup:             $([ -d "$backup_dir/esp-complete-backup" ] && echo "YES ($(find "$backup_dir/esp-complete-backup" -type f 2>/dev/null | wc -l) files)" || echo "NO")
ESP file list:          $([ -f "$backup_dir/esp-file-list.txt" ] && echo "YES" || echo "NO")
Kernel version:         $([ -f "$backup_dir/kernel-version.txt" ] && echo "YES ($(cat "$backup_dir/kernel-version.txt"))" || echo "NO")
Installed kernels:      $([ -f "$backup_dir/installed-kernels.txt" ] && echo "YES ($(wc -l < "$backup_dir/installed-kernels.txt") kernels)" || echo "NO")
Initramfs info:         $([ -f "$backup_dir/initramfs-info.txt" ] && echo "YES" || echo "NO")
Boot contents:          $([ -f "$backup_dir/boot-contents.txt" ] && echo "YES" || echo "NO")
EFI boot entries:       $([ -f "$backup_dir/efi-boot-entries.txt" ] && echo "YES" || echo "NO")

================================================================================
SYSTEM STATE SNAPSHOTS
================================================================================
Loaded modules:         $([ -f "$backup_dir/loaded-modules.txt" ] && echo "YES" || echo "NO")
ZFS module info:        $([ -f "$backup_dir/zfs-module-info.txt" ] && echo "YES" || echo "NO")
Disk layout:            $([ -f "$backup_dir/disk-layout.txt" ] && echo "YES" || echo "NO")
Memory info:            $([ -f "$backup_dir/memory-info.txt" ] && echo "YES" || echo "NO")

================================================================================
ROLLBACK READINESS
================================================================================
All critical backups:   $([ -f "$backup_dir/zfs-datasets.txt" ] && [ -f "$backup_dir/installed-packages.txt" ] && [ -f "$backup_dir/fstab" ] && echo "YES" || echo "NO")
Snapshots created:      $([ -f "$backup_dir/created-snapshots.txt" ] && echo "YES" || echo "NO")
ESP backed up:          $([ -d "$backup_dir/esp-complete-backup" ] && echo "YES" || echo "NO")

ROLLBACK READY:         $([ -f "$backup_dir/created-snapshots.txt" ] && [ -f "$backup_dir/installed-packages.txt" ] && [ -f "$backup_dir/zfs-datasets.txt" ] && echo "✓ YES - Full rollback possible" || echo "✗ NO - Missing critical backups")

================================================================================
NOTES
================================================================================
- All backups are timestamped and preserved
- ZFS snapshots are atomic and can be rolled back instantly
- Package cache may allow package version rollback
- ESP backup allows bootloader restoration
- Use zfs-rollback-update.sh to rollback this update

================================================================================
EOF
    
    # Validate critical backups exist
    local missing_critical=()
    
    if [[ ! -f "$backup_dir/zfs-datasets.txt" ]]; then
        missing_critical+=("zfs-datasets.txt")
    fi
    
    if [[ ! -f "$backup_dir/installed-packages.txt" ]]; then
        missing_critical+=("installed-packages.txt")
    fi
    
    if [[ ! -f "$backup_dir/created-snapshots.txt" ]]; then
        missing_critical+=("ZFS snapshots")
    fi
    
    if [[ ${#missing_critical[@]} -gt 0 ]]; then
        error "Critical backups missing: ${missing_critical[*]}"
        error_exit "Cannot proceed without complete backup"
    fi
    
    success "All critical backups completed successfully"
    BACKUP_COMPLETED=true
    
    # Display backup summary
    echo ""
    header "Backup Summary"
    cat "$backup_dir/BACKUP_MANIFEST.txt"
    echo ""
    
    success "Backup location: $backup_dir"
    info "Backup manifest: $backup_dir/BACKUP_MANIFEST.txt"
    
    # Store backup path for easy access
    echo "$backup_dir" > /tmp/zfs-update-backup.txt
    
    return 0
}

# Perform the actual update
perform_update() {
    header "Performing System Update"
    
    # Verify backup was completed
    if [[ "$BACKUP_COMPLETED" != "true" ]]; then
        error_exit "Backup not completed - cannot proceed with update"
    fi
    
    if [[ "$SNAPSHOTS_CREATED" != "true" ]]; then
        warning "No ZFS snapshots were created"
        warning "Rollback capability will be limited"
        
        local response
        read -p "Continue anyway? (yes/no): " response
        if [[ "$response" != "yes" ]]; then
            info "Update cancelled by user"
            exit 0
        fi
    fi
    
    if [[ -z "$ALL_PACKAGES" ]]; then
        warning "No packages to update"
        return 0
    fi
    
    info "Updating packages: $ALL_PACKAGES"
    
    # Perform update with xbps-install
    # Reference: XBPS - https://docs.voidlinux.org/xbps/index.html#updating-the-system
    if xbps-install -yu $ALL_PACKAGES 2>&1 | tee -a "$LOG_FILE"; then
        success "Packages updated successfully"
        
        # Save update flags to config for rollback
        echo "KERNEL_UPDATED=$KERNEL_UPDATED" >> "$CONFIG_FILE"
        echo "ZFS_UPDATED=$ZFS_UPDATED" >> "$CONFIG_FILE"
        echo "DRACUT_UPDATED=$DRACUT_UPDATED" >> "$CONFIG_FILE"
    else
        error_exit "Package update failed"
    fi
    
    # Sync xbps database
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
            
            # Reference: Dracut - https://www.kernel.org/pub/linux/utils/boot/dracut/dracut.html
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
        # Reference: ZFSBootMenu - https://docs.zfsbootmenu.org/en/latest/guides/general/generate-zbm.html
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
        info "Backup manifest: $backup_dir/BACKUP_MANIFEST.txt"
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
        info "4. If issues occur, use zfs-rollback-update.sh to rollback"
    fi
    echo ""
    
    if [[ "$SNAPSHOTS_CREATED" == true ]]; then
        success "ZFS snapshots were created - full rollback is possible"
    else
        warning "No ZFS snapshots were created - rollback capability is limited"
    fi
}

# Main execution
main() {
    header "ZFS/Kernel Update Installation"
    
    check_root
    load_config
    verify_zfs_health
    parse_updates
    
    # CRITICAL: Complete backup BEFORE any updates
    create_backup
    
    # Verify backup completed before proceeding
    if [[ "$BACKUP_COMPLETED" != "true" ]]; then
        error_exit "Backup did not complete successfully - aborting update"
    fi
    
    # Proceed with update
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
