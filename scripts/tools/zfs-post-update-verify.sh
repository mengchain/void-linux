#!/bin/bash
# ZFS Post-Update Verification Script
# Comprehensive verification after ZFS/kernel updates
# Aligned with zfs-void-install.sh structure and best practices

# ============================================
# SCRIPT INITIALIZATION
# ============================================

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source required libraries
if [[ -f "${SCRIPT_DIR}/common.sh" ]]; then
    source "${SCRIPT_DIR}/common.sh"
elif [[ -f "/usr/local/lib/zfs-scripts/common.sh" ]]; then
    source "/usr/local/lib/zfs-scripts/common.sh"
else
    echo "ERROR: common.sh not found" >&2
    exit 1
fi

# Source configuration helper functions
if [[ -f "${SCRIPT_DIR}/zfs-setup-conf-helper.sh" ]]; then
    source "${SCRIPT_DIR}/zfs-setup-conf-helper.sh"
elif [[ -f "/usr/local/lib/zfs-scripts/zfs-setup-conf-helper.sh" ]]; then
    source "/usr/local/lib/zfs-scripts/zfs-setup-conf-helper.sh"
else
    echo "ERROR: zfs-setup-conf-helper.sh not found" >&2
    exit 1
fi

# Enable strict mode and error trapping
set_strict_mode      # Sets: set -euo pipefail
set_error_trap       # Traps ERR signal

# ============================================
# CONFIGURATION
# ============================================

# Load Configuration
load_config "zfs-setup.conf"

# Configuration files
CONFIG_FILE="/etc/zfs-update.conf"
LOG_FILE="/var/log/zfs-post-verify-$(timestamp).log"

# Global variables for cross-function use
RUNNING_KERNEL=""
LATEST_KERNEL=""
ZFS_MODULE_VERSION=""
ZFS_USERLAND_VERSION=""
KERNEL_MISMATCH=false

# Pool configuration (will be detected or loaded from config)
POOL_NAME="${POOL_NAME:-}"
BOOT_POOL_NAME="${BOOT_POOL_NAME:-}"

# Boot environment configuration from config
BE_ROOT="${BE_ROOT:-ROOT}"

# Dataset configuration from config
DATA_DATASET="${DATA_DATASET:-data}"
HOME_DATASET="${HOME_DATASET:-data/home}"
ROOT_HOME_DATASET="${ROOT_HOME_DATASET:-data/root}"

# ESP configuration from config
ESP_MOUNT="${ESP_MOUNT:-/boot/efi}"
ESP_FSTYPE="${ESP_FSTYPE:-vfat}"

# Swap configuration from config
SWAP_SIZE="${SWAP_SIZE:-}"

# Encryption configuration from config
ENCRYPTION="${ENCRYPTION:-false}"
KEY_LOCATION="${KEY_LOCATION:-/etc/zfs}"

# ZFSBootMenu configuration from config
ZFSBOOTMENU="${ZFSBOOTMENU:-false}"
ZBM_CMDLINE="${ZBM_CMDLINE:-ro quiet loglevel=0}"

# Dracut configuration from config
DRACUT_HOSTONLY="${DRACUT_HOSTONLY:-yes}"
DRACUT_COMPRESS="${DRACUT_COMPRESS:-zstd}"

# Service configuration
SERVICE_DIR="/etc/runit/runsvdir/default"
ZFS_SERVICES=("zfs-import" "zfs-mount" "zfs-zed")

# Counters for final summary
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0
CRITICAL_FAILURES=0

# ============================================
# OVERRIDE LOGGING FUNCTIONS FOR TRACKING
# ============================================

# Override common.sh logging functions to track counters
_original_success="$(declare -f success)"
success() {
    eval "${_original_success/success/command success}"
    ((CHECKS_PASSED++))
}

_original_warning="$(declare -f warning)"
warning() {
    eval "${_original_warning/warning/command warning}"
    ((CHECKS_WARNED++))
}

_original_error="$(declare -f error)"
error() {
    eval "${_original_error/error/command error}"
    ((CHECKS_FAILED++))
}

# ============================================
# CUSTOM ERROR FUNCTIONS
# ============================================

critical_error() {
    error "$@"
    ((CRITICAL_FAILURES++))
}

error_exit() {
    critical_error "$1"
    info "Post-update verification failed with critical errors."
    exit 1
}

# ============================================
# SYSTEM DETECTION
# ============================================

detect_system_config() {
    info "Detecting system configuration..."
    
    # Detect if ZFSBootMenu is installed (override config if detected)
    if command_exists generate-zbm; then
        ZFSBOOTMENU=true
        info "Detected ZFSBootMenu installation"
    else
        if [[ "$ZFSBOOTMENU" = true ]]; then
            warning "ZFSBOOTMENU=true in config but generate-zbm not found"
            ZFSBOOTMENU=false
        fi
        info "Traditional bootloader configuration"
    fi
    
    # Detect if ZFS pools exist
    local pool_list
    pool_list=$(zpool list -H -o name 2>/dev/null || true)
    if [[ -n "$pool_list" ]]; then
        POOLS_EXIST=true
        info "Detected ZFS pools: $(echo $pool_list | tr '\n' ' ')"
        
        # Auto-detect main pool if not configured
        if [[ -z "$POOL_NAME" ]]; then
            # Try to find root pool from bootfs property
            local detected_pool
            detected_pool=$(zpool list -H -o name,bootfs 2>/dev/null | grep -v "^-" | head -1 | awk '{print $1}' || true)
            
            if [[ -n "$detected_pool" ]]; then
                POOL_NAME="$detected_pool"
                info "Auto-detected main pool: $POOL_NAME"
            else
                # Fallback to first pool
                POOL_NAME=$(echo "$pool_list" | head -1)
                warning "Could not detect boot pool, using first pool: $POOL_NAME"
            fi
        fi
        
        # Verify pool exists
        if ! zpool list "$POOL_NAME" &>/dev/null; then
            warning "Configured pool '$POOL_NAME' not found"
            POOL_NAME=$(echo "$pool_list" | head -1)
            warning "Using first available pool: $POOL_NAME"
        fi
    else
        POOLS_EXIST=false
        warning "No ZFS pools detected"
    fi
}

# ============================================
# VERIFICATION FUNCTIONS
# ============================================

