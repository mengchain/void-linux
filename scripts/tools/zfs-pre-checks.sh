#!/bin/bash
# filepath: zfs-pre-checks.sh
# ZFS Pre-Update Checks for Void Linux with ZFSBootMenu Support
# This script performs comprehensive PRE-CHECKS ONLY
# NO BACKUPS - NO MODIFICATIONS - VALIDATION ONLY
#
# References:
# - ZFS Administration Guide: https://openzfs.github.io/openzfs-docs/
# - Void Linux Handbook: https://docs.voidlinux.org/
# - ZFSBootMenu Documentation: https://docs.zfsbootmenu.org/

set -euo pipefail

# Configuration
LOG_FILE="/var/log/zfs-pre-checks-$(date +%Y%m%d-%H%M%S).log"
CONFIG_FILE="/etc/zfs-update.conf"
ZBM_CONFIG="/etc/zfsbootmenu/config.yaml"

# Global variables for cross-function validation results
ZBM_DETECTED=false
TOTAL_UPDATES=0
ZFS_COUNT=0
ZBM_COUNT=0
DRACUT_COUNT=0
KERNEL_COUNT=0
POOLS_EXIST=false
ESP_MOUNTED=false
ESP_MOUNT="/boot/efi"

# Colors for output - Consistent with other scripts
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[1;94m'      # Light Blue (bright blue)
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Standardized logging functions
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

# Error handling
error_exit() {
    error "$1"
    log "Pre-checks failed. Address issues before proceeding with updates."
    exit 1
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root"
    fi
}

# Validate system requirements
validate_dependencies() {
    header "Validating System Dependencies"
    
    local missing_deps=()
    local required_commands=(zfs zpool xbps-install xbps-query)
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
            error "Required command not found: $cmd"
        else
            info "Found: $cmd"
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        error_exit "Missing required dependencies: ${missing_deps[*]}"
    fi
    
    success "All required dependencies present"
}

# Check for available updates FIRST
check_available_updates() {
    header "Checking for Available Updates"
    
    info "Querying XBPS repository for updates..."
    
    # Sync repository first
    if ! xbps-install -S 2>&1 | tee -a "$LOG_FILE"; then
        error "Failed to sync repository"
        return 1
    fi
    
    # Check for updates - FIXED SIGPIPE
    local update_output
    update_output=$(xbps-install -un 2>/dev/null || echo "")
    
    if [[ -z "$update_output" ]]; then
        success "No updates available - system is up to date"
        info "Nothing to do. Exiting."
        exit 0
    fi
    
    # Parse and categorize updates
    info "Analyzing available updates..."
    
    local all_packages
    all_packages=$(echo "$update_output" | awk '{print $1}' | tr '\n' ' ')
    
    # Count and categorize packages
    for pkg in $all_packages; do
        ((TOTAL_UPDATES++))
        
        case "$pkg" in
            zfs|zfs-*)
                ((ZFS_COUNT++))
                info "ZFS package: $pkg"
                ;;
            zfsbootmenu|zfsbootmenu-*)
                ((ZBM_COUNT++))
                info "ZFSBootMenu package: $pkg"
                ;;
            dracut|dracut-*)
                ((DRACUT_COUNT++))
                info "Dracut package: $pkg"
                ;;
            linux|linux[0-9]*|linux-headers*)
                ((KERNEL_COUNT++))
                info "Kernel package: $pkg"
                ;;
        esac
    done
    
    # Display summary
    echo ""
    success "Found $TOTAL_UPDATES package(s) with updates available"
    
    if [[ $ZFS_COUNT -gt 0 ]]; then
        warning "ZFS packages: $ZFS_COUNT (requires special handling)"
    fi
    
    if [[ $KERNEL_COUNT -gt 0 ]]; then
        warning "Kernel packages: $KERNEL_COUNT (requires reboot)"
    fi
    
    if [[ $DRACUT_COUNT -gt 0 ]]; then
        info "Dracut packages: $DRACUT_COUNT (initramfs rebuild required)"
    fi
    
    if [[ $ZBM_COUNT -gt 0 ]]; then
        info "ZFSBootMenu packages: $ZBM_COUNT (bootloader update required)"
    fi
    
    # Store package list for installation script
    export PACKAGES_TO_UPDATE="$all_packages"
    
    return 0
}

