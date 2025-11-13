#!/bin/bash
# filepath: zfs-rollback-update.sh
# ZFS/Kernel Update Rollback Script for Void Linux
# Simple rollback using snapshots and backups created by zfs-install-updates.sh

set -euo pipefail

# Configuration
readonly CONFIG_FILE="/etc/zfs-update.conf"
readonly LOG_FILE="/var/log/zfs-rollback-$(date +%Y%m%d-%H%M%S).log"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

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
    log "Rollback failed. Manual intervention may be required."
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root"
    fi
}

load_config() {
    local config_file="$CONFIG_FILE"
    
    if [[ ! -f "$config_file" ]]; then
        error_exit "Configuration file not found: $config_file"
    fi
    
    # Source the config file
    source "$config_file"
    
    # Validate required variables with local defaults
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
    
    info "Configuration loaded for rollback"
    info "Backup directory: $BACKUP_DIR"
    info "Snapshot name: ${SNAPSHOT_NAME:-none}"
    info "System type: $([ "$ZFSBOOTMENU" = "true" ] && echo "ZFSBootMenu" || echo "Traditional")"
}

validate_backups() {
    header "BACKUP VALIDATION"
    
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
        local datasets
        datasets=$(zfs list -t filesystem -H -o name 2>/dev/null || true)
        
        local snapshot_found=false
        while IFS= read -r dataset; do
            if [[ -n "$dataset" ]]; then
                local snapshot="$dataset@$SNAPSHOT_NAME"
                if zfs list -t snapshot "$snapshot" >/dev/null 2>&1; then
                    info "Found snapshot: $snapshot"
                    snapshot_found=true
                fi
            fi
        done <<< "$datasets"
        
        if [[ "$snapshot_found" == "false" ]]; then
            warning "No snapshots found with name: $SNAPSHOT_NAME"
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
    header "ROLLBACK CONFIRMATION"
    
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
    header "BACKUP CURRENT STATE"
    
    local current_backup_dir="$BACKUP_DIR/pre-rollback-$(date +%Y%m%d-%H%M%S)"
    
    info "Creating backup of current state: $current_backup_dir"
    mkdir -p "$current_backup_dir"
    
    # Backup current package state
    xbps-query -l > "$current_backup_dir/current-packages.txt" 2>/dev/null || true
    
    # Backup current ZFS state
    zpool list > "$current_backup_dir/current-zpools.txt" 2>/dev/null || true
    zfs list > "$current_backup_dir/current-datasets.txt" 2>/dev/null || true
    
    # Backup critical configs
    cp /etc/fstab "$current_backup_dir/current-fstab" 2>/dev/null || true
    
    if [[ "$ZFSBOOTMENU" == "true" ]] && [[ -f "/etc/zfsbootmenu/config.yaml" ]]; then
        cp /etc/zfsbootmenu/config.yaml "$current_backup_dir/current-zfsbootmenu-config.yaml" 2>/dev/null || true
    fi
    
    success "Current state backed up to: $current_backup_dir"
}

attempt_package_rollback() {
    header "PACKAGE ROLLBACK"
    
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
        if [[ -n "$line" ]]; then
            local pkg_name
            local pkg_version
            pkg_name=$(echo "$line" | awk '{print $1}')
            pkg_version=$(echo "$line" | awk '{print $2}')
            
            # Focus on ZFS and kernel packages
            if [[ "$pkg_name" =~ ^(zfs|linux|zfsbootmenu|dracut) ]]; then
                info "Attempting to rollback package: $pkg_name to version $pkg_version"
                rollback_attempted=true
                
                # Try exact version install
                if xbps-install -y -f "${pkg_name}-${pkg_version}" 2>/dev/null; then
                    success "Rolled back $pkg_name to $pkg_version"
                    rollback_success=true
                else
                    # Try from cache
                    local cached_pkg
                    cached_pkg=$(find /var/cache/xbps -name "${pkg_name}-${pkg_version}*.xbps" 2>/dev/null | head -1 || true)
                    
                    if [[ -n "$cached_pkg" ]] && [[ -f "$cached_pkg" ]]; then
                        if xbps-install -y -f "$cached_pkg" 2>/dev/null; then
                            success "Rolled back $pkg_name from cache"
                            rollback_success=true
                        else
                            warning "Failed to rollback $pkg_name from cache"
                        fi
                    else
                        warning "Package $pkg_name version $pkg_version not available in cache"
                    fi
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
        warning "Package rollback was attempted but may not have been successful"
    fi
}

