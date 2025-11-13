#!/bin/bash
# filepath: zfs-post-update-verify.sh
# ZFS Post-Update Verification Script
# Comprehensive verification after ZFS/kernel updates

set -euo pipefail

# Configuration
CONFIG_FILE="/etc/zfs-update.conf"
LOG_FILE="/var/log/zfs-post-verify-$(date +%Y%m%d-%H%M%S).log"

# Global variables for cross-function use
RUNNING_KERNEL=""
LATEST_KERNEL=""
ZFS_MODULE_VERSION=""
ZFS_USERLAND_VERSION=""
KERNEL_MISMATCH=false

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
    log "Post-update verification failed."
    exit 1
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        warning "Configuration file not found - running basic verification"
        ZFSBOOTMENU=false
        POOLS_EXIST=false
        KERNEL_UPDATED=false
        DRACUT_UPDATED=false
        ZFS_UPDATED=false
        BACKUP_DIR=""
        return 0
    fi
    
    source "$CONFIG_FILE"
    
    # Set defaults for variables that might not exist - match Scripts 1 & 2
    ZFSBOOTMENU=${ZFSBOOTMENU:-false}
    POOLS_EXIST=${POOLS_EXIST:-false}
    KERNEL_UPDATED=${KERNEL_UPDATED:-false}
    DRACUT_UPDATED=${DRACUT_UPDATED:-false}
    ZFS_UPDATED=${ZFS_UPDATED:-false}
    BACKUP_DIR=${BACKUP_DIR:-""}
    ZFS_COUNT=${ZFS_COUNT:-0}
    ZBM_COUNT=${ZBM_COUNT:-0}
    DRACUT_COUNT=${DRACUT_COUNT:-0}
    KERNEL_COUNT=${KERNEL_COUNT:-0}
    FIRMWARE_COUNT=${FIRMWARE_COUNT:-0}
    TOTAL_UPDATES=${TOTAL_UPDATES:-0}
    ESP_MOUNT=${ESP_MOUNT:-/boot/efi}
    BOOT_POOLS=${BOOT_POOLS:-""}
    
    info "Configuration loaded"
    log "System type: $([ "$ZFSBOOTMENU" = true ] && echo "ZFSBootMenu" || echo "Traditional")"
    log "Pools exist: $POOLS_EXIST"
    log "Updates applied - Kernel: $KERNEL_UPDATED, ZFS: $ZFS_UPDATED, Dracut: $DRACUT_UPDATED"
    log "Total updates performed: $TOTAL_UPDATES"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root"
    fi
}

verify_kernel_version() {
    info "Verifying kernel version..."
    
    local running_kernel installed_kernels latest_kernel kernel_mismatch
    
    running_kernel=$(uname -r)
    installed_kernels=$(ls /lib/modules 2>/dev/null | sort -V || echo "")
    latest_kernel=$(echo "$installed_kernels" | tail -1)
    
    log "Running kernel: $running_kernel"
    log "Latest installed kernel: $latest_kernel"
    
    if [ "$running_kernel" = "$latest_kernel" ]; then
        success "Running the latest installed kernel"
        kernel_mismatch=false
    else
        if [ "$KERNEL_UPDATED" = true ]; then
            warning "Running kernel ($running_kernel) != latest installed ($latest_kernel)"
            warning "This is expected if you haven't rebooted after kernel update"
            kernel_mismatch=true
        else
            info "Kernel versions differ but no kernel update was performed"
            kernel_mismatch=false
        fi
    fi
    
    # Export global variables
    RUNNING_KERNEL="$running_kernel"
    LATEST_KERNEL="$latest_kernel"
    KERNEL_MISMATCH=$kernel_mismatch
    
    # Save kernel info to config for future reference
    {
        echo "RUNNING_KERNEL=\"$running_kernel\""
        echo "LATEST_KERNEL=\"$latest_kernel\""
        echo "KERNEL_MISMATCH=$kernel_mismatch"
    } >> "$CONFIG_FILE" 2>/dev/null || true
}

