#!/bin/bash
# filepath: zfs-health-check.sh
# ZFS Health Check and Auto-Repair Script for Void Linux
# All variables properly localized
# Compatible with voidZFSInstallRepo.sh installation
# SIGPIPE fixes applied throughout
# Standardized logging functions

set -euo pipefail

# Colors for output - Consistent with other scripts
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[1;94m'      # Light Blue (bright blue)
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Logging (these can remain global)
readonly LOG_FILE="/var/log/zfs_health_check.log"

# Global flags (these are intentionally global)
DRY_RUN=false
AUTO_REPAIR=false
FORCE_REPAIR=false
FORCE_REBUILD=false  # New flag for forcing rebuilds

# Standardized logging functions - UPDATED to match other scripts
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

# Additional helper function for repair actions
print_repair() {
    log "${CYAN}🔧 REPAIR: $1${NC}"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

# Confirm repair action with user
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
    
    read -p "Perform repair: $action? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0
    else
        info "Skipping repair"
        return 1
    fi
}

# Execute repair command with proper logging
execute_repair() {
    local description="$1"
    shift
    local cmd=("$@")
    
    if [[ "$DRY_RUN" == true ]]; then
        info "DRY RUN: Would execute: ${cmd[*]}"
        return 0
    fi
    
    print_repair "Executing: $description"
    log "Command: ${cmd[*]}"
    
    if "${cmd[@]}" >> "$LOG_FILE" 2>&1; then
        success "$description completed"
        return 0
    else
        error "$description failed"
        return 1
    fi
}

# Check if ZFS is available and repair if needed
check_zfs_availability() {
    header "Checking ZFS Availability"
    
    local issues_found=0
    
    # Check if ZFS module is loaded - FIXED SIGPIPE
    local lsmod_output
    lsmod_output=$(lsmod 2>/dev/null || echo "")
    
    if ! echo "$lsmod_output" | grep -q "^zfs "; then
        warning "ZFS kernel module is not loaded"
        issues_found=$((issues_found + 1))
        
        if confirm_repair "Load ZFS kernel module"; then
            if execute_repair "Loading ZFS module" modprobe zfs; then
                success "ZFS module loaded successfully"
                issues_found=$((issues_found - 1))
            fi
        fi
    else
        success "ZFS kernel module is loaded"
    fi
    
    # Check ZFS commands availability
    local missing_commands=()
    for cmd in zpool zfs; do
        if ! command -v "$cmd" &>/dev/null; then
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
    
    return "$issues_found"
}

# Check and fix ZFS hostid only if missing or corrupted (NEVER force)
check_and_repair_hostid() {
    header "Checking ZFS Host ID"
    
    local hostid_issues=0
    
    # Check if hostid file exists
    if [[ ! -f /etc/hostid ]]; then
        warning "Host ID file is missing: /etc/hostid"
        hostid_issues=$((hostid_issues + 1))
        
        if confirm_repair "Generate new host ID"; then
            if execute_repair "Generating host ID" zgenhostid; then
                success "Host ID generated successfully"
                hostid_issues=$((hostid_issues - 1))
            fi
        fi
    else
        success "Host ID file exists"
        
        # Check hostid file size (should be exactly 4 bytes)
        local hostid_size
        hostid_size=$(stat -c %s /etc/hostid 2>/dev/null || echo "0")
        
        if [[ "$hostid_size" -ne 4 ]]; then
            warning "Host ID file has incorrect size: $hostid_size bytes (expected 4)"
            hostid_issues=$((hostid_issues + 1))
            
            if confirm_repair "Regenerate corrupted host ID"; then
                # Backup corrupted file
                local backup_file="/etc/hostid.corrupt.$(date +%Y%m%d-%H%M%S)"
                cp /etc/hostid "$backup_file" 2>/dev/null || true
                
                if execute_repair "Regenerating host ID" zgenhostid -f; then
                    success "Host ID regenerated successfully"
                    info "Corrupted hostid backed up to: $backup_file"
                    hostid_issues=$((hostid_issues - 1))
                fi
            fi
        else
            success "Host ID file has correct size"
        fi
        
        # Verify hostid consistency
        local hostid_cmd hostid_file
        hostid_cmd=$(hostid 2>/dev/null || echo "error")
        hostid_file=$(od -An -tx4 /etc/hostid 2>/dev/null | tr -d ' \n' || echo "error")
        
        info "hostid command: $hostid_cmd"
        info "hostid file:    $hostid_file"
        
        if [[ "$hostid_cmd" != "$hostid_file" ]]; then
            warning "Host ID mismatch between command and file"
            hostid_issues=$((hostid_issues + 1))
        else
            success "Host ID is consistent"
        fi
    fi
    
    return "$hostid_issues"
}

# Check and repair zpool.cache
check_and_repair_zpool_cache() {
    header "Checking ZFS Pool Cache"
    
    local cache_issues=0
    
    # Check if cache file exists
    if [[ ! -f /etc/zfs/zpool.cache ]]; then
        warning "zpool.cache is missing"
        cache_issues=$((cache_issues + 1))
        
        # Check if any pools are imported - FIXED SIGPIPE
        local pools
        pools=$(zpool list -H -o name 2>/dev/null || echo "")
        
        if [[ -n "$pools" ]]; then
            info "Pools are imported, regenerating cache"
            
            if confirm_repair "Regenerate zpool.cache"; then
                if execute_repair "Setting cachefile property" zpool set cachefile=/etc/zfs/zpool.cache zroot; then
                    sleep 2
                    if [[ -f /etc/zfs/zpool.cache ]]; then
                        success "zpool.cache regenerated successfully"
                        cache_issues=$((cache_issues - 1))
                    else
                        error "Failed to regenerate zpool.cache"
                    fi
                fi
            fi
        else
            info "No pools imported, cache will be created on next import"
        fi
    else
        success "zpool.cache exists"
        
        # Check cache file size
        local cache_size
        cache_size=$(stat -c %s /etc/zfs/zpool.cache 2>/dev/null || echo "0")
        
        if [[ "$cache_size" -lt 100 ]]; then
            warning "zpool.cache seems unusually small ($cache_size bytes)"
            cache_issues=$((cache_issues + 1))
        else
            success "zpool.cache has reasonable size ($cache_size bytes)"
        fi
        
        # Check cache permissions
        local cache_perms
        cache_perms=$(stat -c %a /etc/zfs/zpool.cache 2>/dev/null || echo "0")
        
        if [[ "$cache_perms" != "644" ]]; then
            warning "zpool.cache has incorrect permissions: $cache_perms"
            
            if confirm_repair "Fix zpool.cache permissions to 644"; then
                if execute_repair "Fixing cache permissions" chmod 644 /etc/zfs/zpool.cache; then
                    cache_issues=$((cache_issues - 1))
                fi
            fi
        else
            success "zpool.cache has correct permissions"
        fi
    fi
    
    return "$cache_issues"
}

# Check pool health
check_pool_health() {
    header "Checking ZFS Pool Health"
    
    local pool_issues=0
    
    # Get list of pools - FIXED SIGPIPE
    local pools
    pools=$(zpool list -H -o name 2>/dev/null || echo "")
    
    if [[ -z "$pools" ]]; then
        warning "No ZFS pools found"
        return 0
    fi
    
    # Check each pool
    while IFS= read -r pool; do
        [[ -z "$pool" ]] && continue
        
        info "Checking pool: $pool"
        
        # Get pool health - FIXED SIGPIPE
        local pool_health
        pool_health=$(zpool list -H -o health "$pool" 2>/dev/null || echo "UNKNOWN")
        
        case "$pool_health" in
            ONLINE)
                success "Pool $pool is healthy: $pool_health"
                ;;
            DEGRADED)
                warning "Pool $pool is degraded"
                pool_issues=$((pool_issues + 1))
                
                # Show pool status for details
                zpool status "$pool"
                
                if confirm_repair "Attempt to clear errors on $pool"; then
                    if execute_repair "Clearing pool errors" zpool clear "$pool"; then
                        # Re-check health
                        pool_health=$(zpool list -H -o health "$pool" 2>/dev/null || echo "UNKNOWN")
                        if [[ "$pool_health" == "ONLINE" ]]; then
                            success "Pool $pool is now healthy"
                            pool_issues=$((pool_issues - 1))
                        fi
                    fi
                fi
                ;;
            FAULTED|UNAVAIL)
                error "Pool $pool is in critical state: $pool_health"
                pool_issues=$((pool_issues + 1))
                zpool status "$pool"
                error "Manual intervention required for $pool"
                ;;
            *)
                warning "Pool $pool has unknown health status: $pool_health"
                pool_issues=$((pool_issues + 1))
                ;;
        esac
        
        # Check for errors - FIXED SIGPIPE
        local pool_status
        pool_status=$(zpool status "$pool" 2>/dev/null || echo "")
        
        if echo "$pool_status" | grep -q "errors: No known data errors"; then
            success "Pool $pool has no data errors"
        else
            warning "Pool $pool may have errors"
            local error_info
            error_info=$(echo "$pool_status" | grep -A 3 "errors:" || echo "Unable to extract error info")
            log "$error_info"
            pool_issues=$((pool_issues + 1))
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
        
    done <<< "$pools"
    
    return "$pool_issues"
}

