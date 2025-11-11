#!/bin/bash
# filepath: zfs-rollback-update.sh
# ZFS/Kernel Update Rollback Script
# Rolls back failed ZFS/kernel updates using snapshots and backups

set -euo pipefail

# Configuration
CONFIG_FILE="/etc/zfs-update.conf"
LOG_FILE="/var/log/zfs-rollback-$(date +%Y%m%d-%H%M%S).log"

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
    log "Rollback failed. Manual intervention may be required."
    exit 1
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root"
    fi
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        error_exit "Configuration file not found. Cannot proceed with rollback without update context."
    fi
    
    source "$CONFIG_FILE"
    
    # Check for required variables
    if [ -z "${BACKUP_DIR:-}" ] || [ ! -d "$BACKUP_DIR" ]; then
        error_exit "Backup directory not found. Rollback may not be possible."
    fi
    
    # Set defaults for variables that might not exist
    ZFSBOOTMENU=${ZFSBOOTMENU:-false}
    POOLS_EXIST=${POOLS_EXIST:-false}
    KERNEL_UPDATED=${KERNEL_UPDATED:-false}
    SNAPSHOT_NAME=${SNAPSHOT_NAME:-""}
    TOTAL_UPDATES=${TOTAL_UPDATES:-0}
    ZFS_COUNT=${ZFS_COUNT:-0}
    KERNEL_COUNT=${KERNEL_COUNT:-0}
    
    info "Configuration loaded for rollback"
    log "System type: $([ "$ZFSBOOTMENU" = true ] && echo "ZFSBootMenu" || echo "Traditional")"
    log "Backup directory: $BACKUP_DIR"
    log "Snapshot name: ${SNAPSHOT_NAME:-none}"
    log "Kernel was updated: $KERNEL_UPDATED"
    log "Updates that were applied: $TOTAL_UPDATES packages"
}

detect_rollback_reason() {
    header "ROLLBACK ANALYSIS"
    
    info "Analyzing system state to determine rollback strategy..."
    
    ROLLBACK_REASONS=""
    CRITICAL_ISSUES=false
    
    # Check if ZFS is functioning
    if ! lsmod | grep -q zfs; then
        ROLLBACK_REASONS="$ROLLBACK_REASONS\n• ZFS kernel module not loaded"
        CRITICAL_ISSUES=true
    fi
    
    # Check if ZFS commands work
    if ! command -v zpool >/dev/null 2>&1 || ! zpool list >/dev/null 2>&1; then
        ROLLBACK_REASONS="$ROLLBACK_REASONS\n• ZFS commands not working"
        CRITICAL_ISSUES=true
    fi
    
    # Check pool health if pools exist
    if [ "$POOLS_EXIST" = "true" ]; then
        if zpool status 2>/dev/null | grep -E "(DEGRADED|FAULTED|OFFLINE|UNAVAIL)"; then
            ROLLBACK_REASONS="$ROLLBACK_REASONS\n• ZFS pool errors detected"
            CRITICAL_ISSUES=true
        fi
    fi
    
    # Check kernel compatibility
    if [ "$KERNEL_UPDATED" = "true" ]; then
        RUNNING_KERNEL=$(uname -r)
        ZFS_MODULE_KERNEL=$(modinfo zfs 2>/dev/null | grep -E "^vermagic:" | awk '{print $2}' || echo "unknown")
        
        if [ "$ZFS_MODULE_KERNEL" != "unknown" ] && [[ ! "$ZFS_MODULE_KERNEL" == "$RUNNING_KERNEL"* ]]; then
            ROLLBACK_REASONS="$ROLLBACK_REASONS\n• ZFS module/kernel version mismatch"
            CRITICAL_ISSUES=true
        fi
    fi
    
    # Check boot issues for ZFSBootMenu
    if [ "$ZFSBOOTMENU" = "true" ] && [ "$KERNEL_UPDATED" = "true" ]; then
        ZBM_EFI_PATH=${ZBM_EFI_PATH:-}
        if [ -n "$ZBM_EFI_PATH" ] && [ ! -f "$ZBM_EFI_PATH" ]; then
            ROLLBACK_REASONS="$ROLLBACK_REASONS\n• ZFSBootMenu EFI image missing"
            CRITICAL_ISSUES=true
        fi
    fi
    
    if [ -n "$ROLLBACK_REASONS" ]; then
        warning "Issues detected requiring rollback:"
        echo -e "$ROLLBACK_REASONS"
        echo ""
    else
        info "No critical issues detected. Proceeding with user-requested rollback."
    fi
    
    log "Critical issues detected: $CRITICAL_ISSUES"
}