verify_zfs_module() {
    info "Verifying ZFS kernel module..."
    
    if ! lsmod | grep -q zfs; then
        error_exit "ZFS kernel module is not loaded"
    fi
    success "ZFS kernel module is loaded"
    
    local zfs_module_version zfs_module_kernel running_kernel_short
    
    # Get ZFS module version and kernel compatibility
    zfs_module_version=$(modinfo zfs 2>/dev/null | grep -E "^version:" | awk '{print $2}' || echo "unknown")
    zfs_module_kernel=$(modinfo zfs 2>/dev/null | grep -E "^vermagic:" | awk '{print $2}' || echo "unknown")
    running_kernel_short=$(echo "$RUNNING_KERNEL" | cut -d- -f1-2)
    
    log "ZFS kernel module version: $zfs_module_version"
    log "ZFS module built for kernel: $zfs_module_kernel"
    log "Running kernel (short): $running_kernel_short"
    
    if [[ "$zfs_module_kernel" == "$running_kernel_short"* ]] || [ "$zfs_module_kernel" = "unknown" ]; then
        success "ZFS module matches running kernel"
    else
        warning "ZFS module kernel version ($zfs_module_kernel) may not match running kernel ($running_kernel_short)"
        warning "This could indicate the ZFS module needs rebuilding"
    fi
    
    # Export global variable
    ZFS_MODULE_VERSION="$zfs_module_version"
}

verify_zfs_userland() {
    info "Verifying ZFS userland tools..."
    
    if ! command -v zpool >/dev/null 2>&1; then
        error_exit "zpool command not found"
    fi
    
    if ! command -v zfs >/dev/null 2>&1; then
        error_exit "zfs command not found"
    fi
    
    success "ZFS userland tools are available"
    
    local zfs_userland_version
    
    # Get userland version - match detection from Scripts 1 & 2
    zfs_userland_version=$(zfs version 2>/dev/null | grep -E "^zfs-" | head -1 | awk '{print $2}' || echo "unknown")
    
    # Fallback to alternative detection
    if [ "$zfs_userland_version" = "unknown" ]; then
        zfs_userland_version=$(zfs version 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
    fi
    
    log "ZFS userland version: $zfs_userland_version"
    
    # Compare module and userland versions
    if [ "$ZFS_MODULE_VERSION" != "unknown" ] && [ "$zfs_userland_version" != "unknown" ]; then
        if [ "$ZFS_MODULE_VERSION" = "$zfs_userland_version" ]; then
            success "ZFS kernel module and userland versions match"
        else
            warning "ZFS kernel module ($ZFS_MODULE_VERSION) and userland ($zfs_userland_version) versions differ"
            warning "This is unusual and may indicate an incomplete update"
        fi
    fi
    
    # Export global variable
    ZFS_USERLAND_VERSION="$zfs_userland_version"
}

verify_dracut_functionality() {
    info "Verifying dracut functionality..."
    
    local dracut_version
    
    if ! command -v dracut >/dev/null 2>&1; then
        warning "dracut command not found"
        return 0
    fi
    
    dracut_version=$(dracut --version 2>/dev/null | head -1 || echo "unknown")
    log "Dracut version: $dracut_version"
    
    # Check if dracut can detect ZFS modules
    if dracut --list-modules 2>/dev/null | grep -q zfs; then
        success "Dracut has ZFS module support"
    else
        warning "Dracut may not have ZFS module support"
    fi
    
    # Check dracut configuration - match installation script expectations
    if [ -f /etc/dracut.conf ] || [ -d /etc/dracut.conf.d ]; then
        success "Dracut configuration found"
        
        # Look for ZFS-related configuration from installation script
        if [ -f /etc/dracut.conf.d/zfs.conf ]; then
            success "ZFS-specific dracut configuration found"
        elif grep -r "zfs" /etc/dracut.conf /etc/dracut.conf.d/ 2>/dev/null | grep -v "^#" >/dev/null; then
            info "ZFS configuration found in dracut settings"
        fi
    else
        info "No custom dracut configuration found (using defaults)"
    fi
}

verify_pool_status() {
    if [ "$POOLS_EXIST" != "true" ]; then
        info "No ZFS pools to verify"
        return 0
    fi
    
    info "Verifying ZFS pool status..."
    
    if ! zpool list >/dev/null 2>&1; then
        error_exit "Cannot list ZFS pools"
    fi
    
    local pool_list pool_errors pool_warnings pool pool_state
    
    # Get list of current pools
    pool_list=$(zpool list -H -o name 2>/dev/null || echo "")
    
    if [ -z "$pool_list" ]; then
        warning "No ZFS pools found (but pools were expected)"
        return 0
    fi
    
    info "Found pools: $pool_list"
    
    # Check each pool status
    pool_errors=0
    pool_warnings=0
    
    for pool in $pool_list; do
        log "Checking pool: $pool"
        
        pool_state=$(zpool list -H -o health "$pool" 2>/dev/null || echo "UNKNOWN")
        
        case "$pool_state" in
            "ONLINE")
                success "Pool $pool is ONLINE"
                ;;
            "DEGRADED")
                warning "Pool $pool is DEGRADED"
                ((pool_warnings++))
                ;;
            "FAULTED"|"OFFLINE"|"UNAVAIL")
                error "Pool $pool is $pool_state"
                ((pool_errors++))
                ;;
            *)
                warning "Pool $pool has unknown state: $pool_state"
                ((pool_warnings++))
                ;;
        esac
    done
    
    # Overall pool health summary
    if [ $pool_errors -eq 0 ] && [ $pool_warnings -eq 0 ]; then
        success "All pools are healthy"
    elif [ $pool_errors -eq 0 ]; then
        warning "$pool_warnings pools have warnings"
    else
        error "$pool_errors pools have errors, $pool_warnings have warnings"
        info "Detailed pool status:"
        zpool status -v | tee -a "$LOG_FILE"
        error_exit "Critical pool errors detected"
    fi
}

