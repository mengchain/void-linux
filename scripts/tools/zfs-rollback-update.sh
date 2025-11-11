#!/bin/bash
# filepath: zfs-rollback-update.sh
# ZFS/Kernel Update Rollback Script
# Comprehensive rollback of failed ZFS/kernel updates using snapshots and backups

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
    
    # Set defaults for all variables that might not exist
    ZFSBOOTMENU=${ZFSBOOTMENU:-false}
    POOLS_EXIST=${POOLS_EXIST:-false}
    KERNEL_UPDATED=${KERNEL_UPDATED:-false}
    DRACUT_UPDATED=${DRACUT_UPDATED:-false}
    ZFS_UPDATED=${ZFS_UPDATED:-false}
    DKMS_UPDATED=${DKMS_UPDATED:-false}
    DKMS_AVAILABLE=${DKMS_AVAILABLE:-false}
    SNAPSHOT_NAME=${SNAPSHOT_NAME:-""}
    INSTALL_SNAPSHOT_NAME=${INSTALL_SNAPSHOT_NAME:-""}
    TOTAL_UPDATES=${TOTAL_UPDATES:-0}
    ZFS_COUNT=${ZFS_COUNT:-0}
    DRACUT_COUNT=${DRACUT_COUNT:-0}
    KERNEL_COUNT=${KERNEL_COUNT:-0}
    DKMS_COUNT=${DKMS_COUNT:-0}
    ESP_MOUNT=${ESP_MOUNT:-""}
    ZBM_EFI_PATH=${ZBM_EFI_PATH:-""}
    
    info "Configuration loaded for rollback"
    log "System type: $([ "$ZFSBOOTMENU" = true ] && echo "ZFSBootMenu" || echo "Traditional")"
    log "Backup directory: $BACKUP_DIR"
    log "Snapshot name: ${INSTALL_SNAPSHOT_NAME:-${SNAPSHOT_NAME:-none}}"
    log "Components updated - Kernel: $KERNEL_UPDATED, ZFS: $ZFS_UPDATED, Dracut: $DRACUT_UPDATED, DKMS: $DKMS_UPDATED"
    log "Total updates that were applied: $TOTAL_UPDATES packages"
}

