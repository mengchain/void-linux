#!/bin/bash
# filepath: zfs-rollback-update.sh
# ZFS/Kernel Update Rollback Script for Void Linux
# Simple rollback using snapshots and backups created by zfs-install-updates.sh
# Compatible with ZFSBootMenu and traditional boot setups

set -euo pipefail

# Configuration
CONFIG_FILE="/etc/zfs-update.conf"
LOG_FILE="/var/log/zfs-rollback-$(date +%Y%m%d-%H%M%S).log"

# Colors for output - FIXED: Light Blue for consistency
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

error_exit() {
    error "$1"
    log "Rollback failed. Manual intervention may be required."
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root"
    fi
}

load_config() {
    header "Loading Configuration"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error_exit "Configuration file not found: $CONFIG_FILE"
    fi
    
    # Source the config file
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    
    # Validate required variables
    local backup_dir="${BACKUP_DIR:-}"
    local zfsbootmenu="${ZFSBOOTMENU:-false}"
    local pools_exist="${POOLS_EXIST:-false}"
    local esp_mount="${ESP_MOUNT:-/boot/efi}"
    local snapshot_name="${INSTALL_SNAPSHOT_NAME:-${SNAPSHOT_NAME:-}}"
    
    if [[ -z "$backup_dir" ]] || [[ ! -d "$backup_dir" ]]; then
        error_exit "Backup directory not found: ${backup_dir:-<not set>}"
    fi
    
    # Export for use by other functions
    export BACKUP_DIR="$backup_dir"
    export ZFSBOOTMENU="$zfsbootmenu"
    export POOLS_EXIST="$pools_exist"
    export ESP_MOUNT="$esp_mount"
    export SNAPSHOT_NAME="$snapshot_name"
    export KERNEL_UPDATED="${KERNEL_UPDATED:-false}"
    export ZFS_UPDATED="${ZFS_UPDATED:-false}"
    export DRACUT_UPDATED="${DRACUT_UPDATED:-false}"
    
    success "Configuration loaded"
    info "Backup directory: $BACKUP_DIR"
    info "Snapshot name: ${SNAPSHOT_NAME:-none}"
    info "System type: $([ "$ZFSBOOTMENU" = "true" ] && echo "ZFSBootMenu" || echo "Traditional")"
}

validate_backups() {
    header "Backup Validation"
    
    local backup_dir="$BACKUP_DIR"
    local missing_critical=false
    local missing_files=""
    
    info "Validating backup completeness in: $backup_dir"
    
    # Essential ZFS backup files
    local essential_files=(
        "zfs-datasets.txt"
        "zpool-list.txt"
        "exported-pools.txt"
        "installed-packages.txt"
    )
    
    for file in "${essential_files[@]}"; do
        local file_path="$backup_dir/$file"
        if [[ ! -f "$file_path" ]]; then
            missing_files="$missing_files $file"
            missing_critical=true
            error "Missing critical backup file: $file"
        else
            info "Found backup file: $file"
        fi
    done
    
    # System configuration files
    local system_files=(
        "fstab"
        "dracut.conf.d-backup"
    )
    
    for file in "${system_files[@]}"; do
        local file_path="$backup_dir/$file"
        if [[ ! -f "$file_path" ]] && [[ ! -d "$file_path" ]]; then
            warning "Missing system backup: $file"
            missing_files="$missing_files $file"
        else
            info "Found system backup: $file"
        fi
    done
    
    # ZFSBootMenu specific backups
    if [[ "$ZFSBOOTMENU" == "true" ]]; then
        local zbm_files=(
            "zfsbootmenu-config.yaml"
            "esp-complete-backup"
        )
        
        for file in "${zbm_files[@]}"; do
            local file_path="$backup_dir/$file"
            if [[ ! -f "$file_path" ]] && [[ ! -d "$file_path" ]]; then
                warning "Missing ZFSBootMenu backup: $file"
            else
                info "Found ZFSBootMenu backup: $file"
            fi
        done
    fi
    
    # Validate snapshots exist
    if [[ -n "$SNAPSHOT_NAME" ]]; then
        info "Checking for ZFS snapshots with name: $SNAPSHOT_NAME"
        
        # FIXED SIGPIPE: Capture zfs list output first
        local datasets
        datasets=$(zfs list -t filesystem -H -o name 2>/dev/null || echo "")
        
        if [[ -z "$datasets" ]]; then
            warning "No ZFS datasets found"
        else
            local snapshot_found=false
            while IFS= read -r dataset; do
                [[ -z "$dataset" ]] && continue
                
                local snapshot="$dataset@$SNAPSHOT_NAME"
                # FIXED SIGPIPE: Capture existence check
                local snapshot_exists
                snapshot_exists=$(zfs list -t snapshot -H -o name "$snapshot" 2>/dev/null || echo "")
                
                if [[ -n "$snapshot_exists" ]]; then
                    info "Found snapshot: $snapshot"
                    snapshot_found=true
                fi
            done <<< "$datasets"
            
            if [[ "$snapshot_found" == "false" ]]; then
                warning "No snapshots found with name: $SNAPSHOT_NAME"
                warning "Snapshot-based rollback will not be available"
            fi
        fi
    else
        warning "No snapshot name provided - snapshot rollback not available"
    fi
    
    if [[ "$missing_critical" == "true" ]]; then
        error_exit "Critical backup files missing: $missing_files"
    fi
    
    success "Backup validation completed"
}

