#!/bin/bash
# filepath: zfs_health_check.sh

# ZFS Health Check and Auto-Repair Script for Void Linux
# Compatible with voidZFSInstallRepo.sh installation
# Based on official OpenZFS documentation and best practices

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging
LOG_FILE="/var/log/zfs_health_check.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Global flags
DRY_RUN=false
AUTO_REPAIR=false
FORCE_REPAIR=false

log_message() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
    log_message "[$TIMESTAMP] === $1 ==="
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
    log_message "[$TIMESTAMP] SUCCESS: $1"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
    log_message "[$TIMESTAMP] WARNING: $1"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
    log_message "[$TIMESTAMP] ERROR: $1"
}

print_repair() {
    echo -e "${BLUE}🔧 $1${NC}"
    log_message "[$TIMESTAMP] REPAIR: $1"
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
    
    if [[ "$FORCE_REPAIR" == true ]]; then
        return 0
    fi
    
    if [[ "$AUTO_REPAIR" == false ]]; then
        echo -e "${YELLOW}Repair action required: $action${NC}"
        read -p "Do you want to proceed? [y/N]: " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
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
    
    if [[ "$DRY_RUN" == true ]]; then
        print_repair "DRY RUN: Would execute: $command"
        return 0
    fi
    
    print_repair "Executing: $description"
    log_message "[$TIMESTAMP] EXECUTING: $command"
    
    if eval "$command" 2>&1 | tee -a "$LOG_FILE"; then
        print_success "Repair completed: $description"
        return 0
    else
        print_error "Repair failed: $description"
        return 1
    fi
}

# Check if ZFS is available
check_zfs_availability() {
    if ! command -v zpool &> /dev/null; then
        print_error "ZFS tools not found. Install with: xbps-install -S zfs"
        exit 1
    fi
    
    if ! lsmod | grep -q zfs; then
        print_error "ZFS kernel module not loaded"
        if confirm_repair "Load ZFS kernel module"; then
            execute_repair "modprobe zfs" "Loading ZFS kernel module"
        else
            exit 1
        fi
    fi
}