validate_backup_completeness() {
    header "BACKUP VALIDATION"
    
    info "Validating backup completeness..."
    
    MISSING_BACKUPS=""
    CRITICAL_MISSING=false
    
    # Essential backup files
    ESSENTIAL_FILES="zfs-datasets.txt zpool-list.txt"
    for file in $ESSENTIAL_FILES; do
        if [ ! -f "$BACKUP_DIR/$file" ]; then
            MISSING_BACKUPS="$MISSING_BACKUPS\n• Missing: $file (ZFS structure backup)"
            CRITICAL_MISSING=true
        fi
    done
    
    # System configuration backups
    SYSTEM_FILES="fstab"
    for file in $SYSTEM_FILES; do
        if [ ! -f "$BACKUP_DIR/$file" ]; then
            MISSING_BACKUPS="$MISSING_BACKUPS\n• Missing: $file (system configuration)"
        fi
    done
    
    # Dracut configuration backup
    if [ "${DRACUT_UPDATED:-false}" = "true" ]; then
        if [ ! -f "$BACKUP_DIR/dracut.conf" ] && [ ! -d "$BACKUP_DIR/dracut.conf.d" ]; then
            MISSING_BACKUPS="$MISSING_BACKUPS\n• Missing: dracut configuration (dracut was updated)"
        fi
    fi
    
    # ZFSBootMenu specific backups
    if [ "$ZFSBOOTMENU" = "true" ]; then
        ZBM_BACKUPS="zfsbootmenu-config.yaml esp-complete-backup esp-info.txt"
        for file in $ZBM_BACKUPS; do
            if [ ! -f "$BACKUP_DIR/$file" ] && [ ! -d "$BACKUP_DIR/$file" ]; then
                MISSING_BACKUPS="$MISSING_BACKUPS\n• Missing: $file (ZFSBootMenu backup)"
                if [[ "$file" == "esp-complete-backup" ]]; then
                    CRITICAL_MISSING=true
                fi
            fi
        done
        
        if [ ! -f "$BACKUP_DIR/vmlinuz.efi.backup" ]; then
            MISSING_BACKUPS="$MISSING_BACKUPS\n• Missing: vmlinuz.efi.backup (ZFSBootMenu EFI image)"
            CRITICAL_MISSING=true
        fi
    fi
    
    # DKMS backup validation
    if [ "${DKMS_AVAILABLE:-false}" = "true" ] && [ "${DKMS_UPDATED:-false}" = "true" ]; then
        info "DKMS was updated but rollback requires manual DKMS module management"
    fi
    
    # Check for installation snapshots
    USE_INSTALL_SNAPSHOTS=false
    if [ -n "${INSTALL_SNAPSHOT_NAME:-}" ]; then
        # Check if installation snapshots exist
        SNAPSHOT_COUNT=$(zfs list -t snapshot -H -o name 2>/dev/null | grep "@${INSTALL_SNAPSHOT_NAME}" | wc -l || echo "0")
        if [ "$SNAPSHOT_COUNT" -gt 0 ]; then
            success "Found $SNAPSHOT_COUNT installation snapshots for rollback"
            USE_INSTALL_SNAPSHOTS=true
            EFFECTIVE_SNAPSHOT_NAME="$INSTALL_SNAPSHOT_NAME"
        else
            warning "Installation snapshots not found: $INSTALL_SNAPSHOT_NAME"
        fi
    fi
    
    # Fallback to older snapshot name
    if [ "$USE_INSTALL_SNAPSHOTS" = "false" ] && [ -n "${SNAPSHOT_NAME:-}" ]; then
        SNAPSHOT_COUNT=$(zfs list -t snapshot -H -o name 2>/dev/null | grep "@${SNAPSHOT_NAME}" | wc -l || echo "0")
        if [ "$SNAPSHOT_COUNT" -gt 0 ]; then
            info "Using fallback snapshots: $SNAPSHOT_NAME ($SNAPSHOT_COUNT found)"
            EFFECTIVE_SNAPSHOT_NAME="$SNAPSHOT_NAME"
        else
            warning "No snapshots found for rollback"
            EFFECTIVE_SNAPSHOT_NAME=""
        fi
    fi
    
    # Report findings
    if [ -n "$MISSING_BACKUPS" ]; then
        warning "Backup validation issues found:"
        echo -e "$MISSING_BACKUPS"
        echo ""
        
        if [ "$CRITICAL_MISSING" = "true" ]; then
            error "Critical backups are missing - rollback may be incomplete"
            echo "Missing critical backups that should have been created in Script 2:"
            if [ "$ZFSBOOTMENU" = "true" ]; then
                echo "• Complete ESP backup (esp-complete-backup/)"
                echo "• ZFSBootMenu EFI image backup (vmlinuz.efi.backup)"
            fi
            if [ "$POOLS_EXIST" = "true" ]; then
                echo "• ZFS structure backups (zfs-datasets.txt, zpool-list.txt)"
            fi
            echo ""
            read -p "Continue with incomplete rollback? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log "Rollback cancelled due to incomplete backups"
                exit 1
            fi
        fi
    else
        success "All expected backup files found"
    fi
    
    log "Effective snapshot name for rollback: ${EFFECTIVE_SNAPSHOT_NAME:-none}"
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
    if ! command -v zpool >/dev/null 2>&1; then
        ROLLBACK_REASONS="$ROLLBACK_REASONS\n• ZFS commands not available"
        CRITICAL_ISSUES=true
    elif ! zpool list >/dev/null 2>&1; then
        ROLLBACK_REASONS="$ROLLBACK_REASONS\n• ZFS commands not working (pools inaccessible)"
        CRITICAL_ISSUES=true
    fi
    
    # Check pool health if pools exist
    if [ "$POOLS_EXIST" = "true" ] && zpool status >/dev/null 2>&1; then
        if zpool status 2>/dev/null | grep -E "(DEGRADED|FAULTED|OFFLINE|UNAVAIL)"; then
            ROLLBACK_REASONS="$ROLLBACK_REASONS\n• ZFS pool errors detected"
            CRITICAL_ISSUES=true
        fi
    fi
    
    # Check kernel/module compatibility
    if lsmod | grep -q zfs; then
        RUNNING_KERNEL=$(uname -r)
        ZFS_MODULE_KERNEL=$(modinfo zfs 2>/dev/null | grep -E "^vermagic:" | awk '{print $2}' || echo "unknown")
        
        if [ "$ZFS_MODULE_KERNEL" != "unknown" ] && [[ ! "$ZFS_MODULE_KERNEL" == "$RUNNING_KERNEL"* ]]; then
            ROLLBACK_REASONS="$ROLLBACK_REASONS\n• ZFS module/kernel version mismatch"
            ROLLBACK_REASONS="$ROLLBACK_REASONS\n  Running: $RUNNING_KERNEL, Module: $ZFS_MODULE_KERNEL"
            CRITICAL_ISSUES=true
        fi
    fi
    
    # Check DKMS status
    if [ "${DKMS_AVAILABLE:-false}" = "true" ] && command -v dkms >/dev/null 2>&1; then
        DKMS_STATUS=$(dkms status zfs 2>/dev/null || echo "not found")
        if ! echo "$DKMS_STATUS" | grep -q "installed"; then
            ROLLBACK_REASONS="$ROLLBACK_REASONS\n• DKMS ZFS module not properly installed"
        fi
    fi
    
    # Check boot issues for ZFSBootMenu
    if [ "$ZFSBOOTMENU" = "true" ]; then
        if [ -n "$ZBM_EFI_PATH" ] && [ ! -f "$ZBM_EFI_PATH" ]; then
            ROLLBACK_REASONS="$ROLLBACK_REASONS\n• ZFSBootMenu EFI image missing: $ZBM_EFI_PATH"
            CRITICAL_ISSUES=true
        elif [ -n "$ZBM_EFI_PATH" ] && [ -f "$ZBM_EFI_PATH" ]; then
            ZBM_SIZE=$(stat -c%s "$ZBM_EFI_PATH" 2>/dev/null || echo "0")
            if [ "$ZBM_SIZE" -lt 1000000 ]; then
                ROLLBACK_REASONS="$ROLLBACK_REASONS\n• ZFSBootMenu EFI image too small: ${ZBM_SIZE} bytes"
                CRITICAL_ISSUES=true
            fi
        fi
    fi
    
    # Check initramfs issues
    RUNNING_KERNEL=$(uname -r)
    INITRAMFS_PATH="/boot/initramfs-${RUNNING_KERNEL}.img"
    if [ ! -f "$INITRAMFS_PATH" ]; then
        ROLLBACK_REASONS="$ROLLBACK_REASONS\n• Missing initramfs for running kernel: $INITRAMFS_PATH"
        CRITICAL_ISSUES=true
    elif [ -f "$INITRAMFS_PATH" ]; then
        INITRAMFS_SIZE=$(stat -c%s "$INITRAMFS_PATH" 2>/dev/null || echo "0")
        if [ "$INITRAMFS_SIZE" -lt 1000000 ]; then
            ROLLBACK_REASONS="$ROLLBACK_REASONS\n• Initramfs too small: ${INITRAMFS_SIZE} bytes"
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
    [ "${ZFS_COUNT:-0}" -gt 0 ] && echo "• ZFS packages ($ZFS_COUNT packages) - updated: ${ZFS_UPDATED:-false}"
    [ "${DRACUT_COUNT:-0}" -gt 0 ] && echo "• Dracut packages ($DRACUT_COUNT packages) - updated: ${DRACUT_UPDATED:-false}"
    [ "${KERNEL_COUNT:-0}" -gt 0 ] && echo "• Kernel packages ($KERNEL_COUNT packages) - updated: $KERNEL_UPDATED"
    [ "${DKMS_COUNT:-0}" -gt 0 ] && echo "• DKMS packages ($DKMS_COUNT packages) - updated: ${DKMS_UPDATED:-false}"
    echo ""
    echo "Rollback will:"
    echo "1. Create backup of current state"
    echo "2. Attempt package rollback (limited in Void Linux)"
    if [ -n "${EFFECTIVE_SNAPSHOT_NAME:-}" ] && [ "$POOLS_EXIST" = "true" ]; then
        echo "3. Rollback ZFS datasets to snapshot: ${EFFECTIVE_SNAPSHOT_NAME}"
    else
        echo "3. Skip ZFS rollback (no snapshots available)"
    fi
    echo "4. Restore system configurations from backup"
    echo "5. Restore dracut configuration"
    if [ "${DKMS_AVAILABLE:-false}" = "true" ]; then
        echo "6. Rebuild DKMS modules for current kernel"
    fi
    echo "7. Rebuild initramfs"
    if [ "$ZFSBOOTMENU" = "true" ]; then
        echo "8. Restore ZFSBootMenu and ESP configuration"
    else
        echo "8. Update bootloader configuration"
    fi
    echo ""
    echo -e "${RED}WARNING: This operation cannot be undone easily!${NC}"
    echo -e "${YELLOW}Make sure you have alternative boot methods available.${NC}"
    
    if [ -n "${EFFECTIVE_SNAPSHOT_NAME:-}" ]; then
        echo -e "${YELLOW}ZFS rollback will lose all changes since: ${EFFECTIVE_SNAPSHOT_NAME}${NC}"
    fi
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
    
    # Backup current kernel info
    {
        echo "=== Current Kernel ==="
        uname -a
        echo ""
        echo "=== Available Kernels ==="
        ls /lib/modules 2>/dev/null || echo "No modules directory"
        echo ""
        echo "=== ZFS Module Info ==="
        modinfo zfs 2>/dev/null || echo "ZFS module not loaded"
        echo ""
        echo "=== ZFS Version ==="
        zfs version 2>/dev/null || echo "ZFS command failed"
    } > "$ROLLBACK_BACKUP_DIR/current-kernel-info.txt"
    
    # Backup current ZFS state if accessible
    if [ "$POOLS_EXIST" = "true" ] && zpool list >/dev/null 2>&1; then
        zfs list -H -o name,mountpoint > "$ROLLBACK_BACKUP_DIR/current-zfs-datasets.txt" 2>/dev/null || true
        zpool status -v > "$ROLLBACK_BACKUP_DIR/current-pool-status.txt" 2>/dev/null || true
        zfs get all > "$ROLLBACK_BACKUP_DIR/current-zfs-properties.txt" 2>/dev/null || true
    fi
    
    # Backup current system configuration
    cp /etc/fstab "$ROLLBACK_BACKUP_DIR/" 2>/dev/null || true
    
    if [ -f /etc/dracut.conf ]; then
        cp /etc/dracut.conf "$ROLLBACK_BACKUP_DIR/" 2>/dev/null || true
    fi
    
    if [ -d /etc/dracut.conf.d ]; then
        cp -r /etc/dracut.conf.d "$ROLLBACK_BACKUP_DIR/" 2>/dev/null || true
    fi
    
    # Backup DKMS state
    if [ "${DKMS_AVAILABLE:-false}" = "true" ] && command -v dkms >/dev/null 2>&1; then
        dkms status > "$ROLLBACK_BACKUP_DIR/current-dkms-status.txt" 2>/dev/null || true
    fi
    
    # Backup ZFSBootMenu state
    if [ "$ZFSBOOTMENU" = "true" ]; then
        if [ -f "${ZBM_CONFIG:-/etc/zfsbootmenu/config.yaml}" ]; then
            cp "${ZBM_CONFIG:-/etc/zfsbootmenu/config.yaml}" "$ROLLBACK_BACKUP_DIR/current-zbm-config.yaml" 2>/dev/null || true
        fi
        
        if [ -n "$ZBM_EFI_PATH" ] && [ -f "$ZBM_EFI_PATH" ]; then
            cp "$ZBM_EFI_PATH" "$ROLLBACK_BACKUP_DIR/current-vmlinuz.efi" 2>/dev/null || true
        fi
        
        if command -v efibootmgr >/dev/null 2>&1; then
            efibootmgr -v > "$ROLLBACK_BACKUP_DIR/current-efi-entries.txt" 2>/dev/null || true
        fi
    fi
    
    success "Current state backed up to: $ROLLBACK_BACKUP_DIR"
}

