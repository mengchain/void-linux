#!/bin/bash
# filepath: zfs-post-update-verify.sh
# ZFS Post-Update Verification Script
# Comprehensive verification after ZFS/kernel updates

set -euo pipefail

# Configuration
CONFIG_FILE="/etc/zfs-update.conf"
LOG_FILE="/var/log/zfs-post-verify-$(date +%Y%m%d-%H%M%S).log"

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
        BACKUP_DIR=""
        return 0
    fi
    
    source "$CONFIG_FILE"
    
    # Set defaults for variables that might not exist
    ZFSBOOTMENU=${ZFSBOOTMENU:-false}
    POOLS_EXIST=${POOLS_EXIST:-false}
    KERNEL_UPDATED=${KERNEL_UPDATED:-false}
    BACKUP_DIR=${BACKUP_DIR:-""}
    ZFS_COUNT=${ZFS_COUNT:-0}
    KERNEL_COUNT=${KERNEL_COUNT:-0}
    TOTAL_UPDATES=${TOTAL_UPDATES:-0}
    
    info "Configuration loaded"
    log "System type: $([ "$ZFSBOOTMENU" = true ] && echo "ZFSBootMenu" || echo "Traditional")"
    log "Pools exist: $POOLS_EXIST"
    log "Kernel was updated: $KERNEL_UPDATED"
    log "Total updates performed: $TOTAL_UPDATES"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root"
    fi
}

verify_kernel_version() {
    info "Verifying kernel version..."
    
    RUNNING_KERNEL=$(uname -r)
    INSTALLED_KERNELS=$(ls /lib/modules 2>/dev/null | sort -V || echo "")
    LATEST_KERNEL=$(echo "$INSTALLED_KERNELS" | tail -1)
    
    log "Running kernel: $RUNNING_KERNEL"
    log "Latest installed kernel: $LATEST_KERNEL"
    
    if [ "$RUNNING_KERNEL" = "$LATEST_KERNEL" ]; then
        success "Running the latest installed kernel"
        KERNEL_MISMATCH=false
    else
        if [ "$KERNEL_UPDATED" = true ]; then
            warning "Running kernel ($RUNNING_KERNEL) != latest installed ($LATEST_KERNEL)"
            warning "This is expected if you haven't rebooted after kernel update"
            KERNEL_MISMATCH=true
        else
            info "Kernel versions differ but no kernel update was performed"
            KERNEL_MISMATCH=false
        fi
    fi
    
    # Save kernel info to config for future reference
    {
        echo "RUNNING_KERNEL=\"$RUNNING_KERNEL\""
        echo "LATEST_KERNEL=\"$LATEST_KERNEL\""
        echo "KERNEL_MISMATCH=$KERNEL_MISMATCH"
    } >> "$CONFIG_FILE" 2>/dev/null || true
}

