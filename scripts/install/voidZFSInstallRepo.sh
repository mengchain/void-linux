#!/usr/bin/env bash
# filepath: voidZFSInstallRepo.sh
# Void Linux ZFS Installation Script
# Version: 4.3 - Helper functions moved to script
# Description: Automated ZFS-on-root installation for Void Linux

export TERM=xterm
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
    exit 1
fi

# ============================================
# Load ZFS Setup Configuration
# ============================================
# Set installation mode flag (prevents validation of non-existent paths)
export ZFS_INSTALL_MODE=1

# Try to source zfs-setup.conf from standard location
if [[ -f "/etc/zfs-setup.conf" ]]; then
    source /etc/zfs-setup.conf
# Fallback: try relative to script location (for development)
elif [[ -f "$SCRIPT_DIR/../conf/zfs-setup.conf" ]]; then
    source "$SCRIPT_DIR/../conf/zfs-setup.conf"
# Fallback: try same directory as script
elif [[ -f "$SCRIPT_DIR/zfs-setup.conf" ]]; then
    source "$SCRIPT_DIR/zfs-setup.conf"
else
    die "Cannot find zfs-setup.conf configuration file"
fi

# ============================================
# Script Configuration
# ============================================
LOG_FILE="configureNinstall.log"
FONT="drdos8x14"

# Script metadata
SCRIPT_NAME="Void Linux ZFS Installation"
SCRIPT_VERSION="4.3"

# Redirect all output to both console and log file
exec &> >(tee "$LOG_FILE")

# ============================================
# Global Variables for User Input
# ============================================
INSTALL_TYPE=""           # "first" or "dualboot"
SELECTED_DISK=""          # /dev/disk/by-id/xxx
SELECTED_DISK_NAME=""     # Just the name for display
WIPE_DISK=false           # true/false
ZFS_PASSPHRASE=""         # Encryption passphrase
ROOT_DATASET_NAME=""      # Name for root dataset
HOSTNAME=""               # System hostname
TIMEZONE=""               # System timezone
USERNAME=""               # Primary user
ROOT_PASSWORD=""          # Root password
USER_PASSWORD=""          # User password
CREATE_SWAP=false         # true/false
SWAP_SIZE=""              # e.g., "8G"

# Track EFI partition UUID
EFI_UUID=""

# ============================================
# Configuration Writer Helper Functions
# ============================================

# Write dracut ZFS configuration
write_dracut_zfs_config() {
    local target_file="${1:-$DRACUT_ZFS_CONF}"
    local target_dir
    target_dir="$(dirname "$target_file")"
    
    mkdir -p "$target_dir"
    echo "$DRACUT_ZFS_CONFIG_CONTENT" > "$target_file"
    
    return 0
}

# Write dracut main configuration
write_dracut_main_config() {
    local target_file="${1:-$DRACUT_MAIN_CONF}"
    
    echo "$DRACUT_MAIN_CONFIG_CONTENT" > "$target_file"
    
    return 0
}

# Write ZFSBootMenu configuration
write_zbm_config() {
    local target_file="${1:-$ZBM_CONFIG}"
    local target_dir
    target_dir="$(dirname "$target_file")"
    
    mkdir -p "$target_dir"
    echo "$ZBM_CONFIG_CONTENT" > "$target_file"
    
    return 0
}

# Write ZFSBootMenu keymap configuration
write_zbm_keymap_config() {
    local target_file="${1:-$ZBM_KEYMAP_CONF}"
    local target_dir
    target_dir="$(dirname "$target_file")"
    
    mkdir -p "$target_dir"
    echo "$ZBM_KEYMAP_CONFIG_CONTENT" > "$target_file"
    
    return 0
}

# Write kernel command line keymap configuration
write_cmdline_keymap() {
    local target_file="${1:-$CMDLINE_KEYMAP}"
    local target_dir
    target_dir="$(dirname "$target_file")"
    
    mkdir -p "$target_dir"
    echo "$CMDLINE_KEYMAP_CONTENT" > "$target_file"
    
    return 0
}

# Write IWD configuration
write_iwd_config() {
    local target_file="${1:-/etc/iwd/main.conf}"
    local target_dir
    target_dir="$(dirname "$target_file")"
    
    mkdir -p "$target_dir"
    echo "$IWD_MAIN_CONFIG" > "$target_file"
    
    return 0
}

