#!/usr/bin/env bash
# filepath: zfs-void-install-new.sh
# Void Linux ZFS Installation Script
# Version: 3.1 - Configurable pool name support

export TERM=xterm
set -e

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/common.sh" ]]; then
    source "${SCRIPT_DIR}/common.sh"
elif [[ -f "/usr/local/lib/zfs-scripts/common.sh" ]]; then
    source "/usr/local/lib/zfs-scripts/common.sh"
else
    echo "ERROR: common.sh library not found!"
    echo "Please ensure common.sh is in the same directory or /usr/local/lib/zfs-scripts/"
    exit 1
fi

# Configure logging for this script
LOG_FILE="/var/log/zfs-void-install.log"
USE_LOG_FILE=true

exec &> >(tee "configureNinstall.log")

# ============================================
# GLOBAL VARIABLES FOR USER INPUTS
# ============================================

INSTALL_TYPE=""           # "first" or "dualboot"
DISK=""                   # Selected disk path
DISK_TO_WIPE=""          # Boolean: wipe disk or not
ZFS_PASSPHRASE=""        # Encryption passphrase
POOL_NAME="zroot"        # Pool name (configurable, default: zroot)
ROOT_DATASET_NAME=""     # Name of root dataset
CREATE_SWAP=false        # Boolean: create swap or not
SWAP_SIZE=""            # Swap size (e.g., "4G")
SYSTEM_HOSTNAME=""      # System hostname
SYSTEM_TIMEZONE=""      # System timezone
SYSTEM_USERNAME=""      # Regular user account name
ROOT_PASSWORD=""        # Root password
USER_PASSWORD=""        # User password

# Repository configuration
REPO="https://repo-default.voidlinux.org/current"
ARCH="x86_64"

# Partition variables (set during partitioning)
EFI=""
ZFS_PARTITION=""

# Debug mode flag
DEBUG_MODE=false

# ============================================
# VALIDATION FUNCTIONS
# ============================================

check_prerequisites() {
    header "VOID LINUX ZFS INSTALLATION - Prerequisites Check"
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root"
    fi
    
    # Check if booted in UEFI mode
    if [[ ! -d /sys/firmware/efi ]]; then
        die "System must be booted in UEFI mode"
    fi
    
    # Check for required commands
    local required_cmds=(
        "zpool" "zfs" "parted" "mkfs.vfat" 
        "xbps-install" "chroot" "efibootmgr"
    )
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            die "Required command not found: $cmd"
        fi
    done
    
    # Check internet connectivity
    info "Checking internet connectivity..."
    if ! ping -c 1 voidlinux.org &> /dev/null; then
        warning "Cannot reach voidlinux.org - network may not be configured"
        if ! ask_yes_no "Continue anyway?" "n"; then
            die "Internet connectivity required for installation"
        fi
    fi
    
    success "All prerequisites satisfied"
}

# ============================================
# USER INPUT COLLECTION PHASE
# ============================================

collect_user_inputs() {
    header "VOID LINUX ZFS INSTALLATION - User Input Collection Phase"
    
    # Step 1: Installation Type
    subheader "Step 1: Installation Type"
    echo ""
    echo "Is this the first install or a second install to dualboot?"
    PS3=$'\033[1;94m→\033[0m Choose a number: '
    select i in "first" "dualboot"; do
        INSTALL_TYPE="$i"
        break
    done
    info "Selected installation type: $INSTALL_TYPE"
    
    # Step 2: Disk Selection
    subheader "Step 2: Disk Selection"
    collect_disk_selection
    
    # Step 3: Wipe Decision (if first install)
    if [[ "$INSTALL_TYPE" == "first" ]]; then
        subheader "Step 3: Disk Wipe Confirmation"
        collect_wipe_decision
    fi
    
    # Step 4: Pool Name
    subheader "Step 4: ZFS Pool Name"
    collect_pool_name
    
    # Step 5: ZFS Encryption Passphrase
    subheader "Step 5: ZFS Encryption Passphrase"
    collect_zfs_passphrase
    
    # Step 6: Root Dataset Name
    subheader "Step 6: Root Dataset Name"
    collect_dataset_name
    
    # Step 7: Swap Configuration (if first install)
    if [[ "$INSTALL_TYPE" == "first" ]]; then
        subheader "Step 7: Swap Configuration"
        collect_swap_config
    fi
    
    # Step 8: System Information
    subheader "Step 8: System Configuration"
    collect_system_info
    
    success "User input collection complete"
}

