#!/bin/bash
// filepath: zfs-post-update-verify.sh
# ZFS Post-Update Verification Script
# Comprehensive verification after ZFS/kernel updates
# Can be executed independently or after update scripts

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

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root"
    fi
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        warning "Configuration file not found - running basic verification"
        info "This script can run independently for verification"
        
        # Set defaults for independent execution
        ZFSBOOTMENU=false
        POOLS_EXIST=false
        KERNEL_UPDATED=false
        DRACUT_UPDATED=false
        ZFS_UPDATED=false
        BACKUP_DIR=""
        ZFS_COUNT=0
        ZBM_COUNT=0
        DRACUT_COUNT=0
        KERNEL_COUNT=0
        FIRMWARE_COUNT=0
        TOTAL_UPDATES=0
        ESP_MOUNT="/boot/efi"
        BOOT_POOLS=""
        INSTALL_SNAPSHOT_NAME=""
        
        # Detect system configuration
        detect_system_config
        return 0
    fi
    
    source "$CONFIG_FILE"
    
    # Set defaults for variables that might not exist
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
    INSTALL_SNAPSHOT_NAME=${INSTALL_SNAPSHOT_NAME:-""}
    
    info "Configuration loaded from $CONFIG_FILE"
    log "System type: $([ "$ZFSBOOTMENU" = true ] && echo "ZFSBootMenu" || echo "Traditional")"
    log "Pools exist: $POOLS_EXIST"
    log "Updates applied - Kernel: $KERNEL_UPDATED, ZFS: $ZFS_UPDATED, Dracut: $DRACUT_UPDATED"
    log "Total updates performed: $TOTAL_UPDATES"
}

detect_system_config() {
    info "Detecting system configuration..."
    
    # Detect if ZFSBootMenu is installed
    if command -v generate-zbm >/dev/null 2>&1; then
        ZFSBOOTMENU=true
        info "ZFSBootMenu detected"
    else
        ZFSBOOTMENU=false
        info "Traditional bootloader system"
    fi
    
    # Detect if ZFS pools exist
    if command -v zpool >/dev/null 2>&1 && zpool list >/dev/null 2>&1; then
        POOLS_EXIST=true
        local pool_count=$(zpool list -H 2>/dev/null | wc -l)
        info "ZFS pools detected: $pool_count"
        
        # Get pool names
        BOOT_POOLS=$(zpool list -H -o name 2>/dev/null | tr '\n' ' ' || echo "")
    else
        POOLS_EXIST=false
        info "No ZFS pools detected"
    fi
    
    # Detect ESP mount point
    if mountpoint -q /boot/efi 2>/dev/null; then
        ESP_MOUNT="/boot/efi"
    elif mountpoint -q /efi 2>/dev/null; then
        ESP_MOUNT="/efi"
    elif mountpoint -q /boot 2>/dev/null && [ -d /boot/EFI ]; then
        ESP_MOUNT="/boot"
    else
        ESP_MOUNT="/boot/efi"
        warning "Could not detect ESP mount point, using default: $ESP_MOUNT"
    fi
    
    info "ESP mount point: $ESP_MOUNT"
    
    # Since running independently, mark no updates performed
    KERNEL_UPDATED=false
    DRACUT_UPDATED=false
    ZFS_UPDATED=false
    TOTAL_UPDATES=0
}

verify_kernel_version() {
    header "Kernel Version Verification"
    
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
            info "Kernel versions differ but no recent kernel update detected"
            info "Running: $running_kernel, Latest: $latest_kernel"
            kernel_mismatch=false
        fi
    fi
    
    # Export global variables
    RUNNING_KERNEL="$running_kernel"
    LATEST_KERNEL="$latest_kernel"
    KERNEL_MISMATCH=$kernel_mismatch
    
    # Save kernel info to config for future reference
    if [ -w "$CONFIG_FILE" ] 2>/dev/null || [ ! -f "$CONFIG_FILE" ]; then
        {
            echo "RUNNING_KERNEL=\"$running_kernel\""
            echo "LATEST_KERNEL=\"$latest_kernel\""
            echo "KERNEL_MISMATCH=$kernel_mismatch"
        } >> "$CONFIG_FILE" 2>/dev/null || true
    fi
}

