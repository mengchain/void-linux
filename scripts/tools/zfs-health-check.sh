#!/bin/bash

# ZFS Health Check and Auto-Repair Script for Void Linux
# All variables properly localized
# Compatible with voidZFSInstallRepo.sh installation

set -euo pipefail

# Colors for output (these can remain global as they're constants)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging (these can remain global)
readonly LOG_FILE="/var/log/zfs_health_check.log"

# Global flags (these are intentionally global)
DRY_RUN=false
AUTO_REPAIR=false
FORCE_REPAIR=false
FORCE_REBUILD=false  # New flag for forcing rebuilds

log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "$1" | tee -a "$LOG_FILE"
}

print_header() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "\n${BLUE}=== $1 ===${NC}"
    log_message "[$timestamp] === $1 ==="
}

print_success() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${GREEN}✓ $1${NC}"
    log_message "[$timestamp] SUCCESS: $1"
}

print_warning() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}⚠ $1${NC}"
    log_message "[$timestamp] WARNING: $1"
}

print_error() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${RED}✗ $1${NC}"
    log_message "[$timestamp] ERROR: $1"
}

print_repair() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${BLUE}🔧 $1${NC}"
    log_message "[$timestamp] REPAIR: $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Confirm repair action with user
confirm_repair() {
    local action="$1"
    local reply
    
    if [[ "$FORCE_REPAIR" == true ]] || [[ "$FORCE_REBUILD" == true ]]; then
        return 0
    fi
    
    if [[ "$AUTO_REPAIR" == false ]]; then
        read -p "Perform repair: $action? (y/n) " -n 1 -r reply
        echo
        if [[ ! $reply =~ ^[Yy]$ ]]; then
            print_warning "Repair skipped by user"
            return 1
        fi
    fi
    
    return 0
}

# Execute repair command with proper logging
execute_repair() {
    local command="$1"
    local description="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [[ "$DRY_RUN" == true ]]; then
        print_repair "[DRY RUN] Would execute: $description"
        log_message "[$timestamp] DRY RUN: $command"
        return 0
    fi
    
    print_repair "Executing: $description"
    log_message "[$timestamp] EXECUTING: $command"
    
    if eval "$command" 2>&1 | tee -a "$LOG_FILE"; then
        print_success "Completed: $description"
        return 0
    else
        print_error "Failed: $description"
        return 1
    fi
}

# Check if ZFS is available and repair if needed
check_zfs_availability() {
    print_header "ZFS Availability Check"
    local needs_repair=false
    
    if ! command -v zpool &> /dev/null; then
        print_error "ZFS commands not found"
        exit 1
    fi
    
    local lsmod_output=$(lsmod)
    if ! echo "$lsmod_output" | grep -q zfs; then
        print_warning "ZFS kernel module is not loaded"
        needs_repair=true
        
        if [[ "$AUTO_REPAIR" == true ]]; then
            if confirm_repair "Load ZFS kernel module"; then
                execute_repair "modprobe zfs" "Loading ZFS kernel module"
            fi
        fi
    else
        print_success "ZFS kernel module is loaded"
    fi
}

# Check and fix ZFS hostid only if missing or corrupted (NEVER force)
check_and_repair_hostid() {
    print_header "ZFS Host ID Check"
    local needs_repair=false
    local hostid_content
    
    if [[ ! -f /etc/hostid ]]; then
        print_warning "Host ID file missing"
        needs_repair=true
    else
        hostid_content=$(cat /etc/hostid 2>/dev/null | wc -c)
        if [[ $hostid_content -ne 4 ]]; then
            print_warning "Host ID file corrupted (size: $hostid_content bytes, expected: 4)"
            needs_repair=true
        else
            print_success "Host ID file exists and is valid"
        fi
    fi
    
    # NEVER force hostid regeneration, even with --force-rebuild
    if [[ "$needs_repair" == true ]] && [[ "$AUTO_REPAIR" == true ]]; then
        if confirm_repair "Generate host ID"; then
            execute_repair "zgenhostid -f" "Generating host ID"
        fi
    fi
}

