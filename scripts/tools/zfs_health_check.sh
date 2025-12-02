#!/bin/bash
# filepath: zfs_health_check.sh

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
    
    if [[ "$FORCE_REPAIR" == true ]]; then
        return 0
    fi
    
    if [[ "$AUTO_REPAIR" == false ]]; then
        echo -e "${YELLOW}Repair action required: $action${NC}"
        read -p "Do you want to proceed? [y/N]: " -n 1 -r reply
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
        print_repair "DRY RUN: Would execute: $command"
        return 0
    fi
    
    print_repair "Executing: $description"
    log_message "[$timestamp] EXECUTING: $command"
    
    if eval "$command" 2>&1 | tee -a "$LOG_FILE"; then
        print_success "Repair completed: $description"
        return 0
    else
        print_error "Repair failed: $description"
        return 1
    fi
}

# Check if ZFS is available and repair if needed
check_zfs_availability() {
    local needs_repair=false
    
    if ! command -v zpool &> /dev/null; then
        print_error "ZFS tools not found. Install with: xbps-install -S zfs"
        exit 1
    fi
    
    if ! lsmod | grep -q zfs; then
        print_error "ZFS kernel module not loaded"
        needs_repair=true
        
        if [[ "$AUTO_REPAIR" == true ]] && confirm_repair "Load ZFS kernel module"; then
            execute_repair "modprobe zfs" "Loading ZFS kernel module"
        else
            exit 1
        fi
    else
        print_success "ZFS kernel module is loaded"
    fi
}