# Check ZFS system health
check_zfs_health() {
    header "ZFS System Health Check"
    
    # Check if ZFS module is loaded
    info "Checking ZFS kernel module..."
    if ! lsmod | grep -q "^zfs "; then
        error "ZFS module is not loaded"
        error "Load with: modprobe zfs"
        return 1
    fi
    success "ZFS module is loaded"
    
    # Get ZFS module version - FIXED SIGPIPE
    local zfs_version
    zfs_version=$(modinfo zfs 2>/dev/null | grep "^version:" | awk '{print $2}' || echo "unknown")
    info "ZFS module version: $zfs_version"
    
    # Check for ZFS pools
    info "Checking for ZFS pools..."
    local pools
    pools=$(zpool list -H -o name 2>/dev/null || echo "")
    
    if [[ -z "$pools" ]]; then
        warning "No ZFS pools found"
        POOLS_EXIST=false
        return 0
    fi
    
    POOLS_EXIST=true
    success "ZFS pools detected"
    
    # Check health of each pool
    local unhealthy_pools=0
    while IFS= read -r pool; do
        [[ -z "$pool" ]] && continue
        
        local health
        health=$(zpool list -H -o health "$pool" 2>/dev/null || echo "UNKNOWN")
        
        if [[ "$health" == "ONLINE" ]]; then
            success "Pool '$pool' is ONLINE"
        else
            error "Pool '$pool' status: $health"
            ((unhealthy_pools++))
        fi
        
        # Check for pool errors
        local errors
        errors=$(zpool status "$pool" | grep -E "errors:|state:" | tail -2)
        if echo "$errors" | grep -qE "DEGRADED|FAULTED|UNAVAIL"; then
            error "Pool '$pool' has issues:"
            echo "$errors" | tee -a "$LOG_FILE"
            ((unhealthy_pools++))
        fi
    done <<< "$pools"
    
    if [[ $unhealthy_pools -gt 0 ]]; then
        error "Found $unhealthy_pools unhealthy pool(s)"
        error "Fix pool issues before updating"
        return 1
    fi
    
    success "All ZFS pools are healthy"
    return 0
}

# Check ZFS dataset health
check_zfs_datasets() {
    header "ZFS Dataset Health Check"
    
    if [[ "$POOLS_EXIST" != "true" ]]; then
        info "No ZFS pools - skipping dataset check"
        return 0
    fi
    
    info "Checking ZFS datasets..."
    
    # Get all filesystems - FIXED SIGPIPE
    local datasets
    datasets=$(zfs list -H -o name,mounted,mountpoint -t filesystem 2>/dev/null || echo "")
    
    if [[ -z "$datasets" ]]; then
        warning "No ZFS datasets found"
        return 0
    fi
    
    local dataset_count=0
    local unmounted_count=0
    
    while IFS=$'\t' read -r name mounted mountpoint; do
        [[ -z "$name" ]] && continue
        ((dataset_count++))
        
        if [[ "$mounted" == "yes" ]]; then
            info "Dataset '$name' mounted at: $mountpoint"
        else
            warning "Dataset '$name' is NOT mounted"
            ((unmounted_count++))
        fi
    done <<< "$datasets"
    
    success "Found $dataset_count dataset(s)"
    
    if [[ $unmounted_count -gt 0 ]]; then
        warning "$unmounted_count dataset(s) not mounted"
    fi
    
    # Check for snapshots
    local snapshot_count
    snapshot_count=$(zfs list -t snapshot -H 2>/dev/null | wc -l || echo "0")
    info "Existing snapshots: $snapshot_count"
    
    return 0
}

# Detect and validate ZFSBootMenu setup
check_zfsbootmenu() {
    header "ZFSBootMenu Detection"
    
    # Check if ZFSBootMenu is installed
    if ! command -v generate-zbm &>/dev/null; then
        info "ZFSBootMenu not installed - traditional bootloader setup"
        ZBM_DETECTED=false
        return 0
    fi
    
    info "ZFSBootMenu is installed"
    ZBM_DETECTED=true
    
    # Check ZFSBootMenu configuration
    if [[ ! -f "$ZBM_CONFIG" ]]; then
        warning "ZFSBootMenu config not found: $ZBM_CONFIG"
        warning "May need manual configuration"
    else
        success "ZFSBootMenu config found: $ZBM_CONFIG"
        
        # Validate config syntax (basic check)
        if grep -q "Global:" "$ZBM_CONFIG" 2>/dev/null; then
            success "ZFSBootMenu config appears valid"
        else
            warning "ZFSBootMenu config may be invalid"
        fi
    fi
    
    return 0
}