confirm_rollback() {
    header "Rollback Confirmation"
    
    warning "This will rollback your system to the pre-update state"
    warning "Current system state will be LOST"
    
    echo ""
    info "Rollback will include:"
    echo "  • ZFS snapshots rollback (if available)"
    echo "  • Package version rollback (if possible)"
    echo "  • Configuration file restoration"
    if [[ "$ZFSBOOTMENU" == "true" ]]; then
        echo "  • ZFSBootMenu configuration restoration"
        echo "  • ESP (boot partition) restoration"
    fi
    echo "  • Initramfs rebuild"
    echo ""
    
    local response
    read -p "Do you want to proceed with rollback? (yes/no): " response
    
    if [[ "$response" != "yes" ]]; then
        info "Rollback cancelled by user"
        exit 0
    fi
    
    warning "Starting rollback in 5 seconds... Press Ctrl+C to abort"
    sleep 5
}

backup_current_state() {
    header "Backup Current State"
    
    local current_backup_dir="$BACKUP_DIR/pre-rollback-$(date +%Y%m%d-%H%M%S)"
    
    info "Creating backup of current state: $current_backup_dir"
    mkdir -p "$current_backup_dir"
    
    # Backup current package state - FIXED SIGPIPE
    local current_packages
    current_packages=$(xbps-query -l 2>/dev/null || echo "")
    if [[ -n "$current_packages" ]]; then
        echo "$current_packages" > "$current_backup_dir/current-packages.txt"
    fi
    
    # Backup current ZFS state - FIXED SIGPIPE
    local current_zpools current_datasets
    current_zpools=$(zpool list 2>/dev/null || echo "")
    current_datasets=$(zfs list 2>/dev/null || echo "")
    
    if [[ -n "$current_zpools" ]]; then
        echo "$current_zpools" > "$current_backup_dir/current-zpools.txt"
    fi
    
    if [[ -n "$current_datasets" ]]; then
        echo "$current_datasets" > "$current_backup_dir/current-datasets.txt"
    fi
    
    # Backup critical configs
    [[ -f /etc/fstab ]] && cp /etc/fstab "$current_backup_dir/current-fstab" 2>/dev/null || true
    
    if [[ "$ZFSBOOTMENU" == "true" ]] && [[ -f "/etc/zfsbootmenu/config.yaml" ]]; then
        cp /etc/zfsbootmenu/config.yaml "$current_backup_dir/current-zfsbootmenu-config.yaml" 2>/dev/null || true
    fi
    
    success "Current state backed up to: $current_backup_dir"
}