verify_kernel_version() {
    header "KERNEL VERSION VERIFICATION"
    
    RUNNING_KERNEL=$(get_kernel_version)
    info "Running kernel: $RUNNING_KERNEL"
    
    # Find latest installed kernel
    local kernel_images
    kernel_images=$(find /boot -name "vmlinuz-*" -type f 2>/dev/null | sort -V | tail -1 || true)
    
    if [[ -n "$kernel_images" ]]; then
        LATEST_KERNEL=$(basename "$kernel_images" | sed 's/vmlinuz-//')
        info "Latest installed kernel: $LATEST_KERNEL"
        
        if [[ "$RUNNING_KERNEL" = "$LATEST_KERNEL" ]]; then
            success "Running latest installed kernel"
        else
            warning "Running kernel ($RUNNING_KERNEL) differs from latest ($LATEST_KERNEL)"
            warning "A reboot may be required to use the latest kernel"
            KERNEL_MISMATCH=true
        fi
    else
        warning "Could not detect installed kernel images"
    fi
    
    # Check kernel command line
    local cmdline
    cmdline=$(cat /proc/cmdline)
    info "Kernel command line: $cmdline"
    
    if echo "$cmdline" | grep -q "zfs="; then
        success "ZFS boot parameter found in kernel command line"
    else
        info "No explicit ZFS boot parameter (may be set by bootloader/ZBM)"
    fi
    
    # Check for zbm parameters if using ZFSBootMenu
    if [[ "$ZFSBOOTMENU" = true ]]; then
        if echo "$cmdline" | grep -q "zbm"; then
            success "ZFSBootMenu parameters detected in kernel command line"
        else
            info "Running under ZFSBootMenu (ZBM parameters may be dynamically set)"
        fi
    fi
}

verify_zfs_module() {
    header "ZFS MODULE VERIFICATION"
    
    # Check if ZFS module is loaded
    if ! lsmod | grep -q "^zfs "; then
        critical_error "ZFS kernel module is not loaded!"
        info "Try: modprobe zfs"
        return 1
    fi
    
    success "ZFS kernel module is loaded"
    
    # Get ZFS module version
    local modinfo_output
    modinfo_output=$(modinfo zfs 2>/dev/null || true)
    
    if [[ -n "$modinfo_output" ]]; then
        ZFS_MODULE_VERSION=$(echo "$modinfo_output" | grep "^version:" | awk '{print $2}' || echo "unknown")
        info "ZFS module version: $ZFS_MODULE_VERSION"
        
        # Check if module matches running kernel
        local module_kernel
        module_kernel=$(echo "$modinfo_output" | grep "^vermagic:" | awk '{print $2}' || echo "")
        
        if [[ -n "$module_kernel" && "$module_kernel" = "$RUNNING_KERNEL" ]]; then
            success "ZFS module compiled for running kernel"
        else
            warning "ZFS module may not match running kernel"
            warning "Module kernel: $module_kernel, Running: $RUNNING_KERNEL"
        fi
    else
        warning "Could not retrieve ZFS module information"
    fi
    
    # Check ZFS module parameters
    if [[ -d /sys/module/zfs/parameters ]]; then
        local zfs_arc_max
        zfs_arc_max=$(cat /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null || echo "0")
        if [[ "$zfs_arc_max" != "0" ]]; then
            info "ZFS ARC max: $((zfs_arc_max / 1024 / 1024 / 1024))GB"
        fi
    fi
}

verify_zfs_userland() {
    header "ZFS USERLAND TOOLS VERIFICATION"
    
    # Check zfs command
    if ! command_exists zfs; then
        critical_error "zfs command not found!"
        return 1
    fi
    
    if ! command_exists zpool; then
        critical_error "zpool command not found!"
        return 1
    fi
    
    success "ZFS userland tools are available"
    
    # Get userland version
    local zfs_version_output
    zfs_version_output=$(zfs version 2>/dev/null || true)
    
    if [[ -n "$zfs_version_output" ]]; then
        ZFS_USERLAND_VERSION=$(echo "$zfs_version_output" | grep "zfs-" | head -1 | awk '{print $2}' || echo "unknown")
        info "ZFS userland version: $ZFS_USERLAND_VERSION"
        
        # Compare module and userland versions
        if [[ -n "$ZFS_MODULE_VERSION" && "$ZFS_MODULE_VERSION" != "unknown" ]]; then
            if [[ "$ZFS_MODULE_VERSION" = "$ZFS_USERLAND_VERSION" ]]; then
                success "ZFS module and userland versions match"
            else
                warning "Version mismatch - Module: $ZFS_MODULE_VERSION, Userland: $ZFS_USERLAND_VERSION"
            fi
        fi
    else
        warning "Could not retrieve ZFS userland version"
    fi
    
    # Test basic ZFS functionality
    if zfs list >/dev/null 2>&1; then
        success "ZFS list command works"
    else
        critical_error "ZFS list command failed!"
        return 1
    fi
    
    if zpool list >/dev/null 2>&1; then
        success "ZFS pool list command works"
    else
        critical_error "ZFS pool list command failed!"
        return 1
    fi
}

verify_hostid() {
    header "HOSTID VERIFICATION"
    
    if ! validate_file /etc/hostid "hostid file"; then
        critical_error "hostid file missing at /etc/hostid"
        info "Run: zgenhostid -f"
        return 1
    fi
    
    success "hostid file exists"
    
    local hostid_size
    hostid_size=$(stat -c %s /etc/hostid 2>/dev/null || echo "0")
    
    if [[ "$hostid_size" -ne 4 ]]; then
        critical_error "hostid file has incorrect size: $hostid_size bytes (expected 4)"
        info "Run: zgenhostid -f"
        return 1
    fi
    
    success "hostid file has correct size (4 bytes)"
    
    local hostid_cmd hostid_file
    hostid_cmd=$(hostid)
    hostid_file=$(od -An -tx4 /etc/hostid | tr -d ' \n')
    
    info "hostid command: $hostid_cmd"
    info "hostid file:    $hostid_file"
    
    if [[ "$hostid_cmd" = "$hostid_file" ]]; then
        success "Host ID is consistent between command and file"
    else
        critical_error "Host ID mismatch between command ($hostid_cmd) and file ($hostid_file)"
        info "Run: zgenhostid -f"
        return 1
    fi
}

