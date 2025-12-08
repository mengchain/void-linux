#!/usr/bin/env bash
# filepath: zfs-health-check.sh
# ZFS Health Check and Auto-Repair Script for Void Linux
# Version: 2.1
# Compatible with voidZFSInstallRepo.sh installation

set -euo pipefail

# ============================================
# Load Common Library
# ============================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${LIB_DIR:-/usr/local/lib/zfs-scripts}"

# Try to source common.sh from standard location
if [[ -f "$LIB_DIR/common.sh" ]]; then
    source "$LIB_DIR/common.sh"
# Fallback: try relative to script location (for development)
elif [[ -f "$SCRIPT_DIR/../lib/common.sh" ]]; then
    source "$SCRIPT_DIR/../lib/common.sh"
# Fallback: try same directory as script
elif [[ -f "$SCRIPT_DIR/common.sh" ]]; then
    source "$SCRIPT_DIR/common.sh"
else
    echo "ERROR: Cannot find common.sh library"
    echo "Please install common.sh to: $LIB_DIR/"
    exit 1
fi

# ============================================
# Script Configuration
# ============================================
LOG_FILE="/var/log/zfs_health_check.log"
SCRIPT_NAME="ZFS Health Check and Auto-Repair"
SCRIPT_VERSION="2.1"

# Redirect all output to both console and log file
exec &> >(tee -a "$LOG_FILE")

# Global flags
DRY_RUN=false
AUTO_REPAIR=false
FORCE_REPAIR=false
FORCE_REBUILD=false

# ============================================
# Path Constants (MUST match voidZFSInstallRepo.sh)
# ============================================
# ZFS Core Files
readonly ZFS_KEY_FILE="/etc/zfs/zroot.key"
readonly ZFS_CACHE_FILE="/etc/zfs/zpool.cache"
readonly HOSTID_FILE="/etc/hostid"
readonly KEY_BACKUP_DIR="/root/zfs-keys"

# ZFSBootMenu Paths
readonly ZBM_CONFIG="/etc/zfsbootmenu/config.yaml"
readonly ZBM_DRACUT_DIR="/etc/zfsbootmenu/dracut.conf.d"
readonly ZBM_KEYMAP_CONF="$ZBM_DRACUT_DIR/keymap.conf"
readonly ESP_MOUNT="/boot/efi"
readonly ZBM_EFI_DIR="$ESP_MOUNT/EFI/ZBM"
readonly ZBM_EFI_IMAGE="$ZBM_EFI_DIR/vmlinuz.efi"
readonly ZBM_EFI_BACKUP="$ZBM_EFI_DIR/vmlinuz-backup.efi"

# Dracut Configuration Paths
readonly DRACUT_ZFS_CONF="/etc/dracut.conf.d/zfs.conf"
readonly DRACUT_MAIN_CONF="/etc/dracut.conf"

# Boot Paths
readonly BOOT_DIR="/boot"
readonly CMDLINE_DIR="/etc/cmdline.d"
readonly CMDLINE_KEYMAP="$CMDLINE_DIR/keymap.conf"

# Issue counters
TOTAL_ISSUES_FOUND=0
TOTAL_ISSUES_FIXED=0

# ============================================
# Enhanced Repair Functions
# ============================================
print_repair() {
    if [[ "$USE_COLORS" == "true" ]]; then
        echo -e "${CYAN}🔧 REPAIR: $*${NC}"
    else
        echo "REPAIR: $*"
    fi
    
    [[ "$LOG_FILE_WRITABLE" == "true" ]] && echo "REPAIR: $*" >> "$LOG_FILE" 2>/dev/null
}

confirm_repair() {
    local action="$1"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "DRY RUN: Would perform: $action"
        return 1
    fi
    
    if [[ "$AUTO_REPAIR" == true ]] || [[ "$FORCE_REPAIR" == true ]]; then
        print_repair "Auto-repair enabled: $action"
        return 0
    fi
    
    ask_yes_no "Perform repair: $action?" "n"
}

execute_repair() {
    local description="$1"
    shift
    local cmd=("$@")
    
    if [[ "$DRY_RUN" == true ]]; then
        info "DRY RUN: Would execute: ${cmd[*]}"
        return 0
    fi
    
    print_repair "Executing: $description"
    debug "Command: ${cmd[*]}"
    
    if safe_run "${cmd[@]}"; then
        success "$description completed"
        TOTAL_ISSUES_FIXED=$((TOTAL_ISSUES_FIXED + 1))
        return 0
    else
        error "$description failed"
        return 1
    fi
}