attempt_package_rollback() {
    header "Package Rollback"
    
    local backup_file="$BACKUP_DIR/installed-packages.txt"
    
    if [[ ! -f "$backup_file" ]]; then
        warning "No package backup found - skipping package rollback"
        return 0
    fi
    
    info "Attempting to rollback packages using backup: $backup_file"
    
    # Read original package versions and attempt rollback
    local rollback_attempted=false
    local rollback_success=false
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        
        local pkg_name pkg_version
        pkg_name=$(echo "$line" | awk '{print $1}')
        pkg_version=$(echo "$line" | awk '{print $2}')
        
        # Focus on ZFS and kernel packages
        if [[ "$pkg_name" =~ ^(zfs|linux|zfsbootmenu|dracut) ]]; then
            info "Attempting to rollback package: $pkg_name to version $pkg_version"
            rollback_attempted=true
            
            # Try exact version install
            if xbps-install -y -f "${pkg_name}-${pkg_version}" 2>&1 | tee -a "$LOG_FILE"; then
                success "Rolled back $pkg_name to $pkg_version"
                rollback_success=true
            else
                # Try from cache - FIXED SIGPIPE
                info "Searching for cached package..."
                local cached_pkg
                cached_pkg=$(find /var/cache/xbps -name "${pkg_name}-${pkg_version}*.xbps" 2>/dev/null | head -1 || echo "")
                
                if [[ -n "$cached_pkg" ]] && [[ -f "$cached_pkg" ]]; then
                    if xbps-install -y -f "$cached_pkg" 2>&1 | tee -a "$LOG_FILE"; then
                        success "Rolled back $pkg_name from cache"
                        rollback_success=true
                    else
                        warning "Failed to rollback $pkg_name from cache"
                    fi
                else
                    warning "Package $pkg_name version $pkg_version not available"
                    warning "You may need to download manually from: https://repo-default.voidlinux.org/current/"
                fi
            fi
        fi
    done < "$backup_file"
    
    if [[ "$rollback_attempted" == "false" ]]; then
        info "No relevant packages found for rollback"
    elif [[ "$rollback_success" == "true" ]]; then
        success "Some packages were successfully rolled back"
        
        # Reload ZFS modules if ZFS was rolled back
        if [[ "$ZFS_UPDATED" == "true" ]]; then
            reload_zfs_modules
        fi
    else
        warning "Package rollback attempted but may not have been successful"
        warning "Consider manual package installation or system restore"
    fi
}

reload_zfs_modules() {
    header "Reloading ZFS Modules"
    
    # Check if pools are mounted - FIXED SIGPIPE
    local mounted_pools
    mounted_pools=$(zfs list -H -o name 2>/dev/null | wc -l)
    
    if [[ "$mounted_pools" -gt 0 ]]; then
        error "Cannot reload ZFS modules while pools are mounted"
        error "Please export all pools first or reboot the system"
        return 1
    fi
    
    info "Unloading ZFS modules..."
    
    # Unload ZFS modules in correct dependency order (Void Linux specific)
    local modules=(zfs zunicode zavl icp zcommon znvpair spl)
    
    for module in "${modules[@]}"; do
        # FIXED SIGPIPE: Capture lsmod output first
        local lsmod_output
        lsmod_output=$(lsmod 2>/dev/null || echo "")
        
        if echo "$lsmod_output" | grep -q "^$module "; then
            info "Unloading module: $module"
            if ! modprobe -r "$module" 2>/dev/null; then
                warning "Failed to unload $module (may be in use)"
            fi
        fi
    done
    
    # Small delay for clean unload
    sleep 2
    
    # Reload ZFS - Void Linux uses pre-compiled modules
    info "Loading ZFS module..."
    if modprobe zfs 2>&1 | tee -a "$LOG_FILE"; then
        success "ZFS modules reloaded successfully"
        
        # Verify ZFS functionality - FIXED SIGPIPE
        local zpool_test
        zpool_test=$(zpool list 2>/dev/null || echo "error")
        
        if [[ "$zpool_test" != "error" ]]; then
            success "ZFS functionality verified"
        else
            warning "ZFS module loaded but pools not accessible"
        fi
    else
        error "Failed to reload ZFS modules"
        
        # Diagnostics for Void Linux
        local running_kernel
        running_kernel=$(uname -r)
        error "Running kernel: $running_kernel"
        
        local zfs_module_path="/lib/modules/$running_kernel/extra/zfs/zfs.ko"
        if [[ -f "$zfs_module_path" ]]; then
            error "ZFS module exists but won't load: $zfs_module_path"
            error "Try: dmesg | tail -20 for more information"
        else
            error "ZFS module not found for kernel: $running_kernel"
            error "This indicates a kernel/ZFS package version mismatch"
            error "You may need to boot to an older kernel version"
        fi
        
        return 1
    fi
}