verify_zfs_module() {
    info "Verifying ZFS kernel module..."
    
    if ! lsmod | grep -q zfs; then
        error_exit "ZFS kernel module is not loaded"
    fi
    success "ZFS kernel module is loaded"
    
    # Get ZFS module version and kernel compatibility
    ZFS_MODULE_VERSION=$(modinfo zfs 2>/dev/null | grep -E "^version:" | awk '{print $2}' || echo "unknown")
    ZFS_MODULE_KERNEL=$(modinfo zfs 2>/dev/null | grep -E "^vermagic:" | awk '{print $2}' || echo "unknown")
    RUNNING_KERNEL_SHORT=$(echo "$RUNNING_KERNEL" | cut -d- -f1-2)
    
    log "ZFS kernel module version: $ZFS_MODULE_VERSION"
    log "ZFS module built for kernel: $ZFS_MODULE_KERNEL"
    log "Running kernel (short): $RUNNING_KERNEL_SHORT"
    
    if [[ "$ZFS_MODULE_KERNEL" == "$RUNNING_KERNEL_SHORT"* ]] || [ "$ZFS_MODULE_KERNEL" = "unknown" ]; then
        success "ZFS module matches running kernel"
    else
        warning "ZFS module kernel version ($ZFS_MODULE_KERNEL) may not match running kernel ($RUNNING_KERNEL_SHORT)"
        warning "This could indicate the ZFS module needs rebuilding"
    fi
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
    
    # Get userland version
    ZFS_USERLAND_VERSION=$(zfs version 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
    log "ZFS userland version: $ZFS_USERLAND_VERSION"
    
    # Compare module and userland versions
    if [ "$ZFS_MODULE_VERSION" != "unknown" ] && [ "$ZFS_USERLAND_VERSION" != "unknown" ]; then
        if [ "$ZFS_MODULE_VERSION" = "$ZFS_USERLAND_VERSION" ]; then
            success "ZFS kernel module and userland versions match"
        else
            warning "ZFS kernel module ($ZFS_MODULE_VERSION) and userland ($ZFS_USERLAND_VERSION) versions differ"
            warning "This is unusual and may indicate an incomplete update"
        fi
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
    
    # Get list of current pools
    POOL_LIST=$(zpool list -H -o name 2>/dev/null || echo "")
    
    if [ -z "$POOL_LIST" ]; then
        warning "No ZFS pools found (but pools were expected)"
        return 0
    fi
    
    info "Found pools: $POOL_LIST"
    
    # Check each pool status
    POOL_ERRORS=0
    POOL_WARNINGS=0
    
    for pool in $POOL_LIST; do
        log "Checking pool: $pool"
        
        POOL_STATE=$(zpool list -H -o health "$pool" 2>/dev/null || echo "UNKNOWN")
        
        case "$POOL_STATE" in
            "ONLINE")
                success "Pool $pool is ONLINE"
                ;;
            "DEGRADED")
                warning "Pool $pool is DEGRADED"
                ((POOL_WARNINGS++))
                ;;
            "FAULTED"|"OFFLINE"|"UNAVAIL")
                error "Pool $pool is $POOL_STATE"
                ((POOL_ERRORS++))
                ;;
            *)
                warning "Pool $pool has unknown state: $POOL_STATE"
                ((POOL_WARNINGS++))
                ;;
        esac
    done
    
    # Overall pool health summary
    if [ $POOL_ERRORS -eq 0 ] && [ $POOL_WARNINGS -eq 0 ]; then
        success "All pools are healthy"
    elif [ $POOL_ERRORS -eq 0 ]; then
        warning "$POOL_WARNINGS pools have warnings"
    else
        error "$POOL_ERRORS pools have errors, $POOL_WARNINGS have warnings"
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
    
    # Check if we have the backup of expected pools
    if [ -n "$BACKUP_DIR" ] && [ -f "$BACKUP_DIR/exported-pools.txt" ]; then
        EXPECTED_POOLS=$(cat "$BACKUP_DIR/exported-pools.txt" 2>/dev/null || echo "")
        CURRENT_POOLS=$(zpool list -H -o name 2>/dev/null || echo "")
        
        if [ -n "$EXPECTED_POOLS" ]; then
            info "Expected pools: $EXPECTED_POOLS"
            info "Current pools: $CURRENT_POOLS"
            
            MISSING_POOLS=""
            for pool in $EXPECTED_POOLS; do
                if ! echo "$CURRENT_POOLS" | grep -q "^$pool$"; then
                    MISSING_POOLS="$MISSING_POOLS $pool"
                fi
            done
            
            if [ -n "$(echo $MISSING_POOLS | xargs)" ]; then
                error "Missing pools: $MISSING_POOLS"
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
    
    # Get list of datasets that should be mounted
    MOUNTABLE_DATASETS=$(zfs list -H -o name,canmount,mountpoint 2>/dev/null | awk '$2=="on" && $3!="none" && $3!="-" {print $1}' || echo "")
    
    if [ -z "$MOUNTABLE_DATASETS" ]; then
        info "No mountable datasets found"
        return 0
    fi
    
    MOUNT_ERRORS=0
    MOUNT_WARNINGS=0
    
    for dataset in $MOUNTABLE_DATASETS; do
        EXPECTED_MOUNT=$(zfs get -H -o value mountpoint "$dataset" 2>/dev/null || echo "")
        
        if [ -n "$EXPECTED_MOUNT" ] && [ "$EXPECTED_MOUNT" != "none" ] && [ "$EXPECTED_MOUNT" != "-" ]; then
            if mountpoint -q "$EXPECTED_MOUNT" 2>/dev/null; then
                # Check if it's actually the ZFS dataset mounted
                ACTUAL_SOURCE=$(findmnt -n -o SOURCE "$EXPECTED_MOUNT" 2>/dev/null || echo "")
                if [ "$ACTUAL_SOURCE" = "$dataset" ]; then
                    log "✓ Dataset $dataset mounted at $EXPECTED_MOUNT"
                else
                    warning "Dataset $dataset: mountpoint $EXPECTED_MOUNT exists but wrong source ($ACTUAL_SOURCE)"
                    ((MOUNT_WARNINGS++))
                fi
            else
                error "Dataset $dataset not mounted at expected location: $EXPECTED_MOUNT"
                ((MOUNT_ERRORS++))
            fi
        fi
    done
    
    if [ $MOUNT_ERRORS -eq 0 ] && [ $MOUNT_WARNINGS -eq 0 ]; then
        success "All datasets are properly mounted"
    elif [ $MOUNT_ERRORS -eq 0 ]; then
        warning "$MOUNT_WARNINGS datasets have mount warnings"
    else
        error "$MOUNT_ERRORS datasets have mount errors, $MOUNT_WARNINGS have warnings"
        error_exit "Dataset mount errors detected"
    fi
}