# Check and fix ZFS hostid only if missing or corrupted
check_and_repair_hostid() {
    print_header "ZFS Host ID Check"
    local needs_repair=false
    local hostid_content
    
    if [[ ! -f /etc/hostid ]]; then
        print_warning "ZFS hostid file missing"
        needs_repair=true
    else
        # Validate hostid format (should be 8 hex chars)
        hostid_content=$(xxd -p /etc/hostid 2>/dev/null | tr -d '\n' || echo "invalid")
        if [[ ${#hostid_content} -eq 8 ]] && [[ "$hostid_content" =~ ^[0-9a-f]{8}$ ]]; then
            print_success "ZFS hostid file exists and is valid: $hostid_content"
        else
            print_warning "ZFS hostid appears corrupted"
            needs_repair=true
        fi
    fi
    
    if [[ "$needs_repair" == true ]] && [[ "$AUTO_REPAIR" == true ]]; then
        if confirm_repair "Generate/repair ZFS hostid"; then
            execute_repair "zgenhostid" "Generating ZFS hostid"
        fi
    fi
}

# Check and repair ZFS services only if they have issues
check_and_repair_zfs_services() {
    print_header "ZFS Services Check"
    local services_need_repair=false
    local -a zfs_services=("zfs-import" "zfs-mount")
    local service
    local service_path
    local service_link
    local status
    
    for service in "${zfs_services[@]}"; do
        service_path="/etc/sv/$service"
        service_link="/var/service/$service"
        
        if [[ -d "$service_path" ]]; then
            if [[ -L "$service_link" ]]; then
                status=$(sv status "$service" 2>/dev/null || echo "down")
                if [[ "$status" =~ "run" ]]; then
                    print_success "Service $service is running"
                else
                    print_warning "Service $service is not running: $status"
                    services_need_repair=true
                    
                    if [[ "$AUTO_REPAIR" == true ]] && confirm_repair "Start $service service"; then
                        execute_repair "sv up $service" "Starting $service service"
                    fi
                fi
            else
                print_warning "Service $service not enabled"
                services_need_repair=true
                
                if [[ "$AUTO_REPAIR" == true ]] && confirm_repair "Enable $service service"; then
                    execute_repair "ln -sf $service_path $service_link" "Enabling $service service"
                fi
            fi
        else
            print_warning "Service $service not found - ZFS may not be properly installed"
        fi
    done
    
    if [[ "$services_need_repair" == true ]] && [[ "$AUTO_REPAIR" == true ]]; then
        print_repair "Waiting for services to stabilize..."
        sleep 3
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
        # Check permissions
        perms=$(stat -c "%a" "$key_file")
        if [[ "$perms" == "400" ]]; then
            print_success "ZFS encryption key found with secure permissions"
        else
            print_warning "ZFS key permissions are not secure: $perms"
            key_issues=true
            
            if [[ "$AUTO_REPAIR" == true ]] && confirm_repair "Secure ZFS key permissions"; then
                execute_repair "chmod 400 $key_file" "Setting secure permissions on ZFS key"
            fi
        fi
    else
        print_error "ZFS encryption key missing: $key_file"
        print_error "This may prevent pool import on reboot!"
        key_issues=true
    fi
    
    # Check backup keys
    if [[ -d "$backup_key_dir" ]]; then
        if [[ -f "$backup_key_dir/zroot.key" ]]; then
            print_success "ZFS key backup found"
        else
            print_warning "ZFS key backup missing"
            key_issues=true
        fi
    else
        print_warning "ZFS key backup directory missing: $backup_key_dir"
        key_issues=true
    fi
}

# Check and repair dracut initramfs only if issues detected
check_and_repair_dracut_initramfs() {
    print_header "Dracut Initramfs Check"
    local needs_rebuild=false
    local current_kernel=$(uname -r)
    local initramfs_path="/boot/initramfs-${current_kernel}.img"
    local dracut_zfs_conf="/etc/dracut.conf.d/zfs.conf"
    local -a required_items=("zfs" "zroot.key")
    local item
    
    # Check specific dracut config from installation
    if [[ -f "$dracut_zfs_conf" ]]; then
        print_success "Dracut ZFS configuration found"
        
        # Validate key components from voidZFSInstallRepo.sh
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
    else
        if ! lsinitrd "$initramfs_path" 2>/dev/null | grep "zfs.ko"; then
            print_warning "ZFS module not found in initramfs"
            needs_rebuild=true
        else
            print_success "ZFS module found in initramfs"
        fi
        
        if ! lsinitrd "$initramfs_path" 2>/dev/null | grep "zroot.key"; then
            print_warning "ZFS encryption key not found in initramfs"
            needs_rebuild=true
        else
            print_success "ZFS encryption key found in initramfs"
        fi
    fi
    
    # Only rebuild if issues were found
    if [[ "$needs_rebuild" == true ]] && [[ "$AUTO_REPAIR" == true ]]; then
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
    elif [[ "$needs_rebuild" == false ]]; then
        print_success "Initramfs has proper ZFS support"
    fi
}

# Check and repair ZFSBootMenu only if issues found
check_and_repair_zfsbootmenu() {
    print_header "ZFSBootMenu Check"
    local zbm_issues=false
    local zbm_config="/etc/zfsbootmenu/config.yaml"
    local zbm_esp="/boot/efi/EFI/ZBM"
    local zbm_dracut_dir="/etc/zfsbootmenu/dracut.conf.d"
    local keymap_conf="$zbm_dracut_dir/keymap.conf"
    
    if ! command -v generate-zbm &> /dev/null; then
        print_warning "ZFSBootMenu not installed"
        zbm_issues=true
        
        if [[ "$AUTO_REPAIR" == true ]] && confirm_repair "Install ZFSBootMenu"; then
            execute_repair "xbps-install -Sy zfsbootmenu" "Installing ZFSBootMenu"
        fi
        return
    else
        print_success "ZFSBootMenu is installed"
    fi
    
    # Check main ZBM configuration
    if [[ -f "$zbm_config" ]]; then
        # Check key settings from installation script
        if grep -q "ImageDir: /boot/efi/EFI/ZBM" "$zbm_config" && \
           grep -q "BootMountPoint: /boot/efi" "$zbm_config"; then
            print_success "ZFSBootMenu configuration is correct"
        else
            print_warning "ZFSBootMenu configuration may be outdated"
            zbm_issues=true
        fi
    else
        print_warning "ZFSBootMenu configuration missing"
        zbm_issues=true
    fi
    
    # Check dracut configuration directory
    if [[ ! -d "$zbm_dracut_dir" ]]; then
        print_warning "ZFSBootMenu dracut config directory missing"
        zbm_issues=true
    else
        print_success "ZFSBootMenu dracut directory exists"
    fi
    
    # Check keymap config
    if [[ ! -f "$keymap_conf" ]]; then
        print_warning "ZFSBootMenu keymap configuration missing"
        zbm_issues=true
    else
        print_success "ZFSBootMenu keymap configuration found"
    fi
    
    # Check ESP directory and images
    if [[ ! -d "$zbm_esp" ]]; then
        print_warning "ZFSBootMenu ESP directory missing"
        zbm_issues=true
    else
        print_success "ZFSBootMenu ESP directory exists"
    fi
    
    # Check for ZBM EFI images
    if ! ls "$zbm_esp"/vmlinuz*.efi &> /dev/null; then
        print_warning "ZFSBootMenu EFI images missing"
        zbm_issues=true
    else
        print_success "ZFSBootMenu EFI images found"
        
        # Check for backup image
        if [[ -f "$zbm_esp/vmlinuz.efi" ]] && [[ ! -f "$zbm_esp/vmlinuz-backup.efi" ]]; then
            print_warning "ZFSBootMenu backup image missing"
            zbm_issues=true
        else
            print_success "ZFSBootMenu backup image exists"
        fi
    fi
    
    # Only repair if issues were found
    if [[ "$zbm_issues" == true ]] && [[ "$AUTO_REPAIR" == true ]]; then
        # Create missing configuration
        if [[ ! -f "$zbm_config" ]] && confirm_repair "Create ZFSBootMenu configuration"; then
            execute_repair "mkdir -p /etc/zfsbootmenu" "Creating ZBM config directory"
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
        
        # Create missing dracut directory
        if [[ ! -d "$zbm_dracut_dir" ]] && confirm_repair "Create ZFSBootMenu dracut directory"; then
            execute_repair "mkdir -p $zbm_dracut_dir" "Creating ZBM dracut config directory"
        fi
        
        # Create missing keymap config
        if [[ ! -f "$keymap_conf" ]] && confirm_repair "Create keymap configuration"; then
            execute_repair "cat > $keymap_conf << 'EOF'
install_optional_items+=\" /etc/cmdline.d/keymap.conf \"
EOF" "Creating keymap configuration"
            
            execute_repair "mkdir -p /etc/cmdline.d" "Creating cmdline.d directory"
            execute_repair "cat > /etc/cmdline.d/keymap.conf << 'EOF'
rd.vconsole.keymap=en
EOF" "Creating keymap cmdline configuration"
        fi
        
        # Create missing ESP directory
        if [[ ! -d "$zbm_esp" ]] && confirm_repair "Create ZFSBootMenu ESP directory"; then
            execute_repair "mkdir -p $zbm_esp" "Creating ZBM ESP directory"
        fi
        
        # Generate missing EFI images
        if ! ls "$zbm_esp"/vmlinuz*.efi &> /dev/null && confirm_repair "Generate ZFSBootMenu images"; then
            execute_repair "zbm-builder.sh" "Building ZFSBootMenu images"
        fi
        
        # Create missing backup image
        if [[ -f "$zbm_esp/vmlinuz.efi" ]] && [[ ! -f "$zbm_esp/vmlinuz-backup.efi" ]] && confirm_repair "Create backup ZFSBootMenu image"; then
            execute_repair "cp $zbm_esp/vmlinuz.efi $zbm_esp/vmlinuz-backup.efi" "Creating backup ZBM image"
        fi
    fi
}

# Check EFI boot entries without repair
check_efi_boot_entries() {
    print_header "EFI Boot Entries Check"
    local zbm_entries
    
    if ! command -v efibootmgr &> /dev/null; then
        print_warning "efibootmgr not found"
        return
    fi
    
    # Check for ZFSBootMenu entries
    zbm_entries=$(efibootmgr | grep -c "ZFSBootMenu" || echo "0")
    
    if [[ "$zbm_entries" -eq 0 ]]; then
        print_warning "No ZFSBootMenu EFI entries found"
        print_repair "Boot entries may need to be recreated manually"
    elif [[ "$zbm_entries" -eq 1 ]]; then
        print_warning "Only one ZFSBootMenu entry found (backup missing)"
    else
        print_success "ZFSBootMenu EFI entries found: $zbm_entries"
    fi
    
    # Show current entries
    efibootmgr | grep -E "(Boot|ZFSBootMenu)" | head -10
}

# Check ZFS layout without repair
check_zfs_layout() {
    print_header "ZFS Layout Verification"
    local root_datasets
    local subdir
    
    # Check for expected pool structure from installation
    if zpool list zroot &>/dev/null; then
        print_success "Pool 'zroot' found"
        
        # Check ROOT dataset
        if zfs list zroot/ROOT &>/dev/null; then
            print_success "ROOT dataset exists"
            
            # Check for system datasets
            if zfs list | grep -q "zroot/ROOT/"; then
                root_datasets=$(zfs list -H -o name | grep "zroot/ROOT/" | wc -l)
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
        
        # Check swap dataset and repair if needed
        if zfs list zroot/swap &>/dev/null; then
            print_success "Swap dataset exists"
            
            # Check if swap is active
            if swapon --show=NAME | grep -q "/dev/zd0"; then
                print_success "ZFS swap is active"
            else
                print_warning "ZFS swap exists but not active"
                if [[ "$AUTO_REPAIR" == true ]] && confirm_repair "Activate ZFS swap"; then
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

# Check and repair pool issues only when found
check_and_repair_pool_issues() {
    local pool="$1"
    print_header "Pool Status Check: $pool"
    local status=$(zpool status "$pool" | grep "state:" | awk '{print $2}')
    local pool_has_issues=false
    local device
    local line
    local new_status
    
    case "$status" in
        "ONLINE")
            print_success "Pool $pool is ONLINE and healthy"
            ;;
        "DEGRADED")
            print_warning "Pool $pool is DEGRADED"
            pool_has_issues=true
            
            if [[ "$AUTO_REPAIR" == true ]]; then
                # Check for devices that can be cleared
                if zpool status "$pool" | grep -q "FAULTED.*was /dev/"; then
                    if confirm_repair "Clear faulted devices in pool $pool"; then
                        # Get faulted devices and try to clear them
                        while read -r line; do
                            device=$(echo "$line" | awk '{print $1}')
                            execute_repair "zpool clear $pool $device" "Clearing faulted device $device"
                        done < <(zpool status "$pool" | grep "FAULTED")
                    fi
                fi
                
                # Check for offline devices that can be brought online
                if zpool status "$pool" | grep -q "OFFLINE"; then
                    if confirm_repair "Bring offline devices online in pool $pool"; then
                        while read -r line; do
                            device=$(echo "$line" | awk '{print $1}')
                            execute_repair "zpool online $pool $device" "Bringing device $device online"
                        done < <(zpool status "$pool" | grep "OFFLINE")
                    fi
                fi
            fi
            ;;
        "FAULTED")
            print_error "Pool $pool is FAULTED"
            pool_has_issues=true
            
            if [[ "$AUTO_REPAIR" == true ]] && confirm_repair "Attempt to clear pool errors"; then
                execute_repair "zpool clear $pool" "Clearing pool errors"
            fi
            ;;
        "UNAVAIL")
            print_error "Pool $pool is UNAVAILABLE"
            pool_has_issues=true
            
            if [[ "$AUTO_REPAIR" == true ]] && confirm_repair "Force import pool $pool"; then
                execute_repair "zpool import -f $pool" "Force importing pool"
            fi
            ;;
    esac
    
    if [[ "$pool_has_issues" == true ]] && [[ "$AUTO_REPAIR" == true ]]; then
        print_repair "Waiting for pool to stabilize..."
        sleep 2
        new_status=$(zpool status "$pool" | grep "state:" | awk '{print $2}')
        print_repair "Pool $pool status after repair: $new_status"
    fi
}