# Check and repair ZFS services only if they have issues
check_and_repair_zfs_services() {
    print_header "ZFS Installation and Services Check"
    local services_need_repair=false
    
    # Check if ZFS package is installed
    if xbps-query zfs >/dev/null 2>&1; then
        print_success "ZFS package is installed"
    else
        print_error "ZFS package is not installed"
        services_need_repair=true
    fi
    
    # Check ZFS services
    local services=("zfs-import" "zfs-mount" "zfs.target")
    local service
    for service in "${services[@]}"; do
        local sv_output=$(sv status "$service" 2>&1)
        if echo "$sv_output" | grep -q "run"; then
            print_success "Service $service is running"
        else
            print_warning "Service $service is not running properly"
            services_need_repair=true
        fi
    done
    
    if [[ "$services_need_repair" == true ]] && [[ "$AUTO_REPAIR" == true ]]; then
        if confirm_repair "Restart ZFS services"; then
            for service in "${services[@]}"; do
                execute_repair "sv restart $service" "Restarting $service"
            done
            sleep 3
        fi
    fi
}

# Check ZFS encryption keys and only repair if issues found
check_and_repair_zfs_encryption_keys() {
    print_header "ZFS Encryption Key Check"
    local key_issues=false
    local key_file="/etc/zfs/zroot.key"
    local backup_key_dir="/root/zfs-keys"
    local perms
    
    if [[ -f "$key_file" ]]; then
        print_success "ZFS encryption key exists: $key_file"
        
        perms=$(stat -c %a "$key_file")
        if [[ "$perms" != "400" ]] && [[ "$perms" != "600" ]]; then
            print_warning "ZFS encryption key has insecure permissions: $perms"
            key_issues=true
            
            if [[ "$AUTO_REPAIR" == true ]]; then
                if confirm_repair "Fix key file permissions to 400"; then
                    execute_repair "chmod 400 $key_file" "Setting key file permissions"
                fi
            fi
        else
            print_success "ZFS encryption key has secure permissions: $perms"
        fi
    else
        print_error "ZFS encryption key missing: $key_file"
        key_issues=true
    fi
    
    # Check backup keys
    if [[ -d "$backup_key_dir" ]]; then
        local key_count=$(find "$backup_key_dir" -name "*.key" 2>/dev/null | wc -l)
        if [[ $key_count -gt 0 ]]; then
            print_success "Backup encryption keys found: $key_count key(s)"
        else
            print_warning "No backup encryption keys found in $backup_key_dir"
            key_issues=true
        fi
    else
        print_warning "Backup key directory does not exist: $backup_key_dir"
        key_issues=true
    fi
}

# Check and repair dracut initramfs only if issues detected OR force rebuild
check_and_repair_dracut_initramfs() {
    print_header "Dracut Initramfs Check"
    local needs_rebuild=false
    local current_kernel=$(uname -r)
    local initramfs_path="/boot/initramfs-${current_kernel}.img"
    local dracut_zfs_conf="/etc/dracut.conf.d/zfs.conf"
    local -a required_items=("zfs" "zroot.key")
    local item
    
    # Force rebuild if requested
    if [[ "$FORCE_REBUILD" == true ]]; then
        print_warning "Force rebuild requested for initramfs"
        needs_rebuild=true
    else
        # Check specific dracut config from installation
        if [[ -f "$dracut_zfs_conf" ]]; then
            print_success "Dracut ZFS configuration found"
            local dracut_conf_content=$(cat "$dracut_zfs_conf")
            for item in "${required_items[@]}"; do
                if echo "$dracut_conf_content" | grep -q "$item"; then
                    print_success "Dracut config includes: $item"
                else
                    print_warning "Dracut config missing: $item"
                    needs_rebuild=true
                fi
            done
        else
            print_warning "Dracut ZFS configuration missing"
            needs_rebuild=true
        fi

        # Check initramfs for ZFS support
        if [[ ! -f "$initramfs_path" ]]; then
            print_warning "Initramfs missing for current kernel: $initramfs_path"
            needs_rebuild=true
        else
            print_repair "Checking initramfs for ZFS module and encryption key"
            
            local initramfs_content=$(lsinitrd "$initramfs_path" 2>/dev/null || echo "")
            
            if echo "$initramfs_content" | grep -q "zfs.ko"; then
                print_success "ZFS module found in initramfs"
            else
                print_warning "ZFS module not found in initramfs"
                needs_rebuild=true
            fi
            
            if echo "$initramfs_content" | grep -q "zroot.key"; then
                print_success "ZFS encryption key found in initramfs"
            else
                print_warning "ZFS encryption key not found in initramfs"
                needs_rebuild=true
            fi
        fi
    fi
    
    # Only rebuild if issues were found or forced
    if [[ "$needs_rebuild" == true ]] && [[ "$AUTO_REPAIR" == true ]]; then
        if confirm_repair "Rebuild initramfs with ZFS support"; then
            if [[ ! -f "$dracut_zfs_conf" ]]; then
                execute_repair "cat > $dracut_zfs_conf << 'EOF'
hostonly=\"yes\"
nofsck=\"yes\"
add_dracutmodules+=\" zfs \"
omit_dracutmodules+=\" btrfs resume \"
install_items+=\" /etc/zfs/zroot.key \"
force_drivers+=\" zfs \"
filesystems+=\" zfs \"
EOF" "Creating dracut ZFS configuration"
            fi
            
            execute_repair "dracut -f --kver $current_kernel" "Rebuilding initramfs for kernel $current_kernel"
        fi
    elif [[ "$needs_rebuild" == false ]]; then
        print_success "Initramfs has proper ZFS support"
    fi
}

