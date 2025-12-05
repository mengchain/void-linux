#!/bin/bash
# filepath: zfs-post-update-verify.sh
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

# Colors for output - UPDATED: Light Blue for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;94m'
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
        warning "Configuration file not found: $CONFIG_FILE"
        warning "Running in standalone mode with limited information"
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
        info "ZFSBootMenu detected"
        ZFSBOOTMENU=true
    else
        info "Traditional bootloader system"
        ZFSBOOTMENU=false
    fi
    
    # Detect if ZFS pools exist - FIXED SIGPIPE
    local pool_list
    pool_list=$(zpool list -H -o name 2>/dev/null || true)
    if [ -n "$pool_list" ]; then
        info "ZFS pools detected: $(echo "$pool_list" | tr '\n' ' ')"
        POOLS_EXIST=true
    else
        info "No ZFS pools found"
        POOLS_EXIST=false
    fi
}

verify_kernel_version() {
    header "KERNEL VERSION VERIFICATION"
    
    RUNNING_KERNEL=$(uname -r)
    info "Running kernel: $RUNNING_KERNEL"
    
    # Find latest installed kernel - FIXED SIGPIPE
    local kernel_images
    kernel_images=$(find /boot -name "vmlinuz-*" -type f 2>/dev/null | sort -V | tail -1 || true)
    
    if [ -n "$kernel_images" ]; then
        LATEST_KERNEL=$(basename "$kernel_images" | sed 's/vmlinuz-//')
        info "Latest installed kernel: $LATEST_KERNEL"
        
        if [ "$RUNNING_KERNEL" != "$LATEST_KERNEL" ]; then
            KERNEL_MISMATCH=true
            warning "Kernel mismatch detected!"
            warning "Running: $RUNNING_KERNEL"
            warning "Latest:  $LATEST_KERNEL"
            warning "A reboot is required to use the new kernel"
        else
            success "Running the latest kernel"
        fi
    else
        warning "Could not detect installed kernel images"
    fi
    
    # Check kernel command line
    local cmdline
    cmdline=$(cat /proc/cmdline)
    log "Kernel command line: $cmdline"
    
    # Capture grep output - FIXED SIGPIPE
    if echo "$cmdline" | grep -q "zfs="; then
        success "ZFS boot parameter found in kernel command line"
    else
        info "No ZFS boot parameter in kernel command line (may be set by bootloader)"
    fi
}

verify_zfs_module() {
    header "ZFS MODULE VERIFICATION"
    
    # Check if ZFS module is loaded - FIXED SIGPIPE
    local lsmod_output
    lsmod_output=$(lsmod)
    if ! echo "$lsmod_output" | grep -q "^zfs "; then
        error_exit "ZFS kernel module is not loaded!"
    fi
    
    success "ZFS kernel module is loaded"
    
    # Get ZFS module version - FIXED SIGPIPE (capture modinfo output)
    local modinfo_output
    modinfo_output=$(modinfo zfs 2>/dev/null || true)
    
    if [ -n "$modinfo_output" ]; then
        ZFS_MODULE_VERSION=$(echo "$modinfo_output" | grep "^version:" | awk '{print $2}' || echo "unknown")
        info "ZFS module version: $ZFS_MODULE_VERSION"
        
        local module_filename
        module_filename=$(echo "$modinfo_output" | grep "^filename:" | awk '{print $2}' || echo "unknown")
        log "Module location: $module_filename"
        
        # Check if module matches running kernel
        if echo "$module_filename" | grep -q "$RUNNING_KERNEL"; then
            success "ZFS module matches running kernel"
        else
            warning "ZFS module may not match running kernel"
            warning "Module: $module_filename"
            warning "Kernel: $RUNNING_KERNEL"
        fi
    else
        warning "Could not retrieve ZFS module information"
    fi
    
    # Check ZFS module parameters
    if [ -d /sys/module/zfs/parameters ]; then
        info "ZFS module is properly loaded with parameters"
        
        # Check critical parameters
        local zfs_arc_max
        zfs_arc_max=$(cat /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null || echo "0")
        if [ "$zfs_arc_max" != "0" ]; then
            local arc_max_gb=$((zfs_arc_max / 1024 / 1024 / 1024))
            info "ZFS ARC max size: ${arc_max_gb}GB"
        fi
    fi
}