collect_disk_selection() {
    echo ""
    info "Available disks:"
    lsblk -dno NAME,SIZE,MODEL | grep -v loop
    echo ""
    
    while true; do
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Enter disk (e.g., sda, nvme0n1): "
        read -r disk_name
        
        if [[ -z "$disk_name" ]]; then
            error "Disk name cannot be empty"
            continue
        fi
        
        # Try common disk paths
        if [[ -b "/dev/$disk_name" ]]; then
            DISK="/dev/$disk_name"
            break
        elif [[ -b "/dev/disk/by-id/$disk_name" ]]; then
            DISK="/dev/disk/by-id/$disk_name"
            break
        else
            error "Disk not found: $disk_name"
            echo "Please enter a valid disk name from the list above"
        fi
    done
    
    info "Selected disk: $DISK"
    
    # Show disk information
    info "Disk information:"
    lsblk "$DISK"
}

collect_wipe_decision() {
    echo ""
    warning "This will DESTROY ALL DATA on $DISK"
    echo ""
    
    if ask_yes_no "Do you want to wipe the disk?" "n"; then
        DISK_TO_WIPE="true"
        warning "Disk will be wiped before installation"
    else
        DISK_TO_WIPE="false"
        info "Disk will not be wiped (existing partitions will be used if compatible)"
    fi
}