# Write resolvconf configuration
write_resolvconf_config() {
    local target_file="${1:-/etc/resolvconf.conf}"
    
    echo "$RESOLVCONF_CONFIG" >> "$target_file"
    
    return 0
}

# Write sysctl configuration
write_sysctl_config() {
    local target_file="${1:-/etc/sysctl.conf}"
    
    echo "$SYSCTL_CONFIG" > "$target_file"
    
    return 0
}

# Write useradd defaults
write_useradd_defaults() {
    local target_file="${1:-/etc/default/useradd}"
    
    echo "$USERADD_DEFAULTS" > "$target_file"
    
    return 0
}

# Write sudoers wheel configuration
write_sudoers_wheel() {
    local target_file="${1:-/etc/sudoers.d/99-wheel}"
    local target_dir
    target_dir="$(dirname "$target_file")"
    
    mkdir -p "$target_dir"
    echo "$SUDOERS_WHEEL" > "$target_file"
    chmod 0440 "$target_file"
    
    return 0
}

# Write fstab configuration
# Parameters:
#   $1 - target file path
#   $2 - EFI UUID
#   $3 - ESP mount point
#   $4 - pool name (for swap)
#   $5 - include swap (true/false)
write_fstab() {
    local target_file="${1:-/etc/fstab}"
    local efi_uuid="${2:-}"
    local esp_mount="${3:-$ESP_MOUNT}"
    local pool_name="${4:-$DEFAULT_POOL_NAME}"
    local include_swap="${5:-false}"
    
    # Validate required parameters
    if [[ -z "$efi_uuid" ]]; then
        error "EFI UUID is required for fstab"
        return 1
    fi
    
    # Replace variables in template
    local fstab_content="$FSTAB_TEMPLATE"
    fstab_content="${fstab_content//__EFI_UUID__/$efi_uuid}"
    fstab_content="${fstab_content//__ESP_MOUNT__/$esp_mount}"
    
    # Write base fstab
    echo "$fstab_content" > "$target_file"
    
    # Add swap entry if requested
    if [[ "$include_swap" == "true" ]]; then
        local swap_entry="$FSTAB_SWAP_TEMPLATE"
        swap_entry="${swap_entry//__POOL_NAME__/$pool_name}"
        echo "$swap_entry" >> "$target_file"
    fi
    
    success "fstab written to $target_file"
    return 0
}

# Write user configuration script
# Parameters:
#   $1 - target file path
#   $2 - root password
#   $3 - username
#   $4 - user password
write_user_config_script() {
    local target_file="${1:-/tmp/configure_users.sh}"
    local root_password="${2:-}"
    local username="${3:-}"
    local user_password="${4:-}"
    
    # Validate required parameters
    if [[ -z "$root_password" ]] || [[ -z "$username" ]] || [[ -z "$user_password" ]]; then
        error "All passwords and username are required"
        return 1
    fi
    
    # Replace variables in template
    local script_content="$CONFIGURE_USERS_SCRIPT_TEMPLATE"
    script_content="${script_content//__ROOT_PASSWORD__/$root_password}"
    script_content="${script_content//__USERNAME__/$username}"
    script_content="${script_content//__USER_PASSWORD__/$user_password}"
    
    # Write script
    echo "$script_content" > "$target_file"
    chmod +x "$target_file"
    
    success "User configuration script written to $target_file"
    return 0
}

# ============================================
# Additional UI Functions (beyond common.sh)
# ============================================
print() {
    echo -e "$@"
}

menu() {
    local title="$1"
    shift
    local options=("$@")
    
    header "$title"
    
    local i=1
    for option in "${options[@]}"; do
        print "  ${CYAN}$i)${NC} $option"
        ((i++))
    done
    
    echo
    local choice
    while true; do
        read -rp "$(print "${BLUE}?${NC} Select option [1-${#options[@]}]: ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#options[@]})); then
            echo "$choice"
            return 0
        fi
        error "Invalid selection. Please enter a number between 1 and ${#options[@]}"
    done
}

# ============================================
# Validation Functions for ask_input
# ============================================
validate_dataset_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]
}

validate_swap_size() {
    local size="$1"
    [[ "$size" =~ ^[0-9]+[GMgm]$ ]]
}

validate_hostname() {
    local hostname="$1"
    [[ "$hostname" =~ ^[a-zA-Z0-9-]+$ ]]
}

validate_username() {
    local username="$1"
    [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]
}