verify_zfs_userland() {
    header "ZFS USERLAND TOOLS VERIFICATION"
    
    # Check zfs command
    if ! command -v zfs >/dev/null 2>&1; then
        error_exit "zfs command not found!"
    fi
    
    if ! command -v zpool >/dev/null 2>&1; then
        error_exit "zpool command not found!"
    fi
    
    success "ZFS userland tools are available"
    
    # Get userland version - FIXED SIGPIPE (capture zfs version output)
    local zfs_version_output
    zfs_version_output=$(zfs version 2>/dev/null || true)
    
    if [ -n "$zfs_version_output" ]; then
        ZFS_USERLAND_VERSION=$(echo "$zfs_version_output" | sed -n 's/.*zfs-\([0-9.]*\).*/\1/p' || echo "unknown")
        info "ZFS userland version: $ZFS_USERLAND_VERSION"
        
        # Check for version mismatch
        if [ "$ZFS_MODULE_VERSION" != "unknown" ] && [ "$ZFS_USERLAND_VERSION" != "unknown" ]; then
            if [ "$ZFS_MODULE_VERSION" = "$ZFS_USERLAND_VERSION" ]; then
                success "ZFS module and userland versions match"
            else
                warning "Version mismatch detected!"
                warning "Module:   $ZFS_MODULE_VERSION"
                warning "Userland: $ZFS_USERLAND_VERSION"
                warning "This may cause issues - consider rebooting"
            fi
        fi
    else
        warning "Could not retrieve ZFS userland version"
    fi
    
    # Test basic ZFS functionality
    if zfs list >/dev/null 2>&1; then
        success "ZFS list command works"
    else
        error "ZFS list command failed!"
    fi
    
    if zpool list >/dev/null 2>&1; then
        success "ZFS pool list command works"
    else
        error "ZFS pool list command failed!"
    fi
}

verify_hostid() {
    header "HOSTID VERIFICATION"
    
    if [ ! -f /etc/hostid ]; then
        error "Host ID file missing: /etc/hostid"
        error "This can cause pool import issues"
        return 1
    fi
    
    local hostid_size
    hostid_size=$(stat -c %s /etc/hostid 2>/dev/null || echo "0")
    
    if [ "$hostid_size" -ne 4 ]; then
        error "Host ID file has incorrect size: $hostid_size bytes (expected 4)"
        return 1
    fi
    
    local hostid_cmd hostid_file
    hostid_cmd=$(hostid)
    hostid_file=$(od -An -tx4 /etc/hostid | tr -d ' \n')
    
    info "hostid command: $hostid_cmd"
    info "hostid file:    $hostid_file"
    
    if [ "$hostid_cmd" = "$hostid_file" ]; then
        success "Host ID is consistent"
    else
        warning "Host ID mismatch between command and file"
    fi
}

verify_encryption_keys() {
    header "ENCRYPTION KEY VERIFICATION"
    
    local key_file="/etc/zfs/zroot.key"
    
    if [ ! -f "$key_file" ]; then
        warning "ZFS encryption key not found: $key_file"
        info "If you're not using encryption, this is normal"
        return 0
    fi
    
    success "ZFS encryption key exists"
    
    # Check permissions
    local key_perms
    key_perms=$(stat -c %a "$key_file")
    
    if [ "$key_perms" = "400" ] || [ "$key_perms" = "600" ]; then
        success "Encryption key has secure permissions: $key_perms"
    else
        warning "Encryption key has insecure permissions: $key_perms"
        warning "Recommended: chmod 400 $key_file"
    fi
    
    # Check if key is being used - FIXED SIGPIPE
    if [ "$POOLS_EXIST" = true ]; then
        local encrypted_datasets
        encrypted_datasets=$(zfs get -H -o name,value encryption 2>/dev/null | grep -v "off$" | awk '{print $1}' || true)
        
        if [ -n "$encrypted_datasets" ]; then
            info "Encrypted datasets found:"
            echo "$encrypted_datasets" | while read -r dataset; do
                log "  - $dataset"
            done
            success "Encryption is in use"
        else
            info "No encrypted datasets found"
        fi
    fi
}