export_zfs_pools() {
    header "Exporting ZFS Pools"
    
    if [[ "$POOLS_EXIST" != "true" ]]; then
        info "No ZFS pools detected - skipping pool export"
        return 0
    fi
    
    # FIXED SIGPIPE: Capture pool list first
    local pools
    pools=$(zpool list -H -o name 2>/dev/null || echo "")
    
    if [[ -z "$pools" ]]; then
        info "No pools currently imported"
        return 0
    fi
    
    info "Exporting ZFS pools for rollback..."
    
    while IFS= read -r pool; do
        [[ -z "$pool" ]] && continue
        
        info "Exporting pool: $pool"
        if zpool export "$pool" 2>&1 | tee -a "$LOG_FILE"; then
            success "Exported pool: $pool"
        else
            warning "Failed to export pool: $pool (may be in use)"
            warning "Try: lsof | grep $pool to find processes using the pool"
        fi
    done <<< "$pools"
}

rollback_zfs_snapshots() {
    header "ZFS Snapshot Rollback"
    
    if [[ -z "$SNAPSHOT_NAME" ]]; then
        warning "No snapshot name available - skipping snapshot rollback"
        return 0
    fi
    
    info "Rolling back ZFS datasets to snapshot: $SNAPSHOT_NAME"
    
    # Get all datasets from backup
    local backup_datasets="$BACKUP_DIR/zfs-datasets.txt"
    if [[ ! -f "$backup_datasets" ]]; then
        warning "No dataset backup found - skipping snapshot rollback"
        return 0
    fi
    
    local rollback_success=false
    local rollback_count=0
    
    while IFS= read -r dataset; do
        [[ -z "$dataset" ]] && continue
        
        local snapshot="$dataset@$SNAPSHOT_NAME"
        
        info "Attempting rollback: $snapshot"
        
        # Check if snapshot exists - FIXED SIGPIPE
        local snapshot_check
        snapshot_check=$(zfs list -t snapshot -H -o name "$snapshot" 2>/dev/null || echo "")
        
        if [[ -n "$snapshot_check" ]]; then
            # Try rollback with -r flag to handle newer snapshots
            if zfs rollback -r "$snapshot" 2>&1 | tee -a "$LOG_FILE"; then
                success "Rolled back: $snapshot"
                rollback_success=true
                ((rollback_count++))
            else
                error "Failed to rollback: $snapshot"
                error "This may indicate:"
                error "  • Newer snapshots exist (use -R to destroy them)"
                error "  • Dataset is busy or mounted"
                error "  • Insufficient permissions"
            fi
        else
            warning "Snapshot not found: $snapshot"
        fi
    done < "$backup_datasets"
    
    if [[ "$rollback_success" == "true" ]]; then
        success "ZFS snapshot rollback completed ($rollback_count dataset(s))"
    else
        warning "No snapshots were successfully rolled back"
        warning "You may need to manually rollback with: zfs rollback -R dataset@snapshot"
    fi
}