# Check ESP (EFI System Partition)
check_esp() {
    header "ESP (EFI System Partition) Check"
    
    if [[ "$ZBM_DETECTED" != "true" ]]; then
        info "Not a ZFSBootMenu system - skipping ESP check"
        return 0
    fi
    
    # Find ESP mount point
    info "Locating ESP..."
    
    # Check common mount points
    local esp_candidates=("/boot/efi" "/boot" "/efi")
    local found_esp=false
    
    for mount_point in "${esp_candidates[@]}"; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            local fs_type
            fs_type=$(findmnt -n -o FSTYPE "$mount_point" 2>/dev/null || echo "")
            
            if [[ "$fs_type" == "vfat" ]]; then
                ESP_MOUNT="$mount_point"
                ESP_MOUNTED=true
                found_esp=true
                success "ESP mounted at: $ESP_MOUNT"
                break
            fi
        fi
    done
    
    if [[ "$found_esp" != "true" ]]; then
        # Try to find ESP device - FIXED SIGPIPE
        local esp_device
        esp_device=$(blkid -t TYPE=vfat 2>/dev/null | grep -E '/dev/(sd|nvme)' | cut -d: -f1 | head -1 || echo "")
        
        if [[ -n "$esp_device" ]]; then
            warning "ESP found but not mounted: $esp_device"
            info "Recommended mount point: /boot/efi"
            ESP_MOUNTED=false
        else
            error "ESP not found - required for ZFSBootMenu"
            return 1
        fi
    fi
    
    # Check ESP contents if mounted
    if [[ "$ESP_MOUNTED" == "true" ]]; then
        info "Checking ESP contents..."
        
        # Check for ZFSBootMenu EFI image
        if [[ -f "$ESP_MOUNT/EFI/ZBM/vmlinuz.efi" ]]; then
            success "ZFSBootMenu EFI image found"
            
            # Check backup
            if [[ -f "$ESP_MOUNT/EFI/ZBM/vmlinuz-backup.efi" ]]; then
                info "ZFSBootMenu backup image found"
            else
                warning "No ZFSBootMenu backup image"
            fi
        else
            warning "ZFSBootMenu EFI image not found in expected location"
            warning "Expected: $ESP_MOUNT/EFI/ZBM/vmlinuz.efi"
        fi
        
        # Check ESP free space
        local esp_free
        esp_free=$(df -h "$ESP_MOUNT" | tail -1 | awk '{print $4}')
        info "ESP free space: $esp_free"
        
        # Check if enough space (recommend at least 100MB)
        local esp_free_kb
        esp_free_kb=$(df -k "$ESP_MOUNT" | tail -1 | awk '{print $4}')
        
        if [[ $esp_free_kb -lt 102400 ]]; then
            warning "ESP has less than 100MB free space"
            warning "May need cleanup before update"
        else
            success "ESP has sufficient free space"
        fi
    fi
    
    return 0
}