# Check and repair ZFSBootMenu only if issues found OR force rebuild
check_and_repair_zfsbootmenu() {
    print_header "ZFSBootMenu Check"
    local zbm_issues=false
    local zbm_config="/etc/zfsbootmenu/config.yaml"
    local zbm_esp="/boot/efi/EFI/ZBM"
    local zbm_dracut_dir="/etc/zfsbootmenu/dracut.conf.d"
    local keymap_conf="$zbm_dracut_dir/keymap.conf"
    
    if ! command -v generate-zbm &> /dev/null; then
        print_warning "ZFSBootMenu is not installed (optional)"
        return
    else
        print_success "ZFSBootMenu is installed"
    fi
    
    # Force rebuild if requested
    if [[ "$FORCE_REBUILD" == true ]]; then
        print_warning "Force rebuild requested for ZFSBootMenu"
        zbm_issues=true
    else
        # Check ZBM configuration
        if [[ -f "$zbm_config" ]]; then
            print_success "ZFSBootMenu configuration exists"
        else
            print_warning "ZFSBootMenu configuration missing"
            zbm_issues=true
        fi
        
        # Check ZBM ESP directory
        if [[ -d "$zbm_esp" ]]; then
            print_success "ZFSBootMenu ESP directory exists"
            
            if [[ -f "$zbm_esp/vmlinuz.efi" ]]; then
                print_success "ZFSBootMenu kernel image exists"
            else
                print_warning "ZFSBootMenu kernel image missing"
                zbm_issues=true
            fi
        else
            print_warning "ZFSBootMenu ESP directory missing"
            zbm_issues=true
        fi
        
        # Check keymap configuration
        if [[ -f "$keymap_conf" ]]; then
            print_success "ZFSBootMenu keymap configuration exists"
        else
            print_warning "ZFSBootMenu keymap configuration missing"
            zbm_issues=true
        fi
    fi
    
    # Only repair if issues were found or forced
    if [[ "$zbm_issues" == true ]] && [[ "$AUTO_REPAIR" == true ]]; then
        if confirm_repair "Rebuild ZFSBootMenu"; then
            # Create config if missing
            if [[ ! -f "$zbm_config" ]]; then
                execute_repair "mkdir -p /etc/zfsbootmenu && cat > $zbm_config << 'EOF'
Global:
  ManageImages: true
  BootMountPoint: /boot/efi
  DracutConfDir: /etc/zfsbootmenu/dracut.conf.d
Components:
  Enabled: false
EFI:
  Enabled: true
Kernel:
  Prefix: vmlinuz
EOF" "Creating ZFSBootMenu configuration"
            fi
            
            # Create keymap config if missing
            if [[ ! -f "$keymap_conf" ]]; then
                execute_repair "mkdir -p $zbm_dracut_dir && cat > $keymap_conf << 'EOF'
install_optional_items+=\" /etc/cmdline.d/keymap.conf \"
EOF" "Creating keymap configuration"
                
                execute_repair "mkdir -p /etc/cmdline.d && cat > /etc/cmdline.d/keymap.conf << 'EOF'
rd.vconsole.keymap=en
EOF" "Creating keymap cmdline configuration"
            fi
            
            execute_repair "generate-zbm --debug" "Generating ZFSBootMenu"
        fi
    elif [[ "$zbm_issues" == false ]]; then
        print_success "ZFSBootMenu is properly configured"
    fi
}