attempt_package_rollback() {
    header "PACKAGE ROLLBACK ATTEMPT"
    
    warning "Package rollback in Void Linux is complex and not fully automated"
    
    info "Available approaches for package rollback:"
    echo "1. Using package cache (/var/cache/xbps)"
    echo "2. Manual installation of specific versions"
    echo "3. Using xbps-src to build previous versions"
    echo ""
    
    # Check package cache
    if [ -d "/var/cache/xbps" ]; then
        info "Checking package cache for previous versions..."
        
        # ZFS packages
        if [ "${ZFS_UPDATED:-false}" = "true" ]; then
            ZFS_CACHE_PKGS=$(find /var/cache/xbps -name "*zfs*.xbps" 2>/dev/null | head -10 | sort -V || true)
            if [ -n "$ZFS_CACHE_PKGS" ]; then
                info "Available ZFS packages in cache:"
                echo "$ZFS_CACHE_PKGS" | while IFS= read -r pkg; do
                    [ -n "$pkg" ] && log "  $(basename "$pkg")"
                done
            fi
        fi
        
        # Kernel packages
        if [ "$KERNEL_UPDATED" = "true" ]; then
            KERNEL_CACHE_PKGS=$(find /var/cache/xbps -name "linux*.xbps" 2>/dev/null | head -10 | sort -V || true)
            if [ -n "$KERNEL_CACHE_PKGS" ]; then
                info "Available kernel packages in cache:"
                echo "$KERNEL_CACHE_PKGS" | while IFS= read -r pkg; do
                    [ -n "$pkg" ] && log "  $(basename "$pkg")"
                done
            fi
        fi
        
        # Dracut packages
        if [ "${DRACUT_UPDATED:-false}" = "true" ]; then
            DRACUT_CACHE_PKGS=$(find /var/cache/xbps -name "*dracut*.xbps" 2>/dev/null | head -5 | sort -V || true)
            if [ -n "$DRACUT_CACHE_PKGS" ]; then
                info "Available dracut packages in cache:"
                echo "$DRACUT_CACHE_PKGS" | while IFS= read -r pkg; do
                    [ -n "$pkg" ] && log "  $(basename "$pkg")"
                done
            fi
        fi
    else
        warning "Package cache not found at /var/cache/xbps"
    fi
    
    echo ""
    warning "Automatic package downgrade not implemented"
    info "Manual package rollback options:"
    echo "• Use 'xbps-install -f /var/cache/xbps/package.xbps' for cached packages"
    echo "• Use 'xbps-install package=version' for specific versions if available"
    echo "• Build previous versions with xbps-src"
    echo ""
    info "Continuing with configuration and snapshot rollback..."
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
    
    # Save current pool list for re-import
    echo "$ALL_POOLS" > "$ROLLBACK_BACKUP_DIR/pools-to-reimport.txt"
    
    for pool in $ALL_POOLS; do
        info "Exporting pool: $pool"
        if zpool export "$pool" 2>/dev/null; then
            success "Exported $pool"
        else
            warning "Failed to export $pool - it may be in use"
            
            # Show what's using the pool
            if command -v lsof >/dev/null 2>&1; then
                info "Processes using pool $pool:"
                POOL_MOUNTS=$(zfs list -H -o mountpoint -r "$pool" 2>/dev/null | grep -v "none\|-" || true)
                for mount in $POOL_MOUNTS; do
                    if [ -n "$mount" ] && [ -d "$mount" ]; then
                        lsof +D "$mount" 2>/dev/null | head -5 | tee -a "$LOG_FILE" || true
                    fi
                done
            fi
            
            # For critical pools, try force export
            warning "Attempting force export of $pool"
            if zpool export -f "$pool" 2>/dev/null; then
                warning "Force export of $pool succeeded"
            else
                error "Cannot export pool $pool - manual intervention required"
            fi
        fi
    done
}