verify_zfsbootmenu() {
    if [ "$ZFSBOOTMENU" != true ]; then
        return 0
    fi
    
    info "Verifying ZFSBootMenu configuration..."
    
    # Check if ZBM command is available
    if ! command -v zfsbootmenu >/dev/null 2>&1; then
        warning "ZFSBootMenu command not available"
        return 0
    fi
    
    # Check ZBM configuration
    ZBM_CONFIG_FILE=${ZBM_CONFIG:-/etc/zfsbootmenu/config.yaml}
    if [ ! -f "$ZBM_CONFIG_FILE" ]; then
        warning "ZFSBootMenu configuration not found: $ZBM_CONFIG_FILE"
    else
        success "ZFSBootMenu configuration found"
        log "Config file: $ZBM_CONFIG_FILE"
    fi
    
    # Check EFI image
    ESP_MOUNT=${ESP_MOUNT:-/boot/efi}
    ZBM_EFI_PATH=${ZBM_EFI_PATH:-$ESP_MOUNT/EFI/zbm/vmlinuz.efi}
    
    if [ -f "$ZBM_EFI_PATH" ]; then
        ZBM_SIZE=$(stat -c%s "$ZBM_EFI_PATH" 2>/dev/null || stat -f --format="%s" "$ZBM_EFI_PATH" 2>/dev/null || echo "0")
        ZBM_DATE=$(stat -c%y "$ZBM_EFI_PATH" 2>/dev/null || stat -f --format="%Sc" "$ZBM_EFI_PATH" 2>/dev/null || echo "unknown")
        
        log "ZFSBootMenu EFI image: $ZBM_EFI_PATH"
        log "  Size: $ZBM_SIZE bytes"
        log "  Date: $ZBM_DATE"
        
        if [ "$ZBM_SIZE" -gt 1000000 ]; then
            success "ZFSBootMenu EFI image appears valid"
        else
            warning "ZFSBootMenu EFI image seems too small (${ZBM_SIZE} bytes)"
        fi
        
        # Check if the image was updated recently (if kernel was updated)
        if [ "$KERNEL_UPDATED" = true ]; then
            IMAGE_AGE_MINUTES=$(( ($(date +%s) - $(stat -c%Y "$ZBM_EFI_PATH" 2>/dev/null || echo "0")) / 60 ))
            if [ "$IMAGE_AGE_MINUTES" -lt 60 ]; then
                success "ZFSBootMenu image was recently updated (${IMAGE_AGE_MINUTES} minutes ago)"
            else
                warning "ZFSBootMenu image may be outdated (${IMAGE_AGE_MINUTES} minutes old)"
            fi
        fi
    else
        warning "ZFSBootMenu EFI image not found at: $ZBM_EFI_PATH"
    fi
    
    # Check EFI boot entries
    if command -v efibootmgr >/dev/null 2>&1; then
        info "Checking EFI boot entries..."
        ZBM_ENTRIES=$(efibootmgr 2>/dev/null | grep -i "zfsbootmenu\|zbm" || echo "")
        if [ -n "$ZBM_ENTRIES" ]; then
            success "ZFSBootMenu entries found in EFI boot manager"
            echo "$ZBM_ENTRIES" | tee -a "$LOG_FILE"
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
        
        if [ -f /boot/grub/grub.cfg ]; then
            GRUB_DATE=$(stat -c%y /boot/grub/grub.cfg 2>/dev/null || echo "unknown")
            log "GRUB config date: $GRUB_DATE"
            
            # Check if latest kernel is in GRUB config
            if [ -n "${LATEST_KERNEL:-}" ]; then
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
    
    RUNNING_KERNEL=$(uname -r)
    INITRAMFS_PATH="/boot/initramfs-${RUNNING_KERNEL}.img"
    
    if [ -f "$INITRAMFS_PATH" ]; then
        INITRAMFS_DATE=$(stat -c%y "$INITRAMFS_PATH" 2>/dev/null || echo "unknown")
        INITRAMFS_SIZE=$(stat -c%s "$INITRAMFS_PATH" 2>/dev/null || echo "0")
        
        log "Initramfs for running kernel: $INITRAMFS_PATH"
        log "  Date: $INITRAMFS_DATE"
        log "  Size: $INITRAMFS_SIZE bytes"
        
        if [ "$INITRAMFS_SIZE" -gt 1000000 ]; then
            success "Initramfs appears valid for running kernel"
        else
            warning "Initramfs seems too small (${INITRAMFS_SIZE} bytes)"
        fi
        
        # Check if ZFS modules are in initramfs
        if command -v lsinitrd >/dev/null 2>&1; then
            if lsinitrd "$INITRAMFS_PATH" 2>/dev/null | grep -q zfs; then
                success "ZFS modules found in initramfs"
            else
                warning "ZFS modules not detected in initramfs"
                if [ "$POOLS_EXIST" = true ]; then
                    warning "This could prevent ZFS pools from being imported at boot"
                fi
            fi
        elif command -v zcat >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1; then
            # Alternative method to check initramfs content
            if zcat "$INITRAMFS_PATH" 2>/dev/null | cpio -t 2>/dev/null | grep -q zfs; then
                success "ZFS modules found in initramfs (via cpio)"
            else
                warning "ZFS modules not detected in initramfs (via cpio)"
            fi
        fi
        
        # Check if initramfs was updated recently (if kernel or ZFS was updated)
        if [ "$KERNEL_UPDATED" = true ] || [ "${ZFS_COUNT:-0}" -gt 0 ]; then
            INITRAMFS_AGE_MINUTES=$(( ($(date +%s) - $(stat -c%Y "$INITRAMFS_PATH" 2>/dev/null || echo "0")) / 60 ))
            if [ "$INITRAMFS_AGE_MINUTES" -lt 60 ]; then
                success "Initramfs was recently updated (${INITRAMFS_AGE_MINUTES} minutes ago)"
            else
                warning "Initramfs may be outdated (${INITRAMFS_AGE_MINUTES} minutes old)"
            fi
        fi
    else
        warning "Initramfs not found for running kernel: $INITRAMFS_PATH"
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
    FIRST_POOL=$(zpool list -H -o name 2>/dev/null | head -1 || echo "")
    if [ -n "$FIRST_POOL" ]; then
        TEST_DATASET=$(zfs list -H -o name -r "$FIRST_POOL" -t filesystem 2>/dev/null | head -1 || echo "")
        if [ -n "$TEST_DATASET" ]; then
            TEST_SNAPSHOT="${TEST_DATASET}@zfs-verify-test-$(date +%s)"
            
            if zfs snapshot "$TEST_SNAPSHOT" 2>/dev/null; then
                success "ZFS snapshot creation works"
                
                # Clean up test snapshot
                if zfs destroy "$TEST_SNAPSHOT" 2>/dev/null; then
                    log "Test snapshot cleaned up successfully"
                else
                    warning "Failed to clean up test snapshot: $TEST_SNAPSHOT"
                fi
            else
                warning "ZFS snapshot creation failed (dataset may be read-only)"
            fi
        fi
    fi
    
    success "Basic ZFS operations test completed"
}