verify_encryption_keys() {
    header "ENCRYPTION KEY VERIFICATION"
    
    if [[ -z "$POOL_NAME" ]]; then
        warning "No pool name configured, skipping encryption key verification"
        return 0
    fi
    
    local key_file="${KEY_LOCATION}/${POOL_NAME}.key"
    
    if [[ ! -f "$key_file" ]]; then
        if [[ "$ENCRYPTION" = true ]]; then
            critical_error "Encryption enabled but key not found at $key_file"
            return 1
        else
            info "No encryption key found at $key_file"
            info "System may not use encrypted ZFS pools"
            return 0
        fi
    fi
    
    success "ZFS encryption key exists at $key_file"
    
    # Check permissions
    local key_perms
    key_perms=$(stat -c %a "$key_file")
    
    if [[ "$key_perms" = "000" || "$key_perms" = "400" || "$key_perms" = "600" ]]; then
        success "Encryption key has secure permissions: $key_perms"
    else
        warning "Encryption key has permissive permissions: $key_perms"
        warning "Recommended: chmod 400 $key_file"
    fi
    
    # Check if key is being used
    if [[ "$POOLS_EXIST" = true ]]; then
        local encrypted_datasets
        encrypted_datasets=$(zfs get -H -o name,value encryption 2>/dev/null | grep -v "off$" | awk '{print $1}' || true)
        
        if [[ -n "$encrypted_datasets" ]]; then
            success "Found encrypted datasets using encryption"
            while IFS= read -r dataset; do
                local keylocation
                keylocation=$(zfs get -H -o value keylocation "$dataset" 2>/dev/null || true)
                indent 1 "$dataset: $keylocation"
                
                if [[ "$keylocation" = "file://$key_file" ]]; then
                    success "  Key location correctly configured"
                fi
            done <<< "$encrypted_datasets"
        else
            if [[ "$ENCRYPTION" = true ]]; then
                warning "Encryption configured but no encrypted datasets found"
            else
                info "No encrypted datasets found"
            fi
        fi
    fi
    
    # Check for key backup
    local backup_key="/root/zfs-keys/${POOL_NAME}.key"
    if [[ -f "$backup_key" ]]; then
        success "Encryption key backup exists at $backup_key"
        
        if diff "$key_file" "$backup_key" &>/dev/null; then
            success "Backup key matches primary key"
        else
            warning "Backup key differs from primary key"
        fi
    else
        if [[ "$ENCRYPTION" = true ]]; then
            warning "No encryption key backup found at $backup_key"
            info "Consider backing up: install -m 000 $key_file /root/zfs-keys/"
        fi
    fi
}

verify_zfs_services() {
    header "ZFS RUNIT SERVICES VERIFICATION"
    
    local all_enabled=true
    
    for service in "${ZFS_SERVICES[@]}"; do
        if [[ -L "$SERVICE_DIR/$service" ]]; then
            success "Service $service is enabled"
            
            # Check if service is running
            if sv status "$service" >/dev/null 2>&1; then
                local status
                status=$(sv status "$service" 2>&1 || true)
                if echo "$status" | grep -q "run:"; then
                    success "  Service $service is running"
                else
                    warning "  Service $service is not running: $status"
                fi
            fi
        else
            critical_error "Service $service is NOT enabled"
            info "  Enable with: ln -s /etc/sv/$service $SERVICE_DIR/"
            all_enabled=false
        fi
    done
    
    if [[ "$all_enabled" = false ]]; then
        critical_error "Critical ZFS services are not enabled - system may not boot properly!"
        return 1
    fi
}

verify_dracut_configuration() {
    header "DRACUT CONFIGURATION VERIFICATION"
    
    if ! command_exists dracut; then
        critical_error "dracut command not found!"
        return 1
    fi
    
    success "dracut is installed"
    
    # Check dracut version
    local dracut_version
    dracut_version=$(dracut --version 2>/dev/null | head -1 || echo "unknown")
    info "dracut version: $dracut_version"
    
    # Check main dracut configuration
    local dracut_conf="/etc/dracut.conf"
    if validate_file "$dracut_conf" "Main dracut configuration"; then
        success "Main dracut configuration exists"
        
        # Verify configured settings
        if grep -q "hostonly=\"${DRACUT_HOSTONLY}\"" "$dracut_conf" 2>/dev/null; then
            success "  hostonly mode: ${DRACUT_HOSTONLY} (matches config)"
        else
            warning "  hostonly mode not set to configured value: ${DRACUT_HOSTONLY}"
        fi
        
        if grep -q "compress=\"${DRACUT_COMPRESS}\"" "$dracut_conf" 2>/dev/null; then
            success "  compression: ${DRACUT_COMPRESS} (matches config)"
        else
            info "  compression not set to configured value: ${DRACUT_COMPRESS}"
        fi
    else
        warning "Main dracut configuration not found: $dracut_conf"
    fi
    
    # Check dracut ZFS configuration
    local dracut_zfs_conf="/etc/dracut.conf.d/zfs.conf"
    if ! validate_file "$dracut_zfs_conf" "dracut ZFS configuration"; then
        critical_error "dracut ZFS configuration not found: $dracut_zfs_conf"
        return 1
    fi
    
    success "dracut ZFS configuration exists"
    
    # Verify critical ZFS dracut settings
    local required_settings=(
        "hostonly=\"${DRACUT_HOSTONLY}\""
        'add_dracutmodules+=" zfs "'
        'omit_dracutmodules+=" btrfs'
        'install_items+=" /etc/hostid'
        'force_drivers+=" zfs'
    )
    
    # Check for encryption key in dracut config if encryption is enabled
    if [[ "$ENCRYPTION" = true && -n "$POOL_NAME" ]]; then
        local key_file="${KEY_LOCATION}/${POOL_NAME}.key"
        if [[ -f "$key_file" ]]; then
            required_settings+=("install_items+=\".*${POOL_NAME}.key")
        fi
    fi
    
    for setting in "${required_settings[@]}"; do
        if grep -q "$setting" "$dracut_zfs_conf" 2>/dev/null; then
            success "  Found: $setting"
        else
            warning "  Missing or different: $setting"
        fi
    done
    
    # Check for ZFS dracut module
    local dracut_module_dirs=("/usr/lib/dracut/modules.d" "/usr/share/dracut/modules.d")
    local found_zfs_module=false
    
    for module_dir in "${dracut_module_dirs[@]}"; do
        if [[ -d "$module_dir" ]]; then
            if find "$module_dir" -type d -name "*zfs*" 2>/dev/null | grep -q .; then
                found_zfs_module=true
                local zfs_modules
                zfs_modules=$(find "$module_dir" -type d -name "*zfs*" 2>/dev/null | xargs -n1 basename)
                success "Found ZFS dracut module(s): $zfs_modules"
                break
            fi
        fi
    done
    
    if [[ "$found_zfs_module" = false ]]; then
        critical_error "ZFS dracut module not found in ${dracut_module_dirs[*]}"
        return 1
    fi
}