# Check and repair pool errors only when found
check_and_repair_pool_errors() {
    local pool="$1"
    print_header "Pool Error Check: $pool"
    
    if ! zpool status "$pool" | grep -q "errors: No known data errors"; then
        print_warning "Data errors detected in pool $pool"
        zpool status -v "$pool"
        
        if [[ "$AUTO_REPAIR" == true ]] && confirm_repair "Start scrub to repair data errors in pool $pool"; then
            execute_repair "zpool scrub $pool" "Starting repair scrub"
            print_repair "Scrub started. Monitor progress with: zpool status $pool"
        fi
    else
        print_success "No data errors found in pool $pool"
    fi
}

# Check and repair filesystem mount issues only when found
check_and_repair_zfs_filesystem_mounts() {
    print_header "ZFS Filesystem Mount Check"
    local mount_issues=false
    local dataset
    local mounted
    local canmount
    local mountpoint
    
    # Check unmounted datasets
    while IFS=$'\t' read -r dataset mounted; do
        if [[ "$mounted" == "no" ]]; then
            # Check if dataset should be mounted (canmount property)
            canmount=$(zfs get -H -o value canmount "$dataset")
            mountpoint=$(zfs get -H -o value mountpoint "$dataset")
            
            if [[ "$canmount" == "on" && "$mountpoint" != "none" && "$mountpoint" != "legacy" ]]; then
                print_warning "Dataset $dataset should be mounted but isn't"
                mount_issues=true
                
                if [[ "$AUTO_REPAIR" == true ]] && confirm_repair "Mount dataset $dataset"; then
                    execute_repair "zfs mount $dataset" "Mounting dataset $dataset"
                fi
            fi
        fi
    done < <(zfs list -H -o name,mounted 2>/dev/null)
    
    if [[ "$mount_issues" == false ]]; then
        print_success "All ZFS filesystems are properly mounted"
    fi
}