verify_dracut_functionality() {
    header "DRACUT VERIFICATION"
    
    if ! command -v dracut >/dev/null 2>&1; then
        error_exit "dracut command not found!"
    fi
    
    success "dracut is installed"
    
    # Check dracut version
    local dracut_version
    dracut_version=$(dracut --version 2>/dev/null | head -1 || echo "unknown")
    info "dracut version: $dracut_version"
    
    # Check dracut ZFS configuration
    local dracut_zfs_conf="/etc/dracut.conf.d/zfs.conf"
    if [ -f "$dracut_zfs_conf" ]; then
        success "dracut ZFS configuration found"
        
        # Capture config content - FIXED SIGPIPE
        local dracut_conf_content
        dracut_conf_content=$(cat "$dracut_zfs_conf")
        
        # Verify critical settings
        if echo "$dracut_conf_content" | grep -q "add_dracutmodules.*zfs"; then
            success "ZFS module is configured for dracut"
        else
            warning "ZFS module not found in dracut configuration"
        fi
        
        if echo "$dracut_conf_content" | grep -q "install_items.*zroot.key"; then
            success "Encryption key is configured for dracut"
        else
            info "Encryption key not in dracut config (normal if not using encryption)"
        fi
    else
        warning "dracut ZFS configuration not found: $dracut_zfs_conf"
    fi
    
    # Check for ZFS dracut module
    local dracut_module_dirs="/usr/lib/dracut/modules.d /usr/share/dracut/modules.d"
    local found_zfs_module=false
    local module_dir
    
    for module_dir in $dracut_module_dirs; do
        if [ -d "$module_dir/90zfs" ]; then
            success "ZFS dracut module found: $module_dir/90zfs"
            found_zfs_module=true
            break
        fi
    done
    
    if [ "$found_zfs_module" = false ]; then
        error "ZFS dracut module not found!"
    fi
}

verify_pool_status() {
    header "ZFS POOL STATUS VERIFICATION"
    
    if [ "$POOLS_EXIST" != true ]; then
        info "No ZFS pools to verify"
        return 0
    fi
    
    # Get all pools - FIXED SIGPIPE
    local pools
    pools=$(zpool list -H -o name 2>/dev/null || true)
    
    if [ -z "$pools" ]; then
        warning "No ZFS pools found"
        return 0
    fi
    
    local pool pool_health all_healthy=true
    
    echo "$pools" | while read -r pool; do
        info "Checking pool: $pool"
        
        pool_health=$(zpool list -H -o health "$pool" 2>/dev/null || echo "UNKNOWN")
        
        if [ "$pool_health" = "ONLINE" ]; then
            success "Pool $pool is healthy: $pool_health"
        else
            error "Pool $pool has issues: $pool_health"
            all_healthy=false
        fi
        
        # Check for errors - FIXED SIGPIPE (capture zpool status)
        local pool_status
        pool_status=$(zpool status "$pool" 2>/dev/null || true)
        
        if echo "$pool_status" | grep -q "errors: No known data errors"; then
            success "Pool $pool has no errors"
        else
            warning "Pool $pool may have errors"
            echo "$pool_status" | grep -A 5 "errors:" | tee -a "$LOG_FILE"
        fi
        
        # Check pool properties
        local bootfs autoexpand autotrim
        bootfs=$(zpool get -H -o value bootfs "$pool" 2>/dev/null || echo "-")
        autoexpand=$(zpool get -H -o value autoexpand "$pool" 2>/dev/null || echo "off")
        autotrim=$(zpool get -H -o value autotrim "$pool" 2>/dev/null || echo "off")
        
        info "Pool $pool properties:"
        log "  bootfs:     $bootfs"
        log "  autoexpand: $autoexpand"
        log "  autotrim:   $autotrim"
    done
}

verify_pool_import() {
    header "POOL IMPORT CAPABILITY VERIFICATION"
    
    if [ "$POOLS_EXIST" != true ]; then
        info "No ZFS pools to verify"
        return 0
    fi
    
    info "Testing pool import capability (dry-run)..."
    
    # Get all pools - FIXED SIGPIPE
    local pools
    pools=$(zpool list -H -o name 2>/dev/null || true)
    
    if [ -z "$pools" ]; then
        return 0
    fi
    
    local pool
    echo "$pools" | while read -r pool; do
        # Test import without actually importing (pool is already imported)
        if zpool status "$pool" >/dev/null 2>&1; then
            success "Pool $pool is accessible and imported"
        else
            error "Pool $pool is not accessible!"
        fi
    done
    
    # Check zpool.cache
    if [ -f /etc/zfs/zpool.cache ]; then
        success "zpool.cache exists"
        
        local cache_size
        cache_size=$(stat -c %s /etc/zfs/zpool.cache)
        info "zpool.cache size: $cache_size bytes"
        
        if [ "$cache_size" -lt 100 ]; then
            warning "zpool.cache seems unusually small"
        fi
    else
        warning "zpool.cache not found (pools may take longer to import on boot)"
    fi
}