reload_zfs_modules() {
    info "Reloading ZFS modules after package rollback..."
    
    # Unload ZFS modules in correct dependency order (Void Linux specific)
    local modules=(zfs zunicode zavl icp zcommon znvpair spl)
    
    for module in "${modules[@]}"; do
        if lsmod | grep -q "^$module"; then
            info "Unloading module: $module"
            modprobe -r "$module" 2>/dev/null || warning "Failed to unload $module"
        fi
    done
    
    # Small delay for clean unload
    sleep 2
    
    # Reload ZFS - Void Linux uses pre-compiled modules
    if modprobe zfs; then
        success "ZFS modules reloaded successfully"
        
        # Verify ZFS functionality
        if zpool list >/dev/null 2>&1; then
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
        
        local zfs_module_path="/lib/modules/$running_kernel/extra/zfs.ko"
        if [[ -f "$zfs_module_path" ]]; then
            error "ZFS module exists but won't load: $zfs_module_path"
        else
            error "ZFS module not found for kernel: $running_kernel"
            error "This indicates a kernel/ZFS package version mismatch"
        fi
        
        return 1
    fi
}

export_zfs_pools() {
    header "EXPORTING ZFS POOLS"
    
    if [[ "$POOLS_EXIST" != "true" ]]; then
        info "No ZFS pools detected - skipping pool export"
        return 0
    fi
    
    local pools
    pools=$(zpool list -H -o name 2>/dev/null || true)
    
    if [[ -z "$pools" ]]; then
        info "No pools currently imported"
        return 0
    fi
    
    info "Exporting ZFS pools for rollback..."
    
    while IFS= read -r pool; do
        if [[ -n "$pool" ]]; then
            info "Exporting pool: $pool"
            if zpool export "$pool" 2>/dev/null; then
                success "Exported pool: $pool"
            else
                warning "Failed to export pool: $pool (may be in use)"
            fi
        fi
    done <<< "$pools"
}

rollback_zfs_snapshots() {
    header "ZFS SNAPSHOT ROLLBACK"
    
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
    
    while IFS= read -r dataset; do
        if [[ -n "$dataset" ]]; then
            local snapshot="$dataset@$SNAPSHOT_NAME"
            
            info "Attempting rollback: $snapshot"
            
            # Check if snapshot exists
            if zfs list -t snapshot "$snapshot" >/dev/null 2>&1; then
                # Try rollback with -r flag to handle newer snapshots
                if zfs rollback -r "$snapshot" 2>/dev/null; then
                    success "Rolled back: $snapshot"
                    rollback_success=true
                else
                    warning "Failed to rollback: $snapshot"
                fi
            else
                warning "Snapshot not found: $snapshot"
            fi
        fi
    done < "$backup_datasets"
    
    if [[ "$rollback_success" == "true" ]]; then
        success "ZFS snapshot rollback completed"
    else
        warning "No snapshots were successfully rolled back"
    fi
}

reimport_zfs_pools() {
    header "REIMPORTING ZFS POOLS"
    
    if [[ "$POOLS_EXIST" != "true" ]]; then
        info "No ZFS pools to import"
        return 0
    fi
    
    info "Re-importing ZFS pools after rollback..."
    
    # Try importing all pools
    if zpool import -a -N 2>/dev/null; then
        success "Pools imported successfully"
    else
        # Try individual pool import from backup
        local exported_pools="$BACKUP_DIR/exported-pools.txt"
        if [[ -f "$exported_pools" ]]; then
            while IFS= read -r pool; do
                if [[ -n "$pool" ]]; then
                    info "Importing pool: $pool"
                    
                    if zpool import -N "$pool" 2>/dev/null; then
                        success "Imported pool: $pool"
                    else
                        warning "Failed to import pool: $pool"
                    fi
                fi
            done < "$exported_pools"
        fi
    fi
    
    # Load encryption keys and mount datasets
    info "Loading encryption keys and mounting datasets..."
    zfs load-key -a 2>/dev/null || true
    zfs mount -a 2>/dev/null || true
    
    success "Pool import and mount completed"
}

restore_configurations() {
    header "RESTORING CONFIGURATIONS"
    
    # Restore /etc/fstab
    if [[ -f "$BACKUP_DIR/fstab" ]]; then
        info "Restoring /etc/fstab"
        cp "$BACKUP_DIR/fstab" /etc/fstab
        success "Restored /etc/fstab"
    fi
    
    # Restore dracut configuration
    if [[ -d "$BACKUP_DIR/dracut.conf.d-backup" ]]; then
        info "Restoring dracut configuration"
        rm -rf /etc/dracut.conf.d.rollback-backup 2>/dev/null || true
        mv /etc/dracut.conf.d /etc/dracut.conf.d.rollback-backup 2>/dev/null || true
        cp -r "$BACKUP_DIR/dracut.conf.d-backup" /etc/dracut.conf.d
        success "Restored dracut configuration"
    fi
    
    # Restore ZFSBootMenu configuration
    if [[ "$ZFSBOOTMENU" == "true" ]] && [[ -f "$BACKUP_DIR/zfsbootmenu-config.yaml" ]]; then
        info "Restoring ZFSBootMenu configuration"
        mkdir -p /etc/zfsbootmenu
        cp "$BACKUP_DIR/zfsbootmenu-config.yaml" /etc/zfsbootmenu/config.yaml
        success "Restored ZFSBootMenu configuration"
    fi
    
    success "Configuration restoration completed"
}