verify_pool_configuration() {
    header "ZFS POOL CONFIGURATION VERIFICATION"
    
    if [[ "$POOLS_EXIST" != true ]]; then
        info "No ZFS pools to verify"
        return 0
    fi
    
    local pools
    pools=$(zpool list -H -o name 2>/dev/null || true)
    
    if [[ -z "$pools" ]]; then
        warning "Could not list ZFS pools"
        return 1
    fi
    
    while IFS= read -r pool; do
        info "Verifying pool: $pool"
        
        # Check ashift
        local ashift
        ashift=$(zpool get -H -o value ashift "$pool" 2>/dev/null || echo "unknown")
        if [[ "$ashift" = "12" ]]; then
            success "  ashift: $ashift (optimal for modern drives)"
        else
            info "  ashift: $ashift (install script uses 12)"
        fi
        
        # Check autotrim
        local autotrim
        autotrim=$(zpool get -H -o value autotrim "$pool" 2>/dev/null || echo "unknown")
        if [[ "$autotrim" = "on" ]]; then
            success "  autotrim: $autotrim (matches install script)"
        else
            warning "  autotrim: $autotrim (install script sets 'on')"
        fi
        
        # Check compression
        local compression
        compression=$(zpool get -H -o value compression "$pool" 2>/dev/null || echo "unknown")
        if [[ "$compression" = "lz4" ]]; then
            success "  compression: $compression (matches install script)"
        else
            info "  compression: $compression (install script uses lz4)"
        fi
        
        # Check cachefile property
        local cachefile
        cachefile=$(zpool get -H -o value cachefile "$pool" 2>/dev/null || echo "unknown")
        if [[ "$cachefile" = "/etc/zfs/zpool.cache" ]]; then
            success "  cachefile: $cachefile (correctly set)"
        else
            critical_error "  cachefile: $cachefile (should be /etc/zfs/zpool.cache)"
            info "  Fix with: zpool set cachefile=/etc/zfs/zpool.cache $pool"
        fi
        
        # Check bootfs property
        local bootfs
        bootfs=$(zpool get -H -o value bootfs "$pool" 2>/dev/null || echo "-")
        if [[ "$bootfs" != "-" ]]; then
            success "  bootfs: $bootfs"
        else
            info "  bootfs: not set (may be intentional for non-boot pools)"
        fi
    done <<< "$pools"
}

verify_pool_status() {
    header "ZFS POOL STATUS VERIFICATION"
    
    if [[ "$POOLS_EXIST" != true ]]; then
        info "No ZFS pools to verify"
        return 0
    fi
    
    local pools
    pools=$(zpool list -H -o name 2>/dev/null || true)
    
    if [[ -z "$pools" ]]; then
        warning "Could not list ZFS pools"
        return 1
    fi
    
    local all_healthy=true
    
    while IFS= read -r pool; do
        local pool_health
        pool_health=$(zpool list -H -o health "$pool" 2>/dev/null || echo "UNKNOWN")
        
        if [[ "$pool_health" = "ONLINE" ]]; then
            success "Pool $pool: $pool_health"
        else
            error "Pool $pool: $pool_health (not healthy!)"
            all_healthy=false
            
            # Show detailed status
            info "Detailed status for $pool:"
            zpool status "$pool"
        fi
    done <<< "$pools"
    
    if [[ "$all_healthy" = false ]]; then
        critical_error "One or more pools are not healthy!"
        return 1
    fi
}

verify_dataset_structure() {
    header "DATASET STRUCTURE VERIFICATION"
    
    if [[ "$POOLS_EXIST" != true || -z "$POOL_NAME" ]]; then
        info "No ZFS pools to verify"
        return 0
    fi
    
    # Check for boot environment structure
    local be_root_path="${POOL_NAME}/${BE_ROOT}"
    if zfs list "$be_root_path" &>/dev/null; then
        success "Boot environment container exists: $be_root_path"
        
        # Check mountpoint
        local root_mountpoint
        root_mountpoint=$(zfs get -H -o value mountpoint "$be_root_path" 2>/dev/null || echo "")
        if [[ "$root_mountpoint" = "none" ]]; then
            success "  $be_root_path mountpoint: none (correct per install script)"
        else
            warning "  $be_root_path mountpoint: $root_mountpoint (should be 'none')"
        fi
        
        # Check canmount
        local root_canmount
        root_canmount=$(zfs get -H -o value canmount "$be_root_path" 2>/dev/null || echo "")
        if [[ "$root_canmount" = "off" ]]; then
            success "  $be_root_path canmount: off (correct)"
        else
            info "  $be_root_path canmount: $root_canmount"
        fi
        
        # List boot environments
        local boot_envs
        boot_envs=$(zfs list -H -o name -r "$be_root_path" 2>/dev/null | grep -v "^${be_root_path}$" || true)
        if [[ -n "$boot_envs" ]]; then
            success "Boot environments found:"
            while IFS= read -r be; do
                indent 1 "- $be"
            done <<< "$boot_envs"
        else
            warning "No boot environments found under $be_root_path"
        fi
        
        # Check bootfs property
        local bootfs
        bootfs=$(zpool get -H -o value bootfs "$POOL_NAME" 2>/dev/null || echo "-")
        if [[ "$bootfs" != "-" ]]; then
            success "bootfs property set: $bootfs"
            
            # Verify bootfs exists
            if zfs list "$bootfs" &>/dev/null; then
                success "  bootfs dataset exists"
                
                # Check if it's under BE_ROOT
                if echo "$bootfs" | grep -q "${POOL_NAME}/${BE_ROOT}/"; then
                    success "  bootfs is under ${POOL_NAME}/${BE_ROOT} (correct structure)"
                fi
            else
                critical_error "  bootfs dataset does not exist!"
            fi
        else
            warning "bootfs property not set (may prevent booting)"
        fi
    else
        warning "Boot environment container $be_root_path does not exist"
        info "This pool may not follow the recommended structure"
    fi
    
    # Check data structure
    local data_path="${POOL_NAME}/${DATA_DATASET}"
    if zfs list "$data_path" &>/dev/null; then
        success "Data container exists: $data_path"
        
        # Check home dataset
        local home_path="${POOL_NAME}/${HOME_DATASET}"
        if zfs list "$home_path" &>/dev/null; then
            success "  Home dataset exists: $home_path"
            
            local home_mountpoint
            home_mountpoint=$(zfs get -H -o value mountpoint "$home_path" 2>/dev/null || echo "")
            if [[ "$home_mountpoint" = "/home" ]]; then
                success "    Mountpoint: /home (correct)"
            else
                warning "    Mountpoint: $home_mountpoint (expected /home)"
            fi
        else
            info "  Home dataset not found (may not exist in all setups)"
        fi
        
        # Check root home dataset
        local root_home_path="${POOL_NAME}/${ROOT_HOME_DATASET}"
        if zfs list "$root_home_path" &>/dev/null; then
            success "  Root home dataset exists: $root_home_path"
            
            local root_home_mountpoint
            root_home_mountpoint=$(zfs get -H -o value mountpoint "$root_home_path" 2>/dev/null || echo "")
            if [[ "$root_home_mountpoint" = "/root" ]]; then
                success "    Mountpoint: /root (correct)"
            else
                warning "    Mountpoint: $root_home_mountpoint (expected /root)"
            fi
        else
            info "  Root home dataset not found (may not exist in all setups)"
        fi
    else
        info "Data container $data_path does not exist (may not be used)"
    fi
    
    # Check for ZFSBootMenu commandline property
    if [[ "$ZFSBOOTMENU" = true ]]; then
        local zbm_cmdline_prop
        zbm_cmdline_prop=$(zfs get -H -o value org.zfsbootmenu:commandline "$be_root_path" 2>/dev/null || echo "")
        
        if [[ -n "$zbm_cmdline_prop" && "$zbm_cmdline_prop" != "-" ]]; then
            success "ZFSBootMenu commandline property set: $zbm_cmdline_prop"
            
            # Check if it matches config
            if [[ "$zbm_cmdline_prop" = "$ZBM_CMDLINE" ]]; then
                success "  Matches configured value"
            else
                info "  Configured: $ZBM_CMDLINE"
                info "  Actual:     $zbm_cmdline_prop"
            fi
        else
            warning "ZFSBootMenu commandline property not set on $be_root_path"
            info "Configured value: $ZBM_CMDLINE"
        fi
    fi
}