# Check dataset health
check_dataset_health() {
    header "Checking ZFS Dataset Health"
    
    local dataset_issues=0
    
    # Get all datasets - FIXED SIGPIPE
    local datasets
    datasets=$(zfs list -H -o name 2>/dev/null || echo "")
    
    if [[ -z "$datasets" ]]; then
        warning "No ZFS datasets found"
        return 0
    fi
    
    info "Found $(echo "$datasets" | wc -l) dataset(s)"
    
    # Check dataset properties
    while IFS= read -r dataset; do
        [[ -z "$dataset" ]] && continue
        
        # Get critical properties - FIXED SIGPIPE
        local mounted mountpoint compression
        mounted=$(zfs get -H -o value mounted "$dataset" 2>/dev/null || echo "unknown")
        mountpoint=$(zfs get -H -o value mountpoint "$dataset" 2>/dev/null || echo "none")
        compression=$(zfs get -H -o value compression "$dataset" 2>/dev/null || echo "off")
        
        # Check if dataset should be mounted
        if [[ "$mountpoint" != "none" ]] && [[ "$mountpoint" != "-" ]] && [[ "$mountpoint" != "legacy" ]]; then
            if [[ "$mounted" == "yes" ]]; then
                # Verify mount point actually exists
                if mountpoint -q "$mountpoint" 2>/dev/null; then
                    success "Dataset $dataset is properly mounted at $mountpoint"
                else
                    warning "Dataset $dataset reports mounted but mountpoint not found"
                    dataset_issues=$((dataset_issues + 1))
                    
                    if confirm_repair "Remount dataset $dataset"; then
                        if execute_repair "Remounting $dataset" zfs mount "$dataset"; then
                            dataset_issues=$((dataset_issues - 1))
                        fi
                    fi
                fi
            else
                warning "Dataset $dataset is not mounted (mountpoint: $mountpoint)"
                dataset_issues=$((dataset_issues + 1))
                
                if confirm_repair "Mount dataset $dataset"; then
                    if execute_repair "Mounting $dataset" zfs mount "$dataset"; then
                        dataset_issues=$((dataset_issues - 1))
                    fi
                fi
            fi
        fi
        
    done <<< "$datasets"
    
    return "$dataset_issues"
}