rollback_zfs_snapshots() {
    if [ "$POOLS_EXIST" != "true" ] || [ -z "${EFFECTIVE_SNAPSHOT_NAME:-}" ]; then
        info "No ZFS snapshots available for rollback"
        return 0
    fi
    
    header "ZFS SNAPSHOT ROLLBACK"
    
    info "Rolling back ZFS datasets to snapshot: $EFFECTIVE_SNAPSHOT_NAME"
    
    # Re-import pools if needed
    if ! zpool list >/dev/null 2>&1; then
        info "Re-importing pools for snapshot rollback..."
        
        # Try to use our saved list first
        if [ -f "$ROLLBACK_BACKUP_DIR/pools-to-reimport.txt" ]; then
            POOLS_TO_IMPORT=$(cat "$ROLLBACK_BACKUP_DIR/pools-to-reimport.txt")
            for pool in $POOLS_TO_IMPORT; do
                if zpool import "$pool" 2>/dev/null; then
                    success "Imported $pool"
                else
                    warning "Failed to import $pool"
                fi
            done
        elif [ -f "$BACKUP_DIR/exported-pools.txt" ]; then
            # Fallback to original export list
            EXPORTED_POOLS=$(cat "$BACKUP_DIR/exported-pools.txt")
            for pool in $EXPORTED_POOLS; do
                if zpool import "$pool" 2>/dev/null; then
                    success "Imported $pool"
                else
                    warning "Failed to import $pool"
                fi
            done
        else
            # Last resort - try to import all available
            zpool import -a 2>/dev/null || true
        fi
    fi
    
    # Find all snapshots with our rollback name
    ROLLBACK_SNAPSHOTS=$(zfs list -t snapshot -H -o name 2>/dev/null | grep "@$EFFECTIVE_SNAPSHOT_NAME" || echo "")
    
    if [ -z "$ROLLBACK_SNAPSHOTS" ]; then
        warning "No snapshots found with name: $EFFECTIVE_SNAPSHOT_NAME"
        return 0
    fi
    
    info "Found snapshots for rollback:"
    SNAPSHOT_COUNT=0
    echo "$ROLLBACK_SNAPSHOTS" | while IFS= read -r snap; do
        if [ -n "$snap" ]; then
            log "  $snap"
            ((SNAPSHOT_COUNT++))
        fi
    done
    
    SNAPSHOT_COUNT=$(echo "$ROLLBACK_SNAPSHOTS" | grep -c . || echo "0")
    info "Total snapshots for rollback: $SNAPSHOT_COUNT"
    
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
            
            # Check for newer snapshots that would prevent rollback
            NEWER_SNAPS=$(zfs list -t snapshot -H -o name -S creation "$DATASET" 2>/dev/null | awk "/$EFFECTIVE_SNAPSHOT_NAME/{exit} {print}" || true)
            
            if [ -n "$NEWER_SNAPS" ]; then
                warning "Found newer snapshots that may prevent rollback:"
                echo "$NEWER_SNAPS" | head -3 | while IFS= read -r newer; do
                    [ -n "$newer" ] && log "  $newer"
                done
                
                info "Attempting rollback with -r flag to remove newer snapshots"
            fi
            
            if zfs rollback -r "$snapshot" 2>/dev/null; then
                success "Rolled back $DATASET"
                ROLLBACK_SUCCESS=$((ROLLBACK_SUCCESS + 1))
            else
                error "Failed to rollback $DATASET"
                ROLLBACK_FAILED=$((ROLLBACK_FAILED + 1))
                
                # Show detailed error information
                info "Checking rollback obstacles for $DATASET..."
                zfs list -t snapshot,filesystem,volume -r "$DATASET" 2>/dev/null | tail -10 || true
                
                # Check for clones
                CLONES=$(zfs get -H -o value clones "$snapshot" 2>/dev/null || echo "")
                if [ -n "$CLONES" ] && [ "$CLONES" != "-" ]; then
                    warning "Snapshot has clones: $CLONES"
                fi
            fi
        fi
    done
    
    if [ $ROLLBACK_FAILED -eq 0 ]; then
        success "All ZFS snapshots rolled back successfully"
    else
        warning "$ROLLBACK_FAILED snapshots failed to rollback, $ROLLBACK_SUCCESS succeeded"
        warning "Some datasets may need manual attention"
    fi
}