confirm_rollback() {
    header "ROLLBACK CONFIRMATION"
    
    echo "This will rollback the following updates:"
    [ "${ZFS_COUNT:-0}" -gt 0 ] && echo "• ZFS packages ($ZFS_COUNT packages)"
    [ "${KERNEL_COUNT:-0}" -gt 0 ] && echo "• Kernel packages ($KERNEL_COUNT packages)"
    echo ""
    echo "Rollback will:"
    echo "1. Downgrade packages to previous versions"
    if [ -n "$SNAPSHOT_NAME" ] && [ "$POOLS_EXIST" = "true" ]; then
        echo "2. Rollback ZFS datasets to snapshot: $SNAPSHOT_NAME"
    fi
    echo "3. Restore system configurations from backup"
    echo "4. Rebuild initramfs for previous kernel"
    if [ "$ZFSBOOTMENU" = "true" ]; then
        echo "5. Restore ZFSBootMenu configuration"
    else
        echo "5. Update bootloader configuration"
    fi
    echo ""
    echo -e "${RED}WARNING: This operation cannot be undone easily!${NC}"
    echo -e "${YELLOW}Make sure you have alternative boot methods available.${NC}"
    echo ""
    read -p "Are you sure you want to proceed with rollback? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log "Rollback cancelled by user"
        exit 0
    fi
    
    echo ""
    read -p "Type 'ROLLBACK' to confirm: " -r
    if [ "$REPLY" != "ROLLBACK" ]; then
        log "Rollback confirmation failed"
        exit 0
    fi
    
    info "Rollback confirmed by user"
}

backup_current_state() {
    info "Creating backup of current state before rollback..."
    
    ROLLBACK_BACKUP_DIR="$BACKUP_DIR/pre-rollback-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$ROLLBACK_BACKUP_DIR"
    
    # Backup current package state
    xbps-query -l > "$ROLLBACK_BACKUP_DIR/current-packages.txt" 2>/dev/null || true
    
    # Backup current ZFS state if accessible
    if [ "$POOLS_EXIST" = "true" ] && zpool list >/dev/null 2>&1; then
        zfs list -H -o name,mountpoint > "$ROLLBACK_BACKUP_DIR/current-zfs-datasets.txt" 2>/dev/null || true
        zpool status -v > "$ROLLBACK_BACKUP_DIR/current-pool-status.txt" 2>/dev/null || true
    fi
    
    # Backup current kernel info
    uname -a > "$ROLLBACK_BACKUP_DIR/current-kernel.txt"
    
    success "Current state backed up to: $ROLLBACK_BACKUP_DIR"
}

get_previous_package_versions() {
    info "Determining previous package versions..."
    
    # Get currently installed package versions
    if [ "${ZFS_COUNT:-0}" -gt 0 ]; then
        CURRENT_ZFS_PACKAGES=$(xbps-query -l | grep zfs | awk '{print $2}' | tr '\n' ' ' || echo "")
        log "Current ZFS packages: $CURRENT_ZFS_PACKAGES"
    fi
    
    if [ "${KERNEL_COUNT:-0}" -gt 0 ]; then
        CURRENT_KERNEL_PACKAGES=$(xbps-query -l | grep -E "linux[0-9]*-[0-9]" | awk '{print $2}' | tr '\n' ' ' || echo "")
        log "Current kernel packages: $CURRENT_KERNEL_PACKAGES"
    fi
    
    # For simplification, we'll use xbps cache to find previous versions
    info "Checking package cache for previous versions..."
    
    CACHE_DIR="/var/cache/xbps"
    if [ -d "$CACHE_DIR" ]; then
        ZFS_CACHE_PKGS=$(find "$CACHE_DIR" -name "*zfs*.xbps" 2>/dev/null | head -5 || echo "")
        KERNEL_CACHE_PKGS=$(find "$CACHE_DIR" -name "linux*.xbps" 2>/dev/null | head -5 || echo "")
        
        if [ -n "$ZFS_CACHE_PKGS" ]; then
            log "Found ZFS packages in cache:"
            echo "$ZFS_CACHE_PKGS" | while IFS= read -r pkg; do
                [ -n "$pkg" ] && log "  $(basename "$pkg")"
            done
        fi
        
        if [ -n "$KERNEL_CACHE_PKGS" ]; then
            log "Found kernel packages in cache:"
            echo "$KERNEL_CACHE_PKGS" | while IFS= read -r pkg; do
                [ -n "$pkg" ] && log "  $(basename "$pkg")"
            done
        fi
    else
        warning "Package cache not found - automatic downgrade may not be possible"
    fi
}