# Check disk space
check_disk_space() {
    header "Disk Space Check"
    
    # Check root filesystem space
    local root_free
    root_free=$(df -h / | tail -1 | awk '{print $4}')
    local root_free_mb
    root_free_mb=$(df -m / | tail -1 | awk '{print $4}')
    
    info "Root filesystem free space: $root_free"
    
    if [[ $root_free_mb -lt 1024 ]]; then
        error "Root filesystem has less than 1GB free"
        error "Minimum 1GB recommended for updates"
        return 1
    elif [[ $root_free_mb -lt 2048 ]]; then
        warning "Root filesystem has less than 2GB free"
        warning "2GB+ recommended for safe updates"
    else
        success "Root filesystem has sufficient space"
    fi
    
    # Check /var space (for package cache and backups)
    if [[ -d /var ]]; then
        local var_free
        var_free=$(df -h /var | tail -1 | awk '{print $4}')
        local var_free_mb
        var_free_mb=$(df -m /var | tail -1 | awk '{print $4}')
        
        info "/var free space: $var_free"
        
        if [[ $var_free_mb -lt 2048 ]]; then
            warning "/var has less than 2GB free"
            warning "Recommended 2GB+ for backups and cache"
        else
            success "/var has sufficient space"
        fi
    fi
    
    # Check ZFS pool space if pools exist
    if [[ "$POOLS_EXIST" == "true" ]]; then
        info "Checking ZFS pool capacity..."
        
        local pools
        pools=$(zpool list -H -o name 2>/dev/null || echo "")
        
        while IFS= read -r pool; do
            [[ -z "$pool" ]] && continue
            
            local capacity
            capacity=$(zpool list -H -o capacity "$pool" 2>/dev/null || echo "0%")
            local cap_num
            cap_num=${capacity%\%}
            
            if [[ $cap_num -ge 90 ]]; then
                error "Pool '$pool' is ${capacity} full - CRITICAL"
                error "ZFS performance degrades above 80% capacity"
                return 1
            elif [[ $cap_num -ge 80 ]]; then
                warning "Pool '$pool' is ${capacity} full"
                warning "Consider adding space or cleaning up"
            else
                success "Pool '$pool' capacity: ${capacity}"
            fi
        done <<< "$pools"
    fi
    
    return 0
}

# Check kernel compatibility
check_kernel_compatibility() {
    header "Kernel Compatibility Check"
    
    local current_kernel
    current_kernel=$(uname -r)
    info "Current running kernel: $current_kernel"
    
    # Check if ZFS module exists for current kernel
    local zfs_module="/lib/modules/$current_kernel/extra/zfs/zfs.ko"
    
    if [[ -f "$zfs_module" ]]; then
        success "ZFS module available for current kernel"
    else
        warning "ZFS module not found: $zfs_module"
        warning "May indicate kernel/ZFS version mismatch"
    fi
    
    # Check installed kernel packages - FIXED SIGPIPE
    info "Checking installed kernels..."
    local installed_kernels
    installed_kernels=$(ls /lib/modules/ 2>/dev/null | grep -E '^[0-9]' || echo "")
    
    if [[ -n "$installed_kernels" ]]; then
        local kernel_count
        kernel_count=$(echo "$installed_kernels" | wc -l)
        info "Installed kernel versions: $kernel_count"
        
        echo "$installed_kernels" | while IFS= read -r kver; do
            [[ -z "$kver" ]] && continue
            info "  - $kver"
        done
    fi
    
    return 0
}

# Check bootloader configuration
check_bootloader() {
    header "Bootloader Configuration Check"
    
    if [[ "$ZBM_DETECTED" == "true" ]]; then
        info "Using ZFSBootMenu bootloader"
        
        # Check EFI boot entries - FIXED SIGPIPE
        if command -v efibootmgr &>/dev/null; then
            info "Checking EFI boot entries..."
            local efi_entries
            efi_entries=$(efibootmgr 2>/dev/null || echo "")
            
            if [[ -n "$efi_entries" ]]; then
                if echo "$efi_entries" | grep -qi "zfsbootmenu\|ZBM"; then
                    success "ZFSBootMenu found in EFI boot entries"
                    
                    # Show boot order
                    local boot_order
                    boot_order=$(echo "$efi_entries" | grep "BootOrder:" || echo "")
                    if [[ -n "$boot_order" ]]; then
                        info "$boot_order"
                    fi
                else
                    warning "ZFSBootMenu not found in EFI boot entries"
                    warning "May need to create boot entry"
                fi
            else
                warning "Could not read EFI boot entries"
            fi
        else
            info "efibootmgr not available - cannot check EFI entries"
        fi
    else
        info "Traditional bootloader setup detected"
        
        # Check for GRUB
        if command -v grub-mkconfig &>/dev/null; then
            info "GRUB detected"
            
            if [[ -f /boot/grub/grub.cfg ]]; then
                success "GRUB config exists: /boot/grub/grub.cfg"
            else
                warning "GRUB config not found"
            fi
        fi
    fi
    
    return 0
}