# Check encryption keys
check_encryption_keys() {
    header "Checking ZFS Encryption Keys"
    
    local key_issues=0
    
    # Check for encryption key file
    local key_file="/etc/zfs/zroot.key"
    
    if [[ ! -f "$key_file" ]]; then
        info "No ZFS encryption key found (encryption may not be in use)"
        return 0
    fi
    
    success "ZFS encryption key exists: $key_file"
    
    # Check key permissions
    local key_perms
    key_perms=$(stat -c %a "$key_file" 2>/dev/null || echo "0")
    
    if [[ "$key_perms" != "400" ]] && [[ "$key_perms" != "000" ]]; then
        warning "Encryption key has insecure permissions: $key_perms"
        key_issues=$((key_issues + 1))
        
        if confirm_repair "Fix encryption key permissions to 400"; then
            if execute_repair "Fixing key permissions" chmod 400 "$key_file"; then
                key_issues=$((key_issues - 1))
            fi
        fi
    else
        success "Encryption key has secure permissions: $key_perms"
    fi
    
    # Check key ownership
    local key_owner
    key_owner=$(stat -c %U:%G "$key_file" 2>/dev/null || echo "unknown")
    
    if [[ "$key_owner" != "root:root" ]]; then
        warning "Encryption key has incorrect ownership: $key_owner"
        key_issues=$((key_issues + 1))
        
        if confirm_repair "Fix encryption key ownership to root:root"; then
            if execute_repair "Fixing key ownership" chown root:root "$key_file"; then
                key_issues=$((key_issues - 1))
            fi
        fi
    else
        success "Encryption key has correct ownership"
    fi
    
    # Check if key is being used - FIXED SIGPIPE
    local encrypted_datasets
    encrypted_datasets=$(zfs get -H -o name,value encryption 2>/dev/null | grep -v "off$" | awk '{print $1}' || echo "")
    
    if [[ -n "$encrypted_datasets" ]]; then
        info "Encrypted datasets found:"
        while IFS= read -r dataset; do
            [[ -z "$dataset" ]] && continue
            log "  - $dataset"
            
            # Check if key is loaded
            local key_status
            key_status=$(zfs get -H -o value keystatus "$dataset" 2>/dev/null || echo "unknown")
            
            if [[ "$key_status" == "available" ]]; then
                success "Encryption key loaded for $dataset"
            else
                warning "Encryption key not loaded for $dataset (status: $key_status)"
                key_issues=$((key_issues + 1))
                
                if confirm_repair "Load encryption key for $dataset"; then
                    if execute_repair "Loading key for $dataset" zfs load-key "$dataset"; then
                        key_issues=$((key_issues - 1))
                    fi
                fi
            fi
        done <<< "$encrypted_datasets"
    else
        info "No encrypted datasets found"
    fi
    
    return "$key_issues"
}