# Check and repair boot properties only when needed
check_and_repair_boot_properties() {
    local pool="$1"
    print_header "Boot Properties Check: $pool"
    local boot_issues=false
    local bootfs=$(zpool get -H -o value bootfs "$pool")
    local cachefile
    local root_datasets
    local root_dataset
    
    if [[ "$bootfs" != "-" ]]; then
        print_success "Bootfs property set: $bootfs"
        
        # Verify the bootfs dataset exists
        if zfs list "$bootfs" &>/dev/null; then
            print_success "Bootfs dataset exists and is accessible"
        else
            print_error "Bootfs dataset does not exist: $bootfs"
            boot_issues=true
        fi
    else
        print_warning "Bootfs property not set on pool $pool"
        boot_issues=true
        
        if [[ "$AUTO_REPAIR" == true ]]; then
            # Try to detect root dataset
            root_datasets=$(zfs list -H -o name | grep "^$pool/ROOT/" || true)
            if [[ -n "$root_datasets" ]]; then
                root_dataset=$(echo "$root_datasets" | head -1)
                if confirm_repair "Set bootfs property to $root_dataset"; then
                    execute_repair "zpool set bootfs=$root_dataset $pool" "Setting bootfs property"
                fi
            fi
        fi
    fi
    
    # Check cachefile property
    cachefile=$(zpool get -H -o value cachefile "$pool")
    if [[ "$cachefile" == "-" ]]; then
        print_warning "Cachefile property not set on pool $pool"
        boot_issues=true
        
        if [[ "$AUTO_REPAIR" == true ]] && confirm_repair "Set cachefile property"; then
            execute_repair "zpool set cachefile=/etc/zfs/zpool.cache $pool" "Setting cachefile property"
        fi
    else
        print_success "Cachefile property set: $cachefile"
    fi
}