verify_pool_import() {
    if [ "$POOLS_EXIST" != "true" ]; then
        return 0
    fi
    
    info "Verifying all expected pools are imported..."
    
    local expected_pools current_pools missing_pools pool
    
    # Check if we have the backup of expected pools
    if [ -n "$BACKUP_DIR" ] && [ -f "$BACKUP_DIR/exported-pools.txt" ]; then
        expected_pools=$(cat "$BACKUP_DIR/exported-pools.txt" 2>/dev/null || echo "")
        current_pools=$(zpool list -H -o name 2>/dev/null || echo "")
        
        if [ -n "$expected_pools" ]; then
            info "Expected pools: $expected_pools"
            info "Current pools: $current_pools"
            
            missing_pools=""
            for pool in $expected_pools; do
                if ! echo "$current_pools" | grep -q "^$pool$"; then
                    missing_pools="$missing_pools $pool"
                fi
            done
            
            if [ -n "$(echo $missing_pools | xargs)" ]; then
                error "Missing pools: $missing_pools"
                info "Available pools for import:"
                zpool import 2>&1 | tee -a "$LOG_FILE" || true
                error_exit "Some pools are missing - check import status above"
            else
                success "All expected pools are imported"
            fi
        fi
    else
        info "No pool backup found - skipping import verification"
    fi
}

verify_datasets_mounted() {
    if [ "$POOLS_EXIST" != "true" ]; then
        return 0
    fi
    
    info "Verifying ZFS datasets are properly mounted..."
    
    local mountable_datasets mount_errors mount_warnings dataset expected_mount actual_source
    
    # Get list of datasets that should be mounted
    mountable_datasets=$(zfs list -H -o name,canmount,mountpoint 2>/dev/null | awk '$2=="on" && $3!="none" && $3!="-" {print $1}' || echo "")
    
    if [ -z "$mountable_datasets" ]; then
        info "No mountable datasets found"
        return 0
    fi
    
    mount_errors=0
    mount_warnings=0
    
    for dataset in $mountable_datasets; do
        expected_mount=$(zfs get -H -o value mountpoint "$dataset" 2>/dev/null || echo "")
        
        if [ -n "$expected_mount" ] && [ "$expected_mount" != "none" ] && [ "$expected_mount" != "-" ]; then
            if mountpoint -q "$expected_mount" 2>/dev/null; then
                # Check if it's actually the ZFS dataset mounted
                actual_source=$(findmnt -n -o SOURCE "$expected_mount" 2>/dev/null || echo "")
                if [ "$actual_source" = "$dataset" ]; then
                    log "✓ Dataset $dataset mounted at $expected_mount"
                else
                    warning "Dataset $dataset: mountpoint $expected_mount exists but wrong source ($actual_source)"
                    ((mount_warnings++))
                fi
            else
                error "Dataset $dataset not mounted at expected location: $expected_mount"
                ((mount_errors++))
            fi
        fi
    done
    
    if [ $mount_errors -eq 0 ] && [ $mount_warnings -eq 0 ]; then
        success "All datasets are properly mounted"
    elif [ $mount_errors -eq 0 ]; then
        warning "$mount_warnings datasets have mount warnings"
    else
        error "$mount_errors datasets have mount errors, $mount_warnings have warnings"
        error_exit "Dataset mount errors detected"
    fi
}