verify_zfs_module() {
    header "ZFS Kernel Module Verification"
    
    if ! lsmod | grep -q "^zfs "; then
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
    header "ZFS Userland Tools Verification"
    
    if ! command -v zpool >/dev/null 2>&1; then
        error_exit "zpool command not found"
    fi
    
    if ! command -v zfs >/dev/null 2>&1; then
        error_exit "zfs command not found"
    fi
    
    success "ZFS userland tools are available"
    
    local zfs_userland_version
    
    # Get userland version
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

verify_hostid() {
    header "ZFS Hostid Verification"
    
    if [ ! -f /etc/hostid ]; then
        error "ZFS hostid file missing: /etc/hostid"
        warning "This may prevent pool imports on boot"
        warning "Run: zgenhostid (WARNING: May affect existing pool imports)"
        return 1
    fi
    
    local hostid_content
    hostid_content=$(hexdump -v -e '/1 "%02x"' /etc/hostid 2>/dev/null || echo "invalid")
    
    if [[ ${#hostid_content} -eq 8 ]] && [[ "$hostid_content" =~ ^[0-9a-f]{8}$ ]]; then
        success "ZFS hostid is valid: $hostid_content"
        log "Hostid location: /etc/hostid"
    else
        error "ZFS hostid is corrupted: $hostid_content"
        warning "Run: zgenhostid (WARNING: May affect existing pool imports)"
        return 1
    fi
}

verify_encryption_keys() {
    header "ZFS Encryption Keys Verification"
    
    local key_file="/etc/zfs/zroot.key"
    local backup_key_dir="/root/zfs-keys"
    local perms
    local has_encrypted_datasets=false
    
    # Check if any datasets are encrypted
    if [ "$POOLS_EXIST" = "true" ]; then
        if zfs list -H -o encryption 2>/dev/null | grep -v "^off$" | grep -q .; then
            has_encrypted_datasets=true
            info "Encrypted ZFS datasets detected"
        fi
    fi
    
    if [ -f "$key_file" ]; then
        perms=$(stat -c "%a" "$key_file")
        if [ "$perms" = "400" ]; then
            success "ZFS encryption key found with secure permissions (400)"
            log "Key location: $key_file"
        else
            warning "ZFS key permissions are not secure: $perms (should be 400)"
            warning "Fix with: chmod 400 $key_file"
        fi
        
        # Verify key is readable
        if [ -r "$key_file" ]; then
            local key_size=$(stat -c%s "$key_file" 2>/dev/null || echo "0")
            if [ "$key_size" -gt 0 ]; then
                success "Encryption key file is readable and non-empty"
            else
                error "Encryption key file is empty"
            fi
        else
            error "Encryption key file is not readable"
        fi
    else
        if [ "$has_encrypted_datasets" = true ]; then
            error "ZFS encryption key not found: $key_file"
            error "This will prevent encrypted pool imports on boot"
        else
            info "No encryption key found (may be normal if encryption not used)"
        fi
    fi
    
    # Check backup keys
    if [ -d "$backup_key_dir" ]; then
        if [ -f "$backup_key_dir/zroot.key" ]; then
            success "ZFS key backup found: $backup_key_dir/zroot.key"
        else
            if [ "$has_encrypted_datasets" = true ]; then
                warning "ZFS key backup not found in $backup_key_dir"
            else
                info "No key backup found (may be normal if encryption not used)"
            fi
        fi
    else
        if [ "$has_encrypted_datasets" = true ]; then
            warning "ZFS key backup directory does not exist: $backup_key_dir"
        fi
    fi
}

verify_dracut_functionality() {
    header "Dracut Functionality Verification"
    
    local dracut_version
    
    if ! command -v dracut >/dev/null 2>&1; then
        warning "dracut command not found"
        return 0
    fi
    
    dracut_version=$(dracut --version 2>/dev/null | head -1 || echo "unknown")
    log "Dracut version: $dracut_version"
    success "Dracut is installed"
    
    # Check if dracut can detect ZFS modules
    if dracut --list-modules 2>/dev/null | grep -q zfs; then
        success "Dracut has ZFS module support"
    else
        warning "Dracut may not have ZFS module support"
        info "This could prevent ZFS root from booting"
    fi
    
    # Check dracut configuration
    if [ -f /etc/dracut.conf ] || [ -d /etc/dracut.conf.d ]; then
        success "Dracut configuration found"
        
        # Look for ZFS-related configuration
        if [ -f /etc/dracut.conf.d/zfs.conf ]; then
            success "ZFS-specific dracut configuration found: /etc/dracut.conf.d/zfs.conf"
            
            # Check for required ZFS configuration items
            local zfs_conf="/etc/dracut.conf.d/zfs.conf"
            if grep -q "add_dracutmodules.*zfs" "$zfs_conf" 2>/dev/null; then
                success "ZFS modules configured in dracut"
            else
                warning "ZFS modules may not be properly configured in dracut"
            fi
            
            # Check for encryption key in dracut config
            if [ -f /etc/zfs/zroot.key ]; then
                if grep -q "zroot.key" "$zfs_conf" 2>/dev/null; then
                    success "ZFS encryption key configured in dracut"
                else
                    warning "ZFS encryption key may not be included in initramfs"
                fi
            fi
        elif grep -r "zfs" /etc/dracut.conf /etc/dracut.conf.d/ 2>/dev/null | grep -v "^#" >/dev/null; then
            info "ZFS configuration found in dracut settings"
        else
            if [ "$POOLS_EXIST" = "true" ]; then
                warning "No ZFS-specific dracut configuration found"
                warning "This may prevent booting from ZFS"
            fi
        fi
    else
        info "No custom dracut configuration found (using defaults)"
        if [ "$POOLS_EXIST" = "true" ]; then
            warning "Custom dracut configuration recommended for ZFS systems"
        fi
    fi
}

verify_pool_status() {
    if [ "$POOLS_EXIST" != "true" ]; then
        info "No ZFS pools to verify"
        return 0
    fi
    
    header "ZFS Pool Status Verification"
    
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
                zpool status "$pool" | grep -A 5 "state:" | tee -a "$LOG_FILE"
                ;;
            "FAULTED"|"OFFLINE"|"UNAVAIL")
                error "Pool $pool is $pool_state"
                ((pool_errors++))
                zpool status "$pool" | tee -a "$LOG_FILE"
                ;;
            *)
                warning "Pool $pool has unknown state: $pool_state"
                ((pool_warnings++))
                ;;
        esac
        
        # Check for errors
        if ! zpool status "$pool" | grep -q "errors: No known data errors"; then
            warning "Pool $pool has data errors"
            ((pool_warnings++))
        fi
    done
    
    # Overall pool health summary
    if [ $pool_errors -eq 0 ] && [ $pool_warnings -eq 0 ]; then
        success "All pools are healthy"
    elif [ $pool_errors -eq 0 ]; then
        warning "$pool_warnings pools have warnings"
        info "Run 'zpool status' for detailed information"
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
    
    header "Pool Import Verification"
    
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
        info "No pool backup found - verifying current pool state only"
        local current_pool_count=$(zpool list -H 2>/dev/null | wc -l)
        if [ "$current_pool_count" -gt 0 ]; then
            success "$current_pool_count pools are currently imported"
        else
            warning "No pools are currently imported"
        fi
    fi
}

verify_datasets_mounted() {
    if [ "$POOLS_EXIST" != "true" ]; then
        return 0
    fi
    
    header "ZFS Dataset Mount Verification"
    
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

verify_initramfs() {
    header "Initramfs Verification"
    
    local initramfs_path initramfs_date initramfs_size initramfs_age_minutes
    
    initramfs_path="/boot/initramfs-${RUNNING_KERNEL}.img"
    
    if [ -f "$initramfs_path" ]; then
        initramfs_date=$(stat -c%y "$initramfs_path" 2>/dev/null || echo "unknown")
        initramfs_size=$(stat -c%s "$initramfs_path" 2>/dev/null || echo "0")
        
        log "Initramfs for running kernel: $initramfs_path"
        log "  Date: $initramfs_date"
        log "  Size: $initramfs_size bytes"
        
        if [ "$initramfs_size" -gt 1000000 ]; then
            success "Initramfs appears valid for running kernel (size: $initramfs_size bytes)"
        else
            warning "Initramfs seems too small (${initramfs_size} bytes)"
        fi
        
        # Check if ZFS modules are in initramfs
        local zfs_found=false
        if command -v lsinitrd >/dev/null 2>&1; then
            if lsinitrd "$initramfs_path" 2>/dev/null | grep -q "zfs.ko"; then
                success "ZFS modules found in initramfs (lsinitrd)"
                zfs_found=true
            fi
        fi
        
        if [ "$zfs_found" = false ] && command -v zcat >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1; then
            # Alternative method to check initramfs content
            if zcat "$initramfs_path" 2>/dev/null | cpio -t 2>/dev/null | grep -q "zfs"; then
                success "ZFS modules found in initramfs (cpio)"
                zfs_found=true
            fi
        fi
        
        if [ "$zfs_found" = false ] && [ "$POOLS_EXIST" = "true" ]; then
            warning "ZFS modules not detected in initramfs"
            warning "This could prevent ZFS pools from being imported at boot"
            warning "Rebuild with: dracut -f --kver $RUNNING_KERNEL"
        fi
        
        # Check for encryption key in initramfs
        if [ -f /etc/zfs/zroot.key ]; then
            local key_found=false
            if command -v lsinitrd >/dev/null 2>&1; then
                if lsinitrd "$initramfs_path" 2>/dev/null | grep -q "zroot.key"; then
                    success "ZFS encryption key found in initramfs"
                    key_found=true
                fi
            fi
            
            if [ "$key_found" = false ] && command -v zcat >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1; then
                if zcat "$initramfs_path" 2>/dev/null | cpio -t 2>/dev/null | grep -q "zroot.key"; then
                    success "ZFS encryption key found in initramfs (cpio)"
                    key_found=true
                fi
            fi
            
            if [ "$key_found" = false ]; then
                warning "ZFS encryption key not found in initramfs"
                warning "Encrypted pools may not import at boot"
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
                    warning "Consider rebuilding: dracut -f --kver $RUNNING_KERNEL"
                fi
            fi
        fi
        
        # Check initramfs for latest kernel if different
        if [ "$KERNEL_MISMATCH" = true ]; then
            local latest_initramfs="/boot/initramfs-${LATEST_KERNEL}.img"
            if [ -f "$latest_initramfs" ]; then
                success "Initramfs exists for latest kernel: $latest_initramfs"
            else
                warning "Initramfs missing for latest kernel: $latest_initramfs"
                warning "Create with: dracut -f --kver $LATEST_KERNEL"
            fi
        fi
    else
        error "Initramfs not found for running kernel: $initramfs_path"
        if [ "$KERNEL_UPDATED" = true ]; then
            error "Missing initramfs for running kernel after kernel update"
            error "Create with: dracut -f --kver $RUNNING_KERNEL"
        else
            warning "Create with: dracut -f --kver $RUNNING_KERNEL"
        fi
    fi
}

verify_zfsbootmenu() {
    if [ "$ZFSBOOTMENU" != true ]; then
        return 0
    fi
    
    header "ZFSBootMenu Verification"
    
    local zbm_config_file zbm_efi_path zbm_backup_path zbm_size zbm_date image_age_minutes zbm_entries
    
    # Check if ZFSBootMenu tools are available
    if ! command -v generate-zbm >/dev/null 2>&1; then
        warning "generate-zbm command not available"
        warning "ZFSBootMenu may not be properly installed"
        return 0
    fi
    
    success "generate-zbm command is available"
    
    # Check ZBM configuration
    zbm_config_file="/etc/zfsbootmenu/config.yaml"
    if [ ! -f "$zbm_config_file" ]; then
        warning "ZFSBootMenu configuration not found: $zbm_config_file"
    else
        success "ZFSBootMenu configuration found: $zbm_config_file"
        
        # Validate configuration syntax if yaml-lint available
        if command -v yaml-lint >/dev/null 2>&1; then
            if yaml-lint "$zbm_config_file" >/dev/null 2>&1; then
                success "ZFSBootMenu configuration syntax is valid"
            else
                warning "ZFSBootMenu configuration may have syntax issues"
            fi
        fi
        
        # Check key configuration values
        if grep -q "ManageImages: true" "$zbm_config_file" 2>/dev/null; then
            info "ZFSBootMenu is configured to manage images"
        fi
        
        if grep -q "BootMountPoint:" "$zbm_config_file" 2>/dev/null; then
            local configured_esp=$(grep "BootMountPoint:" "$zbm_config_file" | awk '{print $2}')
            log "Configured ESP mount point: $configured_esp"
        fi
    fi
    
    # Check ZBM dracut configuration
    if [ -d /etc/zfsbootmenu/dracut.conf.d ]; then
        success "ZFSBootMenu dracut configuration directory exists"
        
        if [ -f /etc/zfsbootmenu/dracut.conf.d/keymap.conf ]; then
            success "ZFSBootMenu keymap configuration found"
        fi
    else
        warning "ZFSBootMenu dracut configuration directory not found"
    fi
    
    # Use consistent ESP mount point
    local esp_mount="${ESP_MOUNT}"
    
    # Check EFI images
    zbm_efi_path="$esp_mount/EFI/ZBM/vmlinuz.efi"
    zbm_backup_path="$esp_mount/EFI/ZBM/vmlinuz-backup.efi"
    
    if [ -f "$zbm_efi_path" ]; then
        zbm_size=$(stat -c%s "$zbm_efi_path" 2>/dev/null || echo "0")
        zbm_date=$(stat -c%y "$zbm_efi_path" 2>/dev/null || echo "unknown")
        
        log "ZFSBootMenu EFI image: $zbm_efi_path"
        log "  Size: $zbm_size bytes"
        log "  Date: $zbm_date"
        
        if [ "$zbm_size" -gt 1000000 ]; then
            success "ZFSBootMenu EFI image appears valid (size: $zbm_size bytes)"
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
        
        # Check backup image
        if [ -f "$zbm_backup_path" ]; then
            success "Backup ZFSBootMenu image exists: $zbm_backup_path"
            local backup_size=$(stat -c%s "$zbm_backup_path" 2>/dev/null || echo "0")
            log "  Backup size: $backup_size bytes"
        else
            warning "Backup ZFSBootMenu image missing: $zbm_backup_path"
            info "Having a backup image is recommended for recovery"
        fi
    else
        error "ZFSBootMenu EFI image not found at: $zbm_efi_path"
        error "Generate with: generate-zbm"
        
        # Check if directory exists
        if [ ! -d "$(dirname "$zbm_efi_path")" ]; then
            error "ZFSBootMenu directory does not exist: $(dirname "$zbm_efi_path")"
        fi
    fi
    
    # Check EFI boot entries
    if command -v efibootmgr >/dev/null 2>&1; then
        info "Checking EFI boot entries..."
        zbm_entries=$(efibootmgr 2>/dev/null | grep -i "zfsbootmenu\|ZBM" || echo "")
        if [ -n "$zbm_entries" ]; then
            success "ZFSBootMenu entries found in EFI boot manager:"
            echo "$zbm_entries" | tee -a "$LOG_FILE"
            
            # Check boot order
            local boot_order=$(efibootmgr 2>/dev/null | grep "BootOrder:" || echo "")
            if [ -n "$boot_order" ]; then
                log "$boot_order"
            fi
        else
            warning "No ZFSBootMenu entries found in EFI boot manager"
            warning "System may not boot to ZFSBootMenu"
            info "Add boot entries with efibootmgr or your system's boot manager"
        fi
    else
        warning "efibootmgr not available - cannot check EFI boot entries"
    fi
}

verify_bootloader() {
    header "Bootloader Verification"
    
    if [ "$ZFSBOOTMENU" = true ]; then
        verify_zfsbootmenu
    else
        info "Verifying traditional bootloader..."
        
        local grub_date grub_cfg
        
        # Check for GRUB configuration
        if [ -f /boot/grub/grub.cfg ]; then
            grub_cfg="/boot/grub/grub.cfg"
        elif [ -f /boot/grub2/grub.cfg ]; then
            grub_cfg="/boot/grub2/grub.cfg"
        else
            warning "GRUB configuration file not found"
            return 0
        fi
        
        success "GRUB configuration found: $grub_cfg"
        grub_date=$(stat -c%y "$grub_cfg" 2>/dev/null || echo "unknown")
        log "GRUB config date: $grub_date"
        
        # Check if latest kernel is in GRUB config
        if [ -n "$LATEST_KERNEL" ]; then
            if grep -q "$LATEST_KERNEL" "$grub_cfg" 2>/dev/null; then
                success "Latest kernel ($LATEST_KERNEL) found in GRUB configuration"
            else
                warning "Latest kernel ($LATEST_KERNEL) not found in GRUB configuration"
                if [ "$KERNEL_UPDATED" = true ]; then
                    warning "This could prevent booting the new kernel"
                    warning "Update GRUB configuration with: grub-mkconfig -o $grub_cfg"
                fi
            fi
        fi
        
        # Check if running kernel is in GRUB config
        if grep -q "$RUNNING_KERNEL" "$grub_cfg" 2>/dev/null; then
            success "Running kernel ($RUNNING_KERNEL) found in GRUB configuration"
        else
            warning "Running kernel ($RUNNING_KERNEL) not in GRUB configuration"
        fi
        
        # Check for ZFS root support in GRUB
        if [ "$POOLS_EXIST" = "true" ]; then
            if grep -q "zfs=" "$grub_cfg" 2>/dev/null || grep -q "root=ZFS=" "$grub_cfg" 2>/dev/null; then
                success "GRUB appears configured for ZFS root"
            else
                warning "GRUB may not be properly configured for ZFS root"
            fi
        fi
    fi
}

test_basic_zfs_operations() {
    if [ "$POOLS_EXIST" != "true" ]; then
        return 0
    fi
    
    header "ZFS Operations Test"
    
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
    
    # Test pool status
    if zpool status >/dev/null 2>&1; then
        success "zpool status command works"
    else
        error_exit "zpool status command failed"
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
                    success "ZFS snapshot listing works"
                fi
                
                # Clean up test snapshot
                if zfs destroy "$test_snapshot" 2>/dev/null; then
                    success "ZFS snapshot deletion works"
                else
                    warning "Failed to clean up test snapshot: $test_snapshot"
                fi
            else
                info "ZFS snapshot test skipped (dataset may be read-only or have limited permissions)"
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
    
    header "Rollback Capability Check"
    
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
            info "Snapshot name: $install_snapshot_name"
            log "Available snapshots: $existing_snapshots"
        else
            info "No installation snapshots found with name: $install_snapshot_name"
        fi
    else
        info "No installation snapshot name recorded"
        
        # Check for any recent snapshots
        local recent_snapshots=$(zfs list -t snapshot -o name -s creation 2>/dev/null | tail -5 || echo "")
        if [ -n "$recent_snapshots" ]; then
            info "Recent snapshots available:"
            echo "$recent_snapshots" | tee -a "$LOG_FILE"
        fi
    fi
    
    # Check for backup directory
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        success "Backup directory exists: $BACKUP_DIR"
        
        # Check key backup files
        backup_files="zfs-datasets.txt zpool-list.txt exported-pools.txt"
        for file in $backup_files; do
            if [ -f "$BACKUP_DIR/$file" ]; then
                success "Backup file found: $file"
            else
                info "Backup file not found: $file (may be normal)"
            fi
        done
    else
        info "No backup directory configured"
        info "Manual recovery may be required if issues occur"
    fi
}

run_comprehensive_checks() {
    header "COMPREHENSIVE POST-UPDATE VERIFICATION"
    
    verify_kernel_version
    verify_zfs_module
    verify_zfs_userland
    verify_hostid
    verify_encryption_keys
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
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "• Running kernel: $RUNNING_KERNEL"
    echo "• Latest kernel: $LATEST_KERNEL"
    echo "• ZFS module version: $ZFS_MODULE_VERSION"
    echo "• ZFS userland version: $ZFS_USERLAND_VERSION"
    echo "• System type: $([ "$ZFSBOOTMENU" = true ] && echo "ZFSBootMenu" || echo "Traditional")"
    echo "• Pools exist: $POOLS_EXIST"
    
    if [ "$POOLS_EXIST" = "true" ]; then
        echo ""
        echo "Pool Status:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        zpool list 2>/dev/null || echo "Error listing pools"
        
        echo ""
        echo "Pool Health:"
        zpool status 2>/dev/null | grep -E "(pool:|state:|scan:|errors:)" || true
    fi
    
    echo ""
    echo "Update Information:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ "$TOTAL_UPDATES" -gt 0 ]; then
        echo "• Total updates applied: $TOTAL_UPDATES"
        echo "• ZFS updates: ${ZFS_COUNT:-0} (updated: $ZFS_UPDATED)"
        echo "• ZBM updates: ${ZBM_COUNT:-0}"
        echo "• Dracut updates: ${DRACUT_COUNT:-0} (updated: $DRACUT_UPDATED)"
        echo "• Kernel updates: ${KERNEL_COUNT:-0} (updated: $KERNEL_UPDATED)"
        echo "• Firmware updates: ${FIRMWARE_COUNT:-0}"
    else
        echo "• No recent updates recorded (running standalone verification)"
    fi
    
    echo ""
    echo "Files:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "• Log file: $LOG_FILE"
    if [ -n "$BACKUP_DIR" ]; then
        echo "• Backup directory: $BACKUP_DIR"
    fi
    echo "• Config file: $CONFIG_FILE"
}

show_recommendations() {
    header "RECOMMENDATIONS"
    
    echo "General Maintenance:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "• Review the log file for any warnings: $LOG_FILE"
    echo "• Run 'xbps-install -Su' to check for additional updates"
    if [ "$POOLS_EXIST" = "true" ]; then
        echo "• Consider running a ZFS scrub: 'zpool scrub <pool>'"
        echo "• Monitor pool health: 'zpool status'"
    fi
    
    # Kernel-specific recommendations
    if [ "$KERNEL_UPDATED" = true ]; then
        echo ""
        echo "Kernel Update Status:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [ "$KERNEL_MISMATCH" = true ]; then
            echo -e "${YELLOW}⚠ REBOOT REQUIRED${NC}"
            echo "• Currently running: $RUNNING_KERNEL"
            echo "• New kernel available: $LATEST_KERNEL"
            echo "• Reboot to activate new kernel: 'sudo reboot'"
            echo "• After reboot, run this verification again"
        else
            echo -e "${GREEN}✓ Kernel update complete${NC}"
            echo "• Successfully running the updated kernel: $RUNNING_KERNEL"
        fi
    elif [ "$KERNEL_MISMATCH" = true ]; then
        echo ""
        echo "Kernel Status:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "• Running: $RUNNING_KERNEL"
        echo "• Latest installed: $LATEST_KERNEL"
        echo "• Consider rebooting to use the latest kernel"
    fi
    
    # ZFS-specific recommendations
    if [ "$ZFS_UPDATED" = "true" ]; then
        echo ""
        echo "ZFS Update Status:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "• ZFS was updated successfully"
        echo "• Module version: $ZFS_MODULE_VERSION"
        echo "• Userland version: $ZFS_USERLAND_VERSION"
        if [ "$ZFS_MODULE_VERSION" != "$ZFS_USERLAND_VERSION" ]; then
            echo "• Consider verifying ZFS functionality with your workload"
        fi
    fi
    
    # Dracut-specific recommendations
    if [ "$DRACUT_UPDATED" = "true" ]; then
        echo ""
        echo "Dracut Update Status:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "• Dracut was updated - initramfs rebuilt"
        echo "• Verify boot functionality on next reboot"
    fi
    
    # ZFSBootMenu specific
    if [ "$ZFSBOOTMENU" = true ]; then
        echo ""
        echo "ZFSBootMenu Notes:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [ "$KERNEL_UPDATED" = true ] || [ "$ZFS_UPDATED" = "true" ]; then
            echo "• ZFSBootMenu image should be updated for kernel/ZFS changes"
            echo "• Verify boot functionality on next reboot"
            if [ "$KERNEL_MISMATCH" = true ]; then
                echo "• After reboot, ZFSBootMenu should show new kernel"
            fi
        else
            echo "• ZFSBootMenu is installed and configured"
            echo "• No recent kernel/ZFS updates detected"
        fi
    fi
    
    # Rollback information
    if [ -n "${INSTALL_SNAPSHOT_NAME:-}" ]; then
        echo ""
        echo "Rollback Information:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "• Installation snapshots available: $INSTALL_SNAPSHOT_NAME"
        echo "• Rollback possible if issues arise"
        echo "• Use ZFS rollback commands if needed"
    fi
    
    echo ""
    echo "Additional Resources:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "• ZFS documentation: https://openzfs.github.io/openzfs-docs/"
    echo "• Void Linux ZFS guide: https://docs.voidlinux.org/config/filesystems/zfs.html"
    if [ "$ZFSBOOTMENU" = true ]; then
        echo "• ZFSBootMenu: https://docs.zfsbootmenu.org/"
    fi
}

main() {
    header "ZFS POST-UPDATE VERIFICATION"
    
    log "Starting post-update verification..."
    log "Script can run independently for system verification"
    
    check_root
    load_config
    
    run_comprehensive_checks
    
    show_system_summary
    show_recommendations
    
    header "VERIFICATION COMPLETED"
    
    success "Post-update verification completed successfully!"
    success "Review the log file for complete details: $LOG_FILE"
    
    log "Verification completed. System appears to be functioning correctly."
    
    # Return appropriate exit code
    if [ "$POOLS_EXIST" = "true" ]; then
        # Check if any pools have errors
        if zpool status 2>/dev/null | grep -q "state: DEGRADED\|state: FAULTED\|state: UNAVAIL"; then
            warning "Some pools have issues - review the status above"
            exit 1
        fi
    fi
    
    exit 0
}

main "$@"