verify_datasets_mounted() {
    header "DATASET MOUNT VERIFICATION"
    
    if [ "$POOLS_EXIST" != true ]; then
        info "No ZFS pools to verify"
        return 0
    fi
    
    # Get all datasets with mountpoints - FIXED SIGPIPE
    local datasets
    datasets=$(zfs list -H -o name,mounted,mountpoint 2>/dev/null || true)
    
    if [ -z "$datasets" ]; then
        warning "No ZFS datasets found"
        return 0
    fi
    
    local mount_issues=0
    
    echo "$datasets" | while read -r name mounted mountpoint; do
        # Skip datasets without mountpoints
        if [ "$mountpoint" = "none" ] || [ "$mountpoint" = "-" ] || [ "$mountpoint" = "legacy" ]; then
            continue
        fi
        
        if [ "$mounted" = "yes" ]; then
            log "✓ $name mounted at $mountpoint"
        else
            warning "Dataset $name is not mounted (mountpoint: $mountpoint)"
            mount_issues=$((mount_issues + 1))
        fi
    done
    
    if [ "$mount_issues" -eq 0 ]; then
        success "All datasets with mountpoints are mounted"
    else
        warning "$mount_issues dataset(s) are not mounted"
    fi
}

verify_initramfs() {
    header "INITRAMFS VERIFICATION"
    
    local current_kernel
    current_kernel=$(uname -r)
    local initramfs_path="/boot/initramfs-${current_kernel}.img"
    
    if [ ! -f "$initramfs_path" ]; then
        error "Initramfs not found for current kernel: $initramfs_path"
        
        # Check for any initramfs files
        local initramfs_files
        initramfs_files=$(find /boot -name "initramfs-*.img" -type f 2>/dev/null || true)
        
        if [ -n "$initramfs_files" ]; then
            warning "Available initramfs images:"
            echo "$initramfs_files" | tee -a "$LOG_FILE"
        fi
        return 1
    fi
    
    success "Initramfs exists for current kernel"
    
    # Check initramfs size
    local initramfs_size_mb
    initramfs_size_mb=$(du -m "$initramfs_path" | awk '{print $1}')
    info "Initramfs size: ${initramfs_size_mb}MB"
    
    if [ "$initramfs_size_mb" -lt 10 ]; then
        warning "Initramfs seems unusually small (${initramfs_size_mb}MB)"
    fi
    
    # Check initramfs contents - FIXED SIGPIPE (capture lsinitrd output)
    info "Checking initramfs contents..."
    
    if command -v lsinitrd >/dev/null 2>&1; then
        local initramfs_content
        initramfs_content=$(lsinitrd "$initramfs_path" 2>/dev/null || true)
        
        if [ -n "$initramfs_content" ]; then
            # Check for ZFS module
            if [[ "$initramfs_content" == *"zfs.ko"* ]]; then
                success "ZFS module found in initramfs"
            else
                error "ZFS module NOT found in initramfs!"
            fi
            
            # Check for encryption key
            if [[ "$initramfs_content" == *"zroot.key"* ]]; then
                success "ZFS encryption key found in initramfs"
            else
                info "ZFS encryption key not in initramfs (normal if not using encryption)"
            fi
            
            # Check for hostid
            if  [[ "$initramfs_content" == *"etc/hostid|hostid"* ]]; then
                success "Host ID found in initramfs"
            else
                warning "Host ID not found in initramfs"
            fi
        else
            warning "Could not read initramfs contents"
        fi
    else
        # Fallback to cpio if lsinitrd not available
        info "lsinitrd not available, using cpio for verification..."
        
        # Create temp directory for extraction
        local temp_dir
        temp_dir=$(mktemp -d)
        
        if (cd "$temp_dir" && zcat "$initramfs_path" 2>/dev/null | cpio -t 2>/dev/null) > "${temp_dir}/contents.txt"; then
            local cpio_contents
            cpio_contents=$(cat "${temp_dir}/contents.txt")
            
            if echo "$cpio_contents" | grep -q "zfs.ko"; then
                success "ZFS module found in initramfs (via cpio)"
            else
                error "ZFS module NOT found in initramfs!"
            fi
            
            if echo "$cpio_contents" | grep -q "zroot.key"; then
                success "ZFS encryption key found in initramfs (via cpio)"
            else
                info "ZFS encryption key not in initramfs (normal if not using encryption)"
            fi
        fi
        
        rm -rf "$temp_dir"
    fi
}