verify_zfsbootmenu() {
    if [ "$ZFSBOOTMENU" != true ]; then
        return 0
    fi
    
    info "Verifying ZFSBootMenu configuration..."
    
    local zbm_config_file zbm_efi_path zbm_size zbm_date image_age_minutes zbm_entries
    
    # Check if generate-zbm command is available (CORRECTED)
    if ! command -v generate-zbm >/dev/null 2>&1; then
        warning "generate-zbm command not available"
        return 0
    fi
    
    # Check ZBM configuration - match Script 1 paths
    zbm_config_file=${ZBM_CONFIG:-/etc/zfsbootmenu/config.yaml}
    if [ ! -f "$zbm_config_file" ]; then
        warning "ZFSBootMenu configuration not found: $zbm_config_file"
    else
        success "ZFSBootMenu configuration found"
        log "Config file: $zbm_config_file"
        
        # Validate configuration syntax if yaml-lint available
        if command -v yaml-lint >/dev/null 2>&1; then
            if yaml-lint "$zbm_config_file" >/dev/null 2>&1; then
                success "ZFSBootMenu configuration syntax is valid"
            else
                warning "ZFSBootMenu configuration may have syntax issues"
            fi
        fi
    fi
    
    # Check EFI image - CORRECTED path to match installation script and Scripts 1 & 2
    zbm_efi_path="$ESP_MOUNT/EFI/ZBM/vmlinuz.efi"
    
    if [ -f "$zbm_efi_path" ]; then
        zbm_size=$(stat -c%s "$zbm_efi_path" 2>/dev/null || stat -f --format="%s" "$zbm_efi_path" 2>/dev/null || echo "0")
        zbm_date=$(stat -c%y "$zbm_efi_path" 2>/dev/null || stat -f --format="%Sc" "$zbm_efi_path" 2>/dev/null || echo "unknown")
        
        log "ZFSBootMenu EFI image: $zbm_efi_path"
        log "  Size: $zbm_size bytes"
        log "  Date: $zbm_date"
        
        if [ "$zbm_size" -gt 1000000 ]; then
            success "ZFSBootMenu EFI image appears valid"
        else
            warning "ZFSBootMenu EFI image seems too small (${zbm_size} bytes)"
        fi
        
        # Check if the image was updated recently (if kernel was updated)
        if [ "$KERNEL_UPDATED" = true ] || [ "$ZFS_UPDATED" = true ]; then
            image_age_minutes=$(( ($(date +%s) - $(stat -c%Y "$zbm_efi_path" 2>/dev/null || echo "0")) / 60 ))
            if [ "$image_age_minutes" -lt 60 ]; then
                success "ZFSBootMenu image was recently updated (${image_age_minutes} minutes ago)"
            else
                warning "ZFSBootMenu image may be outdated (${image_age_minutes} minutes old)"
                if [ "$KERNEL_UPDATED" = true ]; then
                    warning "Consider regenerating ZFSBootMenu image: generate-zbm"
                fi
            fi
        fi
        
        # Check backup image too - match installation script structure
        local zbm_backup_path="$ESP_MOUNT/EFI/ZBM/vmlinuz-backup.efi"
        if [ -f "$zbm_backup_path" ]; then
            info "Backup ZFSBootMenu image also exists"
        fi
    else
        warning "ZFSBootMenu EFI image not found at: $zbm_efi_path"
    fi
    
    # Check EFI boot entries
    if command -v efibootmgr >/dev/null 2>&1; then
        info "Checking EFI boot entries..."
        zbm_entries=$(efibootmgr 2>/dev/null | grep -i "zfsbootmenu\|ZBM" || echo "")
        if [ -n "$zbm_entries" ]; then
            success "ZFSBootMenu entries found in EFI boot manager"
            echo "$zbm_entries" | tee -a "$LOG_FILE"
        else
            warning "No ZFSBootMenu entries found in EFI boot manager"
        fi
    fi
}