# Fix ZFS hostid if missing - specific to voidZFSInstallRepo.sh setup
repair_missing_hostid() {
    print_header "ZFS Host ID Repair"
    
    if [[ ! -f /etc/hostid ]]; then
        print_warning "ZFS hostid file missing"
        if confirm_repair "Generate ZFS hostid"; then
            execute_repair "zgenhostid" "Generating ZFS hostid"
        fi
    else
        print_success "ZFS hostid file exists"
        
        # Validate hostid format (should be 8 hex chars)
        local hostid_content=$(xxd -p /etc/hostid 2>/dev/null | tr -d '\n' || echo "invalid")
        if [[ ${#hostid_content} -eq 8 ]] && [[ "$hostid_content" =~ ^[0-9a-f]{8}$ ]]; then
            print_success "ZFS hostid format is valid: $hostid_content"
        else
            print_warning "ZFS hostid appears corrupted"
            if confirm_repair "Regenerate ZFS hostid"; then
                execute_repair "zgenhostid" "Regenerating ZFS hostid"
            fi
        fi
    fi
}

# Repair ZFS services - specific to void runit setup
repair_zfs_services() {
    print_header "ZFS Services Repair"
    
    # Check for void-specific ZFS services
    local zfs_services=("zfs-import" "zfs-mount")
    local services_repaired=false
    
    for service in "${zfs_services[@]}"; do
        local service_path="/etc/sv/$service"
        local service_link="/var/service/$service"
        
        if [[ -d "$service_path" ]]; then
            if [[ -L "$service_link" ]]; then
                local status=$(sv status "$service" 2>/dev/null || echo "down")
                if [[ "$status" =~ "run" ]]; then
                    print_success "Service $service is running"
                else
                    print_warning "Service $service is not running: $status"
                    if confirm_repair "Start $service service"; then
                        execute_repair "sv up $service" "Starting $service service"
                        services_repaired=true
                    fi
                fi
            else
                print_warning "Service $service not enabled"
                if confirm_repair "Enable $service service"; then
                    execute_repair "ln -sf $service_path $service_link" "Enabling $service service"
                    services_repaired=true
                fi
            fi
        else
            print_warning "Service $service not found - ZFS may not be properly installed"
        fi
    done
    
    if [[ "$services_repaired" == true ]]; then
        print_repair "Waiting for services to stabilize..."
        sleep 3
    fi
}

# Check ZFS encryption key setup - specific to voidZFSInstallRepo.sh
check_zfs_encryption_keys() {
    print_header "ZFS Encryption Key Check"
    
    # Check for the specific key file created by installation script
    local key_file="/etc/zfs/zroot.key"
    local backup_key_dir="/root/zfs-keys"
    
    if [[ -f "$key_file" ]]; then
        print_success "ZFS encryption key found: $key_file"
        
        # Check permissions
        local perms=$(stat -c "%a" "$key_file")
        if [[ "$perms" == "000" ]]; then
            print_success "ZFS key permissions are secure (000)"
        else
            print_warning "ZFS key permissions are not secure: $perms"
            if confirm_repair "Secure ZFS key permissions"; then
                execute_repair "chmod 000 $key_file" "Setting secure permissions on ZFS key"
            fi
        fi
    else
        print_error "ZFS encryption key missing: $key_file"
        print_error "This may prevent pool import on reboot!"
    fi
    
    # Check backup keys
    if [[ -d "$backup_key_dir" ]]; then
        if [[ -f "$backup_key_dir/zroot.key" ]]; then
            print_success "ZFS key backup found"
        else
            print_warning "ZFS key backup missing"
        fi
    else
        print_warning "ZFS key backup directory missing: $backup_key_dir"
    fi
}

# Repair dracut initramfs - compatible with voidZFSInstallRepo.sh dracut config
repair_dracut_initramfs() {
    print_header "Dracut Initramfs Repair"
    
    local current_kernel=$(uname -r)
    local initramfs_path="/boot/initramfs-${current_kernel}.img"
    local needs_rebuild=false
    
    # Check specific dracut config from installation
    local dracut_zfs_conf="/etc/dracut.conf.d/zfs.conf"
    if [[ -f "$dracut_zfs_conf" ]]; then
        print_success "Dracut ZFS configuration found"
        
        # Validate key components from voidZFSInstallRepo.sh
        local required_items=("zfs" "zroot.key")
        for item in "${required_items[@]}"; do
            if grep -q "$item" "$dracut_zfs_conf"; then
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
    
    # Check if initramfs exists and contains ZFS
    if [[ ! -f "$initramfs_path" ]]; then
        print_warning "Initramfs missing for current kernel"
        needs_rebuild=true
    elif ! lsinitrd "$initramfs_path" 2>/dev/null | grep -q "zfs.ko"; then
        print_warning "ZFS module not found in initramfs"
        needs_rebuild=true
    elif ! lsinitrd "$initramfs_path" 2>/dev/null | grep -q "zroot.key"; then
        print_warning "ZFS encryption key not found in initramfs"
        needs_rebuild=true
    fi
    
    if [[ "$needs_rebuild" == true ]]; then
        if confirm_repair "Rebuild initramfs with ZFS support"; then
            # Recreate dracut config if missing
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
    else
        print_success "Initramfs appears to have proper ZFS support"
    fi
}

# Repair ZFSBootMenu configuration - specific to voidZFSInstallRepo.sh setup
repair_zfsbootmenu() {
    print_header "ZFSBootMenu Repair"
    
    if ! command -v zbm-builder.sh &> /dev/null; then
        print_warning "ZFSBootMenu not installed"
        if confirm_repair "Install ZFSBootMenu"; then
            execute_repair "xbps-install -Sy zfsbootmenu" "Installing ZFSBootMenu"
        fi
        return
    fi
    
    local zbm_config="/etc/zfsbootmenu/config.yaml"
    local zbm_esp="/boot/efi/EFI/ZBM"
    local zbm_dracut_dir="/etc/zfsbootmenu/dracut.conf.d"
    
    # Check main ZBM configuration (matches voidZFSInstallRepo.sh)
    if [[ -f "$zbm_config" ]]; then
        print_success "ZFSBootMenu configuration found"
        
        # Check key settings from installation script
        if grep -q "ImageDir: /boot/efi/EFI/ZBM" "$zbm_config" && \
           grep -q "BootMountPoint: /boot/efi" "$zbm_config"; then
            print_success "ZFSBootMenu configuration matches installation"
        else
            print_warning "ZFSBootMenu configuration may be outdated"
        fi
    else
        print_warning "ZFSBootMenu configuration missing"
        if confirm_repair "Create ZFSBootMenu configuration"; then
            execute_repair "mkdir -p /etc/zfsbootmenu" "Creating ZBM config directory"
            
            # Create config matching voidZFSInstallRepo.sh
            execute_repair "cat > $zbm_config << 'EOF'
Global:
  ManageImages: true
  BootMountPoint: /boot/efi
  DracutConfDir: /etc/zfsbootmenu/dracut.conf.d
Components:
  Enabled: false
EFI:
  ImageDir: /boot/efi/EFI/ZBM
  Versions: false
  Enabled: true
Kernel:
  CommandLine: ro quiet loglevel=0
  Prefix: vmlinuz
EOF" "Creating ZFSBootMenu configuration"
        fi
    fi
    
    # Check dracut configuration directory
    if [[ ! -d "$zbm_dracut_dir" ]]; then
        print_warning "ZFSBootMenu dracut config directory missing"
        if confirm_repair "Create ZFSBootMenu dracut directory"; then
            execute_repair "mkdir -p $zbm_dracut_dir" "Creating ZBM dracut config directory"
        fi
    fi
    
    # Check keymap config (from voidZFSInstallRepo.sh)
    local keymap_conf="$zbm_dracut_dir/keymap.conf"
    if [[ ! -f "$keymap_conf" ]]; then
        print_warning "ZFSBootMenu keymap configuration missing"
        if confirm_repair "Create keymap configuration"; then
            execute_repair "cat > $keymap_conf << 'EOF'
install_optional_items+=\" /etc/cmdline.d/keymap.conf \"
EOF" "Creating keymap configuration"
            
            execute_repair "mkdir -p /etc/cmdline.d" "Creating cmdline.d directory"
            execute_repair "cat > /etc/cmdline.d/keymap.conf << 'EOF'
rd.vconsole.keymap=en
EOF" "Creating keymap cmdline configuration"
        fi
    fi
    
    # Check ESP directory and images
    if [[ ! -d "$zbm_esp" ]]; then
        print_warning "ZFSBootMenu ESP directory missing"
        if confirm_repair "Create ZFSBootMenu ESP directory"; then
            execute_repair "mkdir -p $zbm_esp" "Creating ZBM ESP directory"
        fi
    fi
    
    # Check for ZBM EFI images
    if ! ls "$zbm_esp"/vmlinuz*.efi &> /dev/null; then
        print_warning "ZFSBootMenu EFI images missing"
        if confirm_repair "Generate ZFSBootMenu images"; then
            execute_repair "zbm-builder.sh" "Building ZFSBootMenu images"
        fi
    else
        print_success "ZFSBootMenu EFI images found"
        
        # Check for backup image (created by installation script)
        if [[ -f "$zbm_esp/vmlinuz.efi" ]] && [[ ! -f "$zbm_esp/vmlinuz-backup.efi" ]]; then
            print_warning "ZFSBootMenu backup image missing"
            if confirm_repair "Create backup ZFSBootMenu image"; then
                execute_repair "cp $zbm_esp/vmlinuz.efi $zbm_esp/vmlinuz-backup.efi" "Creating backup ZBM image"
            fi
        fi
    fi
}

# Check EFI boot entries - specific to voidZFSInstallRepo.sh boot setup
check_efi_boot_entries() {
    print_header "EFI Boot Entries Check"
    
    if ! command -v efibootmgr &> /dev/null; then
        print_warning "efibootmgr not found"
        return
    fi
    
    # Check for ZFSBootMenu entries
    local zbm_entries=$(efibootmgr | grep -c "ZFSBootMenu" || echo "0")
    
    if [[ "$zbm_entries" -eq 0 ]]; then
        print_warning "No ZFSBootMenu EFI entries found"
        print_repair "Boot entries may need to be recreated"
    elif [[ "$zbm_entries" -eq 1 ]]; then
        print_warning "Only one ZFSBootMenu entry found (backup missing)"
    else
        print_success "ZFSBootMenu EFI entries found: $zbm_entries"
    fi
    
    # Show current entries
    efibootmgr | grep -E "(Boot|ZFSBootMenu)" | head -10
}

# Check ZFS pool structure specific to voidZFSInstallRepo.sh layout
check_zfs_layout() {
    print_header "ZFS Layout Verification"
    
    # Check for expected pool structure from installation
    if zpool list zroot &>/dev/null; then
        print_success "Pool 'zroot' found"
        
        # Check ROOT dataset
        if zfs list zroot/ROOT &>/dev/null; then
            print_success "ROOT dataset exists"
            
            # Check for system datasets
            if zfs list | grep -q "zroot/ROOT/"; then
                local root_datasets=$(zfs list -H -o name | grep "zroot/ROOT/" | wc -l)
                print_success "Found $root_datasets ROOT dataset(s)"
            fi
        else
            print_error "ROOT dataset missing from zroot pool"
        fi
        
        # Check data datasets
        if zfs list zroot/data &>/dev/null; then
            print_success "Data dataset exists"
            
            # Check home and root datasets
            for subdir in home root; do
                if zfs list "zroot/data/$subdir" &>/dev/null; then
                    print_success "Dataset zroot/data/$subdir exists"
                else
                    print_warning "Dataset zroot/data/$subdir missing"
                fi
            done
        else
            print_warning "Data dataset missing (may be normal for minimal installs)"
        fi
        
        # Check swap dataset if it should exist
        if zfs list zroot/swap &>/dev/null; then
            print_success "Swap dataset exists"
            
            # Check if swap is active
            if swapon --show=NAME | grep -q "/dev/zvol/zroot/swap"; then
                print_success "ZFS swap is active"
            else
                print_warning "ZFS swap exists but not active"
                if confirm_repair "Activate ZFS swap"; then
                    execute_repair "swapon /dev/zvol/zroot/swap" "Activating ZFS swap"
                fi
            fi
        fi
    else
        print_error "Pool 'zroot' not found - this may not be a system installed with voidZFSInstallRepo.sh"
    fi
}

# Get all ZFS pools
get_zfs_pools() {
    zpool list -H -o name 2>/dev/null || true
}

# Repair pool issues based on status
repair_pool_issues() {
    local pool="$1"
    print_header "Pool Repair: $pool"
    
    local status=$(zpool status "$pool" | grep "state:" | awk '{print $2}')
    local pool_repaired=false
    
    case "$status" in
        "ONLINE")
            print_success "Pool $pool is ONLINE and healthy"
            ;;
        "DEGRADED")
            print_warning "Pool $pool is DEGRADED"
            
            # Check for devices that can be cleared
            if zpool status "$pool" | grep -q "FAULTED.*was /dev/"; then
                if confirm_repair "Clear faulted devices in pool $pool"; then
                    # Get faulted devices and try to clear them
                    zpool status "$pool" | grep "FAULTED" | while read -r line; do
                        local device=$(echo "$line" | awk '{print $1}')
                        execute_repair "zpool clear $pool $device" "Clearing faulted device $device"
                    done
                    pool_repaired=true
                fi
            fi
            
            # Check for offline devices that can be brought online
            if zpool status "$pool" | grep -q "OFFLINE"; then
                if confirm_repair "Bring offline devices online in pool $pool"; then
                    zpool status "$pool" | grep "OFFLINE" | while read -r line; do
                        local device=$(echo "$line" | awk '{print $1}')
                        execute_repair "zpool online $pool $device" "Bringing device $device online"
                    done
                    pool_repaired=true
                fi
            fi
            ;;
        "FAULTED")
            print_error "Pool $pool is FAULTED"
            if confirm_repair "Attempt to clear pool errors"; then
                execute_repair "zpool clear $pool" "Clearing pool errors"
                pool_repaired=true
            fi
            ;;
        "UNAVAIL")
            print_error "Pool $pool is UNAVAILABLE"
            if confirm_repair "Force import pool $pool"; then
                execute_repair "zpool import -f $pool" "Force importing pool"
                pool_repaired=true
            fi
            ;;
    esac
    
    if [[ "$pool_repaired" == true ]]; then
        print_repair "Waiting for pool to stabilize..."
        sleep 2
        local new_status=$(zpool status "$pool" | grep "state:" | awk '{print $2}')
        print_repair "Pool $pool status after repair: $new_status"
    fi
}