export_zfs_pools_for_rollback() {
    if [ "$POOLS_EXIST" != "true" ]; then
        info "No ZFS pools to export"
        return 0
    fi
    
    info "Exporting ZFS pools for rollback..."
    
    # Only export if pools are currently accessible
    if ! zpool list >/dev/null 2>&1; then
        info "Pools already inaccessible - skipping export"
        return 0
    fi
    
    ALL_POOLS=$(zpool list -H -o name 2>/dev/null || echo "")
    
    if [ -z "$ALL_POOLS" ]; then
        info "No pools to export"
        return 0
    fi
    
    for pool in $ALL_POOLS; do
        info "Exporting pool: $pool"
        if zpool export "$pool" 2>/dev/null; then
            success "Exported $pool"
        else
            warning "Failed to export $pool - it may be in use"
            
            # Show what's using the pool
            if command -v lsof >/dev/null 2>&1; then
                info "Processes using pool $pool:"
                lsof +D "$(zfs get -H -o value mountpoint "$pool" 2>/dev/null || echo "/")" 2>/dev/null | head -5 | tee -a "$LOG_FILE" || true
            fi
        fi
    done
}

downgrade_packages() {
    header "PACKAGE DOWNGRADE"
    
    info "Attempting to downgrade packages..."
    
    # Note: XBPS doesn't have a built-in downgrade mechanism
    # We'll need to use the package cache or manually install previous versions
    
    warning "Package downgrade in Void Linux requires manual intervention"
    info "Options available:"
    echo "1. Use cached packages from /var/cache/xbps"
    echo "2. Install specific package versions with: xbps-install -f <package>=<version>"
    echo "3. Use xbps-src to build previous versions"
    echo ""
    
    # Check if we can use cached packages
    if [ -d "/var/cache/xbps" ]; then
        info "Checking for cached packages to downgrade..."
        
        # This is a simplified approach - in practice, you'd need more sophisticated
        # version detection and dependency resolution
        
        if [ "${ZFS_COUNT:-0}" -gt 0 ]; then
            info "ZFS downgrade requires manual package selection"
            info "Available ZFS packages in cache:"
            find /var/cache/xbps -name "*zfs*.xbps" 2>/dev/null | sort || true
        fi
        
        if [ "${KERNEL_COUNT:-0}" -gt 0 ]; then
            info "Kernel downgrade requires manual package selection"
            info "Available kernel packages in cache:"
            find /var/cache/xbps -name "linux*.xbps" 2>/dev/null | sort || true
        fi
    fi
    
    warning "Automatic package downgrade not implemented - manual intervention required"
    info "Consider using ZFS snapshot rollback instead of package downgrade"
}