verify_pool_import() {
    header "POOL IMPORT CAPABILITY VERIFICATION"
    
    if [[ "$POOLS_EXIST" != true ]]; then
        info "No ZFS pools to verify"
        return 0
    fi
    
    info "Testing pool import capability (dry-run)..."
    
    local pools
    pools=$(zpool list -H -o name 2>/dev/null || true)
    
    if [[ -z "$pools" ]]; then
        warning "Could not list ZFS pools"
        return 1
    fi
    
    while IFS= read -r pool; do
        # Test import with -N (no mount)
        if zpool import -d /dev/disk/by-id -N "$pool" &>/dev/null; then
            success "Pool $pool can be imported from /dev/disk/by-id"
        else
            # Pool already imported, try to verify it's importable
            if zpool status "$pool" &>/dev/null; then
                success "Pool $pool is already imported and accessible"
            else
                error "Pool $pool import test failed"
            fi
        fi
    done <<< "$pools"
    
    # Check zpool.cache
    if validate_file /etc/zfs/zpool.cache "zpool.cache"; then
        success "zpool.cache exists at /etc/zfs/zpool.cache"
        
        local cache_size
        cache_size=$(stat -c %s /etc/zfs/zpool.cache 2>/dev/null || echo "0")
        if [[ "$cache_size" -gt 0 ]]; then
            success "  zpool.cache is not empty (${cache_size} bytes)"
        else
            warning "  zpool.cache is empty"
        fi
    else
        warning "zpool.cache not found at /etc/zfs/zpool.cache"
        info "Pools may take longer to import on boot"
        info "Generate with: zpool set cachefile=/etc/zfs/zpool.cache <pool>"
    fi
}

verify_datasets_mounted() {
    header "DATASET MOUNT VERIFICATION"
    
    if [[ "$POOLS_EXIST" != true ]]; then
        info "No ZFS pools to verify"
        return 0
    fi
    
    local datasets
    datasets=$(zfs list -H -o name,mounted,mountpoint 2>/dev/null || true)
    
    if [[ -z "$datasets" ]]; then
        warning "Could not list ZFS datasets"
        return 1
    fi
    
    local mount_issues=0
    
    while IFS=$'\t' read -r name mounted mountpoint; do
        # Skip datasets with no mountpoint or legacy mountpoint
        if [[ "$mountpoint" = "none" || "$mountpoint" = "legacy" || "$mountpoint" = "-" ]]; then
            continue
        fi
        
        if [[ "$mounted" = "yes" ]]; then
            # Verify mountpoint actually exists and is mounted
            if mountpoint -q "$mountpoint" 2>/dev/null; then
                success "Dataset $name mounted at $mountpoint"
            else
                warning "Dataset $name reports mounted but $mountpoint is not a mountpoint"
                ((mount_issues++))
            fi
        else
            # Check canmount property
            local canmount
            canmount=$(zfs get -H -o value canmount "$name" 2>/dev/null || echo "on")
            
            if [[ "$canmount" = "off" || "$canmount" = "noauto" ]]; then
                info "Dataset $name not mounted (canmount=$canmount)"
            else
                warning "Dataset $name should be mounted at $mountpoint but is not"
                ((mount_issues++))
            fi
        fi
    done <<< "$datasets"
    
    if [[ "$mount_issues" -eq 0 ]]; then
        success "All mountable datasets are properly mounted"
    else
        warning "$mount_issues dataset(s) have mount issues"
    fi
}