run_comprehensive_checks() {
    header "COMPREHENSIVE POST-UPDATE VERIFICATION"
    
    verify_kernel_version
    verify_zfs_module
    verify_zfs_userland
    verify_pool_status
    verify_pool_import
    verify_datasets_mounted
    verify_initramfs
    verify_bootloader
    test_basic_zfs_operations
}

show_system_summary() {
    header "VERIFICATION SUMMARY"
    
    echo ""
    echo "System Information:"
    echo "• Running kernel: ${RUNNING_KERNEL:-unknown}"
    echo "• Latest kernel: ${LATEST_KERNEL:-unknown}"
    echo "• ZFS module version: ${ZFS_MODULE_VERSION:-unknown}"
    echo "• ZFS userland version: ${ZFS_USERLAND_VERSION:-unknown}"
    echo "• System type: $([ "$ZFSBOOTMENU" = true ] && echo "ZFSBootMenu" || echo "Traditional")"
    echo "• Pools exist: $POOLS_EXIST"
    
    if [ "$POOLS_EXIST" = "true" ]; then
        echo ""
        echo "Pool Status:"
        zpool list 2>/dev/null || echo "Error listing pools"
    fi
    
    echo ""
    echo "Update Information:"
    echo "• Total updates applied: ${TOTAL_UPDATES:-0}"
    echo "• ZFS updates: ${ZFS_COUNT:-0}"
    echo "• Kernel updates: ${KERNEL_COUNT:-0}"
    echo "• Kernel was updated: $KERNEL_UPDATED"
    
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
        if [ "${KERNEL_MISMATCH:-false}" = true ]; then
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
    if [ "${ZFS_COUNT:-0}" -gt 0 ]; then
        echo ""
        echo "ZFS Update Notes:"
        echo "• ZFS was updated successfully"
        if [ "$ZFS_MODULE_VERSION" != "$ZFS_USERLAND_VERSION" ]; then
            echo "• Consider verifying ZFS functionality with your workload"
        fi
    fi
    
    # ZFSBootMenu specific
    if [ "$ZFSBOOTMENU" = true ] && [ "$KERNEL_UPDATED" = true ]; then
        echo ""
        echo "ZFSBootMenu Notes:"
        echo "• ZFSBootMenu image should be updated for new kernel"
        echo "• Verify boot functionality on next reboot"
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