record_issue() {
    TOTAL_ISSUES_FOUND=$((TOTAL_ISSUES_FOUND + 1))
}

# ============================================
# ZFS Availability Check
# ============================================
check_zfs_availability() {
    header "Checking ZFS Availability"
    
    local issues_found=0
    
    # Check if ZFS module is loaded
    if ! lsmod 2>/dev/null | grep -q "^zfs "; then
        warning "ZFS kernel module is not loaded"
        record_issue
        
        if confirm_repair "Load ZFS kernel module"; then
            if execute_repair "Loading ZFS module" modprobe zfs; then
                issues_found=$((issues_found - 1))
            fi
        fi
    else
        success "ZFS kernel module is loaded"
    fi
    
    # Check ZFS commands availability
    local missing_commands=()
    for cmd in zpool zfs; do
        if ! command_exists "$cmd"; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        error "Missing ZFS commands: ${missing_commands[*]}"
        error "Please install ZFS userland tools: xbps-install -S zfs"
        return 1
    else
        success "ZFS commands are available"
    fi
    
    # Check ZFS version
    local zfs_version
    zfs_version=$(zfs version 2>/dev/null | head -1 || echo "unknown")
    info "ZFS version: $zfs_version"
    
    return "$issues_found"
}

# ============================================
# Host ID Check
# ============================================
check_and_repair_hostid() {
    header "Checking ZFS Host ID"
    
    local issues_found=0
    
    # Check if hostid file exists
    if [[ ! -f "$HOSTID_FILE" ]]; then
        warning "Host ID file is missing: $HOSTID_FILE"
        record_issue
        
        if confirm_repair "Generate new host ID"; then
            if execute_repair "Generating host ID" zgenhostid; then
                issues_found=$((issues_found - 1))
            fi
        fi
    else
        success "Host ID file exists"
        
        # Check hostid file size (should be exactly 4 bytes)
        local hostid_size
        hostid_size=$(stat -c %s "$HOSTID_FILE" 2>/dev/null || echo "0")
        
        if [[ "$hostid_size" -ne 4 ]]; then
            warning "Host ID file has incorrect size: $hostid_size bytes (expected 4)"
            record_issue
            
            if confirm_repair "Regenerate corrupted host ID"; then
                local backup_file="${HOSTID_FILE}.corrupt.$(date +%Y%m%d-%H%M%S)"
                cp "$HOSTID_FILE" "$backup_file" 2>/dev/null || true
                
                if execute_repair "Regenerating host ID" zgenhostid -f; then
                    success "Host ID regenerated successfully"
                    info "Corrupted hostid backed up to: $backup_file"
                    issues_found=$((issues_found - 1))
                fi
            fi
        else
            success "Host ID file has correct size"
        fi
        
        # Verify hostid consistency
        local hostid_cmd hostid_file
        hostid_cmd=$(hostid 2>/dev/null || echo "error")
        hostid_file=$(od -An -tx4 "$HOSTID_FILE" 2>/dev/null | tr -d ' \n' || echo "error")
        
        info "hostid command: $hostid_cmd"
        info "hostid file:    $hostid_file"
        
        if [[ "$hostid_cmd" != "$hostid_file" ]]; then
            warning "Host ID mismatch between command and file"
            record_issue
        else
            success "Host ID is consistent"
        fi
    fi
    
    return "$issues_found"
}

# ============================================
# ZPool Cache Check
# ============================================
check_and_repair_zpool_cache() {
    header "Checking ZFS Pool Cache"
    
    local issues_found=0
    
    # Check if cache file exists
    if [[ ! -f "$ZFS_CACHE_FILE" ]]; then
        warning "zpool.cache is missing"
        record_issue
        
        # Check if any pools are imported
        local pools
        pools=$(zpool list -H -o name 2>/dev/null || echo "")
        
        if [[ -n "$pools" ]]; then
            info "Pools are imported, regenerating cache"
            
            if confirm_repair "Regenerate zpool.cache"; then
                while IFS= read -r pool; do
                    [[ -z "$pool" ]] && continue
                    if execute_repair "Setting cachefile for $pool" zpool set cachefile="$ZFS_CACHE_FILE" "$pool"; then
                        issues_found=$((issues_found - 1))
                    fi
                done <<< "$pools"
                
                sleep 2
                
                if [[ -f "$ZFS_CACHE_FILE" ]]; then
                    success "zpool.cache regenerated successfully"
                else
                    error "Failed to regenerate zpool.cache"
                fi
            fi
        else
            info "No pools imported, cache will be created on next import"
        fi
    else
        success "zpool.cache exists"
        
        # Check cache file size
        local cache_size
        cache_size=$(stat -c %s "$ZFS_CACHE_FILE" 2>/dev/null || echo "0")
        
        if [[ "$cache_size" -lt 100 ]]; then
            warning "zpool.cache seems unusually small ($cache_size bytes)"
            record_issue
        else
            success "zpool.cache has reasonable size ($cache_size bytes)"
        fi
        
        # Check cache permissions
        local cache_perms
        cache_perms=$(stat -c %a "$ZFS_CACHE_FILE" 2>/dev/null || echo "0")
        
        if [[ "$cache_perms" != "644" ]]; then
            warning "zpool.cache has incorrect permissions: $cache_perms"
            record_issue
            
            if confirm_repair "Fix zpool.cache permissions to 644"; then
                if execute_repair "Fixing cache permissions" chmod 644 "$ZFS_CACHE_FILE"; then
                    issues_found=$((issues_found - 1))
                fi
            fi
        else
            success "zpool.cache has correct permissions"
        fi
    fi
    
    return "$issues_found"
}