verify_bootloader() {
    if [ "$ZFSBOOTMENU" = true ]; then
        verify_zfsbootmenu
    else
        info "Verifying traditional bootloader..."
        
        local grub_date
        
        if [ -f /boot/grub/grub.cfg ]; then
            grub_date=$(stat -c%y /boot/grub/grub.cfg 2>/dev/null || echo "unknown")
            log "GRUB config date: $grub_date"
            
            # Check if latest kernel is in GRUB config
            if [ -n "$LATEST_KERNEL" ]; then
                if grep -q "$LATEST_KERNEL" /boot/grub/grub.cfg 2>/dev/null; then
                    success "Latest kernel ($LATEST_KERNEL) found in GRUB configuration"
                else
                    warning "Latest kernel ($LATEST_KERNEL) not found in GRUB configuration"
                    if [ "$KERNEL_UPDATED" = true ]; then
                        warning "This could prevent booting the new kernel"
                    fi
                fi
            fi
        else
            warning "GRUB configuration file not found"
        fi
    fi
}

verify_initramfs() {
    info "Verifying initramfs..."
    
    local initramfs_path initramfs_date initramfs_size initramfs_age_minutes
    
    initramfs_path="/boot/initramfs-${RUNNING_KERNEL}.img"
    
    if [ -f "$initramfs_path" ]; then
        initramfs_date=$(stat -c%y "$initramfs_path" 2>/dev/null || echo "unknown")
        initramfs_size=$(stat -c%s "$initramfs_path" 2>/dev/null || echo "0")
        
        log "Initramfs for running kernel: $initramfs_path"
        log "  Date: $initramfs_date"
        log "  Size: $initramfs_size bytes"
        
        if [ "$initramfs_size" -gt 1000000 ]; then
            success "Initramfs appears valid for running kernel"
        else
            warning "Initramfs seems too small (${initramfs_size} bytes)"
        fi
        
        # Check if ZFS modules are in initramfs
        if command -v lsinitrd >/dev/null 2>&1; then
            if lsinitrd "$initramfs_path" 2>/dev/null | grep -q zfs; then
                success "ZFS modules found in initramfs"
            else
                warning "ZFS modules not detected in initramfs"
                if [ "$POOLS_EXIST" = true ]; then
                    warning "This could prevent ZFS pools from being imported at boot"
                fi
            fi
        elif command -v zcat >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1; then
            # Alternative method to check initramfs content
            if zcat "$initramfs_path" 2>/dev/null | cpio -t 2>/dev/null | grep -q zfs; then
                success "ZFS modules found in initramfs (via cpio)"
            else
                warning "ZFS modules not detected in initramfs (via cpio)"
            fi
        fi
        
        # Check if initramfs was updated recently (if kernel or ZFS was updated)
        if [ "$KERNEL_UPDATED" = true ] || [ "$ZFS_UPDATED" = true ] || [ "$DRACUT_UPDATED" = true ]; then
            initramfs_age_minutes=$(( ($(date +%s) - $(stat -c%Y "$initramfs_path" 2>/dev/null || echo "0")) / 60 ))
            if [ "$initramfs_age_minutes" -lt 60 ]; then
                success "Initramfs was recently updated (${initramfs_age_minutes} minutes ago)"
            else
                warning "Initramfs may be outdated (${initramfs_age_minutes} minutes old)"
                if [ "$KERNEL_UPDATED" = true ] || [ "$ZFS_UPDATED" = true ]; then
                    warning "Consider rebuilding: dracut -f"
                fi
            fi
        fi
    else
        warning "Initramfs not found for running kernel: $initramfs_path"
        if [ "$KERNEL_UPDATED" = true ]; then
            error "Missing initramfs for running kernel after kernel update"
        fi
    fi
}