restore_configurations() {
    header "CONFIGURATION RESTORE"
    
    info "Restoring system configurations from backup..."
    
    # Restore system files
    if [ -f "$BACKUP_DIR/fstab" ]; then
        info "Restoring /etc/fstab"
        if cp "$BACKUP_DIR/fstab" /etc/fstab; then
            success "fstab restored"
        else
            warning "Failed to restore fstab"
        fi
    fi
    
    # Restore dracut configuration
    if [ "${DRACUT_UPDATED:-false}" = "true" ]; then
        info "Restoring dracut configuration (dracut was updated)"
        
        if [ -f "$BACKUP_DIR/dracut.conf" ]; then
            if cp "$BACKUP_DIR/dracut.conf" /etc/dracut.conf; then
                success "dracut.conf restored"
            else
                warning "Failed to restore dracut.conf"
            fi
        fi
        
        if [ -d "$BACKUP_DIR/dracut.conf.d" ]; then
            info "Restoring dracut.conf.d directory"
            rm -rf /etc/dracut.conf.d
            if cp -r "$BACKUP_DIR/dracut.conf.d" /etc/; then
                success "dracut.conf.d restored"
            else
                warning "Failed to restore dracut.conf.d"
            fi
        fi
    else
        info "Dracut was not updated - skipping dracut configuration restore"
    fi
    
    # Restore modprobe configurations
    if find "$BACKUP_DIR" -name "*.conf" -path "*/modprobe.d/*" >/dev/null 2>&1; then
        info "Restoring modprobe configurations"
        find "$BACKUP_DIR" -name "*.conf" -exec basename {} \; | while IFS= read -r conf; do
            if [ -f "$BACKUP_DIR/$conf" ]; then
                cp "$BACKUP_DIR/$conf" /etc/modprobe.d/ 2>/dev/null || true
            fi
        done
        success "Modprobe configurations restored"
    fi
    
    # Restore GRUB configuration (for traditional systems)
    if [ "$ZFSBOOTMENU" != "true" ] && [ -d "$BACKUP_DIR/grub-backup" ]; then
        info "Restoring GRUB configuration"
        if [ -d /boot/grub ]; then
            cp -r /boot/grub /boot/grub.rollback-backup.$(date +%s) 2>/dev/null || true
        fi
        
        rm -rf /boot/grub
        if cp -r "$BACKUP_DIR/grub-backup" /boot/grub; then
            success "GRUB configuration restored"
        else
            warning "Failed to restore GRUB configuration"
        fi
    fi
    
    success "Configuration restore completed"
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
        if cp "$BACKUP_DIR/zfsbootmenu-config.yaml" "${ZBM_CONFIG:-/etc/zfsbootmenu/config.yaml}"; then
            success "ZFSBootMenu config restored"
        else
            warning "Failed to restore ZFSBootMenu config"
        fi
    fi
    
    # Restore ZBM directory
    if [ -d "$BACKUP_DIR/zfsbootmenu-etc" ]; then
        if [ -d /etc/zfsbootmenu ]; then
            cp -r /etc/zfsbootmenu "/etc/zfsbootmenu.rollback-backup.$(date +%s)" 2>/dev/null || true
        fi
        
        rm -rf /etc/zfsbootmenu
        if cp -r "$BACKUP_DIR/zfsbootmenu-etc" /etc/zfsbootmenu; then
            success "ZFSBootMenu etc directory restored"
        else
            warning "Failed to restore ZFSBootMenu etc directory"
        fi
    fi
    
    # Restore complete ESP backup
    if [ -d "$BACKUP_DIR/esp-complete-backup" ] && [ -n "$ESP_MOUNT" ]; then
        info "Restoring complete ESP from backup"
        warning "This will overwrite the entire ESP - make sure system is not booted from ESP"
        
        read -p "Continue with ESP restore? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if [ -d "$ESP_MOUNT" ]; then
                # Backup current ESP
                ESP_BACKUP_NAME="esp-backup-$(date +%s)"
                if cp -r "$ESP_MOUNT" "$ROLLBACK_BACKUP_DIR/$ESP_BACKUP_NAME"; then
                    info "Current ESP backed up to: $ESP_BACKUP_NAME"
                fi
                
                # Clear and restore ESP
                find "$ESP_MOUNT" -mindepth 1 -delete 2>/dev/null || true
                if cp -r "$BACKUP_DIR/esp-complete-backup"/* "$ESP_MOUNT"/; then
                    success "Complete ESP restored from backup"
                else
                    error "Failed to restore ESP - system may not boot!"
                    warning "ESP backup available at: $ROLLBACK_BACKUP_DIR/$ESP_BACKUP_NAME"
                fi
            else
                warning "ESP mount point not found: $ESP_MOUNT"
            fi
        else
            info "ESP restore skipped"
            
            # Just restore the ZBM EFI image
            if [ -f "$BACKUP_DIR/vmlinuz.efi.backup" ] && [ -n "$ZBM_EFI_PATH" ]; then
                ZBM_EFI_DIR=$(dirname "$ZBM_EFI_PATH")
                mkdir -p "$ZBM_EFI_DIR"
                if cp "$BACKUP_DIR/vmlinuz.efi.backup" "$ZBM_EFI_PATH"; then
                    success "ZFSBootMenu EFI image restored"
                else
                    warning "Failed to restore ZFSBootMenu EFI image"
                fi
            fi
        fi
    elif [ -f "$BACKUP_DIR/vmlinuz.efi.backup" ] && [ -n "$ZBM_EFI_PATH" ]; then
        # Just restore the EFI image
        ZBM_EFI_DIR=$(dirname "$ZBM_EFI_PATH")
        mkdir -p "$ZBM_EFI_DIR"
        if cp "$BACKUP_DIR/vmlinuz.efi.backup" "$ZBM_EFI_PATH"; then
            success "ZFSBootMenu EFI image restored"
        else
            warning "Failed to restore ZFSBootMenu EFI image"
        fi
    else
        warning "No ZFSBootMenu EFI backup found"
    fi
    
    # Restore EFI boot entries information (for reference)
    if [ -f "$BACKUP_DIR/efi-boot-entries.txt" ]; then
        info "Original EFI boot entries (for reference):"
        cat "$BACKUP_DIR/efi-boot-entries.txt" | tee -a "$LOG_FILE"
    fi
    
    success "ZFSBootMenu restore completed"
}

rollback_dkms_modules() {
    if [ "${DKMS_AVAILABLE:-false}" != "true" ]; then
        info "DKMS not available - skipping DKMS rollback"
        return 0
    fi
    
    if [ "${DKMS_UPDATED:-false}" != "true" ]; then
        info "DKMS was not updated - skipping DKMS rollback"
        return 0
    fi
    
    header "DKMS MODULE ROLLBACK"
    
    info "Handling DKMS module rollback..."
    
    if ! command -v dkms >/dev/null 2>&1; then
        warning "DKMS command not available"
        return 0
    fi
    
    # Get current kernel
    CURRENT_KERNEL=$(uname -r)
    
    info "Rebuilding DKMS modules for current kernel: $CURRENT_KERNEL"
    
    # Remove and rebuild ZFS DKMS modules
    info "Removing current ZFS DKMS modules"
    dkms remove zfs --all 2>/dev/null || true
    
    info "Adding and building ZFS DKMS modules for rollback"
    if dkms add zfs && dkms build zfs && dkms install zfs; then
        success "DKMS ZFS modules rebuilt for rollback"
    else
        warning "DKMS ZFS module rebuild failed"
        warning "Manual DKMS intervention may be required"
        info "Try: dkms install zfs -k $CURRENT_KERNEL"
    fi
}

rebuild_initramfs_for_rollback() {
    header "INITRAMFS ROLLBACK REBUILD"
    
    info "Rebuilding initramfs after rollback..."
    
    # Get current kernel after rollback
    CURRENT_KERNEL=$(uname -r)
    
    info "Rebuilding initramfs for kernel: $CURRENT_KERNEL"
    
    # Backup current initramfs
    CURRENT_INITRAMFS="/boot/initramfs-${CURRENT_KERNEL}.img"
    if [ -f "$CURRENT_INITRAMFS" ]; then
        cp "$CURRENT_INITRAMFS" "$ROLLBACK_BACKUP_DIR/initramfs-${CURRENT_KERNEL}.img.pre-rollback" 2>/dev/null || true
    fi
    
    if [ "$ZFSBOOTMENU" = "true" ]; then
        # ZBM-specific dracut
        info "Rebuilding initramfs with ZFSBootMenu optimizations"
        if dracut -f --kver "$CURRENT_KERNEL" --add zfs --omit systemd; then
            success "Initramfs rebuilt for ZFSBootMenu"
        else
            error "Failed to rebuild initramfs for ZFSBootMenu"
            warning "System may not boot properly"
        fi
    else
        # Traditional dracut
        info "Rebuilding initramfs with traditional configuration"
        if dracut -f --kver "$CURRENT_KERNEL"; then
            success "Initramfs rebuilt"
        else
            error "Failed to rebuild initramfs"
            warning "System may not boot properly"
        fi
    fi
    
    # Verify initramfs was created and has reasonable size
    if [ -f "$CURRENT_INITRAMFS" ]; then
        INITRAMFS_SIZE=$(stat -c%s "$CURRENT_INITRAMFS" 2>/dev/null || echo "0")
        if [ "$INITRAMFS_SIZE" -gt 1000000 ]; then
            success "Initramfs appears valid (${INITRAMFS_SIZE} bytes)"
        else
            warning "Initramfs seems too small (${INITRAMFS_SIZE} bytes)"
        fi
    else
        error "Initramfs was not created: $CURRENT_INITRAMFS"
    fi
}

cleanup_rollback() {
    header "ROLLBACK CLEANUP"
    
    info "Cleaning up after rollback..."
    
    # Re-import pools if they were exported and not already imported
    if [ "$POOLS_EXIST" = "true" ]; then
        info "Ensuring pools are imported after rollback..."
        
        if ! zpool list >/dev/null 2>&1; then
            warning "Pools not imported - attempting auto-import"
            zpool import -a 2>/dev/null || true
        fi
        
        if zpool list >/dev/null 2>&1; then
            success "ZFS pools are accessible after rollback"
            
            # Quick pool health check
            if zpool status | grep -E "(DEGRADED|FAULTED|OFFLINE|UNAVAIL)"; then
                warning "Pool health issues detected after rollback"
                zpool status -v | tee -a "$LOG_FILE"
            else
                success "All pools appear healthy after rollback"
            fi
        else
            warning "Some ZFS pools may need manual import"
            info "Available pools for import:"
            zpool import 2>&1 | tee -a "$LOG_FILE" || true
        fi
    fi
    
    # Update bootloader if needed
    if [ "$ZFSBOOTMENU" != "true" ]; then
        info "Updating GRUB configuration after rollback"
        if command -v update-grub >/dev/null 2>&1; then
            update-grub 2>/dev/null || warning "GRUB update failed"
        elif command -v grub-mkconfig >/dev/null 2>&1; then
            grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || warning "GRUB update failed"
        fi
    fi
    
    success "Rollback cleanup completed"
}

verify_rollback() {
    header "ROLLBACK VERIFICATION"
    
    info "Verifying system state after rollback..."
    
    VERIFICATION_ISSUES=0
    
    # Check ZFS functionality
    if lsmod | grep -q zfs; then
        success "ZFS module is loaded"
    else
        error "ZFS module not loaded after rollback"
        ((VERIFICATION_ISSUES++))
    fi
    
    # Check ZFS commands
    if command -v zpool >/dev/null 2>&1 && command -v zfs >/dev/null 2>&1; then
        success "ZFS commands available"
        
        # Check if we can list pools
        if [ "$POOLS_EXIST" = "true" ]; then
            if zpool list >/dev/null 2>&1; then
                success "ZFS pools are accessible"
                
                # Check pool health
                if zpool status | grep -E "(DEGRADED|FAULTED|OFFLINE|UNAVAIL)"; then
                    warning "Pool errors detected after rollback"
                    ((VERIFICATION_ISSUES++))
                else
                    success "All pools are healthy after rollback"
                fi
                
                # Verify dataset mounts
                MOUNT_ISSUES=$(zfs list -H -o name,canmount,mountpoint 2>/dev/null | awk '$2=="on" && $3!="none" && $3!="-"' | while IFS= read -r line; do
                    dataset=$(echo "$line" | awk '{print $1}')
                    mountpoint=$(echo "$line" | awk '{print $3}')
                    if [ -n "$mountpoint" ] && ! mountpoint -q "$mountpoint" 2>/dev/null; then
                        echo "unmounted:$dataset:$mountpoint"
                    fi
                done | wc -l)
                
                if [ "${MOUNT_ISSUES:-0}" -gt 0 ]; then
                    warning "$MOUNT_ISSUES datasets are not mounted"
                    ((VERIFICATION_ISSUES++))
                else
                    success "All datasets appear properly mounted"
                fi
            else
                error "ZFS pools not accessible after rollback"
                ((VERIFICATION_ISSUES++))
            fi
        fi
    else
        error "ZFS commands not available after rollback"
        ((VERIFICATION_ISSUES++))
    fi
    
    # Check initramfs
    CURRENT_KERNEL=$(uname -r)
    INITRAMFS_PATH="/boot/initramfs-${CURRENT_KERNEL}.img"
    if [ -f "$INITRAMFS_PATH" ]; then
        INITRAMFS_SIZE=$(stat -c%s "$INITRAMFS_PATH" 2>/dev/null || echo "0")
        if [ "$INITRAMFS_SIZE" -gt 1000000 ]; then
            success "Initramfs exists and appears valid"
        else
            warning "Initramfs exists but seems small (${INITRAMFS_SIZE} bytes)"
            ((VERIFICATION_ISSUES++))
        fi
    else
        error "Initramfs missing for current kernel: $INITRAMFS_PATH"
        ((VERIFICATION_ISSUES++))
    fi
    
    # Check ZFSBootMenu if applicable
    if [ "$ZFSBOOTMENU" = "true" ]; then
        if [ -n "$ZBM_EFI_PATH" ] && [ -f "$ZBM_EFI_PATH" ]; then
            ZBM_SIZE=$(stat -c%s "$ZBM_EFI_PATH" 2>/dev/null || echo "0")
            if [ "$ZBM_SIZE" -gt 1000000 ]; then
                success "ZFSBootMenu EFI image restored and appears valid"
            else
                warning "ZFSBootMenu EFI image seems too small (${ZBM_SIZE} bytes)"
                ((VERIFICATION_ISSUES++))
            fi
        else
            warning "ZFSBootMenu EFI image not found after rollback"
            ((VERIFICATION_ISSUES++))
        fi
    fi
    
    # Check DKMS if applicable
    if [ "${DKMS_AVAILABLE:-false}" = "true" ] && command -v dkms >/dev/null 2>&1; then
        DKMS_STATUS=$(dkms status zfs 2>/dev/null || echo "not found")
        if echo "$DKMS_STATUS" | grep -q "installed"; then
            success "DKMS ZFS module properly installed"
        else
            warning "DKMS ZFS module status: $DKMS_STATUS"
            ((VERIFICATION_ISSUES++))
        fi
    fi
    
    # Summary
    if [ $VERIFICATION_ISSUES -eq 0 ]; then
        success "All rollback verification checks passed"
    else
        warning "$VERIFICATION_ISSUES verification issues detected"
        warning "Manual intervention may be required"
    fi
    
    log "Rollback verification completed with $VERIFICATION_ISSUES issues"
}

main() {
    header "ZFS UPDATE ROLLBACK"
    
    log "Starting ZFS/kernel update rollback..."
    
    check_root
    load_config
    validate_backup_completeness
    detect_rollback_reason
    confirm_rollback
    
    backup_current_state
    
    # Rollback sequence
    attempt_package_rollback
    export_zfs_pools_for_rollback
    rollback_zfs_snapshots
    restore_configurations
    restore_zfsbootmenu
    rollback_dkms_modules
    rebuild_initramfs_for_rollback
    cleanup_rollback
    verify_rollback
    
    header "ROLLBACK COMPLETED"
    
    success "System rollback completed!"
    
    echo ""
    echo "Rollback Summary:"
    [ -n "${EFFECTIVE_SNAPSHOT_NAME:-}" ] && echo "• ZFS datasets rolled back to: ${EFFECTIVE_SNAPSHOT_NAME}"
    echo "• System configurations restored from backup"
    echo "• Dracut configuration restored: ${DRACUT_UPDATED:-false}"
    echo "• DKMS modules rebuilt: ${DKMS_AVAILABLE:-false}"
    if [ "$ZFSBOOTMENU" = "true" ]; then
        echo "• ZFSBootMenu configuration and ESP restored"
    fi
    echo "• Initramfs rebuilt"
    echo ""
    echo "Important Notes:"
    echo "• Package rollback in Void Linux requires manual intervention"
    echo "• ZFS snapshot rollback completed: $([ -n "${EFFECTIVE_SNAPSHOT_NAME:-}" ] && echo "Yes" || echo "No")"
    echo "• Monitor system stability after rollback"
    echo "• Consider running zfs-post-update-verify.sh to check system"
    echo ""
    echo "Files:"
    echo "• Rollback log: $LOG_FILE"
    echo "• Original backup: $BACKUP_DIR"
    echo "• Pre-rollback state: ${ROLLBACK_BACKUP_DIR:-N/A}"
    
    if [ "${VERIFICATION_ISSUES:-0}" -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}⚠ Some verification issues detected - check log for details${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}REBOOT STRONGLY RECOMMENDED${NC} to ensure clean state after rollback"
    
    log "Rollback procedure completed"
}

main "$@"