reimport_zfs_pools() {
    header "Reimporting ZFS Pools"
    
    if [[ "$POOLS_EXIST" != "true" ]]; then
        info "No ZFS pools to import"
        return 0
    fi
    
    info "Re-importing ZFS pools after rollback..."
    
    # Try importing all pools
    if zpool import -a -N 2>&1 | tee -a "$LOG_FILE"; then
        success "Pools imported successfully"
    else
        warning "Automatic import failed, trying individual pools..."
        
        # Try individual pool import from backup
        local exported_pools="$BACKUP_DIR/exported-pools.txt"
        if [[ -f "$exported_pools" ]]; then
            while IFS= read -r pool; do
                [[ -z "$pool" ]] && continue
                
                info "Importing pool: $pool"
                
                if zpool import -N "$pool" 2>&1 | tee -a "$LOG_FILE"; then
                    success "Imported pool: $pool"
                else
                    error "Failed to import pool: $pool"
                    error "Try manually: zpool import -f $pool"
                fi
            done < "$exported_pools"
        fi
    fi
    
    # Load encryption keys and mount datasets
    info "Loading encryption keys and mounting datasets..."
    
    # Load keys - FIXED SIGPIPE
    local key_load_result
    key_load_result=$(zfs load-key -a 2>&1 || echo "")
    if [[ -n "$key_load_result" ]]; then
        info "Encryption keys loaded"
    fi
    
    # Mount datasets - FIXED SIGPIPE
    local mount_result
    mount_result=$(zfs mount -a 2>&1 || echo "")
    if [[ -n "$mount_result" ]]; then
        info "Datasets mounted"
    fi
    
    # Verify bootfs is set correctly for boot pool
    local boot_pool
    boot_pool=$(zpool list -H -o name,bootfs 2>/dev/null | grep -v '^-' | awk '{print $1}' | head -1 || echo "")
    
    if [[ -n "$boot_pool" ]]; then
        info "Verifying bootfs property on pool: $boot_pool"
        local bootfs
        bootfs=$(zpool get -H -o value bootfs "$boot_pool" 2>/dev/null || echo "")
        
        if [[ -n "$bootfs" ]] && [[ "$bootfs" != "-" ]]; then
            success "bootfs is set: $bootfs"
        else
            warning "bootfs is not set on boot pool"
            warning "You may need to set it manually: zpool set bootfs=zroot/ROOT/void $boot_pool"
        fi
    fi
    
    success "Pool import and mount completed"
}

restore_configurations() {
    header "Restoring Configurations"
    
    local restored=0
    
    # Restore /etc/fstab
    if [[ -f "$BACKUP_DIR/fstab" ]]; then
        info "Restoring /etc/fstab"
        cp "$BACKUP_DIR/fstab" /etc/fstab
        success "Restored /etc/fstab"
        ((restored++))
    else
        warning "No fstab backup found"
    fi
    
    # Restore dracut configuration
    if [[ -d "$BACKUP_DIR/dracut.conf.d-backup" ]]; then
        info "Restoring dracut configuration"
        
        # Backup current dracut config
        if [[ -d /etc/dracut.conf.d ]]; then
            mv /etc/dracut.conf.d /etc/dracut.conf.d.rollback-backup 2>/dev/null || true
        fi
        
        cp -r "$BACKUP_DIR/dracut.conf.d-backup" /etc/dracut.conf.d
        success "Restored dracut configuration"
        ((restored++))
    else
        warning "No dracut configuration backup found"
    fi
    
    # Restore ZFSBootMenu configuration
    if [[ "$ZFSBOOTMENU" == "true" ]] && [[ -f "$BACKUP_DIR/zfsbootmenu-config.yaml" ]]; then
        info "Restoring ZFSBootMenu configuration"
        mkdir -p /etc/zfsbootmenu
        cp "$BACKUP_DIR/zfsbootmenu-config.yaml" /etc/zfsbootmenu/config.yaml
        success "Restored ZFSBootMenu configuration"
        ((restored++))
    fi
    
    if [[ $restored -gt 0 ]]; then
        success "Configuration restoration completed ($restored file(s))"
    else
        warning "No configurations were restored"
    fi
}