verify_initramfs() {
    header "INITRAMFS VERIFICATION"
    
    local current_kernel="$RUNNING_KERNEL"
    local initramfs_path="/boot/initramfs-${current_kernel}.img"
    
    if ! validate_file "$initramfs_path" "Initramfs for current kernel"; then
        critical_error "Initramfs not found for current kernel: $initramfs_path"
        info "Generate with: xbps-reconfigure -f linux${current_kernel#[0-9]*}"
        return 1
    fi
    
    success "Initramfs exists for current kernel: $initramfs_path"
    
    # Check initramfs size
    local initramfs_size_mb
    initramfs_size_mb=$(du -m "$initramfs_path" | awk '{print $1}')
    info "Initramfs size: ${initramfs_size_mb}MB"
    
    if [[ "$initramfs_size_mb" -lt 10 ]]; then
        warning "Initramfs seems unusually small (${initramfs_size_mb}MB)"
    else
        success "Initramfs size looks reasonable"
    fi
    
    # Check initramfs contents
    info "Checking initramfs contents..."
    
    if command_exists lsinitrd; then
        # Check for critical files/modules
        local lsinitrd_output
        lsinitrd_output=$(lsinitrd "$initramfs_path" 2>/dev/null || true)
        
        if [[ -n "$lsinitrd_output" ]]; then
            # Check for ZFS module
            if echo "$lsinitrd_output" | grep -q "zfs.ko"; then
                success "  ZFS kernel module included"
            else
                critical_error "  ZFS kernel module NOT found in initramfs"
            fi
            
            # Check for hostid
            if echo "$lsinitrd_output" | grep -q "etc/hostid"; then
                success "  hostid file included"
            else
                critical_error "  hostid file NOT found in initramfs"
            fi
            
            # Check for encryption key (if encryption is enabled)
            if [[ "$ENCRYPTION" = true && -n "$POOL_NAME" ]]; then
                local key_file="${KEY_LOCATION}/${POOL_NAME}.key"
                if [[ -f "$key_file" ]]; then
                    if echo "$lsinitrd_output" | grep -q "$(basename "$key_file")"; then
                        success "  Encryption key included"
                    else
                        critical_error "  Encryption key NOT found in initramfs"
                        info "  Key should be included per dracut zfs.conf"
                    fi
                fi
            fi
            
            # Check for zpool.cache
            if echo "$lsinitrd_output" | grep -q "etc/zfs/zpool.cache"; then
                success "  zpool.cache included"
            else
                warning "  zpool.cache not found in initramfs (may cause slow boot)"
            fi
            
            # Check for dracut ZFS modules
            if echo "$lsinitrd_output" | grep -q "dracut.*zfs"; then
                success "  Dracut ZFS module included"
            else
                warning "  Dracut ZFS module may not be included"
            fi
        else
            warning "Could not list initramfs contents"
        fi
    else
        info "lsinitrd not available, using basic check"
        
        # Basic check by extracting to temp directory
        local temp_dir
        temp_dir=$(mktemp -d)
        register_cleanup "rm -rf '$temp_dir'"
        
        if cd "$temp_dir" && zcat "$initramfs_path" 2>/dev/null | cpio -idm --quiet 2>/dev/null; then
            # Check for ZFS
            if [[ -f "usr/lib/modules/${current_kernel}/kernel/fs/zfs/zfs.ko" ]] || \
               find . -name "zfs.ko*" 2>/dev/null | grep -q .; then
                success "  ZFS module found in initramfs"
            else
                critical_error "  ZFS module NOT found in initramfs"
            fi
            
            # Check for hostid
            if [[ -f "etc/hostid" ]]; then
                success "  hostid included"
            else
                critical_error "  hostid NOT included"
            fi
            
            # Check for key
            if [[ "$ENCRYPTION" = true && -n "$POOL_NAME" ]]; then
                local key_file="${KEY_LOCATION}/${POOL_NAME}.key"
                if [[ -f "$key_file" ]]; then
                    if [[ -f "etc/zfs/$(basename "$key_file")" ]]; then
                        success "  Encryption key included"
                    else
                        critical_error "  Encryption key NOT included"
                    fi
                fi
            fi
            
            cd - >/dev/null
        else
            warning "Could not extract initramfs for detailed check"
        fi
    fi
}

verify_zfsbootmenu() {
    if [[ "$ZFSBOOTMENU" != true ]]; then
        info "ZFSBootMenu not in use, skipping ZBM checks"
        return 0
    fi
    
    header "ZFSBOOTMENU VERIFICATION"
    
    # Check ZBM command
    if ! command_exists generate-zbm; then
        critical_error "generate-zbm command not found but ZFSBOOTMENU=true"
        return 1
    fi
    
    success "ZFSBootMenu tools are installed"
    
    # Check ZBM version
    local zbm_version
    zbm_version=$(generate-zbm --version 2>/dev/null | head -1 || echo "unknown")
    info "ZFSBootMenu version: $zbm_version"
    
    # Check ZBM configuration
    local zbm_config="/etc/zfsbootmenu/config.yaml"
    if [[ ! -f "$zbm_config" ]]; then
        zbm_config="/etc/zfsbootmenu.yaml"
        if ! validate_file "$zbm_config" "ZFSBootMenu configuration"; then
            critical_error "ZFSBootMenu configuration not found"
            info "Expected at: /etc/zfsbootmenu/config.yaml"
            return 1
        fi
    fi
    
    success "ZFSBootMenu configuration found: $zbm_config"
    
    # Verify configuration settings
    if grep -q "Enabled: true" "$zbm_config" 2>/dev/null; then
        success "  EFI generation enabled"
    else
        info "  Checking EFI generation setting..."
    fi
    
    # Check ESP mount
    if ! validate_directory "$ESP_MOUNT" "ESP mount point"; then
        critical_error "ESP mount point does not exist: $ESP_MOUNT"
        return 1
    fi
    
    if ! findmnt "$ESP_MOUNT" >/dev/null 2>&1; then
        critical_error "ESP is not mounted: $ESP_MOUNT"
        info "Check /etc/fstab and mount the ESP"
        return 1
    fi
    
    success "ESP is mounted: $ESP_MOUNT"
    
    # Check ESP filesystem
    local esp_fstype_actual
    esp_fstype_actual=$(findmnt -n -o FSTYPE "$ESP_MOUNT" 2>/dev/null || echo "unknown")
    if [[ "$esp_fstype_actual" = "$ESP_FSTYPE" ]]; then
        success "  ESP filesystem: $esp_fstype_actual (matches config)"
    else
        warning "  ESP filesystem: $esp_fstype_actual (configured: $ESP_FSTYPE)"
    fi
    
    # Check for ZBM EFI files
    local zbm_efi_path="$ESP_MOUNT/EFI/ZBM/vmlinuz.efi"
    
    if validate_file "$zbm_efi_path" "ZBM EFI image"; then
        success "ZBM EFI image exists: $zbm_efi_path"
        
        local zbm_mtime
        zbm_mtime=$(stat -c %y "$zbm_efi_path" | cut -d'.' -f1)
        info "ZBM EFI image last modified: $zbm_mtime"
        
        # Check backup
        local zbm_backup="$ESP_MOUNT/EFI/ZBM/vmlinuz-backup.efi"
        if [[ -f "$zbm_backup" ]]; then
            success "ZBM backup EFI image exists"
        else
            warning "ZBM backup EFI image not found"
            info "Install script creates: $zbm_backup"
        fi
    else
        critical_error "ZBM EFI image not found: $zbm_efi_path"
        info "Generate with: generate-zbm"
        return 1
    fi
    
    # Check ZBM dracut configuration
    local zbm_dracut_dir="/etc/zfsbootmenu/dracut.conf.d"
    if [[ -d "$zbm_dracut_dir" ]]; then
        success "ZBM dracut configuration directory exists"
        
        # Check for keymap configuration
        if [[ -f "$zbm_dracut_dir/keymap.conf" ]]; then
            success "  ZBM keymap configuration exists"
        else
            info "  ZBM keymap configuration not found (optional)"
        fi
    else
        warning "ZBM dracut configuration directory not found: $zbm_dracut_dir"
    fi
    
    # Check cmdline.d for keymap
    if [[ -f "/etc/cmdline.d/keymap.conf" ]]; then
        success "Keymap cmdline configuration exists"
    else
        info "Keymap cmdline configuration not found (optional)"
    fi
    
    # Check EFI boot entries
    if command_exists efibootmgr; then
        local efi_entries
        efi_entries=$(efibootmgr 2>/dev/null || true)
        
        if [[ -n "$efi_entries" ]]; then
            info "EFI boot entries:"
            echo "$efi_entries"
            
            if echo "$efi_entries" | grep -q "ZFSBootMenu"; then
                success "ZFSBootMenu entries found in EFI"
                
                # Check for backup entry
                if echo "$efi_entries" | grep -q "ZFSBootMenu.*Backup"; then
                    success "  ZFSBootMenu backup entry found"
                else
                    info "  ZFSBootMenu backup entry not found"
                fi
            else
                warning "No ZFSBootMenu entries found in EFI boot manager"
                info "Add with: efibootmgr --create --disk /dev/XXX --part 1 --label 'ZFSBootMenu' --loader '\\EFI\\ZBM\\vmlinuz.efi'"
            fi
        else
            warning "Could not read EFI boot entries"
        fi
    else
        info "efibootmgr not available, skipping EFI entry check"
    fi
}