# Check scrub status and perform if needed
check_and_perform_scrub() {
    local pool="$1"
    local force_scrub="$2"
    print_header "Scrub Status Check: $pool"
    local scrub_status=$(zpool status "$pool" | grep -A1 "scan:")
    local scrub_needed=false
    local scrub_age
    local days
    local scrub_type
    
    if echo "$scrub_status" | grep -q "none requested"; then
        print_warning "No scrub has been performed on pool $pool"
        scrub_needed=true
    elif echo "$scrub_status" | grep -q "scrub in progress"; then
        print_success "Scrub already in progress for pool $pool"
        return
    else
        # Check scrub age
        if echo "$scrub_status" | grep -q "scrub repaired.*ago"; then
            scrub_age=$(echo "$scrub_status" | grep -o "[0-9]\+ days ago" | head -1)
            if [[ -n "$scrub_age" ]]; then
                days=$(echo "$scrub_age" | grep -o "[0-9]\+")
                if [[ $days -gt 30 ]]; then
                    print_warning "Last scrub was $scrub_age (recommended: monthly)"
                    scrub_needed=true
                else
                    print_success "Last scrub was recent: $scrub_age"
                fi
            fi
        else
            print_success "Scrub status appears normal"
        fi
    fi
    
    # Only scrub if needed or forced
    if ([[ "$scrub_needed" == true ]] && [[ "$AUTO_REPAIR" == true ]]) || [[ "$force_scrub" == true ]]; then
        scrub_type="maintenance"
        [[ "$scrub_needed" == true ]] && scrub_type="initial"
        
        if confirm_repair "Start $scrub_type scrub on pool $pool"; then
            execute_repair "zpool scrub $pool" "Starting $scrub_type scrub"
        fi
    fi
}