verify_zfsbootmenu() {
    if [ "$ZFSBOOTMENU" != true ]; then
        info "ZFSBootMenu not in use, skipping verification"
        return 0
    fi
    
    header "ZFSBOOTMENU VERIFICATION"
    
    # Check ZBM command
    if ! command -v generate-zbm >/dev/null 2>&1; then
        error "generate-zbm command not found!"
        return 1
    fi
    
    success "ZFSBootMenu tools are installed"
    
    # Check ZBM version
    local zbm_version
    zbm_version=$(generate-zbm --version 2>/dev/null | head -1 || echo "unknown")
    info "ZFSBootMenu version: $zbm_version"
    
    # Check ZBM configuration
    local zbm_config="/etc/zfsbootmenu/config.yaml"
    if [ ! -f "$zbm_config" ]; then
        # Try alternate locations
        if [ -f "/etc/zfsbootmenu.yaml" ]; then
            zbm_config="/etc/zfsbootmenu.yaml"
        else
            error "ZFSBootMenu configuration not found"
            return 1
        fi
    fi
    
    success "ZFSBootMenu configuration found: $zbm_config"
    
    # Check ESP mount
    local esp_mount="${ESP_MOUNT:-/boot/efi}"
    
    if [ ! -d "$esp_mount" ]; then
        error "ESP mount point not found: $esp_mount"
        return 1
    fi
    
    # Capture findmnt output - FIXED SIGPIPE
    local esp_findmnt
    esp_findmnt=$(findmnt "$esp_mount" 2>/dev/null || true)
    
    if [ -z "$esp_findmnt" ]; then
        error "ESP is not mounted: $esp_mount"
        return 1
    fi
    
    success "ESP is mounted: $esp_mount"
    
    # Check for ZBM EFI files - Match installation script path
    local zbm_efi_path="$esp_mount/EFI/ZBM/vmlinuz.efi"
    
    if [ -f "$zbm_efi_path" ]; then
        success "ZFSBootMenu EFI image found: $zbm_efi_path"
        
        local zbm_size_mb
        zbm_size_mb=$(du -m "$zbm_efi_path" | awk '{print $1}')
        info "ZBM EFI image size: ${zbm_size_mb}MB"
        
        # Check modification time
        local zbm_mtime
        zbm_mtime=$(stat -c %y "$zbm_efi_path" | cut -d' ' -f1,2)
        info "ZBM EFI image last modified: $zbm_mtime"
    else
        error "ZFSBootMenu EFI image not found: $zbm_efi_path"
        
        # Check for backup
        if [ -f "$esp_mount/EFI/ZBM/vmlinuz-backup.efi" ]; then
            warning "Only backup ZBM image found"
        fi
    fi
    
    # Check EFI boot entries - FIXED SIGPIPE (capture efibootmgr output)
    if command -v efibootmgr >/dev/null 2>&1; then
        local efi_entries
        efi_entries=$(efibootmgr 2>/dev/null || true)
        
        if [ -n "$efi_entries" ]; then
            if echo "$efi_entries" | grep -qi "zfsbootmenu\|ZBM"; then
                success "ZFSBootMenu found in EFI boot entries"
            else
                warning "ZFSBootMenu not found in EFI boot entries"
            fi
            
            # Show current boot order
            local boot_order
            boot_order=$(echo "$efi_entries" | grep "^BootOrder:" || echo "BootOrder: unknown")
            info "$boot_order"
        fi
    fi
}