# Check EFI boot entries without repair
check_efi_boot_entries() {
    print_header "EFI Boot Entries Check"
    
    if [[ ! -d /sys/firmware/efi ]]; then
        print_warning "System is not booted in UEFI mode"
        return
    fi
    
    local efibootmgr_output=$(efibootmgr 2>/dev/null || echo "")
    if [[ -z "$efibootmgr_output" ]]; then
        print_error "Unable to read EFI boot entries"
        return
    fi
    
    if echo "$efibootmgr_output" | grep -qi "ZFSBootMenu"; then
        print_success "ZFSBootMenu EFI entry found"
    else
        print_warning "ZFSBootMenu EFI entry not found"
    fi
    
    echo "$efibootmgr_output" | head -n 20
}

# Check ZFS layout without repair
check_zfs_layout() {
    print_header "ZFS Pool Layout"
    
    local pools=$(zpool list -H -o name 2>/dev/null || echo "")
    if [[ -z "$pools" ]]; then
        print_error "No ZFS pools found"
        return
    fi
    
    echo "$pools" | while read -r pool; do
        print_success "Pool: $pool"
        zpool status "$pool" | head -n 30
    done
}

# Get all ZFS pools
get_zfs_pools() {
    zpool list -H -o name 2>/dev/null || echo ""
}

# Check and repair pool issues only when found
check_and_repair_pool_issues() {
    print_header "ZFS Pool Health Check"
    
    local pools=$(get_zfs_pools)
    if [[ -z "$pools" ]]; then
        print_error "No ZFS pools found"
        return
    fi
    
    echo "$pools" | while read -r pool; do
        local pool_health=$(zpool list -H -o health "$pool" 2>/dev/null || echo "UNKNOWN")
        
        if [[ "$pool_health" == "ONLINE" ]]; then
            print_success "Pool $pool is healthy: $pool_health"
        else
            print_warning "Pool $pool has issues: $pool_health"
            
            if [[ "$AUTO_REPAIR" == true ]]; then
                if confirm_repair "Clear pool errors for $pool"; then
                    execute_repair "zpool clear $pool" "Clearing pool errors"
                fi
            fi
        fi
    done
}

# Check pool properties
check_pool_properties() {
    print_header "ZFS Pool Properties"
    
    local pools=$(get_zfs_pools)
    if [[ -z "$pools" ]]; then
        return
    fi
    
    echo "$pools" | while read -r pool; do
        echo -e "\n${BLUE}Pool: $pool${NC}"
        zpool get all "$pool" | grep -E "bootfs|cachefile|autotrim|autoexpand"
    done
}

# Check and repair pool errors only when found
check_and_repair_pool_errors() {
    print_header "ZFS Pool Error Check"
    
    local pools=$(get_zfs_pools)
    if [[ -z "$pools" ]]; then
        return
    fi
    
    echo "$pools" | while read -r pool; do
        local status_output=$(zpool status "$pool" 2>/dev/null || echo "")
        
        if echo "$status_output" | grep -q "errors: No known data errors"; then
            print_success "Pool $pool has no errors"
        else
            print_warning "Pool $pool may have errors"
            echo "$status_output" | grep -A 5 "errors:"
            
            if [[ "$AUTO_REPAIR" == true ]]; then
                if confirm_repair "Attempt to repair pool $pool"; then
                    execute_repair "zpool scrub $pool" "Starting scrub on pool $pool"
                fi
            fi
        fi
    done
}