verify_fstab() {
    header "FSTAB VERIFICATION"
    
    if ! validate_file /etc/fstab "/etc/fstab"; then
        warning "No /etc/fstab file found"
        return 1
    fi
    
    success "/etc/fstab exists"
    
    # Check ESP entry
    if grep -q "$ESP_MOUNT" /etc/fstab 2>/dev/null; then
        success "ESP mount entry found in fstab"
        
        # Verify it's using UUID
        if grep "$ESP_MOUNT" /etc/fstab | grep -q "UUID="; then
            success "  Using UUID for ESP (best practice)"
        else
            info "  Not using UUID for ESP"
        fi
        
        # Check filesystem type
        if grep "$ESP_MOUNT" /etc/fstab | grep -q "$ESP_FSTYPE"; then
            success "  ESP filesystem type: $ESP_FSTYPE (correct)"
        else
            warning "  ESP filesystem type may be incorrect (expected: $ESP_FSTYPE)"
        fi
    else
        warning "No ESP mount entry found in fstab for $ESP_MOUNT"
    fi
    
    # Check for swap (if configured)
    if [[ -n "$POOL_NAME" && -n "$SWAP_SIZE" ]]; then
        if grep -q "^/dev/zvol/${POOL_NAME}/swap" /etc/fstab 2>/dev/null; then
            success "ZFS swap volume entry found in fstab"
            
            # Verify swap volume exists
            if [[ -e "/dev/zvol/${POOL_NAME}/swap" ]]; then
                success "  Swap volume exists"
                
                # Check if swap is active
                if swapon --show | grep -q "${POOL_NAME}/swap"; then
                    success "  Swap is active"
                else
                    warning "  Swap volume exists but is not active"
                fi
            else
                warning "  Swap volume entry in fstab but volume does not exist"
            fi
        else
            info "No ZFS swap volume configured in fstab (SWAP_SIZE=${SWAP_SIZE})"
        fi
    else
        info "No ZFS swap configured (SWAP_SIZE not set or pool not found)"
    fi
    
    # Check for tmpfs entries
    if grep -q "tmpfs.*/tmp" /etc/fstab 2>/dev/null; then
        success "/tmp mounted as tmpfs (recommended)"
    else
        info "/tmp not configured as tmpfs"
    fi
    
    if grep -q "tmpfs.*/dev/shm" /etc/fstab 2>/dev/null; then
        success "/dev/shm mounted as tmpfs"
    else
        info "/dev/shm not explicitly configured in fstab"
    fi
}

test_basic_zfs_operations() {
    header "BASIC ZFS OPERATIONS TEST"
    
    if [[ "$POOLS_EXIST" != true ]]; then
        info "No ZFS pools available for testing"
        return 0
    fi
    
    local test_pool="${POOL_NAME:-$(zpool list -H -o name 2>/dev/null | head -1)}"
    
    if [[ -z "$test_pool" ]]; then
        warning "Could not determine test pool"
        return 1
    fi
    
    info "Testing basic operations on pool: $test_pool"
    
    # Test dataset creation and deletion
    local test_dataset="${test_pool}/test-verify-$$"
    
    if zfs create "$test_dataset" 2>/dev/null; then
        success "Dataset creation successful"
        
        # Test snapshot creation
        if zfs snapshot "${test_dataset}@test" 2>/dev/null; then
            success "Snapshot creation successful"
            
            # Test snapshot deletion
            if zfs destroy "${test_dataset}@test" 2>/dev/null; then
                success "Snapshot deletion successful"
            else
                error "Snapshot deletion failed"
            fi
        else
            error "Snapshot creation failed"
        fi
        
        # Cleanup test dataset
        if zfs destroy "$test_dataset" 2>/dev/null; then
            success "Dataset deletion successful"
            success "Basic ZFS operations are working correctly"
        else
            error "Dataset deletion failed"
            warning "Manual cleanup required: zfs destroy $test_dataset"
        fi
    else
        error "Dataset creation failed"
        critical_error "Basic ZFS operations are not working"
        return 1
    fi
}

