#!/usr/bin/env bash
# filepath: zfs-void-install.sh
# Void Linux ZFS Installation Script
# Version: 3.0 - Refactored with main() and phase functions

export TERM=xterm
set -e

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/common.sh" ]]; then
    source "${SCRIPT_DIR}/common.sh"
elif [[ -f "/usr/local/lib/zfs-scripts/common.sh" ]]; then
    source "/usr/local/lib/zfs-scripts/common.sh"
else
    echo "ERROR: common.sh library not found!" >&2
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
    local failed=0
    
    header "Checking Prerequisites"
    
    # Check for root privileges
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        failed=1
    else
        success "Running as root"
    fi
    
    # Check for EFI boot mode
    if ! ls /sys/firmware/efi/efivars &>/dev/null; then
        error "System not booted in EFI mode"
        failed=1
    else
        success "System is in EFI mode"
    fi
    
    # Check network connectivity
    if ! ping -c 1 voidlinux.org &>/dev/null; then
        error "No network connectivity to voidlinux.org"
        failed=1
    else
        success "Network connectivity verified"
    fi
    
    # Check for ZFS module
    if ! modprobe zfs &>/dev/null; then
        error "ZFS kernel module not available"
        failed=1
    else
        success "ZFS module loaded"
    fi
    
    if ((failed)); then
        die "Prerequisites check failed"
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
    # Use printf to render colors for PS3 prompt
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
    
    # Step 4: ZFS Encryption Passphrase
    subheader "Step 4: ZFS Encryption Passphrase"
    collect_zfs_passphrase
    
    # Step 5: Root Dataset Name
    subheader "Step 5: Root Dataset Name"
    collect_dataset_name
    
    # Step 6: Swap Configuration (if first install)
    if [[ "$INSTALL_TYPE" == "first" ]]; then
        subheader "Step 6: Swap Configuration"
        collect_swap_config
    fi
    
    # Step 7: System Information
    subheader "Step 7: System Configuration"
    collect_system_info
    
    success "User input collection complete"
}