# Check initramfs
check_initramfs() {
    header "Checking Initramfs"
    
    local initramfs_issues=0
    
    # Get current kernel
    local current_kernel
    current_kernel=$(uname -r)
    local initramfs_path="/boot/initramfs-${current_kernel}.img"
    
    if [[ ! -f "$initramfs_path" ]]; then
        error "Initramfs not found for current kernel: $initramfs_path"
        initramfs_issues=$((initramfs_issues + 1))
        
        if confirm_repair "Rebuild initramfs for kernel $current_kernel"; then
            if execute_repair "Building initramfs" dracut -f --kver "$current_kernel"; then
                initramfs_issues=$((initramfs_issues - 1))
            fi
        fi
    else
        success "Initramfs exists for current kernel"
        
        # Check initramfs age
        local initramfs_age
        initramfs_age=$(stat -c %Y "$initramfs_path" 2>/dev/null || echo "0")
        local current_time
        current_time=$(date +%s)
        local age_days=$(( (current_time - initramfs_age) / 86400 ))
        
        info "Initramfs age: $age_days days"
        
        if [[ $age_days -gt 90 ]]; then
            warning "Initramfs is older than 90 days"
            
            if [[ "$FORCE_REBUILD" == true ]]; then
                info "Force rebuild enabled, regenerating initramfs"
                if execute_repair "Force rebuilding initramfs" dracut -f --kver "$current_kernel"; then
                    success "Initramfs rebuilt successfully"
                fi
            fi
        fi
        
        # Check initramfs contents - FIXED SIGPIPE
        if command -v lsinitrd &>/dev/null; then
            info "Checking initramfs contents..."
            
            local initramfs_content
            initramfs_content=$(lsinitrd "$initramfs_path" 2>/dev/null || echo "")
            
            if [[ -n "$initramfs_content" ]]; then
                # Check for ZFS module
                if echo "$initramfs_content" | grep -q "zfs.ko"; then
                    success "ZFS module found in initramfs"
                else
                    error "ZFS module NOT found in initramfs"
                    initramfs_issues=$((initramfs_issues + 1))
                    
                    if confirm_repair "Rebuild initramfs to include ZFS module"; then
                        if execute_repair "Rebuilding initramfs with ZFS" dracut -f --kver "$current_kernel"; then
                            initramfs_issues=$((initramfs_issues - 1))
                        fi
                    fi
                fi
                
                # Check for encryption key
                if echo "$initramfs_content" | grep -q "zroot.key"; then
                    success "ZFS encryption key found in initramfs"
                elif [[ -f /etc/zfs/zroot.key ]]; then
                    warning "ZFS encryption key exists but not in initramfs"
                    initramfs_issues=$((initramfs_issues + 1))
                    
                    if confirm_repair "Rebuild initramfs to include encryption key"; then
                        if execute_repair "Rebuilding initramfs with key" dracut -f --kver "$current_kernel"; then
                            initramfs_issues=$((initramfs_issues - 1))
                        fi
                    fi
                fi
                
                # Check for hostid
                if echo "$initramfs_content" | grep -q -E "etc/hostid|hostid"; then
                    success "Host ID found in initramfs"
                else
                    warning "Host ID not found in initramfs"
                    initramfs_issues=$((initramfs_issues + 1))
                    
                    if confirm_repair "Rebuild initramfs to include hostid"; then
                        if execute_repair "Rebuilding initramfs with hostid" dracut -f --kver "$current_kernel"; then
                            initramfs_issues=$((initramfs_issues - 1))
                        fi
                    fi
                fi
            else
                warning "Could not read initramfs contents"
            fi
        else
            info "lsinitrd not available, skipping contents check"
        fi
    fi
    
    return "$initramfs_issues"
}