# Check and repair pool errors
repair_pool_errors() {
    local pool="$1"
    print_header "Pool Error Repair: $pool"
    
    if ! zpool status "$pool" | grep -q "errors: No known data errors"; then
        print_warning "Data errors detected in pool $pool"
        zpool status -v "$pool"
        
        if confirm_repair "Start scrub to repair data errors in pool $pool"; then
            execute_repair "zpool scrub $pool" "Starting repair scrub"
            print_repair "Scrub started. Monitor progress with: zpool status $pool"
        fi
    else
        print_success "No data errors found in pool $pool"
    fi
}

# Repair filesystem mount issues
repair_zfs_filesystem_mounts() {
    print_header "ZFS Filesystem Mount Repair"
    
    local mount_issues=false
    
    # Check unmounted datasets
    while IFS=$'\t' read -r dataset mounted; do
        if [[ "$mounted" == "no" ]]; then
            # Check if dataset should be mounted (canmount property)
            local canmount=$(zfs get -H -o value canmount "$dataset")
            local mountpoint=$(zfs get -H -o value mountpoint "$dataset")
            
            if [[ "$canmount" == "on" && "$mountpoint" != "none" && "$mountpoint" != "legacy" ]]; then
                print_warning "Dataset $dataset should be mounted but isn't"
                mount_issues=true
                
                if confirm_repair "Mount dataset $dataset"; then
                    execute_repair "zfs mount $dataset" "Mounting dataset $dataset"
                fi
            fi
        fi
    done < <(zfs list -H -o name,mounted 2>/dev/null)
    
    if [[ "$mount_issues" == false ]]; then
        print_success "All ZFS filesystems are properly mounted"
    fi
}