# ============================================
# Pool Health Check
# ============================================
check_pool_health() {
    header "Checking ZFS Pool Health"
    
    local issues_found=0
    
    local pools
    pools=$(zpool list -H -o name 2>/dev/null || echo "")
    
    if [[ -z "$pools" ]]; then
        warning "No ZFS pools found"
        return 0
    fi
    
    while IFS= read -r pool; do
        [[ -z "$pool" ]] && continue
        
        subheader "Pool: $pool"
        
        local pool_health
        pool_health=$(zpool list -H -o health "$pool" 2>/dev/null || echo "UNKNOWN")
        
        case "$pool_health" in
            ONLINE)
                success "Pool $pool is healthy: $pool_health"
                ;;
            DEGRADED)
                warning "Pool $pool is degraded"
                record_issue
                zpool status "$pool"
                
                if confirm_repair "Attempt to clear errors on $pool"; then
                    if execute_repair "Clearing pool errors" zpool clear "$pool"; then
                        pool_health=$(zpool list -H -o health "$pool" 2>/dev/null || echo "UNKNOWN")
                        if [[ "$pool_health" == "ONLINE" ]]; then
                            issues_found=$((issues_found - 1))
                        fi
                    fi
                fi
                ;;
            FAULTED|UNAVAIL)
                error "Pool $pool is in critical state: $pool_health"
                record_issue
                zpool status "$pool"
                error "Manual intervention required for $pool"
                ;;
            *)
                warning "Pool $pool has unknown health status: $pool_health"
                record_issue
                ;;
        esac
        
        # Check for errors
        if zpool status "$pool" 2>/dev/null | grep -q "errors: No known data errors"; then
            success "Pool $pool has no data errors"
        else
            warning "Pool $pool may have errors"
            record_issue
            zpool status "$pool" | grep -A 3 "errors:" || true
        fi
        
        # Check pool capacity
        local pool_capacity
        pool_capacity=$(zpool list -H -o capacity "$pool" 2>/dev/null | tr -d '%' || echo "0")
        
        info "Pool capacity: ${pool_capacity}%"
        
        if [[ $pool_capacity -gt 90 ]]; then
            error "Pool $pool is over 90% full!"
            record_issue
        elif [[ $pool_capacity -gt 80 ]]; then
            warning "Pool $pool is over 80% full"
            record_issue
        fi
        
        # Check pool fragmentation
        local pool_frag
        pool_frag=$(zpool list -H -o frag "$pool" 2>/dev/null | tr -d '%' || echo "0")
        
        if [[ $pool_frag -gt 50 ]]; then
            warning "Pool $pool has high fragmentation: ${pool_frag}%"
            info "Consider running defragmentation (ZFS 2.2+)"
        fi
        
    done <<< "$pools"
    
    return "$issues_found"
}