validate_password_length() {
    local password="$1"
    [[ ${#password} -ge 6 ]]
}

validate_passphrase_length() {
    local passphrase="$1"
    [[ ${#passphrase} -ge 8 ]]
}

validate_timezone() {
    local tz="$1"
    [[ -f "/usr/share/zoneinfo/$tz" ]]
}

# ============================================
# Prerequisites Check
# ============================================
check_prerequisites() {
    header "Checking Prerequisites"
    
    # Check if running as root
    require_root
    
    # Check for required commands
    local required_commands=(
        "zfs"
        "zpool"
        "sgdisk"
        "parted"
        "mkfs.vfat"
        "xbps-install"
    )
    
    local missing_commands=()
    for cmd in "${required_commands[@]}"; do
        if ! command_exists "$cmd"; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        error "Missing required commands: ${missing_commands[*]}"
        die "Please install required packages and try again"
    fi
    
    # Check if ZFS modules are loaded
    if ! lsmod | grep -q "^zfs"; then
        warning "ZFS module not loaded, attempting to load..."
        if ! modprobe zfs; then
            die "Failed to load ZFS module"
        fi
    fi
    
    success "All prerequisites satisfied"
}

# ============================================
# USER INPUT COLLECTION - ALL AT ONCE
# ============================================
collect_installation_type() {
    header "Installation Type"
    
    print "Select installation type:"
    print "  ${CYAN}1)${NC} First-time installation (will use entire disk)"
    print "  ${CYAN}2)${NC} Dual-boot installation (preserve existing partitions)"
    echo
    
    local choice
    choice=$(menu "Installation Type" \
        "First-time installation (use entire disk)" \
        "Dual-boot installation (preserve existing)")
    
    case $choice in
        1) INSTALL_TYPE="first" ;;
        2) INSTALL_TYPE="dualboot" ;;
        *) die "Invalid selection" ;;
    esac
    
    success "Installation type: $INSTALL_TYPE"
}

collect_disk_selection() {
    header "Disk Selection"
    
    info "Available disks:"
    
    # Get list of disks by ID
    local disks=()
    local disk_info=()
    
    while IFS= read -r disk; do
        local disk_path="/dev/disk/by-id/$disk"
        local size
        size=$(lsblk -ndo SIZE "$disk_path" 2>/dev/null || echo "Unknown")
        local model
        model=$(lsblk -ndo MODEL "$disk_path" 2>/dev/null || echo "Unknown")
        
        disks+=("$disk")
        disk_info+=("$disk ($size, $model)")
    done < <(ls /dev/disk/by-id/ | grep -v "part" | sort)
    
    if [[ ${#disks[@]} -eq 0 ]]; then
        die "No disks found"
    fi
    
    # Display disks with numbers
    local i=1
    for info in "${disk_info[@]}"; do
        print "  ${CYAN}$i)${NC} $info"
        ((i++))
    done
    
    echo
    local choice
    while true; do
        read -rp "$(print "${BLUE}?${NC} Select disk [1-${#disks[@]}]: ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#disks[@]})); then
            break
        fi
        error "Invalid selection. Please enter a number between 1 and ${#disks[@]}"
    done
    
    SELECTED_DISK_NAME="${disks[$((choice-1))]}"
    SELECTED_DISK="/dev/disk/by-id/$SELECTED_DISK_NAME"
    
    success "Selected disk: $SELECTED_DISK_NAME"
}

collect_disk_wipe_confirmation() {
    if [[ "$INSTALL_TYPE" == "first" ]]; then
        header "Disk Wipe Confirmation"
        
        warning "This will ERASE ALL DATA on $SELECTED_DISK_NAME"
        print "  Disk: ${RED}$SELECTED_DISK${NC}"
        print "  Size: $(lsblk -ndo SIZE "$SELECTED_DISK")"
        print "  Model: $(lsblk -ndo MODEL "$SELECTED_DISK")"
        echo
        
        if confirm_action "Wipe disk and continue?"; then
            WIPE_DISK=true
            success "Disk wipe confirmed"
        else
            die "Installation cancelled by user"
        fi
    fi
}

collect_zfs_passphrase() {
    header "ZFS Encryption"
    
    info "ZFS native encryption will be used"
    info "Encryption algorithm: $ENCRYPTION_ALGORITHM"
    echo
    
    while true; do
        read -rsp "$(print "${BLUE}?${NC} Enter encryption passphrase (min 8 chars): ")" ZFS_PASSPHRASE
        echo
        
        if ! validate_passphrase_length "$ZFS_PASSPHRASE"; then
            error "Passphrase must be at least 8 characters"
            continue
        fi
        
        local confirm
        read -rsp "$(print "${BLUE}?${NC} Confirm passphrase: ")" confirm
        echo
        
        if [[ "$ZFS_PASSPHRASE" == "$confirm" ]]; then
            success "Passphrase set"
            break
        else
            error "Passphrases do not match"
        fi
    done
}

collect_dataset_name() {
    header "Root Dataset Configuration"
    
    ROOT_DATASET_NAME=$(ask_input \
        "Enter name for root dataset" \
        "void" \
        "validate_dataset_name" \
        "Invalid dataset name. Use only letters, numbers, hyphens, and underscores")
    
    success "Root dataset: $DEFAULT_POOL_NAME/ROOT/$ROOT_DATASET_NAME"
}

collect_swap_configuration() {
    header "Swap Configuration"
    
    if ask_yes_no "Create swap space?" "y"; then
        CREATE_SWAP=true
        
        local mem_gb
        mem_gb=$(free -g | awk '/^Mem:/{print $2}')
        local suggested_swap=$((mem_gb + 2))
        
        SWAP_SIZE=$(ask_input \
            "Enter swap size (e.g., 8G, 4096M)" \
            "${suggested_swap}G" \
            "validate_swap_size" \
            "Invalid swap size format. Use format like '8G' or '4096M'")
        
        success "Swap size: $SWAP_SIZE"
    else
        CREATE_SWAP=false
        info "Skipping swap creation"
    fi
}

collect_system_configuration() {
    header "System Configuration"
    
    # Hostname
    HOSTNAME=$(ask_input \
        "Enter hostname" \
        "voidzfs" \
        "validate_hostname" \
        "Invalid hostname. Use only letters, numbers, and hyphens")
    
    # Timezone
    info "Common timezones: America/New_York, America/Chicago, America/Los_Angeles, Europe/London, UTC"
    
    # Try with validation first
    while true; do
        TIMEZONE=$(ask_input \
            "Enter timezone" \
            "America/New_York" \
            "" \
            "")
        
        # Check if timezone exists
        if [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
            break
        fi
        
        warning "Timezone not found in /usr/share/zoneinfo"
        if ask_yes_no "Continue anyway?" "n"; then
            break
        fi
    done
    
    # Username
    USERNAME=$(ask_input \
        "Enter username for primary user" \
        "void" \
        "validate_username" \
        "Invalid username. Must start with lowercase letter or underscore")
    
    success "Hostname: $HOSTNAME"
    success "Timezone: $TIMEZONE"
    success "Username: $USERNAME"
}

collect_passwords() {
    header "Password Configuration"
    
    # Root password
    while true; do
        read -rsp "$(print "${BLUE}?${NC} Enter root password (min 6 chars): ")" ROOT_PASSWORD
        echo
        
        if ! validate_password_length "$ROOT_PASSWORD"; then
            error "Password must be at least 6 characters"
            continue
        fi
        
        local confirm
        read -rsp "$(print "${BLUE}?${NC} Confirm root password: ")" confirm
        echo
        
        if [[ "$ROOT_PASSWORD" == "$confirm" ]]; then
            success "Root password set"
            break
        else
            error "Passwords do not match"
        fi
    done
    
    # User password
    while true; do
        read -rsp "$(print "${BLUE}?${NC} Enter password for $USERNAME (min 6 chars): ")" USER_PASSWORD
        echo
        
        if ! validate_password_length "$USER_PASSWORD"; then
            error "Password must be at least 6 characters"
            continue
        fi
        
        local confirm
        read -rsp "$(print "${BLUE}?${NC} Confirm password for $USERNAME: ")" confirm
        echo
        
        if [[ "$USER_PASSWORD" == "$confirm" ]]; then
            success "User password set"
            break
        else
            error "Passwords do not match"
        fi
    done
}

show_configuration_summary() {
    header "Configuration Summary"
    
    print "${BOLD}Installation Configuration:${NC}"
    separator
    print "  Installation Type:    $INSTALL_TYPE"
    print "  Disk:                 $SELECTED_DISK_NAME"
    print "  Wipe Disk:            $WIPE_DISK"
    print ""
    print "  Pool Name:            $DEFAULT_POOL_NAME"
    print "  Root Dataset:         $DEFAULT_POOL_NAME/ROOT/$ROOT_DATASET_NAME"
    print "  Encryption:           $ENCRYPTION_ALGORITHM"
    print ""
    print "  Hostname:             $HOSTNAME"
    print "  Timezone:             $TIMEZONE"
    print "  Username:             $USERNAME"
    print ""
    print "  Create Swap:          $CREATE_SWAP"
    if [[ "$CREATE_SWAP" == "true" ]]; then
        print "  Swap Size:            $SWAP_SIZE"
    fi
    separator
    
    echo
    if ! confirm_action "Proceed with installation?"; then
        die "Installation cancelled by user"
    fi
}

# ============================================
# Installation Functions (No User Input)
# ============================================
wipe_disk() {
    if [[ "$WIPE_DISK" != "true" ]]; then
        return 0
    fi
    
    header "Wiping Disk"
    
    info "Wiping $SELECTED_DISK..."
    
    # Unmount any mounted partitions
    local mounted_parts
    mounted_parts=$(lsblk -no MOUNTPOINT "$SELECTED_DISK" 2>/dev/null | grep -v '^$' || true)
    if [[ -n "$mounted_parts" ]]; then
        warning "Unmounting partitions..."
        while IFS= read -r mount; do
            safe_run umount -f "$mount" || true
        done <<< "$mounted_parts"
    fi
    
    # Wipe partition table
    safe_run sgdisk --zap-all "$SELECTED_DISK"
    
    # Wipe any ZFS labels
    safe_run zpool labelclear -f "$SELECTED_DISK" 2>/dev/null || true
    
    success "Disk wiped successfully"
}

partition_disk() {
    header "Partitioning Disk"
    
    info "Creating partitions on $SELECTED_DISK..."
    
    # Create GPT partition table
    safe_run sgdisk --clear "$SELECTED_DISK"
    
    # Create EFI partition (1GB)
    safe_run sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI System Partition" "$SELECTED_DISK"
    
    # Create ZFS partition (remaining space)
    safe_run sgdisk -n 2:0:0 -t 2:bf00 -c 2:"ZFS Pool" "$SELECTED_DISK"
    
    # Wait for kernel to re-read partition table
    safe_run partprobe "$SELECTED_DISK"
    sleep 2
    
    # Format EFI partition
    local efi_part="${SELECTED_DISK}-part1"
    info "Formatting EFI partition..."
    safe_run mkfs.vfat -F32 -n EFI "$efi_part"
    
    # Get EFI partition UUID
    EFI_UUID=$(blkid -s UUID -o value "$efi_part")
    
    success "Disk partitioned successfully"
    info "EFI partition: $efi_part (UUID: $EFI_UUID)"
}

setup_zfs_encryption() {
    header "Setting Up ZFS Encryption"
    
    info "Creating encryption key..."
    
    # Create key file directory (in chroot target)
    mkdir -p "/mnt$(dirname "$ZFS_KEY_FILE")"
    
    # Write passphrase to key file
    echo -n "$ZFS_PASSPHRASE" > "/mnt$ZFS_KEY_FILE"
    chmod 400 "/mnt$ZFS_KEY_FILE"
    
    success "Encryption key created: /mnt$ZFS_KEY_FILE"
}

backup_zfs_key() {
    header "Backing Up ZFS Key"
    
    mkdir -p "/mnt$ZFS_KEY_BACKUP_DIR"
    
    local backup_file="$ZFS_KEY_BACKUP_DIR/zroot.key.$(date +%Y%m%d_%H%M%S)"
    safe_run cp "/mnt$ZFS_KEY_FILE" "/mnt$backup_file"
    chmod 400 "/mnt$backup_file"
    
    success "Key backed up to: $backup_file"
}

create_pool() {
    header "Creating ZFS Pool"
    
    local zfs_part="${SELECTED_DISK}-part2"
    
    info "Creating pool: $DEFAULT_POOL_NAME"
    
    # Pool creation options
    local pool_opts=(
        -o ashift=12
        -o autotrim=on
        -O acltype=posixacl
        -O compression=lz4
        -O dnodesize=auto
        -O normalization=formD
        -O relatime=on
        -O xattr=sa
        -O mountpoint=none
        -R /mnt
    )
    
    safe_run zpool create "${pool_opts[@]}" "$DEFAULT_POOL_NAME" "$zfs_part"
    
    success "Pool created: $DEFAULT_POOL_NAME"
}

create_root_dataset() {
    header "Creating Root Dataset"
    
    # Create ROOT container
    safe_run zfs create -o mountpoint=none -o canmount=off "$DEFAULT_POOL_NAME/ROOT"
    
    # Create root dataset with encryption
    info "Creating encrypted root dataset..."
    safe_run zfs create \
        -o encryption="$ENCRYPTION_ALGORITHM" \
        -o keyformat="$KEY_FORMAT" \
        -o keylocation="file:///mnt$ZFS_KEY_FILE" \
        -o mountpoint=/ \
        -o canmount=noauto \
        "$DEFAULT_POOL_NAME/ROOT/$ROOT_DATASET_NAME"
    
    # Mount root dataset
    safe_run zfs mount "$DEFAULT_POOL_NAME/ROOT/$ROOT_DATASET_NAME"
    
    # Set bootfs property
    safe_run zpool set bootfs="$DEFAULT_POOL_NAME/ROOT/$ROOT_DATASET_NAME" "$DEFAULT_POOL_NAME"
    
    success "Root dataset created and mounted"
}

create_system_dataset() {
    header "Creating System Dataset"
    
    # Create system dataset (inherits encryption)
    safe_run zfs create -o mountpoint=/home "$DEFAULT_POOL_NAME/home"
    safe_run zfs create -o mountpoint=/root "$DEFAULT_POOL_NAME/home/root"
    safe_run zfs create -o mountpoint=/var "$DEFAULT_POOL_NAME/var"
    safe_run zfs create -o mountpoint=/var/log "$DEFAULT_POOL_NAME/var/log"
    safe_run zfs create -o mountpoint=/var/cache "$DEFAULT_POOL_NAME/var/cache"
    
    success "System datasets created"
}

create_home_dataset() {
    header "Creating Home Dataset"
    
    safe_run zfs create -o mountpoint="/home/$USERNAME" "$DEFAULT_POOL_NAME/home/$USERNAME"
    
    success "Home dataset created for $USERNAME"
}

create_swapspace() {
    if [[ "$CREATE_SWAP" != "true" ]]; then
        return 0
    fi
    
    header "Creating Swap Space"
    
    info "Creating swap zvol: $SWAP_SIZE"
    
    safe_run zfs create \
        -V "$SWAP_SIZE" \
        -b 4K \
        -o compression=zle \
        -o logbias=throughput \
        -o sync=always \
        -o primarycache=metadata \
        -o secondarycache=none \
        "$DEFAULT_POOL_NAME/swap"
    
    # Format as swap
    safe_run mkswap -f "/dev/zvol/$DEFAULT_POOL_NAME/swap"
    
    success "Swap space created"
}

export_pool() {
    header "Exporting Pool"
    
    safe_run zpool export "$DEFAULT_POOL_NAME"
    
    success "Pool exported"
}

import_pool() {
    header "Importing Pool"
    
    # Import pool
    safe_run zpool import -d /dev/disk/by-id -R /mnt "$DEFAULT_POOL_NAME"
    
    # Load key and mount
    info "Loading encryption key..."
    safe_run zfs load-key -L "file:///mnt$ZFS_KEY_FILE" "$DEFAULT_POOL_NAME/ROOT/$ROOT_DATASET_NAME"
    
    info "Mounting filesystems..."
    safe_run zfs mount "$DEFAULT_POOL_NAME/ROOT/$ROOT_DATASET_NAME"
    safe_run zfs mount -a
    
    success "Pool imported and mounted"
}

mount_system() {
    header "Mounting System Partitions"
    
    # Create and mount EFI
    mkdir -p "/mnt$ESP_MOUNT"
    local efi_part="${SELECTED_DISK}-part1"
    safe_run mount "$efi_part" "/mnt$ESP_MOUNT"
    
    # Create essential directories
    mkdir -p /mnt/dev
    mkdir -p /mnt/proc
    mkdir -p /mnt/sys
    mkdir -p /mnt/tmp
    
    # Mount pseudo filesystems
    safe_run mount -t proc proc /mnt/proc
    safe_run mount -t sysfs sys /mnt/sys
    safe_run mount -B /dev /mnt/dev
    safe_run mount -t devpts pts /mnt/dev/pts
    
    success "System partitions mounted"
}

copy_zpool_cache() {
    header "Copying ZFS Cache"
    
    mkdir -p "/mnt$(dirname "$ZFS_CACHE_FILE")"
    
    if [[ -f "$ZFS_CACHE_FILE" ]]; then
        safe_run cp "$ZFS_CACHE_FILE" "/mnt$ZFS_CACHE_FILE"
        success "ZFS cache copied"
    else
        warning "ZFS cache file not found, generating..."
        safe_run zpool set cachefile="$ZFS_CACHE_FILE" "$DEFAULT_POOL_NAME"
        safe_run cp "$ZFS_CACHE_FILE" "/mnt$ZFS_CACHE_FILE"
        success "ZFS cache generated and copied"
    fi
}

install_base_system() {
    header "Installing Base System"
    
    info "Installing base-system and essential packages..."
    
    # Define package list
    local packages=(
        base-system
        zfs
        zfsbootmenu
        efibootmgr
        gummiboot
        iwd
        dracut
        linux
        linux-headers
        git
    )
    
    # Install packages
    XBPS_ARCH=x86_64 safe_run xbps-install -Sy -R https://repo-default.voidlinux.org/current -r /mnt "${packages[@]}"
    
    success "Base system installed"
}

configure_system() {
    header "Configuring System"
    
    # Generate hostid
    info "Generating hostid..."
    safe_run zgenhostid -f "$(hostid)"
    safe_run cp "$ZFS_HOSTID_FILE" "/mnt$ZFS_HOSTID_FILE"
    
    # Write IWD configuration
    info "Configuring IWD..."
    write_iwd_config "/mnt/etc/iwd/main.conf"
    
    # Write resolvconf configuration
    info "Configuring resolvconf..."
    write_resolvconf_config "/mnt/etc/resolvconf.conf"
    
    # Write sysctl configuration
    info "Configuring sysctl..."
    write_sysctl_config "/mnt/etc/sysctl.conf"
    
    # Configure rc.conf
    info "Configuring rc.conf..."
    cat >> /mnt/etc/rc.conf << EOF
TIMEZONE="$TIMEZONE"
HARDWARECLOCK="UTC"
KEYMAP="us"
FONT="$FONT"
EOF
    
    # Configure vconsole
    info "Configuring vconsole..."
    cat >> /mnt/etc/vconsole.conf <<EOF
FONT=$FONT
EOF
    
    # Write useradd defaults
    info "Configuring useradd defaults..."
    write_useradd_defaults "/mnt/etc/default/useradd"
    
    # Write dracut ZFS configuration
    info "Configuring dracut for ZFS..."
    write_dracut_zfs_config "/mnt$DRACUT_ZFS_CONF"
    
    # Write dracut main configuration
    write_dracut_main_config "/mnt$DRACUT_MAIN_CONF"
    
    success "System configured"
}

configure_users() {
    header "Configuring Users"
    
    # Write user configuration script using template
    info "Creating user configuration script..."
    write_user_config_script \
        "/mnt/tmp/configure_users.sh" \
        "$ROOT_PASSWORD" \
        "$USERNAME" \
        "$USER_PASSWORD"
    
    # Execute the script in chroot
    info "Configuring users in chroot..."
    safe_run chroot /mnt /tmp/configure_users.sh
    
    # Remove the script
    safe_run rm /mnt/tmp/configure_users.sh
    
    success "Users configured"
}

configure_fstab() {
    header "Configuring fstab"
    
    info "Writing fstab configuration..."
    write_fstab \
        "/mnt/etc/fstab" \
        "$EFI_UUID" \
        "$ESP_MOUNT" \
        "$DEFAULT_POOL_NAME" \
        "$CREATE_SWAP"
    
    success "fstab configured"
}

set_passwords() {
    header "Setting Passwords"
    
    # Passwords already set in configure_users
    info "Passwords configured in user setup"
    
    success "Password configuration complete"
}

configure_sudo() {
    header "Configuring Sudo"
    
    write_sudoers_wheel "/mnt/etc/sudoers.d/99-wheel"
    
    success "Sudo configured for wheel group"
}

configure_zfsbootmenu() {
    header "Configuring ZFSBootMenu"
    
    # Write ZFSBootMenu configuration
    info "Writing ZFSBootMenu configuration..."
    write_zbm_config "/mnt$ZBM_CONFIG"
    
    # Write keymap configuration
    info "Writing keymap configuration..."
    write_zbm_keymap_config "/mnt$ZBM_KEYMAP_CONF"
    write_cmdline_keymap "/mnt$CMDLINE_KEYMAP"
    
    # Generate ZFSBootMenu
    info "Generating ZFSBootMenu..."
    safe_run chroot /mnt /usr/bin/generate-zbm
    
    # Create EFI boot entry
    info "Creating EFI boot entry..."
    safe_run chroot /mnt efibootmgr --create --disk "$SELECTED_DISK" --part 1 \
        --label "ZFSBootMenu" \
        --loader '\EFI\ZBM\vmlinuz.efi' \
        --unicode
    
    success "ZFSBootMenu configured"
}

enable_services() {
    header "Enabling Services"
    
    # Enable ZFS services
    for service in "${ZFS_SERVICES[@]}"; do
        info "Enabling $service..."
        safe_run ln -sf "$SERVICE_DIR/$service" "/mnt$RUNSVDIR/"
    done
    
    # Enable IWD
    info "Enabling iwd..."
    safe_run ln -sf "$SERVICE_DIR/iwd" "/mnt$RUNSVDIR/"
    
    # Enable dhcpcd
    info "Enabling dhcpcd..."
    safe_run ln -sf "$SERVICE_DIR/dhcpcd" "/mnt$RUNSVDIR/"
    
    success "Services enabled"
}

cleanup_installation() {
    header "Cleaning Up"
    
    # Unmount pseudo filesystems
    safe_run umount -l /mnt/dev/pts || true
    safe_run umount -l /mnt/dev || true
    safe_run umount -l /mnt/proc || true
    safe_run umount -l /mnt/sys || true
    
    # Unmount EFI
    safe_run umount "/mnt$ESP_MOUNT" || true
    
    # Export pool
    info "Exporting pool..."
    safe_run zpool export "$DEFAULT_POOL_NAME"
    
    success "Cleanup complete"
}

# ============================================
# Main Installation Flow
# ============================================
main() {
    header "$SCRIPT_NAME v$SCRIPT_VERSION"
    
    info "Starting Void Linux ZFS installation"
    info "Using zfs-setup.conf v$CONFIG_VERSION"
    echo
    
    # Check prerequisites
    check_prerequisites
    
    # Collect all user input upfront
    collect_installation_type
    collect_disk_selection
    collect_disk_wipe_confirmation
    collect_zfs_passphrase
    collect_dataset_name
    collect_swap_configuration
    collect_system_configuration
    collect_passwords
    
    # Show summary and confirm
    show_configuration_summary
    
    # Execute installation (no more user interaction)
    header "Starting Installation"
    warning "Installation will now proceed without further input"
    sleep 3
    
    wipe_disk
    partition_disk
    setup_zfs_encryption
    create_pool
    create_root_dataset
    create_system_dataset
    create_home_dataset
    create_swapspace
    export_pool
    import_pool
    mount_system
    copy_zpool_cache
    install_base_system
    configure_system
    configure_users
    configure_fstab
    configure_sudo
    configure_zfsbootmenu
    enable_services
    backup_zfs_key
    
    # Cleanup
    cleanup_installation
    
    # Final message
    separator
    success "Installation Complete!"
    separator
    print ""
    print "${GREEN}${BOLD}Void Linux with ZFS has been successfully installed!${NC}"
    print ""
    print "System Configuration:"
    print "  Pool:      $DEFAULT_POOL_NAME"
    print "  Dataset:   $DEFAULT_POOL_NAME/ROOT/$ROOT_DATASET_NAME"
    print "  Hostname:  $HOSTNAME"
    print "  Username:  $USERNAME"
    print ""
    print "${YELLOW}Important Notes:${NC}"
    print "  1. Encryption key: $ZFS_KEY_FILE"
    print "  2. Key backup:     $ZFS_KEY_BACKUP_DIR/"
    print "  3. Please save your encryption passphrase securely!"
    print "  4. Boot order: Set 'ZFSBootMenu' as first boot option in UEFI"
    print ""
    print "${CYAN}Next Steps:${NC}"
    print "  1. Remove installation media"
    print "  2. Reboot the system"
    print "  3. Enter encryption passphrase at boot"
    print ""
    
    if ask_yes_no "Reboot now?" "n"; then
        info "Rebooting..."
        reboot
    else
        info "Installation complete. You can reboot manually."
    fi
}

# ============================================
# Script Entry Point
# ============================================
main "$@"