# Check ZFSBootMenu
check_zfsbootmenu() {
    header "Checking ZFSBootMenu"
    
    local zbm_issues=0
    
    # Check if ZFSBootMenu is installed
    if ! command -v generate-zbm &>/dev/null; then
        info "ZFSBootMenu not installed (system may use traditional bootloader)"
        return 0
    fi
    
    success "ZFSBootMenu is installed"
    
    # Check ZBM configuration
    local zbm_config="/etc/zfsbootmenu/config.yaml"
    if [[ ! -f "$zbm_config" ]]; then
        # Try alternate location
        if [[ -f "/etc/zfsbootmenu.yaml" ]]; then
            zbm_config="/etc/zfsbootmenu.yaml"
        else
            error "ZFSBootMenu configuration not found"
            zbm_issues=$((zbm_issues + 1))
            return "$zbm_issues"
        fi
    fi
    
    success "ZFSBootMenu configuration found: $zbm_config"
    
    # Check ESP mount
    local esp_mount="/boot/efi"
    
    if [[ ! -d "$esp_mount" ]]; then
        error "ESP mount point not found: $esp_mount"
        zbm_issues=$((zbm_issues + 1))
        return "$zbm_issues"
    fi
    
    # Check if ESP is mounted - FIXED SIGPIPE
    local esp_findmnt
    esp_findmnt=$(findmnt "$esp_mount" 2>/dev/null || echo "")
    
    if [[ -z "$esp_findmnt" ]]; then
        warning "ESP is not mounted: $esp_mount"
        zbm_issues=$((zbm_issues + 1))
        
        if confirm_repair "Mount ESP partition"; then
            # Try to find ESP partition
            local esp_part
            esp_part=$(blkid -t LABEL=EFI -o device 2>/dev/null | head -1 || echo "")
            
            if [[ -n "$esp_part" ]]; then
                if execute_repair "Mounting ESP" mount "$esp_part" "$esp_mount"; then
                    zbm_issues=$((zbm_issues - 1))
                fi
            else
                error "Could not find ESP partition"
            fi
        fi
    else
        success "ESP is mounted: $esp_mount"
    fi
    
    # Check for ZBM EFI files
    local zbm_efi_path="$esp_mount/EFI/ZBM/vmlinuz.efi"
    
    if [[ ! -f "$zbm_efi_path" ]]; then
        error "ZFSBootMenu EFI image not found: $zbm_efi_path"
        zbm_issues=$((zbm_issues + 1))
        
        if confirm_repair "Regenerate ZFSBootMenu EFI image"; then
            if execute_repair "Generating ZFSBootMenu" generate-zbm; then
                if [[ -f "$zbm_efi_path" ]]; then
                    zbm_issues=$((zbm_issues - 1))
                fi
            fi
        fi
    else
        success "ZFSBootMenu EFI image found"
        
        # Check image age
        local zbm_mtime
        zbm_mtime=$(stat -c %Y "$zbm_efi_path" 2>/dev/null || echo "0")
        local current_time
        current_time=$(date +%s)
        local zbm_age_days=$(( (current_time - zbm_mtime) / 86400 ))
        
        info "ZFSBootMenu image age: $zbm_age_days days"
        
        if [[ $zbm_age_days -gt 90 ]]; then
            warning "ZFSBootMenu image is older than 90 days"
            
            if [[ "$FORCE_REBUILD" == true ]]; then
                info "Force rebuild enabled, regenerating ZFSBootMenu"
                if execute_repair "Force rebuilding ZFSBootMenu" generate-zbm; then
                    success "ZFSBootMenu rebuilt successfully"
                fi
            fi
        fi
        
        # Check for backup
        if [[ ! -f "$esp_mount/EFI/ZBM/vmlinuz-backup.efi" ]]; then
            warning "ZFSBootMenu backup image not found"
            
            if confirm_repair "Create ZFSBootMenu backup"; then
                if execute_repair "Creating backup" cp "$zbm_efi_path" "$esp_mount/EFI/ZBM/vmlinuz-backup.efi"; then
                    success "Backup created successfully"
                fi
            fi
        else
            success "ZFSBootMenu backup exists"
        fi
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
                zbm_issues=$((zbm_issues + 1))
                info "You may need to manually create EFI boot entry"
            fi
        fi
    fi
    
    return "$zbm_issues"
}