collect_pool_name() {
    while true; do
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Enter pool name (default: zroot): "
        read -r input_pool_name
        
        # Use default if empty
        input_pool_name=${input_pool_name:-"zroot"}
        
        # Validate name format
        if [[ ! "$input_pool_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            error "Invalid pool name. Use only letters, numbers, hyphens, and underscores."
            continue
        fi
        
        # Check reserved names
        if [[ "$input_pool_name" == "rpool" ]]; then
            warning "Note: 'rpool' is commonly reserved for root pools in some systems."
            if ! ask_yes_no "Are you sure you want to use 'rpool'?" "n"; then
                continue
            fi
        fi
        
        POOL_NAME="$input_pool_name"
        info "Pool name set to: $POOL_NAME"
        
        if [[ "$INSTALL_TYPE" == "dualboot" ]]; then
            info "Note: Will verify pool exists when importing"
        fi
        break
    done
}

collect_zfs_passphrase() {
    while true; do
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Enter ZFS encryption passphrase: "
        read -rs pass1
        echo ""
        
        if [[ ${#pass1} -lt 8 ]]; then
            error "Passphrase must be at least 8 characters"
            continue
        fi
        
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Confirm passphrase: "
        read -rs pass2
        echo ""
        
        if [[ "$pass1" != "$pass2" ]]; then
            error "Passphrases do not match"
            continue
        fi
        
        ZFS_PASSPHRASE="$pass1"
        success "Passphrase set (${#ZFS_PASSPHRASE} characters)"
        break
    done
}

collect_dataset_name() {
    while true; do
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Enter name for root dataset (e.g., void, void-main): "
        read -r dataset_name
        
        if [[ -z "$dataset_name" ]]; then
            error "Dataset name cannot be empty"
            continue
        fi
        
        if [[ ! "$dataset_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            error "Invalid dataset name. Use only letters, numbers, hyphens, and underscores."
            continue
        fi
        
        ROOT_DATASET_NAME="$dataset_name"
        info "Root dataset will be: ${POOL_NAME}/ROOT/$ROOT_DATASET_NAME"
        break
    done
}

collect_swap_config() {
    echo ""
    if ask_yes_no "Do you want to create a swap zvol?" "y"; then
        CREATE_SWAP=true
        
        while true; do
            echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Enter swap size (e.g., 4G, 8G, 16G): "
            read -r swap_input
            
            if [[ -z "$swap_input" ]]; then
                error "Swap size cannot be empty"
                continue
            fi
            
            if [[ ! "$swap_input" =~ ^[0-9]+[GMgm]$ ]]; then
                error "Invalid format. Use format like: 4G, 8G, 512M"
                continue
            fi
            
            SWAP_SIZE="$swap_input"
            info "Swap size set to: $SWAP_SIZE"
            break
        done
    else
        CREATE_SWAP=false
        info "Swap will not be configured"
    fi
}

collect_system_info() {
    # Hostname
    while true; do
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Enter system hostname: "
        read -r hostname_input
        
        if [[ -z "$hostname_input" ]]; then
            error "Hostname cannot be empty"
            continue
        fi
        
        if [[ ! "$hostname_input" =~ ^[a-zA-Z0-9-]+$ ]]; then
            error "Invalid hostname. Use only letters, numbers, and hyphens."
            continue
        fi
        
        SYSTEM_HOSTNAME="$hostname_input"
        break
    done
    
    # Timezone
    echo ""
    info "Common timezones: UTC, America/New_York, Europe/London, Asia/Singapore"
    while true; do
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Enter timezone (default: Asia/Singapore): "
        read -r tz_input
        
        tz_input=${tz_input:-"Asia/Singapore"}
        
        if [[ ! -f "/usr/share/zoneinfo/$tz_input" ]]; then
            error "Invalid timezone. Check /usr/share/zoneinfo/ for valid options."
            continue
        fi
        
        SYSTEM_TIMEZONE="$tz_input"
        break
    done
    
    # Username
    echo ""
    while true; do
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Enter username for regular user account: "
        read -r user_input
        
        if [[ -z "$user_input" ]]; then
            error "Username cannot be empty"
            continue
        fi
        
        if [[ ! "$user_input" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            error "Invalid username. Must start with lowercase letter or underscore."
            continue
        fi
        
        if [[ "$user_input" == "root" ]]; then
            error "Cannot use 'root' as username"
            continue
        fi
        
        SYSTEM_USERNAME="$user_input"
        break
    done
    
    # Root password
    echo ""
    while true; do
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Enter root password: "
        read -rs root_pass1
        echo ""
        
        if [[ ${#root_pass1} -lt 6 ]]; then
            error "Password must be at least 6 characters"
            continue
        fi
        
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Confirm root password: "
        read -rs root_pass2
        echo ""
        
        if [[ "$root_pass1" != "$root_pass2" ]]; then
            error "Passwords do not match"
            continue
        fi
        
        ROOT_PASSWORD="$root_pass1"
        success "Root password set"
        break
    done
    
    # User password
    echo ""
    while true; do
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Enter password for $SYSTEM_USERNAME: "
        read -rs user_pass1
        echo ""
        
        if [[ ${#user_pass1} -lt 6 ]]; then
            error "Password must be at least 6 characters"
            continue
        fi
        
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Confirm password: "
        read -rs user_pass2
        echo ""
        
        if [[ "$user_pass1" != "$user_pass2" ]]; then
            error "Passwords do not match"
            continue
        fi
        
        USER_PASSWORD="$user_pass1"
        success "User password set"
        break
    done
}

# ============================================
# INSTALLATION SUMMARY & CONFIRMATION
# ============================================

show_installation_summary() {
    header "INSTALLATION SUMMARY"
    
    subheader "Installation Configuration:"
    bullet "Installation Type: $INSTALL_TYPE"
    echo ""
    
    subheader "Disk Configuration:"
    bullet "Target Disk: $(basename $DISK)"
    if [[ "$INSTALL_TYPE" == "first" ]]; then
        bullet "Wipe Disk: $DISK_TO_WIPE"
        bullet "Partitions: EFI (512M) + ZFS (remaining)"
    fi
    echo ""
    
    subheader "ZFS Configuration:"
    bullet "Pool Name: $POOL_NAME"
    bullet "Encryption: AES-256-GCM"
    bullet "Compression: lz4"
    bullet "Root Dataset: ${POOL_NAME}/ROOT/$ROOT_DATASET_NAME"
    bullet "Passphrase Length: ${#ZFS_PASSPHRASE} characters"
    echo ""
    
    if [[ "$INSTALL_TYPE" == "first" ]]; then
        subheader "Additional Datasets:"
        bullet "Home: ${POOL_NAME}/data/home"
        bullet "Root home: ${POOL_NAME}/data/root"
        if [[ "$CREATE_SWAP" == true ]]; then
            bullet "Swap: ${POOL_NAME}/swap ($SWAP_SIZE)"
        else
            bullet "Swap: Not configured"
        fi
        echo ""
    fi
    
    subheader "System Configuration:"
    bullet "Hostname: $SYSTEM_HOSTNAME"
    bullet "Timezone: $SYSTEM_TIMEZONE"
    bullet "Locale: en_US.UTF-8"
    bullet "Keymap: us"
    echo ""
    
    subheader "User Account:"
    bullet "Username: $SYSTEM_USERNAME"
    bullet "Groups: network, wheel, video, audio, input, kvm"
    echo ""
    
    subheader "Boot Configuration:"
    bullet "Boot Method: ZFSBootMenu (EFI)"
    bullet "Boot Location: /boot/efi/EFI/ZBM/"
    echo ""
}

confirm_installation() {
    echo ""
    warning "=== FINAL CONFIRMATION ==="
    if [[ "$DISK_TO_WIPE" == "true" ]]; then
        warning "ALL DATA ON $DISK WILL BE DESTROYED"
    fi
    echo ""
    
    if ! ask_yes_no "Proceed with installation?" "n"; then
        info "Installation cancelled by user"
        exit 0
    fi
    
    success "Installation confirmed. Starting..."
}

# ============================================
# DISK OPERATION FUNCTIONS
# ============================================

wipe() {
    if [[ "$DISK_TO_WIPE" != "true" ]]; then
        return 0
    fi
    
    info "Wiping disk: $DISK"
    
    # Unmount any mounted partitions
    umount ${DISK}* 2>/dev/null || true
    
    # Wipe filesystem signatures
    wipefs --all --force "$DISK" 2>/dev/null || true
    
    # Zero out the first 100MB
    dd if=/dev/zero of="$DISK" bs=1M count=100 status=progress conv=fsync 2>/dev/null || true
    
    success "Disk wiped"
}

partition() {
    if [[ "$INSTALL_TYPE" == "dualboot" ]]; then
        info "Dualboot mode - using existing partitions"
        
        # Find EFI partition
        EFI=$(lsblk -no PATH,PARTTYPE "$DISK" | grep -i "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" | awk '{print $1}' | head -n1)
        
        if [[ -z "$EFI" ]]; then
            die "No EFI partition found on $DISK"
        fi
        
        # Find ZFS partition
        ZFS_PARTITION=$(lsblk -no PATH,PARTTYPE "$DISK" | grep -i "6a898cc3-1dd2-11b2-99a6-080020736631" | awk '{print $1}' | head -n1)
        
        if [[ -z "$ZFS_PARTITION" ]]; then
            die "No ZFS partition found on $DISK"
        fi
        
        info "Using EFI partition: $EFI"
        info "Using ZFS partition: $ZFS_PARTITION"
        return 0
    fi
    
    info "Creating partition table on $DISK"
    
    # Create GPT partition table
    parted -s "$DISK" mklabel gpt
    
    # Create EFI partition (512M)
    parted -s "$DISK" mkpart primary fat32 1MiB 513MiB
    parted -s "$DISK" set 1 esp on
    
    # Create ZFS partition (remaining space)
    parted -s "$DISK" mkpart primary 513MiB 100%
    parted -s "$DISK" set 2 boot on
    
    # Inform kernel of partition changes
    partprobe "$DISK"
    sleep 2
    
    # Determine partition naming scheme
    if [[ "$DISK" =~ nvme ]]; then
        EFI="${DISK}p1"
        ZFS_PARTITION="${DISK}p2"
    else
        EFI="${DISK}1"
        ZFS_PARTITION="${DISK}2"
    fi
    
    # Wait for partitions to appear
    local count=0
    while [[ ! -e "$EFI" ]] || [[ ! -e "$ZFS_PARTITION" ]]; do
        if [[ $count -ge 30 ]]; then
            die "Timeout waiting for partitions to appear"
        fi
        sleep 1
        ((count++))
    done
    
    info "Formatting EFI partition"
    mkfs.vfat -F 32 -n EFI "$EFI"
    
    success "Partitions created: EFI=$EFI, ZFS=$ZFS_PARTITION"
}

zfs_passphrase() {
    info "Creating ZFS encryption key file"
    mkdir -p /etc/zfs
    echo "$ZFS_PASSPHRASE" > /etc/zfs/${POOL_NAME}.key
    chmod 000 /etc/zfs/${POOL_NAME}.key
    
    if [[ ! -f /etc/zfs/${POOL_NAME}.key ]] || [[ ! -s /etc/zfs/${POOL_NAME}.key ]]; then
        die "Failed to create key file!"
    fi
    success "Encryption key file created"
}

zfs_passphrase_backup() {
    info 'Creating encryption key backup'
    mkdir -p /mnt/root/zfs-keys
    zfs get -H -o value keylocation ${POOL_NAME} > /mnt/root/zfs-keys/keylocation
    install -m 000 /etc/zfs/${POOL_NAME}.key /mnt/root/zfs-keys/
    
    if ! diff /etc/zfs/${POOL_NAME}.key /mnt/root/zfs-keys/${POOL_NAME}.key &>/dev/null; then
        die "Key backup verification failed!"
    fi
    success "Encryption key backed up"
}

# ============================================
# ZFS POOL & DATASET FUNCTIONS
# ============================================

create_pool() {
    info "Creating ZFS pool: $POOL_NAME"
    zpool create -f -o ashift=12                          \
                 -o autotrim=on                           \
                 -O acltype=posixacl                      \
                 -O compression=lz4                       \
                 -O relatime=on                           \
                 -O xattr=sa                              \
                 -O dnodesize=auto                        \
                 -O encryption=aes-256-gcm                \
                 -O keyformat=passphrase                  \
                 -O keylocation=file:///etc/zfs/${POOL_NAME}.key \
                 -O normalization=formD                   \
                 -O mountpoint=none                       \
                 -O canmount=off                          \
                 -O devices=off                           \
                 -R /mnt                                  \
                 ${POOL_NAME} "$ZFS_PARTITION"
    
    if ! zpool list ${POOL_NAME} &>/dev/null; then
        die "Pool creation failed!"
    fi
    success "ZFS pool created"
}

create_root_dataset() {
    info "Creating root dataset container"
    zfs create -o mountpoint=none ${POOL_NAME}/ROOT
    zfs set org.zfsbootmenu:commandline="ro quiet loglevel=0" ${POOL_NAME}/ROOT
    success "Root dataset container created"
}

create_system_dataset() {
    info "Creating system dataset: $ROOT_DATASET_NAME"
    zfs create -o mountpoint=/ \
           -o canmount=noauto \
           -o recordsize=128K \
           -o atime=off \
           -o relatime=off \
           -o devices=off \
           ${POOL_NAME}/ROOT/"$ROOT_DATASET_NAME"

    info "Generating hostid"
    zgenhostid -f

    if [[ ! -f /etc/hostid ]]; then
        die "Failed to generate hostid!"
    fi
    
    if [[ $(stat -c%s /etc/hostid 2>/dev/null) -ne 4 ]]; then
        die "Hostid file corrupted (wrong size)!"
    fi
    
    info "Generated hostid: $(hostid)"
     
    info "Setting ZFS bootfs"
    zpool set bootfs="${POOL_NAME}/ROOT/$ROOT_DATASET_NAME" ${POOL_NAME}

    zfs mount ${POOL_NAME}/ROOT/"$ROOT_DATASET_NAME"
    
    if ! mountpoint -q /mnt; then
        die "Failed to mount root dataset!"
    fi
    success "System dataset created and mounted"
}

create_home_dataset() {
    info "Creating home datasets"
    zfs create -o mountpoint=none -o canmount=off ${POOL_NAME}/data
    zfs create -o mountpoint=/home \
               -o recordsize=1M \
               -o compression=zstd-3 \
               -o atime=off \
               ${POOL_NAME}/data/home
    zfs create -o mountpoint=/root \
               -o recordsize=128K \
               -o compression=zstd \
               ${POOL_NAME}/data/root
    success "Home datasets created"
}

create_swapspace() {
    if [[ "$CREATE_SWAP" != true ]]; then
        return 0
    fi
    
    info "Creating swap zvol: $SWAP_SIZE"
    
    zfs create -V "$SWAP_SIZE" -b $(getconf PAGESIZE) \
        -o compression=zle \
        -o logbias=throughput \
        -o sync=disabled \
        -o primarycache=metadata \
        -o secondarycache=none \
        -o com.sun:auto-snapshot=false \
        ${POOL_NAME}/swap

    info "Waiting for zvol device..."
    local count=0
    until [[ -e /dev/zvol/${POOL_NAME}/swap ]] || [[ $count -ge 30 ]]; do
        sleep 1
        ((count++))
    done
    
    if [[ ! -e /dev/zvol/${POOL_NAME}/swap ]]; then
        die "Swap zvol device did not appear!"
    fi

    info "Formatting swap"
    mkswap -f /dev/zvol/${POOL_NAME}/swap
    
    echo "true" > /tmp/swap_created
    success "Swap zvol created"
}

export_pool() {
    info "Exporting zpool: $POOL_NAME"
    zpool export ${POOL_NAME}
    
    if zpool list ${POOL_NAME} &>/dev/null; then
        die "Pool export failed!"
    fi
    success "Pool exported"
}

import_pool() {
    info "Importing zpool: $POOL_NAME"
    zpool import -d /dev/disk/by-id -R /mnt ${POOL_NAME} -N -f || {
        die "Failed to import pool"
    }
    
    zfs load-key ${POOL_NAME} || {
        die "Failed to load encryption key"
    }
    
    if ! zpool list ${POOL_NAME} &>/dev/null; then
        die "Pool not imported!"
    fi
    success "Pool imported and unlocked"
}

mount_system() {
    info "Mounting system datasets"
    zfs mount ${POOL_NAME}/ROOT/"$ROOT_DATASET_NAME"
    zfs mount -a

    if ! mountpoint -q /mnt; then
        die "Root dataset not mounted!"
    fi

    info "Mounting EFI partition"
    mkdir -p /mnt/boot/efi
    mount "$EFI" /mnt/boot/efi
    
    if ! mountpoint -q /mnt/boot/efi; then
        die "EFI partition not mounted!"
    fi
    success "All filesystems mounted"
}

copy_zpool_cache() {
    info "Generating and copying ZFS cache"
    mkdir -p /mnt/etc/zfs
    
    zpool set cachefile=/etc/zfs/zpool.cache ${POOL_NAME}
    
    sleep 2
    
    if [[ ! -s /etc/zfs/zpool.cache ]]; then
        die "zpool.cache is missing or empty!"
    fi
    
    cp /etc/zfs/zpool.cache /mnt/etc/zfs/
    
    if ! diff /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache &>/dev/null; then
        die "Cache file copy verification failed!"
    fi
    
    debug "cachefile property set to: /etc/zfs/zpool.cache"
    success "ZFS cache configured"
}

# ============================================
# INSTALLATION PHASE FUNCTIONS
# ============================================

phase_disk_preparation() {
    header "PHASE 1: DISK PREPARATION"
    
    wipe
    partition
    zfs_passphrase
    
    if [[ "$INSTALL_TYPE" == "first" ]]; then
        create_pool
        create_root_dataset
    fi
}

phase_zfs_configuration() {
    header "PHASE 2: ZFS CONFIGURATION"
    
    if [[ "$INSTALL_TYPE" == "dualboot" ]]; then
        info "Importing existing pool for dualboot: $POOL_NAME"
        zpool import -d /dev/disk/by-id -R /mnt ${POOL_NAME} -N -f || {
            die "Failed to import existing pool: $POOL_NAME"
        }
        
        zfs load-key ${POOL_NAME} || {
            die "Failed to load encryption key"
        }
        
        # Check if dataset name already exists
        if zfs list "${POOL_NAME}/ROOT/$ROOT_DATASET_NAME" &>/dev/null; then
            error "Dataset ${POOL_NAME}/ROOT/$ROOT_DATASET_NAME already exists!"
            die "Please restart and choose a different dataset name."
        fi
    fi
    
    create_system_dataset
    
    if [[ "$INSTALL_TYPE" == "first" ]]; then
        create_home_dataset
        create_swapspace
    fi
    
    export_pool
    import_pool
    mount_system
    copy_zpool_cache
    zfs_passphrase_backup
}

phase_base_system_installation() {
    header "PHASE 3: BASE SYSTEM INSTALLATION"
    
    info 'Installing base system packages'
    
    XBPS_ARCH=$ARCH xbps-install -y -S \
        -r /mnt \
        -R "$REPO" \
        base-system \
        void-repo-nonfree \
        zfs \
        zfsbootmenu \
        efibootmgr \
        gummiboot \
        dracut \
        iwd \
        dhcpcd \
        openresolv \
        chrony \
        elogind \
        polkit-elogind \
        cronie \
        acpid \
        git || die "Package installation failed"
    
    success "Base system installed"
}

phase_system_configuration() {
    header "PHASE 4: SYSTEM CONFIGURATION"
    
    # Configure ZFS files
    info 'Copying ZFS configuration files'
    cp /etc/hostid /mnt/etc/hostid
    cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache
    cp -p /etc/zfs/${POOL_NAME}.key /mnt/etc/zfs/
    
    # Verify ZFS files were copied
    for file in /mnt/etc/hostid /mnt/etc/zfs/zpool.cache /mnt/etc/zfs/${POOL_NAME}.key; do
        if [[ ! -f "$file" ]]; then
            die "Failed to copy $(basename $file)!"
        fi
    done
    success "ZFS configuration files copied"
    
    # Configure dracut for ZFS
    info 'Configuring dracut for ZFS'
    mkdir -p /mnt/etc/dracut.conf.d
    cat > /mnt/etc/dracut.conf.d/zfs.conf <<EOF
hostonly="yes"
hostonly_cmdline="no"
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs resume "
install_items+=" /etc/zfs/${POOL_NAME}.key /etc/hostid "
force_drivers+=" zfs "
filesystems+=" zfs "
EOF
    success "Dracut configured"
    
    # Network configuration
    info 'Configuring network services'
    mkdir -p /mnt/etc/iwd
    cat > /mnt/etc/iwd/main.conf <<"EOF"
[General]
UseDefaultInterface=true
EnableNetworkConfiguration=true

[Network]
NameResolvingService=resolvconf
EOF

    cat >> /mnt/etc/resolvconf.conf <<"EOF"
resolv_conf=/etc/resolv.conf
name_servers="1.1.1.1 9.9.9.9"
EOF

    cat > /mnt/etc/sysctl.conf <<"EOF"
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    success "Network configuration complete"
    
    # System locale and time configuration
    info 'Configuring system locale and timezone'
    cat >> /mnt/etc/rc.conf <<EOF
TIMEZONE="$SYSTEM_TIMEZONE"
HARDWARECLOCK="UTC"
KEYMAP="us"
FONT="drdos8x14"
EOF
    
    echo 'LANG=en_US.UTF-8' > /mnt/etc/locale.conf
    echo 'en_US.UTF-8 UTF-8' >> /mnt/etc/default/libc-locales
    success "Locale and timezone configured"
    
    # Set hostname
    info "Setting hostname: $SYSTEM_HOSTNAME"
    echo "$SYSTEM_HOSTNAME" > /mnt/etc/hostname
    success "Hostname set"
    
    # Create fstab
    info 'Creating fstab'
    EFI_UUID=$(blkid -s UUID -o value "$EFI")
    cat > /mnt/etc/fstab <<EOF
# <file system>              <mount point>  <type>  <options>                        <dump> <pass>
UUID=$EFI_UUID               /boot/efi      vfat    defaults,noatime                 0      2
tmpfs                        /tmp           tmpfs   defaults,nosuid,nodev,mode=1777  0      0
tmpfs                        /dev/shm       tmpfs   defaults,nosuid,nodev,noexec     0      0
efivarfs                     /sys/firmware/efi/efivars efivarfs defaults              0      0
EOF
    success "fstab created"
    
    # Mount for chroot
    info 'Preparing chroot environment'
    mount --rbind /sys /mnt/sys
    mount --rbind /dev /mnt/dev
    mount --rbind /proc /mnt/proc
    success "Chroot environment ready"
}

phase_user_configuration() {
    header "PHASE 5: USER AND SERVICE CONFIGURATION"
    
    info 'Configuring users and services in chroot'
    
    chroot /mnt /bin/bash <<CHROOT
      set -e
      
      # Update xbps
      xbps-install -Syu xbps
      
      # Reconfigure packages
      xbps-reconfigure -fa
      
      # Generate locales
      xbps-reconfigure -f glibc-locales
      
      # Set root password
      echo "root:$ROOT_PASSWORD" | chpasswd
      
      # Create user account
      useradd -m -s /bin/bash -G network,wheel,video,audio,input,kvm "$SYSTEM_USERNAME"
      echo "$SYSTEM_USERNAME:$USER_PASSWORD" | chpasswd
      
      # Create user home dataset
      if ! zfs list ${POOL_NAME}/data/home/${SYSTEM_USERNAME} &>/dev/null; then
        zfs create ${POOL_NAME}/data/home/${SYSTEM_USERNAME}
      fi
      
      # Set proper ownership
      chown -R ${SYSTEM_USERNAME}:${SYSTEM_USERNAME} /home/${SYSTEM_USERNAME}
      
      # Activate swap if created
      if [[ -f /tmp/swap_created ]] && [[ "\$(cat /tmp/swap_created)" == "true" ]]; then
        sleep 2
        if [[ -e /dev/zvol/${POOL_NAME}/swap ]]; then
          swapon /dev/zvol/${POOL_NAME}/swap 2>/dev/null || true
        fi
      fi
      
      # Enable essential services
      for service in dhcpcd iwd chronyd crond dbus acpid elogind polkitd; do
        ln -sf /etc/sv/\${service} /etc/runit/runsvdir/default/
      done
      
      # Enable ZFS services
      for service in zfs-import zfs-mount zfs-zed; do
        ln -sf /etc/sv/\${service} /etc/runit/runsvdir/default/
      done
CHROOT
    
    success "User and services configured"
    
    # Configure sudo
    info 'Configuring sudo for wheel group'
    mkdir -p /mnt/etc/sudoers.d
    cat > /mnt/etc/sudoers.d/99-wheel <<"EOF"
## Allow members of group wheel to execute any command
%wheel ALL=(ALL:ALL) ALL

## Uncomment to allow members of group wheel to execute any command without password
# %wheel ALL=(ALL:ALL) NOPASSWD: ALL
EOF
    chmod 0440 /mnt/etc/sudoers.d/99-wheel
    success "Sudo configured"
    
    # Add swap entry if created
    if [[ -f /tmp/swap_created ]] && [[ "$(cat /tmp/swap_created)" == "true" ]]; then
        echo "/dev/zvol/${POOL_NAME}/swap  none           swap    defaults,pri=100                 0      0" >> /mnt/etc/fstab
    fi
}

phase_boot_configuration() {
    header "PHASE 6: BOOT CONFIGURATION"
    
    # Update dracut configuration
    info 'Updating dracut global configuration'
    cat > /mnt/etc/dracut.conf <<"EOF"
hostonly="yes"
compress="zstd"
add_drivers+=" zfs "
omit_dracutmodules+=" network plymouth "
EOF
    success "Dracut global configuration updated"
    
    # Set ZFS boot commandline
    info "Setting ZFS boot parameters"
    zfs set org.zfsbootmenu:commandline="ro quiet nowatchdog loglevel=0 zbm.timeout=5" ${POOL_NAME}/ROOT/"$ROOT_DATASET_NAME"
    
    # Disable gummiboot post-install hook
    info 'Disabling gummiboot hook'
    cat > /mnt/etc/default/gummiboot <<"EOF"
GUMMIBOOT_DISABLE=1
EOF
    
    info 'Generating ZFSBootMenu initramfs'
    chroot /mnt /bin/bash <<CHROOT
      set -e
      generate-zbm
CHROOT
    success "ZFSBootMenu initramfs generated"
    
    # Verify ZFSBootMenu files
    info 'Verifying ZFSBootMenu files'
    if [[ ! -f /mnt/boot/efi/EFI/ZBM/vmlinuz.efi ]]; then
        die "ZFSBootMenu EFI image not found!"
    fi
    
    # Create UEFI boot entries
    info 'Creating UEFI boot entries'
    
    # Remove old entries if they exist
    efibootmgr | grep "ZFSBootMenu" | awk '{print $1}' | sed 's/Boot//;s/*//' | \
        xargs -I {} efibootmgr -b {} -B 2>/dev/null || true
    
    # Add new entry
    DISK_FOR_EFI=$(echo "$DISK" | sed 's/[0-9]*$//')
    PART_NUM=$(echo "$EFI" | grep -o '[0-9]*$')
    
    efibootmgr --create \
        --disk "$DISK_FOR_EFI" \
        --part "$PART_NUM" \
        --label "ZFSBootMenu" \
        --loader '\EFI\ZBM\vmlinuz.efi' \
        --verbose
    
    success "UEFI boot entries created"
    
    # Set backup kernel as fallback
    if [[ -f /mnt/boot/efi/EFI/ZBM/vmlinuz-backup.efi ]]; then
        info 'Creating backup boot entry'
        efibootmgr --create \
            --disk "$DISK_FOR_EFI" \
            --part "$PART_NUM" \
            --label "ZFSBootMenu (Backup)" \
            --loader '\EFI\ZBM\vmlinuz-backup.efi' \
            --verbose
        success "Backup boot entry created"
    fi
    
    info "Current boot order:"
    efibootmgr
}

phase_cleanup() {
    header "PHASE 7: CLEANUP"
    
    info 'Unmounting filesystems'
    
    # Unmount EFI
    umount /mnt/boot/efi || {
        warning "Failed to unmount /mnt/boot/efi"
    }
    
    # Unmount bind mounts
    umount -l /mnt/{dev,proc,sys} 2>/dev/null || true
    
    # Unmount ZFS filesystems
    zfs umount -a
    
    # Export pool
    info "Exporting zpool: $POOL_NAME"
    zpool export ${POOL_NAME}
    
    if zpool list ${POOL_NAME} &>/dev/null 2>&1; then
        warning "Pool still imported, forcing export..."
        zpool export -f ${POOL_NAME}
    fi
    
    success "Cleanup complete"
}

phase_verification() {
    header "INSTALLATION VERIFICATION"
    
    print_status "success" "ZFS pool created: $POOL_NAME"
    print_status "success" "Root dataset: ${POOL_NAME}/ROOT/$ROOT_DATASET_NAME"
    print_status "success" "Encryption: AES-256-GCM"
    print_status "success" "Hostname: $SYSTEM_HOSTNAME"
    print_status "success" "User: $SYSTEM_USERNAME"
    print_status "success" "Timezone: $SYSTEM_TIMEZONE"
    print_status "success" "ZFSBootMenu: installed"
    print_status "success" "UEFI entries: created"
    if [[ "$CREATE_SWAP" == true ]]; then
        print_status "success" "Swap: configured ($SWAP_SIZE)"
    fi
}

# ============================================
# MAIN INSTALLATION ORCHESTRATION
# ============================================

main() {
    # Check prerequisites
    check_prerequisites
    
    # Collect all user inputs
    collect_user_inputs
    
    # Show summary and confirm
    show_installation_summary
    confirm_installation
    
    # Execute installation phases
    phase_disk_preparation
    phase_zfs_configuration
    phase_base_system_installation
    phase_system_configuration
    phase_user_configuration
    phase_boot_configuration
    phase_cleanup
    
    # Show final status
    phase_verification
    
    # Final message
    header "INSTALLATION COMPLETE"
    success "Void Linux with ZFS has been successfully installed!"
    echo ""
    info "Important notes:"
    bullet "ZFS encryption key backed up to: /root/zfs-keys/${POOL_NAME}.key"
    bullet "Pool name: $POOL_NAME"
    bullet "Root dataset: ${POOL_NAME}/ROOT/$ROOT_DATASET_NAME"
    bullet "System will boot to ZFSBootMenu"
    bullet "You will be prompted for the ZFS encryption passphrase at boot"
    echo ""
    info "You can now reboot into your new system:"
    echo "  reboot"
    echo ""
}

# ============================================
# SCRIPT ENTRY POINT
# ============================================

# Run main function
main "$@"