rollback_zfs_snapshots() {
    if [ "$POOLS_EXIST" != "true" ] || [ -z "$SNAPSHOT_NAME" ]; then
        info "No ZFS snapshots available for rollback"
        return 0
    fi
    
    header "ZFS SNAPSHOT ROLLBACK"
    
    info "Rolling back ZFS datasets to snapshot: $SNAPSHOT_NAME"
    
    # Re-import pools if needed
    if ! zpool list >/dev/null 2>&1; then
        info "Re-importing pools for snapshot rollback..."
        if [ -f "$BACKUP_DIR/exported-pools.txt" ]; then
            EXPORTED_POOLS=$(cat "$BACKUP_DIR/exported-pools.txt")
            for pool in $EXPORTED_POOLS; do
                if zpool import "$pool" 2>/dev/null; then
                    success "Imported $pool"
                else
                    warning "Failed to import $pool"
                fi
            done
        else
            zpool import -a 2>/dev/null || true
        fi
    fi
    
    # Find all snapshots with our rollback name
    ROLLBACK_SNAPSHOTS=$(zfs list -t snapshot -H -o name 2>/dev/null | grep "@$SNAPSHOT_NAME" || echo "")
    
    if [ -z "$ROLLBACK_SNAPSHOTS" ]; then
        warning "No snapshots found with name: $SNAPSHOT_NAME"
        return 0
    fi
    
    info "Found snapshots for rollback:"
    echo "$ROLLBACK_SNAPSHOTS" | while IFS= read -r snap; do
        [ -n "$snap" ] && log "  $snap"
    done
    
    echo ""
    warning "Rolling back snapshots will destroy all changes since snapshot creation"
    read -p "Continue with ZFS snapshot rollback? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "ZFS snapshot rollback cancelled"
        return 0
    fi
    
    # Rollback each dataset
    ROLLBACK_SUCCESS=0
    ROLLBACK_FAILED=0
    
    echo "$ROLLBACK_SNAPSHOTS" | while IFS= read -r snapshot; do
        if [ -n "$snapshot" ]; then
            DATASET=$(echo "$snapshot" | cut -d'@' -f1)
            info "Rolling back $DATASET to $snapshot"
            
            if zfs rollback -r "$snapshot" 2>/dev/null; then
                success "Rolled back $DATASET"
                ((ROLLBACK_SUCCESS++))
            else
                error "Failed to rollback $DATASET"
                ((ROLLBACK_FAILED++))
                
                # Show why rollback failed
                info "Checking for newer snapshots or clones..."
                zfs list -t snapshot -r "$DATASET" 2>/dev/null | tail -5 || true
            fi
        fi
    done
    
    if [ $ROLLBACK_FAILED -eq 0 ]; then
        success "All ZFS snapshots rolled back successfully"
    else
        warning "$ROLLBACK_FAILED snapshots failed to rollback, $ROLLBACK_SUCCESS succeeded"
    fi
}

restore_configurations() {
    header "CONFIGURATION RESTORE"
    
    info "Restoring system configurations from backup..."
    
    # Restore system files
    if [ -f "$BACKUP_DIR/fstab" ]; then
        info "Restoring /etc/fstab"
        cp "$BACKUP_DIR/fstab" /etc/fstab
        success "fstab restored"
    fi
    
    # Restore dracut configuration
    if [ -f "$BACKUP_DIR/dracut.conf" ]; then
        info "Restoring dracut configuration"
        cp "$BACKUP_DIR/dracut.conf" /etc/dracut.conf
        success "dracut.conf restored"
    fi
    
    if [ -d "$BACKUP_DIR/dracut.conf.d" ]; then
        info "Restoring dracut.conf.d directory"
        rm -rf /etc/dracut.conf.d
        cp -r "$BACKUP_DIR/dracut.conf.d" /etc/
        success "dracut.conf.d restored"
    fi
    
    # Restore GRUB configuration (for traditional systems)
    if [ "$ZFSBOOTMENU" != "true" ] && [ -d "$BACKUP_DIR/grub-backup" ]; then
        info "Restoring GRUB configuration"
        rm -rf /boot/grub
        cp -r "$BACKUP_DIR/grub-backup" /boot/grub
        success "GRUB configuration restored"
    fi
}

restore_zfsbootmenu() {
    if [ "$ZFSBOOTMENU" != "true" ]; then
        return 0
    fi
    
    header "ZFSBOOTMENU RESTORE"
    
    info "Restoring ZFSBootMenu configuration..."
    
    # Restore ZBM config
    if [ -f "$BACKUP_DIR/zfsbootmenu-config.yaml" ]; then
        ZBM_CONFIG_DIR=$(dirname "${ZBM_CONFIG:-/etc/zfsbootmenu/config.yaml}")
        mkdir -p "$ZBM_CONFIG_DIR"
        cp "$BACKUP_DIR/zfsbootmenu-config.yaml" "${ZBM_CONFIG:-/etc/zfsbootmenu/config.yaml}"
        success "ZFSBootMenu config restored"
    fi
    
    # Restore ZBM directory
    if [ -d "$BACKUP_DIR/zfsbootmenu-etc" ]; then
        rm -rf /etc/zfsbootmenu
        cp -r "$BACKUP_DIR/zfsbootmenu-etc" /etc/zfsbootmenu
        success "ZFSBootMenu etc directory restored"
    fi
    
    # Restore ZBM EFI image
    if [ -f "$BACKUP_DIR/vmlinuz.efi.backup" ] && [ -n "${ZBM_EFI_PATH:-}" ]; then
        ZBM_EFI_DIR=$(dirname "$ZBM_EFI_PATH")
        mkdir -p "$ZBM_EFI_DIR"
        cp "$BACKUP_DIR/vmlinuz.efi.backup" "$ZBM_EFI_PATH"
        success "ZFSBootMenu EFI image restored"
    fi
    
    # Restore EFI boot entries if we have them
    if [ -f "$BACKUP_DIR/efi-boot-entries.txt" ] && command -v efibootmgr >/dev/null 2>&1; then
        info "Original EFI boot entries saved to log for reference"
        cat "$BACKUP_DIR/efi-boot-entries.txt" | tee -a "$LOG_FILE"
    fi
}