# Repair boot filesystem properties
repair_boot_properties() {
    local pool="$1"
    print_header "Boot Properties Repair: $pool"
    
    # Check bootfs property (should be set by voidZFSInstallRepo.sh)
    local bootfs=$(zpool get -H -o value bootfs "$pool")
    
    if [[ "$bootfs" != "-" ]]; then
        print_success "Bootfs property set: $bootfs"
        
        # Verify the bootfs dataset exists
        if zfs list "$bootfs" &>/dev/null; then
            print_success "Bootfs dataset exists and is accessible"
        else
            print_error "Bootfs dataset does not exist: $bootfs"
        fi
    else
        print_warning "Bootfs property not set on pool $pool"
        
        # Try to detect root dataset
        local root_datasets=$(zfs list -H -o name | grep "^$pool/ROOT/" || true)
        if [[ -n "$root_datasets" ]]; then
            local root_dataset=$(echo "$root_datasets" | head -1)
            if confirm_repair "Set bootfs property to $root_dataset"; then
                execute_repair "zpool set bootfs=$root_dataset $pool" "Setting bootfs property"
            fi
        fi
    fi
    
    # Check cachefile property
    local cachefile=$(zpool get -H -o value cachefile "$pool")
    if [[ "$cachefile" == "-" ]]; then
        print_warning "Cachefile property not set on pool $pool"
        if confirm_repair "Set cachefile property"; then
            execute_repair "zpool set cachefile=/etc/zfs/zpool.cache $pool" "Setting cachefile property"
        fi
    else
        print_success "Cachefile property set: $cachefile"
    fi
}