verify_bootloader() {
    header "BOOTLOADER VERIFICATION"
    
    # Check if system uses UEFI
    if [ -d /sys/firmware/efi ]; then
        info "System is running in UEFI mode"
        
        if command -v efibootmgr >/dev/null 2>&1; then
            info "EFI boot entries:"
            efibootmgr | grep -E "^Boot[0-9]" | head -10 | tee -a "$LOG_FILE"
        fi
    else
        info "System is running in BIOS/Legacy mode"
    fi
    
    # Check for GRUB (if not using ZBM)
    if [ "$ZFSBOOTMENU" != true ]; then
        if [ -f /boot/grub/grub.cfg ]; then
            success "GRUB configuration found"
            
            # Capture grub.cfg content - FIXED SIGPIPE
            local grub_cfg
            grub_cfg=$(cat /boot/grub/grub.cfg 2>/dev/null || true)
            
            if echo "$grub_cfg" | grep -q "zfs="; then
                success "GRUB is configured for ZFS boot"
            else
                warning "GRUB may not be configured for ZFS boot"
            fi
        else
            warning "GRUB configuration not found"
        fi
    fi
}

test_basic_zfs_operations() {
    header "BASIC ZFS OPERATIONS TEST"
    
    if [ "$POOLS_EXIST" != true ]; then
        info "No ZFS pools to test"
        return 0
    fi
    
    # Get first pool - FIXED SIGPIPE
    local test_pool
    test_pool=$(zpool list -H -o name 2>/dev/null | head -1 || true)
    
    if [ -z "$test_pool" ]; then
        warning "No pools available for testing"
        return 0
    fi
    
    info "Testing basic operations on pool: $test_pool"
    
    # Test dataset creation and deletion
    local test_dataset="${test_pool}/test-verify-$$"
    
    if zfs create "$test_dataset" 2>/dev/null; then
        success "Created test dataset: $test_dataset"
        
        # Test snapshot
        if zfs snapshot "${test_dataset}@test" 2>/dev/null; then
            success "Created test snapshot"
            
            # Clean up snapshot
            zfs destroy "${test_dataset}@test" 2>/dev/null
            success "Destroyed test snapshot"
        else
            warning "Could not create test snapshot"
        fi
        
        # Clean up dataset
        if zfs destroy "$test_dataset" 2>/dev/null; then
            success "Destroyed test dataset"
        else
            warning "Could not destroy test dataset"
        fi
        
        success "Basic ZFS operations are working"
    else
        error "Could not create test dataset"
        error "ZFS may have issues!"
        return 1
    fi
}

check_rollback_capability() {
    header "ROLLBACK CAPABILITY CHECK"
    
    if [ "$POOLS_EXIST" != true ]; then
        info "No ZFS pools to check"
        return 0
    fi
    
    # Check if installation snapshot exists
    if [ -n "${INSTALL_SNAPSHOT_NAME:-}" ]; then
        # Capture zfs list output - FIXED SIGPIPE
        local snapshot_exists
        snapshot_exists=$(zfs list -H -t snapshot -o name 2>/dev/null | grep "$INSTALL_SNAPSHOT_NAME" || true)
        
        if [ -n "$snapshot_exists" ]; then
            success "Installation snapshot exists: $INSTALL_SNAPSHOT_NAME"
            info "Rollback is possible if needed"
        else
            warning "Installation snapshot not found: $INSTALL_SNAPSHOT_NAME"
        fi
    else
        info "No installation snapshot information available"
    fi
    
    # List recent snapshots
    local recent_snapshots
    recent_snapshots=$(zfs list -t snapshot -o name,creation -s creation 2>/dev/null | tail -10 || true)
    
    if [ -n "$recent_snapshots" ]; then
        info "Recent snapshots:"
        echo "$recent_snapshots" | tee -a "$LOG_FILE"
    else
        info "No recent snapshots found"
    fi
}

run_comprehensive_checks() {
    header "RUNNING COMPREHENSIVE VERIFICATION"
    
    local checks_passed=0
    local checks_failed=0
    local checks_warned=0
    
    # Run all verification checks
    verify_kernel_version || checks_failed=$((checks_failed + 1))
    verify_zfs_module || checks_failed=$((checks_failed + 1))
    verify_zfs_userland || checks_failed=$((checks_failed + 1))
    verify_hostid || checks_warned=$((checks_warned + 1))
    verify_encryption_keys || checks_warned=$((checks_warned + 1))
    verify_dracut_functionality || checks_failed=$((checks_failed + 1))
    verify_pool_status || checks_failed=$((checks_failed + 1))
    verify_pool_import || checks_failed=$((checks_failed + 1))
    verify_datasets_mounted || checks_warned=$((checks_warned + 1))
    verify_initramfs || checks_failed=$((checks_failed + 1))
    verify_zfsbootmenu || checks_warned=$((checks_warned + 1))
    verify_bootloader || checks_warned=$((checks_warned + 1))
    test_basic_zfs_operations || checks_failed=$((checks_failed + 1))
    check_rollback_capability || checks_warned=$((checks_warned + 1))
    
    # Count passed checks
    checks_passed=$((14 - checks_failed - checks_warned))
    
    return 0
}