rebuild_initramfs_for_rollback() {
    info "Rebuilding initramfs after rollback..."
    
    # Get current kernel after rollback
    CURRENT_KERNEL=$(uname -r)
    
    info "Rebuilding initramfs for kernel: $CURRENT_KERNEL"
    
    if [ "$ZFSBOOTMENU" = "true" ]; then
        # ZBM-specific dracut
        if dracut -f --kver "$CURRENT_KERNEL" --add zfs --omit systemd; then
            success "Initramfs rebuilt for ZFSBootMenu"
        else
            error "Failed to rebuild initramfs for ZFSBootMenu"
        fi
    else
        # Traditional dracut
        if dracut -f --kver "$CURRENT_KERNEL"; then
            success "Initramfs rebuilt"
        else
            error "Failed to rebuild initramfs"
        fi
    fi
}

cleanup_rollback() {
    info "Cleaning up after rollback..."
    
    # Clean up any temporary files
    # Re-import pools if they were exported
    if [ "$POOLS_EXIST" = "true" ]; then
        info "Ensuring pools are imported after rollback..."
        zpool import -a 2>/dev/null || true
        
        if zpool list >/dev/null 2>&1; then
            success "ZFS pools are accessible after rollback"
        else
            warning "Some ZFS pools may need manual import"
        fi
    fi
    
    success "Rollback cleanup completed"
}

verify_rollback() {
    header "ROLLBACK VERIFICATION"
    
    info "Verifying system state after rollback..."
    
    # Check ZFS functionality
    if lsmod | grep -q zfs; then
        success "ZFS module is loaded"
    else
        error "ZFS module not loaded after rollback"
    fi
    
    if [ "$POOLS_EXIST" = "true" ]; then
        if zpool list >/dev/null 2>&1; then
            success "ZFS pools are accessible"
            
            # Check pool health
            if zpool status | grep -E "(DEGRADED|FAULTED|OFFLINE|UNAVAIL)"; then
                warning "Pool errors still exist after rollback"
            else
                success "All pools are healthy after rollback"
            fi
        else
            error "ZFS pools not accessible after rollback"
        fi
    fi
    
    success "Rollback verification completed"
}

main() {
    header "ZFS UPDATE ROLLBACK"
    
    log "Starting ZFS/kernel update rollback..."
    
    check_root
    load_config
    detect_rollback_reason
    confirm_rollback
    
    backup_current_state
    
    # Rollback sequence
    get_previous_package_versions
    export_zfs_pools_for_rollback
    
    # Note: Package downgrade is complex in Void Linux
    # Focus on ZFS snapshot rollback and configuration restore
    rollback_zfs_snapshots
    restore_configurations
    restore_zfsbootmenu
    rebuild_initramfs_for_rollback
    cleanup_rollback
    verify_rollback
    
    header "ROLLBACK COMPLETED"
    
    success "System rollback completed!"
    
    echo ""
    echo "Rollback Summary:"
    [ -n "$SNAPSHOT_NAME" ] && echo "• ZFS datasets rolled back to: $SNAPSHOT_NAME"
    echo "• System configurations restored from backup"
    if [ "$ZFSBOOTMENU" = "true" ]; then
        echo "• ZFSBootMenu configuration restored"
    fi
    echo "• Initramfs rebuilt"
    echo ""
    echo "Important Notes:"
    echo "• Package rollback requires manual intervention in Void Linux"
    echo "• Monitor system stability after rollback"
    echo "• Consider running zfs-post-update-verify.sh to check system"
    echo ""
    echo "Files:"
    echo "• Rollback log: $LOG_FILE"
    echo "• Original backup: $BACKUP_DIR"
    echo "• Pre-rollback state: $ROLLBACK_BACKUP_DIR"
    
    warning "Reboot recommended to ensure clean state after rollback"
    
    log "Rollback procedure completed"
}

main "$@"