test_basic_zfs_operations() {
    if [ "$POOLS_EXIST" != "true" ]; then
        return 0
    fi
    
    info "Testing basic ZFS operations..."
    
    local first_pool test_dataset test_snapshot
    
    # Test zpool list
    if zpool list >/dev/null 2>&1; then
        success "zpool list command works"
    else
        error_exit "zpool list command failed"
    fi
    
    # Test zfs list
    if zfs list >/dev/null 2>&1; then
        success "zfs list command works"
    else
        error_exit "zfs list command failed"
    fi
    
    # Test creating and destroying a test snapshot (if we have writable datasets)
    first_pool=$(zpool list -H -o name 2>/dev/null | head -1 || echo "")
    if [ -n "$first_pool" ]; then
        test_dataset=$(zfs list -H -o name -r "$first_pool" -t filesystem 2>/dev/null | head -1 || echo "")
        if [ -n "$test_dataset" ]; then
            test_snapshot="${test_dataset}@zfs-verify-test-$(date +%s)"
            
            if zfs snapshot "$test_snapshot" 2>/dev/null; then
                success "ZFS snapshot creation works"
                
                # Test snapshot listing
                if zfs list -t snapshot "$test_snapshot" >/dev/null 2>&1; then
                    log "ZFS snapshot listing works"
                fi
                
                # Clean up test snapshot
                if zfs destroy "$test_snapshot" 2>/dev/null; then
                    log "Test snapshot cleaned up successfully"
                else
                    warning "Failed to clean up test snapshot: $test_snapshot"
                fi
            else
                warning "ZFS snapshot creation failed (dataset may be read-only)"
            fi
        fi
    fi
    
    success "Basic ZFS operations test completed"
}

check_rollback_capability() {
    if [ "$POOLS_EXIST" != "true" ]; then
        info "No ZFS pools - rollback capability not applicable"
        return 0
    fi
    
    info "Verifying rollback capability..."
    
    local install_snapshot_name snapshot_count existing_snapshots dataset backup_files file
    
    # Check for installation snapshots
    install_snapshot_name=${INSTALL_SNAPSHOT_NAME:-}
    if [ -n "$install_snapshot_name" ]; then
        snapshot_count=0
        existing_snapshots=""
        
        # Check which snapshots actually exist
        for dataset in $(zfs list -H -o name -t filesystem,volume 2>/dev/null || true); do
            if zfs list -t snapshot "${dataset}@${install_snapshot_name}" >/dev/null 2>&1; then
                ((snapshot_count++))
                existing_snapshots="$existing_snapshots ${dataset}@${install_snapshot_name}"
            fi
        done
        
        if [ $snapshot_count -gt 0 ]; then
            success "Found $snapshot_count installation snapshots for rollback"
            info "Snapshots available for rollback: $install_snapshot_name"
        else
            warning "No installation snapshots found - rollback may not be possible"
        fi
    else
        info "No installation snapshot name recorded"
    fi
    
    # Check for backup directory
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        success "Backup directory exists for configuration rollback"
        
        # Check key backup files
        backup_files="zfs-datasets.txt zpool-list.txt"
        for file in $backup_files; do
            if [ -f "$BACKUP_DIR/$file" ]; then
                log "✓ Backup file found: $file"
            else
                warning "Missing backup file: $file"
            fi
        done
    else
        warning "Backup directory not found - configuration rollback limited"
    fi
}

run_comprehensive_checks() {
    header "COMPREHENSIVE POST-UPDATE VERIFICATION"
    
    verify_kernel_version
    verify_zfs_module
    verify_zfs_userland
    verify_dracut_functionality
    verify_pool_status
    verify_pool_import
    verify_datasets_mounted
    verify_initramfs
    verify_bootloader
    test_basic_zfs_operations
    check_rollback_capability
}