# ============================================
# Dataset Health Check
# ============================================
check_dataset_health() {
    header "Checking ZFS Dataset Health"
    
    local issues_found=0
    
    local datasets
    datasets=$(zfs list -H -o name 2>/dev/null || echo "")
    
    if [[ -z "$datasets" ]]; then
        warning "No ZFS datasets found"
        return 0
    fi
    
    info "Found $(echo "$datasets" | wc -l) dataset(s)"
    
    while IFS= read -r dataset; do
        [[ -z "$dataset" ]] && continue
        
        local mounted mountpoint compression canmount
        mounted=$(zfs get -H -o value mounted "$dataset" 2>/dev/null || echo "unknown")
        mountpoint=$(zfs get -H -o value mountpoint "$dataset" 2>/dev/null || echo "none")
        compression=$(zfs get -H -o value compression "$dataset" 2>/dev/null || echo "off")
        canmount=$(zfs get -H -o value canmount "$dataset" 2>/dev/null || echo "on")
        
        if [[ "$canmount" == "on" ]] && [[ "$mountpoint" != "none" ]] && [[ "$mountpoint" != "-" ]] && [[ "$mountpoint" != "legacy" ]]; then
            if [[ "$mounted" == "yes" ]]; then
                if mountpoint -q "$mountpoint" 2>/dev/null; then
                    print_status "ok" "Dataset $dataset mounted at $mountpoint"
                else
                    warning "Dataset $dataset reports mounted but mountpoint not found"
                    record_issue
                    
                    if confirm_repair "Remount dataset $dataset"; then
                        if execute_repair "Remounting $dataset" zfs mount "$dataset"; then
                            issues_found=$((issues_found - 1))
                        fi
                    fi
                fi
            else
                warning "Dataset $dataset is not mounted (mountpoint: $mountpoint)"
                record_issue
                
                if confirm_repair "Mount dataset $dataset"; then
                    if execute_repair "Mounting $dataset" zfs mount "$dataset"; then
                        issues_found=$((issues_found - 1))
                    fi
                fi
            fi
        fi
        
        local snapshot_count
        snapshot_count=$(zfs list -t snapshot -H -o name -r "$dataset" 2>/dev/null | wc -l || echo "0")
        
        if [[ $snapshot_count -gt 0 ]]; then
            debug "Dataset $dataset has $snapshot_count snapshot(s)"
        fi
        
    done <<< "$datasets"
    
    return "$issues_found"
}

# ============================================
# Encryption Key Check
# ============================================
check_encryption_keys() {
    header "Checking ZFS Encryption Keys"
    
    local issues_found=0
    
    # Check for encryption key file
    if [[ ! -f "$ZFS_KEY_FILE" ]]; then
        info "No ZFS encryption key found (encryption may not be in use)"
        return 0
    fi
    
    success "ZFS encryption key exists: $ZFS_KEY_FILE"
    
    # Check key permissions
    local key_perms
    key_perms=$(stat -c %a "$ZFS_KEY_FILE" 2>/dev/null || echo "0")
    
    if [[ "$key_perms" != "400" ]] && [[ "$key_perms" != "000" ]]; then
        warning "Encryption key has insecure permissions: $key_perms"
        record_issue
        
        if confirm_repair "Fix encryption key permissions to 400"; then
            if execute_repair "Fixing key permissions" chmod 400 "$ZFS_KEY_FILE"; then
                issues_found=$((issues_found - 1))
            fi
        fi
    else
        success "Encryption key has secure permissions: $key_perms"
    fi
    
    # Check key ownership
    local key_owner
    key_owner=$(stat -c %U:%G "$ZFS_KEY_FILE" 2>/dev/null || echo "unknown")
    
    if [[ "$key_owner" != "root:root" ]]; then
        warning "Encryption key has incorrect ownership: $key_owner"
        record_issue
        
        if confirm_repair "Fix encryption key ownership to root:root"; then
            if execute_repair "Fixing key ownership" chown root:root "$ZFS_KEY_FILE"; then
                issues_found=$((issues_found - 1))
            fi
        fi
    else
        success "Encryption key has correct ownership"
    fi
    
    # Check key backup
    if [[ -d "$KEY_BACKUP_DIR" ]]; then
        success "Key backup directory exists: $KEY_BACKUP_DIR"
        
        if [[ -f "$KEY_BACKUP_DIR/zroot.key" ]]; then
            success "Key backup exists"
            
            # Verify backup matches original
            if ! diff "$ZFS_KEY_FILE" "$KEY_BACKUP_DIR/zroot.key" &>/dev/null; then
                warning "Key backup does not match original key"
                record_issue
                
                if confirm_repair "Update key backup"; then
                    if execute_repair "Updating key backup" install -m 400 "$ZFS_KEY_FILE" "$KEY_BACKUP_DIR/zroot.key"; then
                        issues_found=$((issues_found - 1))
                    fi
                fi
            else
                success "Key backup matches original"
            fi
        else
            warning "Key backup not found in $KEY_BACKUP_DIR"
            record_issue
            
            if confirm_repair "Create key backup"; then
                if execute_repair "Creating key backup" install -m 400 "$ZFS_KEY_FILE" "$KEY_BACKUP_DIR/zroot.key"; then
                    issues_found=$((issues_found - 1))
                fi
            fi
        fi
    else
        warning "Key backup directory not found: $KEY_BACKUP_DIR"
        record_issue
    fi
    
    # Check encrypted datasets
    local encrypted_datasets
    encrypted_datasets=$(zfs get -H -o name,value encryption 2>/dev/null | grep -v "off$" | awk '{print $1}' || echo "")
    
    if [[ -n "$encrypted_datasets" ]]; then
        info "Encrypted datasets found:"
        while IFS= read -r dataset; do
            [[ -z "$dataset" ]] && continue
            bullet "$dataset"
            
            local key_status
            key_status=$(zfs get -H -o value keystatus "$dataset" 2>/dev/null || echo "unknown")
            
            if [[ "$key_status" == "available" ]]; then
                print_status "ok" "Encryption key loaded"
            else
                warning "Encryption key not loaded (status: $key_status)"
                record_issue
                
                if confirm_repair "Load encryption key for $dataset"; then
                    if execute_repair "Loading key for $dataset" zfs load-key "$dataset"; then
                        issues_found=$((issues_found - 1))
                    fi
                fi
            fi
        done <<< "$encrypted_datasets"
    else
        info "No encrypted datasets found"
    fi
    
    return "$issues_found"
}