# Perform automatic scrub if none has been done
auto_scrub_check() {
    local pool="$1"
    print_header "Auto Scrub Check: $pool"
    
    local scrub_status=$(zpool status "$pool" | grep -A1 "scan:")
    
    if echo "$scrub_status" | grep -q "none requested"; then
        print_warning "No scrub has been performed on pool $pool"
        if confirm_repair "Start initial scrub on pool $pool"; then
            execute_repair "zpool scrub $pool" "Starting initial scrub"
        fi
    elif echo "$scrub_status" | grep -q "scrub in progress"; then
        print_success "Scrub already in progress for pool $pool"
    else
        # Check scrub age
        if echo "$scrub_status" | grep -q "scrub repaired.*ago"; then
            local scrub_age=$(echo "$scrub_status" | grep -o "[0-9]\+ days ago" | head -1)
            if [[ -n "$scrub_age" ]]; then
                local days=$(echo "$scrub_age" | grep -o "[0-9]\+")
                if [[ $days -gt 30 ]]; then
                    print_warning "Last scrub was $scrub_age (recommended: monthly)"
                    if confirm_repair "Start maintenance scrub on pool $pool"; then
                        execute_repair "zpool scrub $pool" "Starting maintenance scrub"
                    fi
                fi
            fi
        fi
    fi
}

# Check pool status
check_pool_status() {
    local pool="$1"
    print_header "Pool Status: $pool"
    
    local status=$(zpool status "$pool" | grep "state:" | awk '{print $2}')
    
    case "$status" in
        "ONLINE")
            print_success "Pool $pool is ONLINE and healthy"
            ;;
        "DEGRADED")
            print_warning "Pool $pool is DEGRADED - repair needed"
            ;;
        "FAULTED"|"OFFLINE"|"UNAVAIL")
            print_error "Pool $pool is in critical state: $status"
            ;;
        *)
            print_warning "Pool $pool has unknown status: $status"
            ;;
    esac
}