check_rollback_capability() {
    header "ROLLBACK CAPABILITY CHECK"
    
    if [[ "$POOLS_EXIST" != true ]]; then
        info "No ZFS pools available"
        return 0
    fi
    
    # Check if installation snapshot exists
    if [[ -n "${INSTALL_SNAPSHOT_NAME:-}" ]]; then
        if zfs list -t snapshot "$INSTALL_SNAPSHOT_NAME" &>/dev/null; then
            success "Installation snapshot exists: $INSTALL_SNAPSHOT_NAME"
            info "System can be rolled back to post-installation state"
        else
            info "Installation snapshot not found: $INSTALL_SNAPSHOT_NAME"
        fi
    else
        info "No installation snapshot information available"
    fi
    
    # List recent snapshots
    info "Recent snapshots (last 10):"
    local recent_snapshots
    recent_snapshots=$(zfs list -t snapshot -o name,creation -s creation 2>/dev/null | tail -10 || true)
    
    if [[ -n "$recent_snapshots" ]]; then
        echo "$recent_snapshots"
        
        # Count snapshots per dataset
        local snapshot_count
        snapshot_count=$(zfs list -t snapshot -H 2>/dev/null | wc -l || echo "0")
        success "Total snapshots available: $snapshot_count"
    else
        info "No snapshots found"
        warning "Consider creating snapshots for system recovery"
    fi
    
    # Check for automatic snapshot service
    if [[ -L "$SERVICE_DIR/zfs-auto-snapshot" ]]; then
        success "Automatic snapshot service enabled"
    else
        info "Automatic snapshot service not enabled (optional)"
    fi
}

# ============================================
# SUMMARY AND REPORTING
# ============================================

show_system_summary() {
    header "SYSTEM SUMMARY"
    
    info "Kernel Information:"
    indent 1 "Running: $RUNNING_KERNEL"
    if [[ -n "$LATEST_KERNEL" ]]; then
        indent 1 "Latest:  $LATEST_KERNEL"
    fi
    
    echo ""
    info "ZFS Information:"
    if [[ -n "$ZFS_MODULE_VERSION" ]]; then
        indent 1 "Module:   $ZFS_MODULE_VERSION"
    fi
    if [[ -n "$ZFS_USERLAND_VERSION" ]]; then
        indent 1 "Userland: $ZFS_USERLAND_VERSION"
    fi
    
    if [[ "$POOLS_EXIST" = true ]]; then
        echo ""
        info "ZFS Pools:"
        zpool list 2>/dev/null || true
        
        echo ""
        info "ZFS Datasets (mounted):"
        zfs list -o name,used,avail,refer,mountpoint 2>/dev/null || true
    fi
    
    echo ""
    info "Configuration:"
    indent 1 "Primary Pool: ${POOL_NAME:-not configured}"
    indent 1 "BE Root: ${BE_ROOT}"
    indent 1 "Boot Method: $([ "$ZFSBOOTMENU" = true ] && echo "ZFSBootMenu" || echo "Traditional")"
    if [[ "$ZFSBOOTMENU" = true ]]; then
        indent 1 "ESP Mount: $ESP_MOUNT"
    fi
    indent 1 "Encryption: $([ "$ENCRYPTION" = true ] && echo "Enabled" || echo "Disabled")"
    if [[ -n "$SWAP_SIZE" ]]; then
        indent 1 "Swap Size: $SWAP_SIZE"
    fi
}

show_recommendations() {
    header "RECOMMENDATIONS & NEXT STEPS"
    
    if [[ $CRITICAL_FAILURES -gt 0 ]]; then
        error "CRITICAL ISSUES DETECTED - SYSTEM MAY NOT BOOT PROPERLY"
        echo ""
        info "Critical issues must be resolved before rebooting:"
        indent 1 "1. Review the errors marked with ${SYMBOL_ERROR}${SYMBOL_ERROR} above"
        indent 1 "2. Follow the suggested fixes"
        indent 1 "3. Re-run this verification script"
        echo ""
    fi
    
    if [[ "$KERNEL_MISMATCH" = true ]]; then
        warning "Kernel Update Detected"
        indent 1 "A newer kernel is installed but not running"
        indent 1 "Recommendation: Reboot to activate the new kernel"
        echo ""
    fi
    
    if [[ $CHECKS_WARNED -gt 0 ]]; then
        info "Warnings Detected"
        indent 1 "Review warnings marked with ${SYMBOL_WARNING} above"
        indent 1 "These are not critical but should be addressed"
        echo ""
    fi
    
    if [[ $CHECKS_FAILED -eq 0 && $CRITICAL_FAILURES -eq 0 ]]; then
        success "ALL CHECKS PASSED"
        echo ""
        info "System appears to be properly configured and ready to boot"
        echo ""
        
        if [[ "$KERNEL_MISMATCH" = true ]]; then
            info "Safe to reboot to activate new kernel"
        fi
    fi
    
    info "Maintenance Recommendations:"
    bullet "Create regular snapshots: zfs snapshot <pool>/<dataset>@\$(date +%Y%m%d)"
    bullet "Monitor pool health: zpool status -v"
    bullet "Check for pool errors: zpool events -v"
    bullet "Update ZFS properties as needed"
    echo ""
    info "Full verification log saved to: $LOG_FILE"
}

# ============================================
# MAIN EXECUTION
# ============================================

main() {
    require_root
    
    header "ZFS POST-UPDATE VERIFICATION SCRIPT"
    info "Started: $(timestamp_iso)"
    echo ""
    
    # Detect system configuration
    detect_system_config
    
    # Run all verification checks
    verify_kernel_version
    verify_zfs_module
    verify_zfs_userland
    verify_hostid
    verify_encryption_keys
    verify_zfs_services
    verify_dracut_configuration
    verify_pool_configuration
    verify_pool_status
    verify_dataset_structure
    verify_pool_import
    verify_datasets_mounted
    verify_initramfs
    verify_zfsbootmenu
    verify_fstab
    test_basic_zfs_operations
    check_rollback_capability
    
    # Show summary and recommendations
    show_system_summary
    show_recommendations
    
    # Final status
    header "VERIFICATION COMPLETE"
    info "Results:"
    indent 1 "${COLOR_SUCCESS}${SYMBOL_SUCCESS} Passed: $CHECKS_PASSED${NC}"
    if [[ $CHECKS_WARNED -gt 0 ]]; then
        indent 1 "${COLOR_WARNING}${SYMBOL_WARNING} Warnings: $CHECKS_WARNED${NC}"
    fi
    if [[ $CHECKS_FAILED -gt 0 ]]; then
        indent 1 "${COLOR_ERROR}${SYMBOL_ERROR} Failed: $CHECKS_FAILED${NC}"
    fi
    if [[ $CRITICAL_FAILURES -gt 0 ]]; then
        indent 1 "${COLOR_ERROR}${SYMBOL_ERROR}${SYMBOL_ERROR} Critical: $CRITICAL_FAILURES${NC}"
    fi
    
    echo ""
    info "Completed: $(timestamp_iso)"
    
    # Exit with appropriate code
    if [[ $CRITICAL_FAILURES -gt 0 ]]; then
        exit 2
    elif [[ $CHECKS_FAILED -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

# Run main function
main "$@"