# ============================================
# Dracut Configuration Check
# ============================================
check_dracut_config() {
    header "Checking Dracut Configuration"
    
    local issues_found=0
    
    # Check main dracut ZFS config
    if [[ ! -f "$DRACUT_ZFS_CONF" ]]; then
        warning "Dracut ZFS config not found: $DRACUT_ZFS_CONF"
        record_issue
        
        if confirm_repair "Create Dracut ZFS configuration"; then
            mkdir -p "$(dirname "$DRACUT_ZFS_CONF")"
            
            cat > "$DRACUT_ZFS_CONF" <<'EOF'
hostonly="yes"
hostonly_cmdline="no"
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs resume "
install_items+=" /etc/zfs/zroot.key /etc/hostid "
force_drivers+=" zfs "
filesystems+=" zfs "
EOF
            
            if [[ -f "$DRACUT_ZFS_CONF" ]]; then
                success "Dracut ZFS config created"
                TOTAL_ISSUES_FIXED=$((TOTAL_ISSUES_FIXED + 1))
                issues_found=$((issues_found - 1))
            fi
        fi
    else
        success "Dracut ZFS config exists"
        
        # Verify critical options
        local missing_options=()
        
        if ! grep -q "add_dracutmodules.*zfs" "$DRACUT_ZFS_CONF"; then
            missing_options+=("add_dracutmodules+=' zfs '")
        fi
        
        if ! grep -q "install_items.*zroot.key" "$DRACUT_ZFS_CONF" && [[ -f "$ZFS_KEY_FILE" ]]; then
            missing_options+=("install_items+=' /etc/zfs/zroot.key '")
        fi
        
        if ! grep -q "install_items.*hostid" "$DRACUT_ZFS_CONF"; then
            missing_options+=("install_items+=' /etc/hostid '")
        fi
        
        if [[ ${#missing_options[@]} -gt 0 ]]; then
            warning "Dracut ZFS config is missing critical options:"
            for opt in "${missing_options[@]}"; do
                bullet "$opt"
            done
            record_issue
        else
            success "Dracut ZFS config has all critical options"
        fi
    fi
    
    # Check main dracut config
    if [[ ! -f "$DRACUT_MAIN_CONF" ]]; then
        warning "Main dracut config not found: $DRACUT_MAIN_CONF"
        record_issue
    else
        success "Main dracut config exists"
    fi
    
    return "$issues_found"
}

# ============================================
# Initramfs Check
# ============================================
check_initramfs() {
    header "Checking Initramfs"
    
    local issues_found=0
    
    local current_kernel
    current_kernel=$(uname -r)
    local initramfs_path="$BOOT_DIR/initramfs-${current_kernel}.img"
    
    if [[ ! -f "$initramfs_path" ]]; then
        error "Initramfs not found for current kernel: $initramfs_path"
        record_issue
        
        if confirm_repair "Rebuild initramfs for kernel $current_kernel"; then
            if execute_repair "Building initramfs" dracut -f --kver "$current_kernel"; then
                issues_found=$((issues_found - 1))
            fi
        fi
    else
        success "Initramfs exists for current kernel"
        
        local initramfs_mtime current_time age_days
        initramfs_mtime=$(stat -c %Y "$initramfs_path" 2>/dev/null || echo "0")
        current_time=$(date +%s)
        age_days=$(( (current_time - initramfs_mtime) / 86400 ))
        
        info "Initramfs age: $age_days days"
        
        if [[ $age_days -gt 90 ]]; then
            warning "Initramfs is older than 90 days"
            
            if [[ "$FORCE_REBUILD" == true ]]; then
                if execute_repair "Force rebuilding initramfs" dracut -f --kver "$current_kernel"; then
                    success "Initramfs rebuilt successfully"
                fi
            fi
        fi
        
        # Check initramfs contents
        if command_exists lsinitrd; then
            info "Checking initramfs contents..."
            
            local has_zfs=false has_key=false has_hostid=false
            
            if lsinitrd "$initramfs_path" 2>/dev/null | grep -q "zfs.ko"; then
                has_zfs=true
                success "ZFS module found in initramfs"
            else
                error "ZFS module NOT found in initramfs"
                record_issue
            fi
            
            if lsinitrd "$initramfs_path" 2>/dev/null | grep -q "zroot.key"; then
                has_key=true
                success "ZFS encryption key found in initramfs"
            elif [[ -f "$ZFS_KEY_FILE" ]]; then
                warning "ZFS encryption key exists but not in initramfs"
                record_issue
            fi
            
            if lsinitrd "$initramfs_path" 2>/dev/null | grep -qE "etc/hostid|hostid"; then
                has_hostid=true
                success "Host ID found in initramfs"
            else
                warning "Host ID not found in initramfs"
                record_issue
            fi
            
            if [[ "$has_zfs" == false ]] || [[ "$has_hostid" == false ]] || ( [[ -f "$ZFS_KEY_FILE" ]] && [[ "$has_key" == false ]] ); then
                if confirm_repair "Rebuild initramfs to include missing components"; then
                    if execute_repair "Rebuilding initramfs" dracut -f --kver "$current_kernel"; then
                        issues_found=$((issues_found - 1))
                    fi
                fi
            fi
        else
            info "lsinitrd not available, skipping contents check"
        fi
    fi
    
    return "$issues_found"
}

# ============================================
# ZFSBootMenu Check
# ============================================
check_zfsbootmenu() {
    header "Checking ZFSBootMenu"
    
    local issues_found=0
    
    if ! command_exists generate-zbm; then
        info "ZFSBootMenu not installed (system may use traditional bootloader)"
        return 0
    fi
    
    success "ZFSBootMenu is installed"
    
    # Check ZBM configuration
    if [[ ! -f "$ZBM_CONFIG" ]]; then
        error "ZFSBootMenu configuration not found: $ZBM_CONFIG"
        record_issue
        return 1
    fi
    
    success "ZFSBootMenu configuration found"
    
    # Check ZBM dracut configuration
    if [[ ! -d "$ZBM_DRACUT_DIR" ]]; then
        warning "ZBM dracut config directory not found: $ZBM_DRACUT_DIR"
        record_issue
    else
        success "ZBM dracut config directory exists"
        
        # Check keymap config
        if [[ ! -f "$ZBM_KEYMAP_CONF" ]]; then
            warning "ZBM keymap config not found: $ZBM_KEYMAP_CONF"
            record_issue
        else
            success "ZBM keymap config exists"
        fi
    fi
    
    # Check cmdline.d directory
    if [[ ! -d "$CMDLINE_DIR" ]]; then
        warning "Kernel cmdline directory not found: $CMDLINE_DIR"
        record_issue
    else
        success "Kernel cmdline directory exists"
        
        # Check keymap cmdline config
        if [[ ! -f "$CMDLINE_KEYMAP" ]]; then
            warning "Keymap cmdline config not found: $CMDLINE_KEYMAP"
            record_issue
        else
            success "Keymap cmdline config exists"
        fi
    fi
    
    # Check ESP mount
    if [[ ! -d "$ESP_MOUNT" ]]; then
        error "ESP mount point not found: $ESP_MOUNT"
        record_issue
        return 1
    fi
    
    if ! findmnt "$ESP_MOUNT" &>/dev/null; then
        warning "ESP is not mounted: $ESP_MOUNT"
        record_issue
        
        if confirm_repair "Mount ESP partition"; then
            local esp_part
            esp_part=$(blkid -t LABEL=EFI -o device 2>/dev/null | head -1 || echo "")
            
            if [[ -n "$esp_part" ]]; then
                if execute_repair "Mounting ESP" mount "$esp_part" "$ESP_MOUNT"; then
                    issues_found=$((issues_found - 1))
                fi
            else
                error "Could not find ESP partition"
            fi
        fi
    else
        success "ESP is mounted"
    fi
    
    # Check for ZBM EFI files
    if [[ ! -f "$ZBM_EFI_IMAGE" ]]; then
        error "ZFSBootMenu EFI image not found: $ZBM_EFI_IMAGE"
        record_issue
        
        if confirm_repair "Regenerate ZFSBootMenu EFI image"; then
            if execute_repair "Generating ZFSBootMenu" generate-zbm; then
                if [[ -f "$ZBM_EFI_IMAGE" ]]; then
                    issues_found=$((issues_found - 1))
                fi
            fi
        fi
    else
        success "ZFSBootMenu EFI image found"
        
        local zbm_mtime current_time zbm_age_days
        zbm_mtime=$(stat -c %Y "$ZBM_EFI_IMAGE" 2>/dev/null || echo "0")
        current_time=$(date +%s)
        zbm_age_days=$(( (current_time - zbm_mtime) / 86400 ))
        
        info "ZFSBootMenu image age: $zbm_age_days days"
        
        if [[ $zbm_age_days -gt 90 ]]; then
            warning "ZFSBootMenu image is older than 90 days"
            
            if [[ "$FORCE_REBUILD" == true ]]; then
                if execute_repair "Force rebuilding ZFSBootMenu" generate-zbm; then
                    success "ZFSBootMenu rebuilt successfully"
                fi
            fi
        fi
        
        # Check for backup
        if [[ ! -f "$ZBM_EFI_BACKUP" ]]; then
            warning "ZFSBootMenu backup image not found"
            
            if confirm_repair "Create ZFSBootMenu backup"; then
                if execute_repair "Creating backup" cp "$ZBM_EFI_IMAGE" "$ZBM_EFI_BACKUP"; then
                    success "Backup created successfully"
                fi
            fi
        else
            success "ZFSBootMenu backup exists"
        fi
    fi
    
    # Check EFI boot entries
    if command_exists efibootmgr; then
        if efibootmgr 2>/dev/null | grep -qi "zfsbootmenu\|ZBM"; then
            success "ZFSBootMenu found in EFI boot entries"
        else
            warning "ZFSBootMenu not found in EFI boot entries"
            record_issue
            info "You may need to manually create EFI boot entry"
        fi
    fi
    
    return "$issues_found"
}

# ============================================
# Scrub Status Check
# ============================================
check_scrub_status() {
    header "Checking ZFS Scrub Status"
    
    local issues_found=0
    
    local pools
    pools=$(zpool list -H -o name 2>/dev/null || echo "")
    
    if [[ -z "$pools" ]]; then
        info "No ZFS pools found"
        return 0
    fi
    
    while IFS= read -r pool; do
        [[ -z "$pool" ]] && continue
        
        subheader "Scrub status for pool: $pool"
        
        local scrub_status
        scrub_status=$(zpool status "$pool" 2>/dev/null || echo "")
        
        if echo "$scrub_status" | grep -q "scrub in progress"; then
            info "Scrub in progress for pool $pool"
            echo "$scrub_status" | grep -A 5 "scan:"
        elif echo "$scrub_status" | grep -q "scrub repaired"; then
            local scrub_date
            scrub_date=$(echo "$scrub_status" | grep "scrub repaired" | sed -n 's/.*on \(.*\)/\1/p' || echo "unknown")
            success "Last scrub completed: $scrub_date"
            
            if echo "$scrub_status" | grep -q "days old"; then
                local scrub_age
                scrub_age=$(echo "$scrub_status" | grep -oP '\d+(?= days old)' || echo "0")
                if [[ $scrub_age -gt 30 ]]; then
                    warning "Last scrub is $scrub_age days old (recommend monthly scrubs)"
                fi
            fi
        elif echo "$scrub_status" | grep -q "none requested"; then
            warning "No scrub has ever been performed on pool $pool"
            record_issue
            
            if confirm_repair "Start scrub on pool $pool"; then
                if execute_repair "Starting scrub" zpool scrub "$pool"; then
                    success "Scrub started on pool $pool"
                    info "This will run in the background"
                    issues_found=$((issues_found - 1))
                fi
            fi
        else
            info "Unable to determine scrub status for pool $pool"
        fi
        
    done <<< "$pools"
    
    return "$issues_found"
}

# ============================================
# ARC (Cache) Health Check
# ============================================
check_arc_health() {
    header "Checking ZFS ARC (Cache) Health"
    
    if ! command_exists arcstat; then
        info "arcstat not available, skipping ARC health check"
        return 0
    fi
    
    info "ARC Statistics:"
    arcstat 1 1 2>/dev/null || {
        warning "Could not retrieve ARC statistics"
        return 0
    }
    
    if [[ -f /proc/spl/kstat/zfs/arcstats ]]; then
        local arc_size arc_max
        arc_size=$(grep "^size " /proc/spl/kstat/zfs/arcstats | awk '{print $3}')
        arc_max=$(grep "^c_max " /proc/spl/kstat/zfs/arcstats | awk '{print $3}')
        
        if [[ -n "$arc_size" ]] && [[ -n "$arc_max" ]]; then
            local arc_usage_pct=$((arc_size * 100 / arc_max))
            info "ARC usage: ${arc_usage_pct}%"
            
            if [[ $arc_usage_pct -gt 95 ]]; then
                warning "ARC is at high utilization (${arc_usage_pct}%)"
            fi
        fi
    fi
    
    success "ARC health check completed"
    return 0
}

# ============================================
# Display usage
# ============================================
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

$SCRIPT_NAME v$SCRIPT_VERSION

Performs comprehensive health checks on ZFS system and offers repairs.

OPTIONS:
    -d, --dry-run           Show what would be done without making changes
    -a, --auto-repair       Automatically repair issues without prompting
    -f, --force             Force repairs even if not strictly necessary
    -r, --force-rebuild     Force rebuild of initramfs and ZFSBootMenu
    -h, --help              Display this help message

EXAMPLES:
    $0                      Run interactive health check
    $0 --dry-run            Show what would be checked/repaired
    $0 --auto-repair        Automatically repair all detected issues
    $0 -a -r                Auto-repair and force rebuild boot components

EXIT CODES:
    0    All checks passed
    1    Issues found (check log for details)

LOG FILE:
    $LOG_FILE

EOF
    exit 0
}

# ============================================
# Parse command line arguments
# ============================================
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--dry-run)
                DRY_RUN=true
                info "DRY RUN MODE: No changes will be made"
                shift
                ;;
            -a|--auto-repair)
                AUTO_REPAIR=true
                info "AUTO REPAIR MODE: Issues will be repaired automatically"
                shift
                ;;
            -f|--force)
                FORCE_REPAIR=true
                info "FORCE MODE: Repairs will be forced"
                shift
                ;;
            -r|--force-rebuild)
                FORCE_REBUILD=true
                info "FORCE REBUILD MODE: Boot components will be rebuilt"
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                error "Unknown option: $1"
                usage
                ;;
        esac
    done
}