# Check pool capacity
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
    local arc_size
    local arc_max
    local hit_ratio
    
    if [[ -f /proc/spl/kstat/zfs/arcstats ]]; then
        arc_size=$(grep "^size" /proc/spl/kstat/zfs/arcstats | awk '{print $3}')
        arc_max=$(grep "^c_max" /proc/spl/kstat/zfs/arcstats | awk '{print $3}')
        hit_ratio=$(awk '/^arc_hits/ {hits=$3} /^arc_misses/ {misses=$3} END {printf "%.2f", hits/(hits+misses)*100}' /proc/spl/kstat/zfs/arcstats)
        
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
    local pools
    local pool
    
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
                AUTO_REPAIR=true  # Enable repair logic for dry-run
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
    
    if [[ "$AUTO_REPAIR" == true ]] && [[ "$DRY_RUN" == false ]]; then
        print_warning "AUTO REPAIR MODE: Issues will be automatically repaired"
    fi
    
    check_root
    check_zfs_availability
    
    # Boot-related checks and repairs (only repair when issues found)
    if [[ "$check_boot_components" == true ]]; then
        check_and_repair_hostid
        check_and_repair_zfs_services  
        check_and_repair_zfs_encryption_keys
        check_and_repair_dracut_initramfs
        check_and_repair_zfsbootmenu
        check_efi_boot_entries  # Check only, no auto-repair
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
    
    # Check and repair each pool (only when issues found)
    for pool in $pools; do
        check_and_repair_pool_issues "$pool"
        check_and_repair_pool_errors "$pool"
        check_pool_capacity "$pool"  # Check only
        check_and_repair_boot_properties "$pool"
        check_and_perform_scrub "$pool" "$scrub_pools"
    done
    
    check_and_repair_zfs_filesystem_mounts
    check_arc_stats  # Check only
    
    print_header "ZFS Health Check Complete"
    print_success "Log saved to: $LOG_FILE"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_warning "This was a dry run. Use --repair to perform actual fixes."
    fi
}

# Run main function with all arguments
main "$@"