# Check pool capacity and suggest actions
check_pool_capacity() {
    local pool="$1"
    print_header "Capacity Check: $pool"
    
    local capacity=$(zpool list -H -o cap "$pool" | tr -d '%')
    
    if [[ $capacity -gt 90 ]]; then
        print_error "Pool $pool is $capacity% full (critical)"
        print_repair "Immediate action required: free space or add storage"
    elif [[ $capacity -gt 80 ]]; then
        print_warning "Pool $pool is $capacity% full (warning)"
        print_repair "Consider freeing space or adding storage soon"
    else
        print_success "Pool $pool capacity is $capacity% (healthy)"
    fi
}

# Check ARC statistics
check_arc_stats() {
    print_header "ARC Statistics"
    
    if [[ -f /proc/spl/kstat/zfs/arcstats ]]; then
        local arc_size=$(grep "^size" /proc/spl/kstat/zfs/arcstats | awk '{print $3}')
        local arc_max=$(grep "^c_max" /proc/spl/kstat/zfs/arcstats | awk '{print $3}')
        local hit_ratio=$(awk '/^arc_hits/ {hits=$3} /^arc_misses/ {misses=$3} END {printf "%.2f", hits/(hits+misses)*100}' /proc/spl/kstat/zfs/arcstats)
        
        print_success "ARC Hit Ratio: $hit_ratio%"
        print_success "ARC Size: $(($arc_size / 1024 / 1024)) MB / $(($arc_max / 1024 / 1024)) MB"
    else
        print_warning "ARC statistics not available"
    fi
}

# Main execution
main() {
    local scrub_pools=false
    local specific_pool=""
    local check_boot_components=true
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --repair)
                AUTO_REPAIR=true
                shift
                ;;
            --force)
                FORCE_REPAIR=true
                AUTO_REPAIR=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --scrub)
                scrub_pools=true
                shift
                ;;
            --pool)
                specific_pool="$2"
                shift 2
                ;;
            --skip-boot-check)
                check_boot_components=false
                shift
                ;;
            --help)
                echo "Usage: $0 [OPTIONS]"
                echo "Options:"
                echo "  --repair          Enable automatic repairs (interactive)"
                echo "  --force           Force all repairs without prompting"
                echo "  --dry-run         Show what would be repaired without doing it"
                echo "  --scrub           Start scrub operation on pools"
                echo "  --pool POOLNAME   Check/repair specific pool only"
                echo "  --skip-boot-check Skip boot component checks"
                echo "  --help            Show this help message"
                echo ""
                echo "Compatible with systems installed via voidZFSInstallRepo.sh"
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    print_header "ZFS Health Check for Void Linux (voidZFSInstallRepo.sh compatible) - $(date)"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_warning "DRY RUN MODE: No actual changes will be made"
    fi
    
    if [[ "$AUTO_REPAIR" == true ]]; then
        print_warning "AUTO REPAIR MODE: Issues will be automatically repaired"
    fi
    
    check_root
    check_zfs_availability
    
    # Boot-related repairs specific to voidZFSInstallRepo.sh installation
    if [[ "$check_boot_components" == true ]]; then
        repair_missing_hostid
        repair_zfs_services
        check_zfs_encryption_keys
        repair_dracut_initramfs
        repair_zfsbootmenu
        check_efi_boot_entries
        check_zfs_layout
    fi
    
    # Get pools to check
    if [[ -n "$specific_pool" ]]; then
        pools="$specific_pool"
    else
        pools=$(get_zfs_pools)
    fi
    
    if [[ -z "$pools" ]]; then
        print_warning "No ZFS pools found"
        exit 0
    fi
    
    # Check and repair each pool
    for pool in $pools; do
        check_pool_status "$pool"
        repair_pool_issues "$pool"
        repair_pool_errors "$pool"
        check_pool_capacity "$pool"
        repair_boot_properties "$pool"
        
        if [[ "$scrub_pools" == true ]] || [[ "$AUTO_REPAIR" == true ]]; then
            auto_scrub_check "$pool"
        fi
    done
    
    repair_zfs_filesystem_mounts
    check_arc_stats
    
    print_header "ZFS Health Check Complete"
    print_success "Log saved to: $LOG_FILE"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_warning "This was a dry run. Use --repair to perform actual fixes."
    fi
}

# Run main function with all arguments
main "$@"