# Generate configuration file for update script
generate_config() {
    header "Generating Configuration File"
    
    info "Creating configuration: $CONFIG_FILE"
    
    cat > "$CONFIG_FILE" << EOF
# ZFS Update Configuration
# Generated by zfs-pre-checks.sh on $(date '+%Y-%m-%d %H:%M:%S')

# System Detection
ZFSBOOTMENU=$ZBM_DETECTED
POOLS_EXIST=$POOLS_EXIST
ESP_MOUNTED=$ESP_MOUNTED
ESP_MOUNT="$ESP_MOUNT"

# Update Counts
TOTAL_UPDATES=$TOTAL_UPDATES
ZFS_COUNT=$ZFS_COUNT
KERNEL_COUNT=$KERNEL_COUNT
DRACUT_COUNT=$DRACUT_COUNT
ZBM_COUNT=$ZBM_COUNT

# Packages to Update
PACKAGES_TO_UPDATE="$PACKAGES_TO_UPDATE"

# System Information
CURRENT_KERNEL="$(uname -r)"
HOSTNAME="$(hostname)"
CHECK_DATE="$(date '+%Y-%m-%d %H:%M:%S')"

# Log File
PRECHECK_LOG="$LOG_FILE"
EOF
    
    chmod 600 "$CONFIG_FILE"
    success "Configuration file created: $CONFIG_FILE"
    
    return 0
}

# Display pre-check summary
show_summary() {
    header "Pre-Check Summary"
    
    echo ""
    info "System Information:"
    info "  Hostname: $(hostname)"
    info "  Kernel: $(uname -r)"
    info "  ZFS Version: $(zfs --version | head -1)"
    echo ""
    
    info "Update Summary:"
    info "  Total packages: $TOTAL_UPDATES"
    if [[ $ZFS_COUNT -gt 0 ]]; then
        info "  ZFS packages: $ZFS_COUNT"
    fi
    if [[ $KERNEL_COUNT -gt 0 ]]; then
        info "  Kernel packages: $KERNEL_COUNT"
    fi
    if [[ $DRACUT_COUNT -gt 0 ]]; then
        info "  Dracut packages: $DRACUT_COUNT"
    fi
    if [[ $ZBM_COUNT -gt 0 ]]; then
        info "  ZFSBootMenu packages: $ZBM_COUNT"
    fi
    echo ""
    
    info "System Configuration:"
    info "  ZFSBootMenu: $([ "$ZBM_DETECTED" = "true" ] && echo "Yes" || echo "No")"
    info "  ZFS Pools: $([ "$POOLS_EXIST" = "true" ] && echo "Yes" || echo "No")"
    if [[ "$ESP_MOUNTED" == "true" ]]; then
        info "  ESP: Mounted at $ESP_MOUNT"
    fi
    echo ""
    
    success "Pre-checks completed successfully"
    echo ""
    info "Configuration saved to: $CONFIG_FILE"
    info "Log file: $LOG_FILE"
    echo ""
    
    if [[ $TOTAL_UPDATES -gt 0 ]]; then
        info "Next steps:"
        info "  1. Review this summary and log file"
        info "  2. Ensure you have time for updates and potential reboot"
        info "  3. Run: zfs-install-updates.sh"
        echo ""
        
        if [[ $KERNEL_COUNT -gt 0 ]] || [[ $ZFS_COUNT -gt 0 ]]; then
            warning "IMPORTANT: System reboot will be required after update"
        fi
    fi
}

# Main execution
main() {
    header "ZFS PRE-UPDATE CHECKS - VOID LINUX"
    
    check_root
    validate_dependencies
    
    # Check for updates FIRST
    if ! check_available_updates; then
        error_exit "Failed to check for updates"
    fi
    
    # If we got here, updates are available, continue checks
    check_zfs_health || error_exit "ZFS health check failed"
    check_zfs_datasets
    check_zfsbootmenu
    check_esp
    check_disk_space || error_exit "Insufficient disk space"
    check_kernel_compatibility
    check_bootloader
    
    # Generate configuration for update script
    generate_config
    
    # Show summary
    show_summary
    
    success "Pre-checks completed - system is ready for updates"
    
    exit 0
}

main "$@"