restore_esp() {
    if [[ "$ZFSBOOTMENU" != "true" ]]; then
        info "Not a ZFSBootMenu system - skipping ESP restore"
        return 0
    fi
    
    header "ESP RESTORATION"
    
    local esp_backup="$BACKUP_DIR/esp-complete-backup"
    
    if [[ ! -d "$esp_backup" ]]; then
        warning "No ESP backup found - skipping ESP restore"
        return 0
    fi
    
    if [[ ! -d "$ESP_MOUNT" ]] || ! mountpoint -q "$ESP_MOUNT"; then
        warning "ESP not mounted at $ESP_MOUNT - attempting to mount"
        
        # Try to find and mount ESP
        local esp_device
        esp_device=$(blkid -t TYPE=vfat | grep -E '/dev/(sd|nvme)' | head -1 | cut -d: -f1 || true)
        
        if [[ -n "$esp_device" ]]; then
            mkdir -p "$ESP_MOUNT"
            if mount "$esp_device" "$ESP_MOUNT"; then
                info "Mounted ESP: $esp_device at $ESP_MOUNT"
            else
                error "Failed to mount ESP - skipping ESP restore"
                return 1
            fi
        else
            error "Could not locate ESP device - skipping ESP restore"
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
    cp -r "$ESP_MOUNT" "$safety_backup" 2>/dev/null || true
    info "Current ESP backed up to: $safety_backup"
    
    # Restore ESP contents
    if cp -r "$esp_backup"/* "$ESP_MOUNT"/ 2>/dev/null; then
        sync
        success "ESP restoration completed"
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
    header "REBUILDING INITRAMFS"
    
    if [[ "$DRACUT_UPDATED" == "true" ]] || [[ "$KERNEL_UPDATED" == "true" ]]; then
        info "Rebuilding initramfs after rollback..."
        
        # Get current kernel version
        local current_kernel
        current_kernel=$(uname -r)
        
        info "Rebuilding initramfs for kernel: $current_kernel"
        
        if dracut --force --kver "$current_kernel"; then
            success "Initramfs rebuilt successfully"
        else
            warning "Initramfs rebuild failed"
        fi
        
        # Update ZFSBootMenu if applicable
        if [[ "$ZFSBOOTMENU" == "true" ]]; then
            info "Regenerating ZFSBootMenu images..."
            
            if command -v generate-zbm >/dev/null 2>&1; then
                if generate-zbm; then
                    success "ZFSBootMenu images regenerated"
                else
                    warning "ZFSBootMenu regeneration failed - trying xbps-reconfigure"
                    xbps-reconfigure -f zfsbootmenu 2>/dev/null || warning "xbps-reconfigure also failed"
                fi
            else
                warning "generate-zbm command not found"
            fi
        fi
    else
        info "No kernel or dracut changes detected - skipping initramfs rebuild"
    fi
}

verify_rollback() {
    header "ROLLBACK VERIFICATION"
    
    local verification_failed=false
    
    # Verify ZFS functionality
    info "Verifying ZFS functionality..."
    if command -v zpool >/dev/null 2>&1 && zpool list >/dev/null 2>&1; then
        success "ZFS pools accessible"
        
        # Check pool health
        local unhealthy_pools
        unhealthy_pools=$(zpool list -H -o name,health | grep -v ONLINE | awk '{print $1}' || true)
        
        if [[ -n "$unhealthy_pools" ]]; then
            warning "Unhealthy pools detected: $unhealthy_pools"
            verification_failed=true
        else
            success "All pools healthy"
        fi
    else
        error "ZFS not functioning properly"
        verification_failed=true
    fi
    
    # Verify datasets mounted
    info "Verifying dataset mounts..."
    local root_mounted
    root_mounted=$(mount | grep -c "zroot/" || echo "0")
    
    if [[ "$root_mounted" -gt 0 ]]; then
        success "ZFS datasets appear to be mounted"
    else
        warning "No ZFS root datasets detected in mounts"
        verification_failed=true
    fi
    
    # Verify boot setup
    if [[ "$ZFSBOOTMENU" == "true" ]]; then
        info "Verifying ZFSBootMenu setup..."
        
        if [[ -f "$ESP_MOUNT/EFI/ZBM/vmlinuz.efi" ]]; then
            success "ZFSBootMenu EFI image found"
        else
            warning "ZFSBootMenu EFI image missing"
            verification_failed=true
        fi
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
    header "ROLLBACK SUMMARY"
    
    info "Rollback operations completed"
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
    
    if verify_rollback; then
        success "System rollback completed successfully"
        echo ""
        warning "Please reboot the system to ensure all changes take effect"
        echo ""
    else
        error "Rollback completed but verification found issues"
        echo ""
        warning "Please check system status before rebooting"
        warning "Consider running: zfs-post-update-verify.sh"
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
trap 'echo "Script interrupted"; exit 1' INT TERM

main "$@"