# ============================================
# Main execution
# ============================================
main() {
    header "$SCRIPT_NAME v$SCRIPT_VERSION"
    
    parse_arguments "$@"
    require_root
    
    info "Starting health check at $(date)"
    separator "="
    echo ""
    
    # Run all checks
    check_zfs_availability
    check_and_repair_hostid
    check_and_repair_zpool_cache
    check_pool_health
    check_dataset_health
    check_encryption_keys
    check_dracut_config
    check_initramfs
    check_zfsbootmenu
    check_scrub_status
    check_arc_health
    
    # Summary
    header "Health Check Summary"
    
    echo ""
    info "Issues found: $TOTAL_ISSUES_FOUND"
    info "Issues fixed: $TOTAL_ISSUES_FIXED"
    echo ""
    
    if [[ $TOTAL_ISSUES_FOUND -eq 0 ]]; then
        success "All checks passed! ZFS system is healthy."
        separator "="
        exit 0
    else
        local remaining_issues=$((TOTAL_ISSUES_FOUND - TOTAL_ISSUES_FIXED))
        
        if [[ "$DRY_RUN" == true ]]; then
            warning "DRY RUN: Found $TOTAL_ISSUES_FOUND issue(s) that would be addressed"
        elif [[ $remaining_issues -eq 0 ]]; then
            success "All $TOTAL_ISSUES_FOUND issue(s) were successfully fixed!"
        elif [[ $TOTAL_ISSUES_FIXED -gt 0 ]]; then
            warning "Fixed $TOTAL_ISSUES_FIXED of $TOTAL_ISSUES_FOUND issue(s)"
            warning "$remaining_issues issue(s) require manual intervention"
        else
            warning "Found $TOTAL_ISSUES_FOUND issue(s)"
            info "Run with --auto-repair to automatically fix issues"
            info "Run with --dry-run to see what would be done"
        fi
        
        echo ""
        info "Review the log file for details: $LOG_FILE"
        separator "="
        exit 1
    fi
}

# Run main function
main "$@"
```