collect_disk_selection() {
    local disks=()
    while IFS= read -r disk; do
        # Filter out partition entries
        if [[ ! $disk =~ -(part|p)[0-9]+$ ]]; then
            disks+=("$disk")
        fi
    done < <(ls /dev/disk/by-id/)
    
    if [[ ${#disks[@]} -eq 0 ]]; then
        die "No disks found!"
    fi
    
    # Use ANSI-C quoting for PS3
    PS3=$'\033[1;94m→\033[0m Select installation disk: '
    select ENTRY in "${disks[@]}"; do
        if [[ -n $ENTRY ]]; then
            DISK="/dev/disk/by-id/$ENTRY"
            info "Selected disk: $ENTRY"
            info "Full path: $DISK"
            
            # Display disk information
            if command -v lsblk &>/dev/null; then
                echo ""
                lsblk "$DISK" 2>/dev/null || true
                echo ""
            fi
            break
        fi
    done
}

collect_wipe_decision() {
    echo ""
    if ask_yes_no "Do you want to wipe all data on $(basename $DISK)?" "n"; then
        DISK_TO_WIPE=true
        warning "Disk will be wiped during installation"
    else
        DISK_TO_WIPE=false
        info "Disk will NOT be wiped. Ensure disk is properly prepared."
    fi
}

collect_zfs_passphrase() {
    while true; do
        # Use echo -e for colored prompt
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Enter ZFS encryption passphrase: "
        read -r -s pass1
        echo
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Confirm passphrase: "
        read -r -s pass2
        echo
        
        if [[ "$pass1" == "$pass2" ]]; then
            if [[ ${#pass1} -lt 8 ]]; then
                error "Passphrase must be at least 8 characters!"
                continue
            fi
            ZFS_PASSPHRASE="$pass1"
            success "Passphrase confirmed (${#pass1} characters)"
            break
        else
            error "Passphrases do not match. Try again."
        fi
    done
}

collect_dataset_name() {
    while true; do
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Enter name for root dataset: "
        read -r ROOT_DATASET_NAME
        
        # Validate name format
        if [[ ! "$ROOT_DATASET_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            error "Invalid dataset name. Use only letters, numbers, hyphens, and underscores."
            continue
        fi
        
        info "Dataset name set to: $ROOT_DATASET_NAME"
        if [[ "$INSTALL_TYPE" == "dualboot" ]]; then
            info "Note: Will verify uniqueness when pool is imported"
        fi
        break
    done
}

collect_swap_config() {
    echo ""
    if ask_yes_no "Do you want to create swap space?" "n"; then
        CREATE_SWAP=true
        
        while true; do
            echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Enter swap size (e.g., 4G, 8G): "
            read -r SWAP_SIZE
            if [[ $SWAP_SIZE =~ ^[0-9]+[GMgm]$ ]]; then
                info "Swap size set to: $SWAP_SIZE"
                break
            else
                error "Invalid format. Use format like 4G or 8G"
            fi
        done
    else
        CREATE_SWAP=false
        info "No swap space will be created"
    fi
}

collect_system_info() {
    # Hostname
    while true; do
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Enter hostname: "
        read -r SYSTEM_HOSTNAME
        if [[ -n "$SYSTEM_HOSTNAME" ]] && [[ "$SYSTEM_HOSTNAME" =~ ^[a-zA-Z0-9-]+$ ]]; then
            info "Hostname set to: $SYSTEM_HOSTNAME"
            break
        else
            error "Invalid hostname. Use only letters, numbers, and hyphens."
        fi
    done
    
    echo ""
    
    # Timezone
    subheader "Common timezones:"
    bullet "America/New_York"
    bullet "America/Los_Angeles"
    bullet "Europe/London"
    bullet "Asia/Singapore"
    bullet "Australia/Sydney"
    echo ""
    
    while true; do
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Enter timezone (default: Asia/Singapore): "
        read -r SYSTEM_TIMEZONE
        SYSTEM_TIMEZONE=${SYSTEM_TIMEZONE:-"Asia/Singapore"}
        
        if [[ -f "/usr/share/zoneinfo/$SYSTEM_TIMEZONE" ]]; then
            info "Timezone set to: $SYSTEM_TIMEZONE"
            break
        else
            error "Invalid timezone. Check /usr/share/zoneinfo/ for valid options."
        fi
    done
    
    echo ""
    
    # Username
    while true; do
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Enter username: "
        read -r SYSTEM_USERNAME
        
        if [[ ! $SYSTEM_USERNAME =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            error "Invalid username. Must start with lowercase letter or underscore."
            continue
        fi
        
        if [[ "$SYSTEM_USERNAME" == "root" ]] || [[ "$SYSTEM_USERNAME" == "nobody" ]]; then
            error "Cannot use reserved username: $SYSTEM_USERNAME"
            continue
        fi
        
        info "Username set to: $SYSTEM_USERNAME"
        break
    done
    
    echo ""
    
    # Root password
    subheader "Set root password:"
    while true; do
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Root password: "
        read -r -s ROOT_PASSWORD
        echo
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Confirm root password: "
        read -r -s pass2
        echo
        
        if [[ "$ROOT_PASSWORD" == "$pass2" ]]; then
            if [[ ${#ROOT_PASSWORD} -lt 6 ]]; then
                error "Password must be at least 6 characters!"
                continue
            fi
            success "Root password set"
            break
        else
            error "Passwords do not match. Try again."
        fi
    done
    
    echo ""
    
    # User password
    subheader "Set password for user: $SYSTEM_USERNAME"
    while true; do
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} User password: "
        read -r -s USER_PASSWORD
        echo
        echo -ne "${BLUE}${SYMBOL_ARROW}${NC} Confirm user password: "
        read -r -s pass2
        echo
        
        if [[ "$USER_PASSWORD" == "$pass2" ]]; then
            if [[ ${#USER_PASSWORD} -lt 6 ]]; then
                error "Password must be at least 6 characters!"
                continue
            fi
            success "User password set"
            break
        else
            error "Passwords do not match. Try again."
        fi
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
    bullet "Pool Name: zroot"
    bullet "Encryption: AES-256-GCM"
    bullet "Compression: lz4"
    bullet "Root Dataset: zroot/ROOT/$ROOT_DATASET_NAME"
    bullet "Passphrase Length: ${#ZFS_PASSPHRASE} characters"
    echo ""
    
    if [[ "$INSTALL_TYPE" == "first" ]]; then
        subheader "Additional Datasets:"
        bullet "Home: zroot/data/home"
        bullet "Root home: zroot/data/root"
        if [[ "$CREATE_SWAP" == true ]]; then
            bullet "Swap: zroot/swap ($SWAP_SIZE)"
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
    warning "Please review the installation summary above."
    echo ""
    
    if ! confirm_action "This will modify disk $(basename $DISK)" "n"; then
        echo ""
        info "Installation aborted by user."
        info "No changes have been made to your system."
        exit 0
    fi
    
    header "Beginning Installation - This process is now automated"
}

# ============================================
# DISK OPERATION FUNCTIONS
# ============================================

wipe() {
    if [[ "$DISK_TO_WIPE" != true ]]; then
        return 0
    fi
    
    info "Wiping disk..."
    dd if=/dev/zero of="$DISK" bs=512 count=1
    wipefs -af "$DISK"
    sgdisk -Zo "$DISK"
    zpool labelclear -f "$DISK" 2>/dev/null || true
    
    partprobe "$DISK"
    sleep 2
    success "Disk wiped"
}

partition() {
    info "Creating EFI partition"
    sgdisk -n1:1M:+512M -t1:EF00 "$DISK"
    EFI="$DISK-part1"

    info "Creating ZFS partition"
    sgdisk -n2:0:0 -t2:BF00 "$DISK"
    ZFS_PARTITION="$DISK-part2"
    
    partprobe "$DISK"
    sleep 2

    until [ -e "$EFI" ]; do sleep 1; done
    until [ -e "$ZFS_PARTITION" ]; do sleep 1; done
        
    info "Formatting EFI partition"    
    mkfs.vfat -F32 -n "EFI" "$EFI" || die "EFI format failed"
    
    sgdisk -p "$DISK"
    success "Disk partitioned successfully"
}

zfs_passphrase() {
    info "Creating ZFS encryption key file"
    echo "$ZFS_PASSPHRASE" > /etc/zfs/zroot.key
    chmod 000 /etc/zfs/zroot.key
    
    if [[ ! -f /etc/zfs/zroot.key ]] || [[ ! -s /etc/zfs/zroot.key ]]; then
        die "Failed to create key file!"
    fi
    success "Encryption key file created"
}

zfs_passphrase_backup() {
    info 'Creating encryption key backup'
    mkdir -p /mnt/root/zfs-keys
    zfs get -H -o value keylocation zroot > /mnt/root/zfs-keys/keylocation
    install -m 000 /etc/zfs/zroot.key /mnt/root/zfs-keys/
    
    if ! diff /etc/zfs/zroot.key /mnt/root/zfs-keys/zroot.key &>/dev/null; then
        die "Key backup verification failed!"
    fi
    success "Encryption key backed up"
}

# ============================================
# ZFS POOL & DATASET FUNCTIONS
# ============================================

create_pool() {
    info "Creating ZFS pool"
    zpool create -f -o ashift=12                          \
                 -o autotrim=on                           \
                 -O acltype=posixacl                      \
                 -O compression=lz4                       \
                 -O relatime=on                           \
                 -O xattr=sa                              \
                 -O dnodesize=auto                        \
                 -O encryption=aes-256-gcm                \
                 -O keyformat=passphrase                  \
                 -O keylocation=file:///etc/zfs/zroot.key \
                 -O normalization=formD                   \
                 -O mountpoint=none                       \
                 -O canmount=off                          \
                 -O devices=off                           \
                 -R /mnt                                  \
                 zroot "$ZFS_PARTITION"
    
    if ! zpool list zroot &>/dev/null; then
        die "Pool creation failed!"
    fi
    success "ZFS pool created"
}

create_root_dataset() {
    info "Creating root dataset container"
    zfs create -o mountpoint=none zroot/ROOT
    zfs set org.zfsbootmenu:commandline="ro quiet loglevel=0" zroot/ROOT
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
           zroot/ROOT/"$ROOT_DATASET_NAME"

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
    zpool set bootfs="zroot/ROOT/$ROOT_DATASET_NAME" zroot

    zfs mount zroot/ROOT/"$ROOT_DATASET_NAME"
    
    if ! mountpoint -q /mnt; then
        die "Failed to mount root dataset!"
    fi
    success "System dataset created and mounted"
}

create_home_dataset() {
    info "Creating home datasets"
    zfs create -o mountpoint=none -o canmount=off zroot/data
    zfs create -o mountpoint=/home \
               -o recordsize=1M \
               -o compression=zstd-3 \
               -o atime=off \
               zroot/data/home
    zfs create -o mountpoint=/root \
               -o recordsize=128K \
               -o compression=zstd \
               zroot/data/root
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
        zroot/swap

    info "Waiting for zvol device..."
    local count=0
    until [[ -e /dev/zvol/zroot/swap ]] || [[ $count -ge 30 ]]; do
        sleep 1
        ((count++))
    done
    
    if [[ ! -e /dev/zvol/zroot/swap ]]; then
        die "Swap zvol device did not appear!"
    fi

    info "Formatting swap"
    mkswap -f /dev/zvol/zroot/swap
    
    echo "true" > /tmp/swap_created
    success "Swap zvol created"
}

export_pool() {
    info "Exporting zpool"
    zpool export zroot
    
    if zpool list zroot &>/dev/null; then
        die "Pool export failed!"
    fi
    success "Pool exported"
}

import_pool() {
    info "Importing zpool"
    zpool import -d /dev/disk/by-id -R /mnt zroot -N -f || {
        die "Failed to import pool"
    }
    
    zfs load-key zroot || {
        die "Failed to load encryption key"
    }
    
    if ! zpool list zroot &>/dev/null; then
        die "Pool not imported!"
    fi
    success "Pool imported and unlocked"
}

mount_system() {
    info "Mounting system datasets"
    zfs mount zroot/ROOT/"$ROOT_DATASET_NAME"
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
    
    zpool set cachefile=/etc/zfs/zpool.cache zroot
    
    local cachefile_value
    cachefile_value=$(zpool get -H -o value cachefile zroot)
    if [[ "$cachefile_value" != "/etc/zfs/zpool.cache" ]]; then
        die "Failed to set cachefile property! Got: $cachefile_value"
    fi
    
    sleep 2
    
    if [[ ! -s /etc/zfs/zpool.cache ]]; then
        die "zpool.cache is missing or empty!"
    fi
    
    cp /etc/zfs/zpool.cache /mnt/etc/zfs/
    
    if ! diff /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache &>/dev/null; then
        die "Cache file copy verification failed!"
    fi
    
    debug "cachefile property set to: $cachefile_value"
    success "ZFS cache configured"
}

# ============================================
# INSTALLATION PHASE FUNCTIONS
# ============================================

phase_disk_preparation() {
    header "PHASE 1: DISK PREPARATION"
    
    if [[ "$INSTALL_TYPE" == "first" ]]; then
        wipe
        partition
        zfs_passphrase
        create_pool
        create_root_dataset
    else
        info "Dualboot mode: Skipping disk preparation"
    fi
}

phase_zfs_configuration() {
    header "PHASE 2: ZFS CONFIGURATION"
    
    if [[ "$INSTALL_TYPE" == "dualboot" ]]; then
        info "Importing existing pool for dualboot"
        zpool import -d /dev/disk/by-id -R /mnt zroot -N -f || {
            die "Failed to import existing pool"
        }
        
        zfs load-key zroot || {
            die "Failed to load encryption key"
        }
        
        # Check if dataset name already exists
        if zfs list "zroot/ROOT/$ROOT_DATASET_NAME" &>/dev/null; then
            error "Dataset zroot/ROOT/$ROOT_DATASET_NAME already exists!"
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
    
    # Copy xbps keys
    info 'Copying xbps keys'
    mkdir -p /mnt/var/db/xbps/keys
    cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
    
    # Install base system
    info 'Installing Void Linux base system (this may take a while)'
    XBPS_ARCH=$ARCH xbps-install -y -S -r /mnt -R "$REPO" \
      base-system \
      void-repo-nonfree
    
    # Verify base system installation
    if [[ ! -f /mnt/usr/bin/xbps-install ]]; then
        die "Base system installation failed!"
    fi
    success "Base system installed"
    
    # Init chroot mounts
    info 'Initializing chroot environment'
    mount --rbind /sys /mnt/sys && mount --make-rslave /mnt/sys
    mount --rbind /dev /mnt/dev && mount --make-rslave /mnt/dev
    mount --rbind /proc /mnt/proc && mount --make-rslave /mnt/proc
    success "Chroot environment ready"
    
    # Disable gummiboot post install hooks
    echo "GUMMIBOOT_DISABLE=1" > /mnt/etc/default/gummiboot
    
    # Install packages
    info 'Installing required packages'
    local packages=(
      zfs
      zfsbootmenu
      efibootmgr
      gummiboot
      chrony
      elogind
      polkit-elogind
      cronie
      acpid
      iwd
      dhcpcd
      git
      openresolv
      dracut
    )
    
    XBPS_ARCH=$ARCH xbps-install -y -S -r /mnt -R "$REPO" "${packages[@]}"
    
    # Verify critical packages
    for pkg in zfs zfsbootmenu dracut; do
        if ! chroot /mnt xbps-query $pkg &>/dev/null; then
            die "Package $pkg not installed!"
        fi
    done
    success "All required packages installed"
}

phase_system_configuration() {
    header "PHASE 4: SYSTEM CONFIGURATION"
    
    # Set hostname
    info "Setting hostname: $SYSTEM_HOSTNAME"
    echo "$SYSTEM_HOSTNAME" > /mnt/etc/hostname
    
    # Configure ZFS files
    info 'Copying ZFS configuration files'
    cp /etc/hostid /mnt/etc/hostid
    cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache
    cp -p /etc/zfs/zroot.key /mnt/etc/zfs/
    
    # Verify ZFS files were copied
    for file in /mnt/etc/hostid /mnt/etc/zfs/zpool.cache /mnt/etc/zfs/zroot.key; do
        if [[ ! -f "$file" ]]; then
            die "Failed to copy $(basename $file)!"
        fi
    done
    success "ZFS configuration files copied"
    
    # Configure iwd
    info 'Configuring iwd'
    mkdir -p /mnt/etc/iwd
    cat > /mnt/etc/iwd/main.conf <<"EOF"
[General]
UseDefaultInterface=true
EnableNetworkConfiguration=true

[Network]
NameResolvingService=resolvconf
EOF
    
    # Configure DNS
    info 'Configuring DNS'
    cat >> /mnt/etc/resolvconf.conf <<"EOF"
resolv_conf=/etc/resolv.conf
name_servers="1.1.1.1 9.9.9.9"
EOF
    
    # Enable IP forwarding
    info 'Configuring sysctl'
    cat > /mnt/etc/sysctl.conf <<"EOF"
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    
    # Prepare locales and keymap
    info 'Configuring locales and keymap'
    echo 'en_US.UTF-8 UTF-8' > /mnt/etc/default/libc-locales
    echo 'LANG="en_US.UTF-8"' > /mnt/etc/locale.conf
    echo 'KEYMAP="us"' > /mnt/etc/vconsole.conf
    
    # Configure system
    info "Configuring timezone: $SYSTEM_TIMEZONE"
    cat >> /mnt/etc/rc.conf << EOF
TIMEZONE="$SYSTEM_TIMEZONE"
HARDWARECLOCK="UTC"
KEYMAP="us"
FONT="drdos8x14"
EOF
    
    # Configure dracut for ZFS
    info 'Configuring dracut'
    mkdir -p /mnt/etc/dracut.conf.d
    
    cat > /mnt/etc/dracut.conf.d/zfs.conf <<"EOF"
hostonly="yes"
hostonly_cmdline="no"
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs resume "
install_items+=" /etc/zfs/zroot.key /etc/hostid "
force_drivers+=" zfs "
filesystems+=" zfs "
EOF
    
    cat > /mnt/etc/dracut.conf <<"EOF"
hostonly="yes"
compress="zstd"
add_drivers+=" zfs "
omit_dracutmodules+=" network plymouth "
EOF
    
    success "System configuration complete"
}

phase_user_configuration() {
    header "PHASE 5: USER CONFIGURATION"
    
    # Chroot and configure system
    info 'Configuring system services and users in chroot'
    chroot /mnt/ /bin/bash -e <<CHROOT_EOF
      set -e
      
      # Configure DNS
      resolvconf -u
    
      # Enable essential services
      ln -sf /etc/sv/dhcpcd /etc/runit/runsvdir/default/
      ln -sf /etc/sv/iwd /etc/runit/runsvdir/default/
      ln -sf /etc/sv/chronyd /etc/runit/runsvdir/default/
      ln -sf /etc/sv/crond /etc/runit/runsvdir/default/
      ln -sf /etc/sv/dbus /etc/runit/runsvdir/default/
      ln -sf /etc/sv/acpid /etc/runit/runsvdir/default/
      ln -sf /etc/sv/elogind /etc/runit/runsvdir/default/
      ln -sf /etc/sv/polkitd /etc/runit/runsvdir/default/
      
      # Enable ZFS services
      ln -sf /etc/sv/zfs-import /etc/runit/runsvdir/default/
      ln -sf /etc/sv/zfs-mount /etc/runit/runsvdir/default/
      ln -sf /etc/sv/zfs-zed /etc/runit/runsvdir/default/
    
      # Set timezone
      ln -sf "/usr/share/zoneinfo/$SYSTEM_TIMEZONE" /etc/localtime
      
      # Generate locales
      xbps-reconfigure -f glibc-locales
    
      # Create user home dataset
      if ! zfs list zroot/data/home/${SYSTEM_USERNAME} &>/dev/null; then
        zfs create zroot/data/home/${SYSTEM_USERNAME}
      fi
      
      # Add user
      useradd -m -d /home/${SYSTEM_USERNAME} -G network,wheel,video,audio,input,kvm ${SYSTEM_USERNAME}
      chown -R ${SYSTEM_USERNAME}:${SYSTEM_USERNAME} /home/${SYSTEM_USERNAME}
      
      # Activate swap if created
      if [[ -f /tmp/swap_created ]] && [[ "\$(cat /tmp/swap_created)" == "true" ]]; then
        sleep 2
        if [[ -e /dev/zvol/zroot/swap ]]; then
          swapon /dev/zvol/zroot/swap 2>/dev/null || true
        fi
      fi
CHROOT_EOF
    
    success "Services and user account configured"
    
    # Configure fstab
    info 'Configuring fstab'
    local EFI_UUID
    EFI_UUID=$(blkid -s UUID -o value "$EFI")
    
    cat > /mnt/etc/fstab <<EOF
# <file system>              <mount point>  <type>  <options>                        <dump> <pass>
UUID=$EFI_UUID               /boot/efi      vfat    defaults,noatime                 0      2
tmpfs                        /tmp           tmpfs   defaults,nosuid,nodev,mode=1777  0      0
tmpfs                        /dev/shm       tmpfs   defaults,nosuid,nodev,noexec     0      0
efivarfs                     /sys/firmware/efi/efivars efivarfs defaults              0      0
EOF
    
    # Add swap entry if created
    if [[ -f /tmp/swap_created ]] && [[ "$(cat /tmp/swap_created)" == "true" ]]; then
        echo "/dev/zvol/zroot/swap  none           swap    defaults,pri=100                 0      0" >> /mnt/etc/fstab
    fi
    success "fstab configured"
    
    # Set passwords
    info 'Setting passwords'
    echo "root:$ROOT_PASSWORD" | chroot /mnt chpasswd
    echo "$SYSTEM_USERNAME:$USER_PASSWORD" | chroot /mnt chpasswd
    success "Passwords set"
    
    # Configure sudo
    info 'Configuring sudo'
    cat > /mnt/etc/sudoers.d/99-wheel <<EOF
## Allow members of group wheel to execute any command
%wheel ALL=(ALL:ALL) ALL

## Uncomment to allow members of group wheel to execute any command without password
# %wheel ALL=(ALL:ALL) NOPASSWD: ALL
EOF
    
    chmod 0440 /mnt/etc/sudoers.d/99-wheel
    
    # Verify sudo configuration
    if ! chroot /mnt visudo -c -f /etc/sudoers.d/99-wheel; then
        die "Invalid sudo configuration!"
    fi
    success "sudo configured"
}

phase_boot_configuration() {
    header "PHASE 6: BOOT CONFIGURATION"
    
    # Configure ZFSBootMenu
    info 'Configuring ZFSBootMenu'
    
    mkdir -p /mnt/boot/efi/EFI/ZBM /mnt/etc/zfsbootmenu/dracut.conf.d
    
    cat > /mnt/etc/zfsbootmenu/config.yaml <<EOF
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
  CommandLine: ro quiet loglevel=0 nowatchdog
  Prefix: vmlinuz
EOF
    
    # Configure dracut for ZBM
    cat > /mnt/etc/zfsbootmenu/dracut.conf.d/keymap.conf <<EOF
install_optional_items+=" /etc/cmdline.d/keymap.conf "
EOF
    
    mkdir -p /mnt/etc/cmdline.d/
    cat > /mnt/etc/cmdline.d/keymap.conf <<EOF
rd.vconsole.keymap=us
EOF
    
    success "ZFSBootMenu configured"
    
    # Set ZFS boot commandline
    info "Setting ZFS boot parameters"
    zfs set org.zfsbootmenu:commandline="ro quiet nowatchdog loglevel=0 zbm.timeout=5" zroot/ROOT/"$ROOT_DATASET_NAME"
    
    # Generate ZFSBootMenu
    info 'Generating ZFSBootMenu and initramfs (this may take a while)'
    chroot /mnt/ /bin/bash -e <<"EOF"
      set -e
    
      # Export locale
      export LANG="en_US.UTF-8"
    
      # Reconfigure all packages to generate initramfs
      xbps-reconfigure -fa
      
      # Verify ZBM files were generated
      if [[ ! -f /boot/efi/EFI/ZBM/vmlinuz.efi ]]; then
        echo "ERROR: ZFSBootMenu generation failed!" >&2
        exit 1
      fi
      
      # Verify initramfs contains ZFS module
      if ! lsinitrd /boot/initramfs-*.img 2>/dev/null | grep -q "zfs.ko"; then
        echo "WARNING: ZFS module may not be in initramfs!"
      fi
EOF
    
    # Verify critical boot files
    if [[ ! -f /mnt/boot/efi/EFI/ZBM/vmlinuz.efi ]]; then
        die "ZFSBootMenu EFI file not found!"
    fi
    success "ZFSBootMenu and initramfs generated"
    
    # Create backup
    if [[ ! -f /mnt/boot/efi/EFI/ZBM/vmlinuz-backup.efi ]]; then
        info "Creating ZFSBootMenu backup"
        cp /mnt/boot/efi/EFI/ZBM/vmlinuz.efi /mnt/boot/efi/EFI/ZBM/vmlinuz-backup.efi
    fi
    
    # Create UEFI boot entries
    info 'Creating EFI boot entries'
    modprobe efivarfs
    mountpoint -q /sys/firmware/efi/efivars \
        || mount -t efivarfs efivarfs /sys/firmware/efi/efivars
    
    # Remove existing ZFSBootMenu entries
    if efibootmgr | grep -q "ZFSBootMenu"; then
        info "Removing old ZFSBootMenu entries"
        for entry in $(efibootmgr | grep "ZFSBootMenu" | sed -E 's/Boot([0-9]+).*/\1/'); do   
            efibootmgr -B -b "$entry"
        done
    fi
    
    # Create backup entry
    info "Creating backup boot entry"
    if ! efibootmgr --disk "$DISK" \
      --part 1 \
      --create \
      --label "ZFSBootMenu Backup" \
      --loader "\EFI\ZBM\vmlinuz-backup.efi" \
      --verbose; then
        warning "Failed to create backup boot entry!"
    fi
    
    # Create main entry
    info "Creating main boot entry"
    if ! efibootmgr --disk "$DISK" \
      --part 1 \
      --create \
      --label "ZFSBootMenu" \
      --loader "\EFI\ZBM\vmlinuz.efi" \
      --verbose; then
        die "Failed to create main boot entry!"
    fi
    
    # Display boot order
    subheader "Current boot order:"
    efibootmgr
    success "Boot configuration complete"
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
    info 'Exporting zpool'
    zpool export zroot
    
    if zpool list zroot &>/dev/null 2>&1; then
        warning "Pool still imported, forcing export..."
        zpool export -f zroot
    fi
    
    success "Cleanup complete"
}

phase_verification() {
    header "INSTALLATION VERIFICATION"
    
    print_status "success" "ZFS pool created: zroot"
    print_status "success" "Root dataset: zroot/ROOT/$ROOT_DATASET_NAME"
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
# MAIN FUNCTION
# ============================================

main() {
    # Parse command line arguments
    if [[ "$1" == "debug" ]]; then
        set -x
        DEBUG_MODE=true
        CURRENT_LOG_LEVEL=$LOG_LEVEL_DEBUG
    fi
    
    # Banner
    echo ""
    echo -e "${MAGENTA}╔════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║   VOID LINUX ZFS INSTALLATION SCRIPT       ║${NC}"
    echo -e "${MAGENTA}║   Version 3.0                              ║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Phase 0: Prerequisites
    check_prerequisites
    
    # Phase 1: User Input Collection
    collect_user_inputs
    
    # Phase 2: Summary and Confirmation
    show_installation_summary
    confirm_installation
    
    # Phase 3: Disk Preparation
    phase_disk_preparation
    
    # Phase 4: ZFS Configuration
    phase_zfs_configuration
    
    # Phase 5: Base System Installation
    phase_base_system_installation
    
    # Phase 6: System Configuration
    phase_system_configuration
    
    # Phase 7: User Configuration
    phase_user_configuration
    
    # Phase 8: Boot Configuration
    phase_boot_configuration
    
    # Phase 9: Cleanup
    phase_cleanup
    
    # Phase 10: Verification
    phase_verification
    
    # Success message
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Installation completed successfully!  ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    subheader "Next steps:"
    bullet "Remove installation media"
    bullet "Reboot the system"
    bullet "At ZFSBootMenu, select your boot environment"
    bullet "Enter encryption passphrase when prompted"
    echo ""
    info "To reboot now, run: reboot"
    echo ""
}

# ============================================
# SCRIPT ENTRY POINT
# ============================================

# Execute main function with all arguments
main "$@"

exit 0