# Check and repair filesystem mount issues only when found
check_and_repair_zfs_filesystem_mounts() {
    print_header "ZFS Filesystem Mount Check"
    
    local datasets=$(zfs list -H -o name,mounted,mountpoint 2>/dev/null || echo "")
    if [[ -z "$datasets" ]]; then
        print_error "No ZFS datasets found"
        return
    fi
    
    local mount_issues=false
    echo "$datasets" | while read -r name mounted mountpoint; do
        if [[ "$mountpoint" == "none" ]] || [[ "$mountpoint" == "-" ]]; then
            continue
        fi
        
        if [[ "$mounted" == "yes" ]]; then
            print_success "Dataset $name is mounted at $mountpoint"
        else
            print_warning "Dataset $name is not mounted (mountpoint: $mountpoint)"
            mount_issues=true
            
            if [[ "$AUTO_REPAIR" == true ]]; then
                if confirm_repair "Mount dataset $name"; then
                    execute_repair "zfs mount $name" "Mounting dataset $name"
                fi
            fi
        fi
    done
}

# Check and repair boot properties only when needed
check_and_repair_boot_properties() {
    print_header "ZFS Boot Properties Check"
    
    local pools=$(get_zfs_pools)
    if [[ -z "$pools" ]]; then
        return
    fi
    
    echo "$pools" | while read -r pool; do
        local bootfs=$(zpool get -H -o value bootfs "$pool" 2>/dev/null || echo "-")
        
        if [[ "$bootfs" == "-" ]]; then
            print_warning "Pool $pool has no bootfs property set"
            
            # Try to find ROOT dataset
            local root_datasets=$(zfs list -H -o name 2>/dev/null | grep "^$pool/ROOT/" || echo "")
            if [[ -n "$root_datasets" ]]; then
                local first_root=$(echo "$root_datasets" | head -n 1)
                print_warning "Suggested bootfs: $first_root"
                
                if [[ "$AUTO_REPAIR" == true ]]; then
                    if confirm_repair "Set bootfs to $first_root"; then
                        execute_repair "zpool set bootfs=$first_root $pool" "Setting bootfs property"
                    fi
                fi
            fi
        else
            print_success "Pool $pool bootfs: $bootfs"
            
            # Check if bootfs dataset exists
            if zfs list "$bootfs" &>/dev/null; then
                print_success "Bootfs dataset exists"
            else
                print_error "Bootfs dataset $bootfs does not exist!"
            fi
        fi
    done
}

# Check dataset properties
check_dataset_properties() {
    print_header "ZFS Dataset Properties"
    
    local datasets=$(zfs list -H -o name 2>/dev/null | head -n 10 || echo "")
    if [[ -z "$datasets" ]]; then
        return
    fi
    
    echo "$datasets" | while read -r dataset; do
        echo -e "\n${BLUE}Dataset: $dataset${NC}"
        zfs get compression,atime,xattr,mountpoint "$dataset"
    done
}

# Check scrub status and perform if needed
check_and_perform_scrub() {
    print_header "ZFS Scrub Status"
    
    local pools=$(get_zfs_pools)
    if [[ -z "$pools" ]]; then
        return
    fi
    
    echo "$pools" | while read -r pool; do
        local status_output=$(zpool status "$pool" 2>/dev/null || echo "")
        local scrub_info=$(echo "$status_output" | grep -A 2 "scan:")
        
        echo -e "\n${BLUE}Pool: $pool${NC}"
        echo "$scrub_info"
        
        if echo "$scrub_info" | grep -q "scrub in progress"; then
            print_success "Scrub is currently running"
        elif echo "$scrub_info" | grep -q "none requested"; then
            print_warning "No scrub has been performed"
            
            if [[ "$AUTO_REPAIR" == true ]]; then
                if confirm_repair "Start scrub on pool $pool"; then
                    execute_repair "zpool scrub $pool" "Starting scrub"
                fi
            fi
        fi
    done
}