# Check scrub status and schedule
check_scrub_status() {
    header "Checking ZFS Scrub Status"
    
    local scrub_issues=0
    
    # Get list of pools - FIXED SIGPIPE
    local pools
    pools=$(zpool list -H -o name 2>/dev/null || echo "")
    
    if [[ -z "$pools" ]]; then
        info "No ZFS pools found"
        return 0
    fi
    
    # Check scrub status for each pool
    while IFS= read -r pool; do
        [[ -z "$pool" ]] && continue
        
        info "Checking scrub status for pool: $pool"
        
        # Get scrub status - FIXED SIGPIPE
        local scrub_status
        scrub_status=$(zpool status "$pool" 2>/dev/null || echo "")
        
        if echo "$scrub_status" | grep -q "scrub in progress"; then
            info "Scrub in progress for pool $pool"
        elif echo "$scrub_status" | grep -q "scrub repaired"; then
            local scrub_date
            scrub_date=$(echo "$scrub_status" | grep "scrub repaired" | sed -n 's/.*on \(.*\)/\1/p' || echo "unknown")
            success "Last scrub completed: $scrub_date"
        elif echo "$scrub_status" | grep -q "none requested"; then
            warning "No scrub has ever been performed on pool $pool"
            scrub_issues=$((scrub_issues + 1))
            
            if confirm_repair "Start scrub on pool $pool"; then
                if execute_repair "Starting scrub" zpool scrub "$pool"; then
                    success "Scrub started on pool $pool"
                    scrub_issues=$((scrub_issues - 1))
                fi
            fi
        else
            info "Unable to determine scrub status for pool $pool"
        fi
        
    done <<< "$pools"
    
    return "$scrub_issues"
}

# Display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

ZFS Health Check and Auto-Repair Script

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

EOF
    exit 0
}

# Parse command line arguments
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

# Main execution
main() {
    header "ZFS Health Check and Auto-Repair"
    
    parse_arguments "$@"
    check_root
    
    local total_issues=0
    
    # Run all checks
    check_zfs_availability || total_issues=$((total_issues + $?))
    check_and_repair_hostid || total_issues=$((total_issues + $?))
    check_and_repair_zpool_cache || total_issues=$((total_issues + $?))
    check_pool_health || total_issues=$((total_issues + $?))
    check_dataset_health || total_issues=$((total_issues + $?))
    check_encryption_keys || total_issues=$((total_issues + $?))
    check_initramfs || total_issues=$((total_issues + $?))
    check_zfsbootmenu || total_issues=$((total_issues + $?))
    check_scrub_status || total_issues=$((total_issues + $?))
    
    # Summary
    header "Health Check Summary"
    
    if [[ $total_issues -eq 0 ]]; then
        success "All checks passed! ZFS system is healthy."
        exit 0
    else
        if [[ "$DRY_RUN" == true ]]; then
            warning "DRY RUN: Found $total_issues issue(s) that would be addressed"
        elif [[ "$AUTO_REPAIR" == true ]]; then
            warning "Found and attempted to repair $total_issues issue(s)"
            info "Review the log file for details: $LOG_FILE"
        else
            warning "Found $total_issues issue(s)"
            info "Run with --auto-repair to automatically fix issues"
            info "Run with --dry-run to see what would be done"
        fi
        exit 1
    fi
}

# Run main function
main "$@"