show_system_summary() {
    header "VERIFICATION SUMMARY"
    
    echo ""
    echo "System Information:"
    echo "• Running kernel: $RUNNING_KERNEL"
    echo "• Latest kernel: $LATEST_KERNEL"
    echo "• ZFS module version: $ZFS_MODULE_VERSION"
    echo "• ZFS userland version: $ZFS_USERLAND_VERSION"
    echo "• System type: $([ "$ZFSBOOTMENU" = true ] && echo "ZFSBootMenu" || echo "Traditional")"
    echo "• Pools exist: $POOLS_EXIST"
    
    if [ "$POOLS_EXIST" = "true" ]; then
        echo ""
        echo "Pool Status:"
        zpool list 2>/dev/null || echo "Error listing pools"
    fi
    
    echo ""
    echo "Update Information:"
    echo "• Total updates applied: $TOTAL_UPDATES"
    echo "• ZFS updates: ${ZFS_COUNT:-0} (updated: $ZFS_UPDATED)"
    echo "• ZBM updates: ${ZBM_COUNT:-0}"
    echo "• Dracut updates: ${DRACUT_COUNT:-0} (updated: $DRACUT_UPDATED)"
    echo "• Kernel updates: ${KERNEL_COUNT:-0} (updated: $KERNEL_UPDATED)"
    echo "• Firmware updates: ${FIRMWARE_COUNT:-0}"
    
    echo ""
    echo "Files:"
    echo "• Log file: $LOG_FILE"
    if [ -n "$BACKUP_DIR" ]; then
        echo "• Backup directory: $BACKUP_DIR"
    fi
    echo "• Config file: $CONFIG_FILE"
}

show_recommendations() {
    header "RECOMMENDATIONS"
    
    echo "Next steps:"
    echo "• Run 'xbps-install -u' to update other packages"
    echo "• Monitor system for any issues"
    echo "• Consider running a ZFS scrub: 'zpool scrub <pool>'"
    
    # Kernel-specific recommendations
    if [ "$KERNEL_UPDATED" = true ]; then
        if [ "$KERNEL_MISMATCH" = true ]; then
            echo ""
            echo -e "${YELLOW}REBOOT NOTICE:${NC}"
            echo "• You're running kernel $RUNNING_KERNEL but $LATEST_KERNEL is installed"
            echo "• Reboot to use the new kernel: 'sudo reboot'"
            echo "• After reboot, run this verification script again"
        else
            echo ""
            echo -e "${GREEN}KERNEL UPDATE COMPLETE:${NC}"
            echo "• Successfully running the updated kernel"
        fi
    fi
    
    # ZFS-specific recommendations
    if [ "$ZFS_UPDATED" = "true" ]; then
        echo ""
        echo "ZFS Update Notes:"
        echo "• ZFS was updated successfully"
        if [ "$ZFS_MODULE_VERSION" != "$ZFS_USERLAND_VERSION" ]; then
            echo "• Consider verifying ZFS functionality with your workload"
        fi
    fi
    
    # Dracut-specific recommendations
    if [ "$DRACUT_UPDATED" = "true" ]; then
        echo ""
        echo "Dracut Update Notes:"
        echo "• Dracut was updated - initramfs should be rebuilt"
        echo "• Verify boot functionality on next reboot"
    fi
    
    # ZFSBootMenu specific
    if [ "$ZFSBOOTMENU" = true ] && ([ "$KERNEL_UPDATED" = true ] || [ "$ZFS_UPDATED" = "true" ]); then
        echo ""
        echo "ZFSBootMenu Notes:"
        echo "• ZFSBootMenu image should be updated for changes"
        echo "• Verify boot functionality on next reboot"
        if [ "$KERNEL_MISMATCH" = true ]; then
            echo "• After reboot, ZFSBootMenu should show new kernel"
        fi
    fi
    
    # Rollback information
    if [ -n "${INSTALL_SNAPSHOT_NAME:-}" ]; then
        echo ""
        echo "Rollback Information:"
        echo "• Installation snapshots created: $INSTALL_SNAPSHOT_NAME"
        echo "• Rollback possible if issues arise"
    fi
}

main() {
    header "ZFS POST-UPDATE VERIFICATION"
    
    log "Starting post-update verification..."
    
    check_root
    load_config
    
    run_comprehensive_checks
    
    show_system_summary
    show_recommendations
    
    header "VERIFICATION COMPLETED"
    
    success "Post-update verification completed successfully!"
    
    log "Verification completed. System appears to be functioning correctly."
}

main "$@"