# Check pool capacity
check_pool_capacity() {
    print_header "ZFS Pool Capacity"
    
    local pools=$(get_zfs_pools)
    if [[ -z "$pools" ]]; then
        return
    fi
    
    echo "$pools" | while read -r pool; do
        local capacity=$(zpool list -H -o capacity "$pool" 2>/dev/null | tr -d '%' || echo "0")
        local size=$(zpool list -H -o size "$pool" 2>/dev/null || echo "unknown")
        local free=$(zpool list -H -o free "$pool" 2>/dev/null || echo "unknown")
        
        echo -e "\n${BLUE}Pool: $pool${NC}"
        echo "Size: $size | Free: $free | Used: ${capacity}%"
        
        if [[ $capacity -lt 70 ]]; then
            print_success "Pool capacity is healthy: ${capacity}%"
        elif [[ $capacity -lt 85 ]]; then
            print_warning "Pool capacity is getting high: ${capacity}%"
        else
            print_error "Pool capacity is critical: ${capacity}%"
        fi
    done
}

# Check ARC statistics
check_arc_stats() {
    print_header "ZFS ARC Statistics"
    
    if [[ ! -f /proc/spl/kstat/zfs/arcstats ]]; then
        print_warning "ARC statistics not available"
        return
    fi
    
    local arc_size=$(grep "^size" /proc/spl/kstat/zfs/arcstats | awk '{print $3}')
    local arc_max=$(grep "^c_max" /proc/spl/kstat/zfs/arcstats | awk '{print $3}')
    local arc_hit=$(grep "^hits" /proc/spl/kstat/zfs/arcstats | awk '{print $3}')
    local arc_miss=$(grep "^misses" /proc/spl/kstat/zfs/arcstats | awk '{print $3}')
    
    # Convert to human readable (simple MB conversion)
    local arc_size_mb=$((arc_size / 1024 / 1024))
    local arc_max_mb=$((arc_max / 1024 / 1024))
    
    echo "Current ARC size: ${arc_size_mb}MB"
    echo "Maximum ARC size: ${arc_max_mb}MB"
    
    if [[ $arc_hit -gt 0 ]] || [[ $arc_miss -gt 0 ]]; then
        local total=$((arc_hit + arc_miss))
        local hit_rate=$((arc_hit * 100 / total))
        echo "ARC hit rate: ${hit_rate}%"
        
        if [[ $hit_rate -gt 80 ]]; then
            print_success "ARC hit rate is good: ${hit_rate}%"
        else
            print_warning "ARC hit rate is low: ${hit_rate}%"
        fi
    fi
}

# Main execution
main() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --auto-repair)
                AUTO_REPAIR=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                FORCE_REPAIR=true
                AUTO_REPAIR=true
                shift
                ;;
            --force-rebuild)
                FORCE_REBUILD=true
                AUTO_REPAIR=true
                shift
                ;;
            --help)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --auto-repair    Automatically repair issues without prompting"
                echo "  --dry-run        Show what would be done without making changes"
                echo "  --force          Force all repairs without confirmation"
                echo "  --force-rebuild  Force rebuild of initramfs and ZFSBootMenu"
                echo "  --help           Show this help message"
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Create/initialize log file
    touch "$LOG_FILE" 2>/dev/null || {
        print_error "Cannot create log file: $LOG_FILE"
        exit 1
    }
    
    print_header "ZFS Health Check Started - $timestamp"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_warning "Running in DRY RUN mode - no changes will be made"
    fi
    
    if [[ "$AUTO_REPAIR" == true ]]; then
        print_warning "Auto-repair mode enabled"
    fi
    
    if [[ "$FORCE_REBUILD" == true ]]; then
        print_warning "Force rebuild mode enabled"
    fi
    
    # Run checks
    check_root
    check_zfs_availability
    check_and_repair_hostid
    check_and_repair_zfs_services
    check_and_repair_zfs_encryption_keys
    check_and_repair_dracut_initramfs
    check_and_repair_zfsbootmenu
    check_efi_boot_entries
    check_zfs_layout
    check_and_repair_pool_issues
    check_pool_properties
    check_and_repair_pool_errors
    check_and_repair_zfs_filesystem_mounts
    check_and_repair_boot_properties
    check_dataset_properties
    check_and_perform_scrub
    check_pool_capacity
    check_arc_stats
    
    print_header "ZFS Health Check Completed - $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "\nLog file: $LOG_FILE"
}

# Run main function with all arguments
main "$@"