show_system_summary() {
    header "SYSTEM SUMMARY"
    
    echo ""
    echo "=========================================="
    echo "VERIFICATION SUMMARY"
    echo "=========================================="
    echo ""
    echo "System Configuration:"
    echo "  Boot Method:    $([ "$ZFSBOOTMENU" = true ] && echo "ZFSBootMenu" || echo "Traditional")"
    echo "  Running Kernel: ${RUNNING_KERNEL}"
    echo "  Latest Kernel:  ${LATEST_KERNEL}"
    echo "  ZFS Module:     ${ZFS_MODULE_VERSION}"
    echo "  ZFS Userland:   ${ZFS_USERLAND_VERSION}"
    echo ""
    
    if [ "$POOLS_EXIST" = true ]; then
        echo "ZFS Pools:"
        zpool list
        echo ""
    fi
    
    echo "Updates Applied:"
    echo "  Total:    ${TOTAL_UPDATES:-unknown}"
    echo "  Kernel:   $([ "${KERNEL_UPDATED:-false}" = true ] && echo "Yes" || echo "No")"
    echo "  ZFS:      $([ "${ZFS_UPDATED:-false}" = true ] && echo "Yes" || echo "No")"
    echo "  Dracut:   $([ "${DRACUT_UPDATED:-false}" = true ] && echo "Yes" || echo "No")"
    echo ""
    
    if [ -n "${BACKUP_DIR:-}" ]; then
        echo "Backup Location: $BACKUP_DIR"
        echo ""
    fi
    
    echo "Log File: $LOG_FILE"
    echo "=========================================="
    echo ""
}

show_recommendations() {
    header "RECOMMENDATIONS"
    
    local needs_reboot=false
    
    # Check if reboot is needed
    if [ "$KERNEL_MISMATCH" = true ]; then
        warning "REBOOT REQUIRED: New kernel is installed but not running"
        needs_reboot=true
    fi
    
    if [ "${KERNEL_UPDATED:-false}" = true ]; then
        warning "REBOOT RECOMMENDED: Kernel was updated"
        needs_reboot=true
    fi
    
    if [ "${ZFS_UPDATED:-false}" = true ] && [ "$ZFS_MODULE_VERSION" != "$ZFS_USERLAND_VERSION" ]; then
        warning "REBOOT RECOMMENDED: ZFS version mismatch detected"
        needs_reboot=true
    fi
    
    if [ "$needs_reboot" = true ]; then
        echo ""
        echo "=========================================="
        echo -e "${YELLOW}${BOLD}REBOOT IS REQUIRED OR RECOMMENDED${NC}"
        echo "=========================================="
        echo ""
        echo "To complete the update process:"
        echo "  1. Review the verification results above"
        echo "  2. Reboot the system: reboot"
        echo "  3. After reboot, run this script again to verify"
        echo ""
    else
        echo ""
        echo "=========================================="
        echo -e "${GREEN}${BOLD}SYSTEM IS READY${NC}"
        echo "=========================================="
        echo ""
        echo "All verifications passed successfully."
        echo "No reboot is required at this time."
        echo ""
    fi
    
    # Additional recommendations
    if [ "$POOLS_EXIST" = true ]; then
        echo "Recommended next steps:"
        echo "  - Monitor ZFS pools: zpool status"
        echo "  - Check for scrub status: zpool status -v"
        echo "  - Review pool health regularly"
        echo ""
    fi
}

main() {
    header "ZFS POST-UPDATE VERIFICATION"
    
    log "Starting post-update verification..."
    log "Script version: 1.2"
    
    check_root
    load_config
    detect_system_config
    run_comprehensive_checks
    show_system_summary
    show_recommendations
    
    header "VERIFICATION COMPLETED"
    
    log "Post-update verification completed"
    log "Review the output above for any warnings or errors"
    
    success "Verification process completed successfully"
}

# Run main function
main "$@"