restore_esp() {
    if [[ "$ZFSBOOTMENU" != "true" ]]; then
        info "Not a ZFSBootMenu system - skipping ESP restore"
        return 0
    fi
    
    header "ESP Restoration"
    
    local esp_backup="$BACKUP_DIR/esp-complete-backup"
    
    if [[ ! -d "$esp_backup" ]]; then
        warning "No ESP backup found - skipping ESP restore"
        return 0
    fi
    
    # Check if ESP is mounted
    if [[ ! -d "$ESP_MOUNT" ]] || ! mountpoint -q "$ESP_MOUNT"; then
        warning "ESP not mounted at $ESP_MOUNT - attempting to mount"
        
        # Try to find and mount ESP - FIXED SIGPIPE
        local esp_device
        esp_device=$(blkid -t TYPE=vfat 2>/dev/null | grep -E '/dev/(sd|nvme)' | cut -d: -f1 | head -1 || echo "")
        
        if [[ -n "$esp_device" ]]; then
            mkdir -p "$ESP_MOUNT"
            if mount "$esp_device" "$ESP_MOUNT" 2>&1 | tee -a "$LOG_FILE"; then
                info "Mounted ESP: $esp_device at $ESP_MOUNT"
            else
                error "Failed to mount ESP - skipping ESP restore"
                return 1
            fi
        else
            error "Could not locate ESP device - skipping ESP restore"
            error "Try: blkid -t TYPE=vfat to find ESP manually"
            return 1
        fi
    fi
    
    warning "ESP restore will overwrite current bootloader files"
    local response
    read -p "Continue with ESP restore? (yes/no): " response
    
    if [[ "$response" != "yes" ]]; then
        info "ESP restore skipped by user"
        return 0
    fi
    
    info "Restoring ESP from backup: $esp_backup"
    
    # Create safety backup of current ESP
    local safety_backup="/tmp/esp-safety-backup-$(date +%Y%m%d-%H%M%S)"
    if cp -r "$ESP_MOUNT" "$safety_backup" 2>/dev/null; then
        info "Current ESP backed up to: $safety_backup"
    else
        warning "Failed to create safety backup of current ESP"
    fi
    
    # Restore ESP contents
    info "Copying ESP backup to $ESP_MOUNT..."
    if cp -rv "$esp_backup"/* "$ESP_MOUNT"/ 2>&1 | tee -a "$LOG_FILE"; then
        sync
        success "ESP restoration completed"
        
        # Verify critical files exist
        if [[ -f "$ESP_MOUNT/EFI/ZBM/vmlinuz.efi" ]]; then
            success "ZFSBootMenu EFI image verified"
        else
            warning "ZFSBootMenu EFI image not found after restore"
        fi
    else
        error "ESP restoration failed"
        
        # Attempt to restore from safety backup
        if [[ -d "$safety_backup" ]]; then
            warning "Attempting to restore from safety backup"
            rm -rf "${ESP_MOUNT:?}"/* 2>/dev/null || true
            cp -r "$safety_backup"/* "$ESP_MOUNT"/ 2>/dev/null || true
        fi
        
        return 1
    fi
}

rebuild_initramfs() {
    header "Rebuilding Initramfs"
    
    if [[ "$DRACUT_UPDATED" == "true" ]] || [[ "$KERNEL_UPDATED" == "true" ]] || [[ "$ZFS_UPDATED" == "true" ]]; then
        info "Critical components were updated, rebuilding initramfs..."
        
        # Get current kernel version
        local current_kernel
        current_kernel=$(uname -r)
        
        info "Rebuilding initramfs for kernel: $current_kernel"
        
        if dracut --force --kver "$current_kernel" 2>&1 | tee -a "$LOG_FILE"; then
            success "Initramfs rebuilt successfully"
            
            # Verify initramfs was created
            if [[ -f "/boot/initramfs-${current_kernel}.img" ]]; then
                success "Initramfs file verified"
                
                # Check for ZFS module in initramfs - FIXED SIGPIPE
                if command -v lsinitrd &>/dev/null; then
                    local initrd_content
                    initrd_content=$(lsinitrd "/boot/initramfs-${current_kernel}.img" 2>/dev/null || echo "")
                    
                    if [[ -n "$initrd_content" ]]; then
                        if echo "$initrd_content" | grep -q "zfs.ko"; then
                            success "ZFS module verified in initramfs"
                        else
                            warning "ZFS module NOT found in initramfs!"
                            warning "You may need to rebuild with: dracut -f --add zfs"
                        fi
                    fi
                fi
            else
                error "Initramfs file not found: /boot/initramfs-${current_kernel}.img"
            fi
        else
            error "Initramfs rebuild failed"
            error "Try manually: dracut -f --kver $current_kernel"
        fi
        
        # Update ZFSBootMenu if applicable
        if [[ "$ZFSBOOTMENU" == "true" ]]; then
            info "Regenerating ZFSBootMenu images..."
            
            if command -v generate-zbm &>/dev/null; then
                if generate-zbm 2>&1 | tee -a "$LOG_FILE"; then
                    success "ZFSBootMenu images regenerated"
                    
                    # Verify ZBM EFI file
                    if [[ -f "/boot/efi/EFI/ZBM/vmlinuz.efi" ]]; then
                        success "ZFSBootMenu EFI image verified"
                    else
                        warning "ZFSBootMenu EFI image not found"
                    fi
                else
                    warning "ZFSBootMenu regeneration failed"
                    info "Trying alternative method with xbps-reconfigure..."
                    xbps-reconfigure -f zfsbootmenu 2>&1 | tee -a "$LOG_FILE" || warning "xbps-reconfigure also failed"
                fi
            else
                warning "generate-zbm command not found"
                info "Try: xbps-reconfigure -f zfsbootmenu"
            fi
        fi
    else
        info "No kernel, dracut, or ZFS changes detected - skipping initramfs rebuild"
    fi
}

verify_rollback() {
    header "Rollback Verification"
    
    local verification_failed=false
    
    # Verify ZFS functionality
    info "Verifying ZFS functionality..."
    
    # Check ZFS commands available
    if ! command -v zpool &>/dev/null; then
        error "ZFS commands not available"
        verification_failed=true
    else
        # Check if we can list pools - FIXED SIGPIPE
        local pool_list
        pool_list=$(zpool list 2>&1 || echo "error")
        
        if [[ "$pool_list" == "error" ]] || [[ -z "$pool_list" ]]; then
            warning "Cannot access ZFS pools"
            verification_failed=true
        else
            success "ZFS pools accessible"
            
            # Check pool health - FIXED SIGPIPE
            local unhealthy_pools
            unhealthy_pools=$(zpool list -H -o name,health 2>/dev/null | grep -v "ONLINE" | awk '{print $1}' || echo "")
            
            if [[ -n "$unhealthy_pools" ]]; then
                warning "Unhealthy pools detected: $unhealthy_pools"
                warning "Check pool status with: zpool status $unhealthy_pools"
                verification_failed=true
            else
                success "All pools healthy"
            fi
        fi
    fi
    
    # Verify datasets mounted - FIXED SIGPIPE
    info "Verifying dataset mounts..."
    local mount_output
    mount_output=$(mount 2>/dev/null || echo "")
    
    local root_mounted
    root_mounted=$(echo "$mount_output" | grep -c "zroot/" || echo "0")
    
    if [[ "$root_mounted" -gt 0 ]]; then
        success "ZFS datasets appear to be mounted ($root_mounted dataset(s))"
    else
        warning "No ZFS root datasets detected in mounts"
        warning "You may need to: zfs mount -a"
        verification_failed=true
    fi
    
    # Verify boot setup
    if [[ "$ZFSBOOTMENU" == "true" ]]; then
        info "Verifying ZFSBootMenu setup..."
        
        if [[ -f "$ESP_MOUNT/EFI/ZBM/vmlinuz.efi" ]]; then
            success "ZFSBootMenu EFI image found"
        else
            error "ZFSBootMenu EFI image missing: $ESP_MOUNT/EFI/ZBM/vmlinuz.efi"
            verification_failed=true
        fi
        
        # Check EFI boot entries - FIXED SIGPIPE
        if command -v efibootmgr &>/dev/null; then
            local efi_entries
            efi_entries=$(efibootmgr 2>/dev/null || echo "")
            
            if [[ -n "$efi_entries" ]]; then
                if echo "$efi_entries" | grep -qi "zfsbootmenu\|ZBM"; then
                    success "ZFSBootMenu found in EFI boot entries"
                else
                    warning "ZFSBootMenu not found in EFI boot entries"
                    info "You may need to create boot entry manually"
                fi
            fi
        fi
    fi
    
    # Verify kernel/ZFS module compatibility
    info "Verifying kernel/ZFS module compatibility..."
    local current_kernel
    current_kernel=$(uname -r)
    local zfs_module="/lib/modules/$current_kernel/extra/zfs/zfs.ko"
    
    if [[ -f "$zfs_module" ]]; then
        success "ZFS module exists for current kernel"
    else
        warning "ZFS module not found for kernel: $current_kernel"
        warning "Path checked: $zfs_module"
        verification_failed=true
    fi
    
    if [[ "$verification_failed" == "true" ]]; then
        error "Rollback verification found issues"
        warning "Manual intervention may be required"
        return 1
    else
        success "Rollback verification completed successfully"
        return 0
    fi
}

show_rollback_summary() {
    header "Rollback Summary"
    
    info "Rollback operations completed at: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "Operations performed:"
    echo "  ✓ Backup validation"
    echo "  ✓ Current state backup"
    echo "  ✓ Package rollback (attempted)"
    echo "  ✓ ZFS pool export/import"
    echo "  ✓ ZFS snapshot rollback"
    echo "  ✓ Configuration restoration"
    if [[ "$ZFSBOOTMENU" == "true" ]]; then
        echo "  ✓ ESP restoration"
    fi
    echo "  ✓ Initramfs rebuild"
    echo "  ✓ System verification"
    echo ""
    
    info "Log file: $LOG_FILE"
    
    if [[ -f /tmp/zfs-update-backup.txt ]]; then
        local backup_dir
        backup_dir=$(cat /tmp/zfs-update-backup.txt)
        info "Original backup: $backup_dir"
    fi
    
    echo ""
    if verify_rollback; then
        success "System rollback completed successfully"
        echo ""
        warning "IMPORTANT: Please reboot the system to complete rollback"
        echo ""
        info "After reboot, verify:"
        info "  • System boots correctly"
        info "  • ZFS pools import automatically"
        info "  • All datasets are accessible"
        info "  • Services start normally"
        echo ""
    else
        error "Rollback completed but verification found issues"
        echo ""
        warning "DO NOT REBOOT until issues are resolved"
        warning "Recommended actions:"
        info "  1. Review this log: $LOG_FILE"
        info "  2. Check ZFS pool status: zpool status"
        info "  3. Check ZFS mounts: zfs list"
        info "  4. Run health check: zfs-health-check.sh"
        info "  5. Run post-update verification: zfs-post-update-verify.sh"
        echo ""
    fi
}

main() {
    header "ZFS ROLLBACK SCRIPT - VOID LINUX"
    
    check_root
    load_config
    validate_backups
    confirm_rollback
    
    # Perform rollback operations
    backup_current_state
    attempt_package_rollback
    export_zfs_pools
    rollback_zfs_snapshots
    reimport_zfs_pools
    restore_configurations
    restore_esp
    rebuild_initramfs
    
    # Final verification and summary
    show_rollback_summary
    
    info "Rollback script completed"
}

# Trap to ensure cleanup on exit
trap 'echo "Script interrupted - rollback may be incomplete"; exit 1' INT TERM

main "$@"
