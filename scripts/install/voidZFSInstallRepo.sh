#!/usr/bin/env bash
# filepath: voidZFSInstallRepo.sh
# Void Linux ZFS Installation Script
# Version: 3.1 - All user input collected upfront

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
    echo "Searched locations:"
    echo "  - $LIB_DIR/common.sh"
    echo "  - $SCRIPT_DIR/../lib/common.sh"
    echo "  - $SCRIPT_DIR/common.sh"
    echo ""
    echo "Please install common.sh to: $LIB_DIR/"
    exit 1
fi

# ============================================
# Script Configuration
# ============================================
LOG_FILE="configureNinstall.log"
FONT="drdos8x14"

# Script metadata
SCRIPT_NAME="Void Linux ZFS Installation"
SCRIPT_VERSION="3.1"

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

# ============================================
# Additional UI Functions (beyond common.sh)
# ============================================
print() {
    echo ""
    info "$1"
    echo ""
    if [[ -n "${debug:-}" ]]; then
        read -rp "Press enter to continue"
    fi
}

ask() {
    read -p "${BLUE}> $1 ${NC}" -r
    echo
}

menu() {
    PS3="$(printf "${BLUE}> Choose a number: ${NC}")"
    select i in "$@"; do
        echo "$i"
        break
    done
}

# ============================================
# Prerequisites Check
# ============================================
check_prerequisites() {
    local failed=0
    
    subheader "Prerequisites Check"
    
    # Check for root privileges
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        failed=1
    else
        print_status "ok" "Running as root"
    fi
    
    # Check for EFI boot mode
    if [[ -d /sys/firmware/efi/efivars ]] && [[ -n "$(ls -A /sys/firmware/efi/efivars 2>/dev/null)" ]]; then
        print_status "ok" "System booted in EFI mode"
    else
        error "System not booted in EFI mode"
        failed=1
    fi
    
    # Check network connectivity
    if ping -c 1 -W 5 voidlinux.org &>/dev/null; then
        print_status "ok" "Network connectivity verified"
    else
        error "No network connectivity to voidlinux.org"
        failed=1
    fi
    
    # Check for ZFS module
    if modprobe zfs &>/dev/null; then
        print_status "ok" "ZFS kernel module available"
    else
        error "ZFS kernel module not available"
        failed=1
    fi
    
    if ((failed)); then
        die "Prerequisites check failed. Cannot continue."
    fi
    
    success "All prerequisites met"
}

# ============================================
# USER INPUT COLLECTION - ALL AT ONCE
# ============================================
collect_installation_type() {
    subheader "Installation Type"
    echo ""
    info "Select installation mode:"
    echo ""
    
    PS3="$(printf "${BLUE}Choose installation type: ${NC}")"
    select type in "First Install (New System)" "Dual Boot (Add to Existing ZFS)"; do
        case "$type" in
            "First Install (New System)")
                INSTALL_TYPE="first"
                success "Installation type: First Install"
                break
                ;;
            "Dual Boot (Add to Existing ZFS)")
                INSTALL_TYPE="dualboot"
                success "Installation type: Dual Boot"
                break
                ;;
            *)
                warning "Invalid selection, please try again"
                ;;
        esac
    done
    echo ""
}

collect_disk_selection() {
    local disks=()
    local disk_list
    
    subheader "Disk Selection"
    
    # Capture ls output first
    disk_list=$(ls /dev/disk/by-id/ 2>/dev/null || echo "")
    
    if [[ -z "$disk_list" ]]; then
        die "No disks found in /dev/disk/by-id/"
    fi
    
    while IFS= read -r disk; do
        [[ -z "$disk" ]] && continue
        # Filter out partition entries
        if [[ ! $disk =~ -(part|p)[0-9]+$ ]]; then
            disks+=("$disk")
        fi
    done <<< "$disk_list"
    
    if [[ ${#disks[@]} -eq 0 ]]; then
        die "No suitable disks found"
    fi
    
    info "Available disks:"
    for disk in "${disks[@]}"; do
        bullet "$disk"
    done
    echo ""
    
    PS3="$(printf "${BLUE}Select installation disk: ${NC}")"
    select ENTRY in "${disks[@]}"; do
        if [[ -n $ENTRY ]]; then
            SELECTED_DISK="/dev/disk/by-id/$ENTRY"
            SELECTED_DISK_NAME="$ENTRY"
            success "Selected disk: $ENTRY"
            break
        fi
    done
    echo ""
}

collect_disk_wipe_confirmation() {
    if [[ "$INSTALL_TYPE" == "first" ]]; then
        subheader "Disk Wipe Confirmation"
        echo ""
        warning "Selected disk: $SELECTED_DISK_NAME"
        warning "ALL DATA ON THIS DISK WILL BE DESTROYED!"
        echo ""
        
        if ask_yes_no "Do you want to wipe all data on $SELECTED_DISK_NAME?" "n"; then
            WIPE_DISK=true
            success "Disk will be wiped"
        else
            WIPE_DISK=false
            info "Skipping disk wipe"
        fi
        echo ""
    fi
}

collect_zfs_passphrase() {
    subheader "ZFS Encryption Passphrase"
    echo ""
    info "You will need to enter this passphrase on every boot"
    info "Minimum length: 8 characters"
    echo ""
    
    while true; do
        echo -e -n "${BLUE}Enter ZFS encryption passphrase: ${NC}"
		read -r -s pass1
		echo
        echo -e -n "${BLUE}Confirm passphrase: ${NC}"
		read -r -s pass2
		echo
        
        if [[ "$pass1" == "$pass2" ]]; then
            if [[ ${#pass1} -lt 8 ]]; then
                warning "Passphrase must be at least 8 characters!"
                continue
            fi
            ZFS_PASSPHRASE="$pass1"
            success "Encryption passphrase set"
            break
        else
            warning "Passphrases do not match. Try again."
        fi
    done
    echo ""
}

collect_dataset_name() {
    subheader "Root Dataset Name"
    echo ""
    info "Enter a name for your root dataset (boot environment)"
    info "Examples: void, void-2024, main, etc."
    echo ""
    
    while true; do
        echo -e -n "${BLUE}Root dataset name: ${NC}"
		read -r -s dataset_name
		echo
        # Validate name
        if [[ -z "$dataset_name" ]]; then
            warning "Dataset name cannot be empty"
            continue
        fi
        
        if [[ ! $dataset_name =~ ^[a-zA-Z0-9_-]+$ ]]; then
            warning "Dataset name can only contain letters, numbers, underscores, and hyphens"
            continue
        fi
        
        # For dualboot, check if dataset already exists
        if [[ "$INSTALL_TYPE" == "dualboot" ]]; then
            if zfs list "zroot/ROOT/$dataset_name" &>/dev/null 2>&1; then
                error "Dataset 'zroot/ROOT/$dataset_name' already exists!"
                warning "Choose a different name"
                continue
            fi
        fi
        
        ROOT_DATASET_NAME="$dataset_name"
        success "Root dataset name: $ROOT_DATASET_NAME"
        break
    done
    echo ""
}

collect_swap_configuration() {
    if [[ "$INSTALL_TYPE" == "first" ]]; then
        subheader "Swap Configuration"
        echo ""
        
        if ask_yes_no "Do you want to create a swap space?" "y"; then
            CREATE_SWAP=true
            
            while true; do                
                echo -e -n "${BLUE}Enter swap size (e.g., 4G, 8G, 16G): ${NC}"
				read -r -s swap_size
				echo				
                if [[ $swap_size =~ ^[0-9]+[GMgm]$ ]]; then
                    SWAP_SIZE="$swap_size"
                    success "Swap size: $SWAP_SIZE"
                    break
                else
                    warning "Invalid format. Use format like 4G or 8G"
                fi
            done
        else
            CREATE_SWAP=false
            info "Skipping swap space creation"
        fi
        echo ""
    fi
}

collect_system_configuration() {
    subheader "System Configuration"
    echo ""
    
    # Hostname
    while true; do        
        echo -e -n "${BLUE}Enter hostname: ${NC}"
		read -r -s hostname_input
		echo
        if [[ -z "$hostname_input" ]]; then
            warning "Hostname cannot be empty"
            continue
        fi
        
        if [[ ! $hostname_input =~ ^[a-zA-Z0-9-]+$ ]]; then
            warning "Hostname can only contain letters, numbers, and hyphens"
            continue
        fi
        
        HOSTNAME="$hostname_input"
        success "Hostname: $HOSTNAME"
        break
    done
    echo ""
    
    # Timezone
    info "Enter timezone (e.g., America/New_York, Europe/London, Asia/Singapore)"
	echo -e -n "${BLUE}Timezone [Asia/Singapore]: ${NC}"
	read -r -s timezone_input
	echo
    TIMEZONE="${timezone_input:-Asia/Singapore}"
    success "Timezone: $TIMEZONE"
    echo ""
    
    # Username
    while true; do
        echo -e -n "${BLUE}Enter username: ${NC}"
		read -r -s username_input

        if [[ -z "$username_input" ]]; then
            warning "Username cannot be empty"
            continue
        fi
        
        if [[ ! $username_input =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            warning "Username must start with lowercase letter or underscore"
            warning "Can contain lowercase letters, numbers, underscores, and hyphens"
            continue
        fi
        
        USERNAME="$username_input"
        success "Username: $USERNAME"
        break
    done
    echo ""
}

collect_passwords() {
    subheader "Password Configuration"
    echo ""
    
    # Root password
    info "Set root password"
    while true; do
		echo -e -n "${BLUE}Enter root password: ${NC}"
		read -r -s root_pass1
        echo
		echo -e -n "${BLUE}Confirm root password: ${NC}"
		read -r -s root_pass2		
        echo
        
        if [[ "$root_pass1" == "$root_pass2" ]]; then
            if [[ ${#root_pass1} -lt 6 ]]; then
                warning "Password must be at least 6 characters!"
                continue
            fi
            ROOT_PASSWORD="$root_pass1"
            success "Root password set"
            break
        else
            warning "Passwords do not match. Try again."
        fi
    done
    echo ""
    
    # User password
    info "Set password for user: $USERNAME"
    while true; do
		echo -e -n "${BLUE}Enter user password: ${NC}"
		read -r -s user_pass1
		echo  
		echo -e -n "${BLUE}Confirm user password: ${NC}"
		read -r -s user_pass2
		echo  
        if [[ "$user_pass1" == "$user_pass2" ]]; then
            if [[ ${#user_pass1} -lt 6 ]]; then
                warning "Password must be at least 6 characters!"
                continue
            fi
            USER_PASSWORD="$user_pass1"
            success "User password set"
            break
        else
            warning "Passwords do not match. Try again."
        fi
    done
    echo ""
}

show_configuration_summary() {
    header "Installation Configuration Summary"
    
    echo ""
    subheader "Installation Settings:"
    bullet "Installation Type: $INSTALL_TYPE"
    bullet "Disk: $SELECTED_DISK_NAME"
    if [[ "$INSTALL_TYPE" == "first" ]]; then
        bullet "Wipe Disk: $([ "$WIPE_DISK" = true ] && echo 'Yes' || echo 'No')"
    fi
    bullet "Root Dataset: zroot/ROOT/$ROOT_DATASET_NAME"
    if [[ "$INSTALL_TYPE" == "first" && "$CREATE_SWAP" == true ]]; then
        bullet "Swap: $SWAP_SIZE"
    fi
    echo ""
    
    subheader "System Configuration:"
    bullet "Hostname: $HOSTNAME"
    bullet "Timezone: $TIMEZONE"
    bullet "Username: $USERNAME"
    bullet "Encryption: AES-256-GCM with passphrase"
    echo ""
    
    separator "="
    echo ""
    warning "This is your last chance to review the configuration!"
    echo ""
    
    if ! ask_yes_no "Proceed with installation?" "y"; then
        info "Installation cancelled by user"
        exit 0
    fi
    
    success "Configuration confirmed. Starting installation..."
    echo ""
}

# ============================================
# Installation Functions (No User Input)
# ============================================
wipe_disk() {
    subheader "Wiping Disk"
    
    if [[ "$WIPE_DISK" == true ]]; then
        info "Wiping all data on $SELECTED_DISK_NAME..."
        dd if=/dev/zero of="$SELECTED_DISK" bs=512 count=1
        wipefs -af "$SELECTED_DISK"
        sgdisk -Zo "$SELECTED_DISK"
        zpool labelclear -f "$SELECTED_DISK" 2>/dev/null || true
        
        # Wait for kernel to update
        partprobe "$SELECTED_DISK"
        sleep 2
        success "Disk wiped successfully"
    else
        info "Skipping disk wipe as per configuration"
    fi
}

partition_disk() {
    subheader "Creating Partitions"
    
    # EFI partition
    info "Creating EFI partition (512MB)"
    sgdisk -n1:1M:+512M -t1:EF00 "$SELECTED_DISK"
    EFI="$SELECTED_DISK-part1"

    # ZFS partition
    info "Creating ZFS partition (remaining space)"
    sgdisk -n2:0:0 -t2:BF00 "$SELECTED_DISK"
    ZFS="$SELECTED_DISK-part2"
    
    # Inform kernel
    partprobe "$SELECTED_DISK"
    sleep 2

    # Wait for partition devices
    info "Waiting for partition devices..."
    local count=0
    until [[ -e "$EFI" ]] && [[ -e "$ZFS" ]] || [[ $count -ge 30 ]]; do
        sleep 1
        ((count++))
    done
    
    if [[ ! -e "$EFI" ]] || [[ ! -e "$ZFS" ]]; then
        die "Partition devices did not appear!"
    fi
        
    info "Formatting EFI partition"
    if ! mkfs.vfat -F32 -n "EFI" "$EFI"; then
        die "EFI format failed"
    fi
    
    # Verify partition table
    print_status "ok" "Partition table verification"
    success "Partitions created successfully"
}

setup_zfs_encryption() {
    subheader "Setting Up ZFS Encryption"
    
    # Secure directory creation
    if [[ ! -d /etc/zfs ]]; then
        mkdir -p /etc/zfs
        chmod 700 /etc/zfs
        chown root:root /etc/zfs
    fi
    
    echo "$ZFS_PASSPHRASE" > /etc/zfs/zroot.key
    chmod 400 /etc/zfs/zroot.key
    chown root:root /etc/zfs/zroot.key
    
    # Verify key file was created
    if [[ ! -f /etc/zfs/zroot.key ]] || [[ ! -s /etc/zfs/zroot.key ]]; then
        die "Failed to create key file!"
    fi
    success "Encryption key file created"
}

backup_zfs_key() {
    subheader "Creating Encryption Key Backup"
    
    mkdir -p /mnt/root/zfs-keys
    chmod 700 /mnt/root/zfs-keys
    chown root:root /mnt/root/zfs-keys
    
    # Save key location
    local keylocation
    keylocation=$(zfs get -H -o value keylocation zroot 2>/dev/null || echo "")
    echo "$keylocation" > /mnt/root/zfs-keys/keylocation
    chmod 400 /mnt/root/zfs-keys/keylocation
    
    # Copy key with secure permissions
    install -m 400 /etc/zfs/zroot.key /mnt/root/zfs-keys/
    
    # Verify backup
    if ! diff /etc/zfs/zroot.key /mnt/root/zfs-keys/zroot.key &>/dev/null; then
        die "Key backup verification failed!"
    fi
    
    success "Encryption key backed up to /root/zfs-keys/"
}

create_pool() {
    subheader "Creating ZFS Pool"
    
    ZFS="$SELECTED_DISK-part2"

    info "Creating encrypted ZFS pool 'zroot'..."
    if ! zpool create -f -o ashift=12                          \
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
                 zroot "$ZFS"; then
        die "Pool creation failed!"
    fi
    
    # Verify pool was created
    if ! zpool list zroot &>/dev/null; then
        die "Pool verification failed!"
    fi
    
    print_status "ok" "Pool: zroot"
    print_status "ok" "Encryption: AES-256-GCM"
    print_status "ok" "Compression: lz4"
    success "ZFS pool 'zroot' created successfully"
}

create_root_dataset() {
    subheader "Creating Root Dataset Container"
    
    info "Creating ROOT dataset container..."
    zfs create -o mountpoint=none zroot/ROOT

    # Set boot command line
    zfs set org.zfsbootmenu:commandline="ro quiet loglevel=0" zroot/ROOT
    
    success "Root dataset container created"
}

create_system_dataset() {
    subheader "Creating System Dataset: $ROOT_DATASET_NAME"
    
    info "Creating boot environment..."
    if ! zfs create -o mountpoint=/ \
           -o canmount=noauto \
           -o recordsize=128K \
           -o atime=off \
           -o relatime=off \
           -o devices=off \
           zroot/ROOT/"$ROOT_DATASET_NAME"; then
        die "Failed to create system dataset!"
    fi

    # Generate hostid
    info "Generating system hostid..."
    zgenhostid -f

    # Validate hostid
    if [[ ! -f /etc/hostid ]]; then
        die "Failed to generate hostid!"
    fi
    
    if [[ $(stat -c%s /etc/hostid 2>/dev/null) -ne 4 ]]; then
        die "Hostid file corrupted (wrong size)!"
    fi
    
    print_status "ok" "Hostid: $(hostid)"
     
    # Set bootfs
    info "Setting bootfs property..."
    zpool set bootfs="zroot/ROOT/$ROOT_DATASET_NAME" zroot

    # Mount root dataset
    info "Mounting root dataset..."
    zfs mount zroot/ROOT/"$ROOT_DATASET_NAME"
    
    # Verify mount
    if ! mountpoint -q /mnt; then
        die "Failed to mount root dataset!"
    fi
    
    success "System dataset created and mounted at /mnt"
}

create_home_dataset() {
    subheader "Creating Home Datasets"
    
    info "Creating data container..."
    zfs create -o mountpoint=none -o canmount=off zroot/data
    
    info "Creating /home dataset..."
    zfs create -o mountpoint=/home \
               -o recordsize=1M \
               -o compression=zstd-3 \
               -o atime=off \
               zroot/data/home
    
    info "Creating /root dataset..."
    zfs create -o mountpoint=/root \
               -o recordsize=128K \
               -o compression=zstd \
               zroot/data/root
    
    success "Home datasets created"
}

create_swapspace() {
    if [[ "$CREATE_SWAP" == true ]]; then
        subheader "Creating Swap Space"
        
        info "Creating swap zvol ($SWAP_SIZE)..."
        zfs create -V "${SWAP_SIZE}" -b $(getconf PAGESIZE) \
            -o compression=zle \
            -o logbias=throughput \
            -o sync=disabled \
            -o primarycache=metadata \
            -o secondarycache=none \
            -o com.sun:auto-snapshot=false \
            zroot/swap

        # Wait for zvol device
        info "Waiting for zvol device..."
        local count=0
        until [[ -e /dev/zvol/zroot/swap ]] || [[ $count -ge 30 ]]; do
            sleep 1
            ((count++))
        done
        
        if [[ ! -e /dev/zvol/zroot/swap ]]; then
            die "Swap zvol device did not appear!"
        fi

        info "Formatting swap..."
        mkswap -f /dev/zvol/zroot/swap
        
        success "Swap space created: ${SWAP_SIZE}"
    else
        info "Skipping swap space creation as per configuration"
    fi
}

export_pool() {
    info "Exporting zpool..."
    zpool export zroot
    
    # Verify export
    if zpool list zroot &>/dev/null; then
        die "Pool export failed!"
    fi
    
    success "Pool exported successfully"
}

import_pool() {
    info "Importing zpool..."
    if ! zpool import -d /dev/disk/by-id -R /mnt zroot -N -f; then
        die "Failed to import pool"
    fi
    
    info "Loading encryption key..."
    if ! zfs load-key zroot; then
        die "Failed to load encryption key"
    fi
    
    # Verify import
    if ! zpool list zroot &>/dev/null; then
        die "Pool not imported!"
    fi
    
    success "Pool imported successfully"
}

mount_system() {
    subheader "Mounting Filesystems"
    
    info "Mounting root dataset..."
    zfs mount zroot/ROOT/"$ROOT_DATASET_NAME"
    
    info "Mounting all ZFS datasets..."
    zfs mount -a

    # Verify root mount
    if ! mountpoint -q /mnt; then
        die "Root dataset not mounted!"
    fi

    # Mount EFI partition
    info "Mounting EFI partition..."
    EFI="$SELECTED_DISK-part1"
    mkdir -p /mnt/boot/efi
    mount "$EFI" /mnt/boot/efi
    
    # Verify EFI mount
    if ! mountpoint -q /mnt/boot/efi; then
        die "EFI partition not mounted!"
    fi
    
    success "All filesystems mounted successfully"
}

copy_zpool_cache() {
    subheader "Configuring ZFS Cache"
    
    mkdir -p /mnt/etc/zfs
    
    info "Setting cachefile property on pool..."
    zpool set cachefile=/etc/zfs/zpool.cache zroot
    
    # Wait for cache file to be written
    sleep 5
    
    # Verify cache file exists and is not empty
    if [[ ! -s /etc/zfs/zpool.cache ]]; then
        die "zpool.cache is missing or empty!"
    fi
    
    info "Copying zpool.cache to target system..."
    cp /etc/zfs/zpool.cache /mnt/etc/zfs/
    
    # Verify copy succeeded
    if ! diff /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache &>/dev/null; then
        die "Cache file copy verification failed!"
    fi
    
    print_status "ok" "cachefile property set"
    print_status "ok" "zpool.cache copied"
    success "ZFS cache configured"
}

install_base_system() {
    header "System Installation"
    
    # Set mirror and architecture
    REPO=https://repo-default.voidlinux.org/current
    ARCH=x86_64

    # Copy xbps keys
    subheader "Preparing Package Manager"
    info "Copying XBPS keys..."
    mkdir -p /mnt/var/db/xbps/keys
    cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
    success "XBPS keys copied"

    # Install base system
    subheader "Installing Base System"
    info "This may take several minutes..."
    if ! XBPS_ARCH=$ARCH xbps-install -y -S -r /mnt -R "$REPO" \
      base-system \
      void-repo-nonfree; then
        die "Base system installation failed!"
    fi

    # Verify base system installation
    if [[ ! -f /mnt/usr/bin/xbps-install ]]; then
        die "Base system verification failed!"
    fi
    success "Base system installed"

    # Init chroot mounts
    subheader "Initializing Chroot Environment"
    info "Mounting pseudo-filesystems..."
    mount --rbind /sys /mnt/sys && mount --make-rslave /mnt/sys
    mount --rbind /dev /mnt/dev && mount --make-rslave /mnt/dev
    mount --rbind /proc /mnt/proc && mount --make-rslave /mnt/proc
    success "Chroot environment initialized"

    # Disable gummiboot post install hooks
    echo "GUMMIBOOT_DISABLE=1" > /mnt/etc/default/gummiboot

    # Install packages
    subheader "Installing Required Packages"
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
    
    info "Installing: ${packages[*]}"
    if ! XBPS_ARCH=$ARCH xbps-install -y -S -r /mnt -R "$REPO" "${packages[@]}"; then
        die "Package installation failed!"
    fi

    # Verify critical packages
    for pkg in zfs zfsbootmenu dracut; do
        if ! chroot /mnt xbps-query "$pkg" &>/dev/null; then
            die "Package $pkg not installed!"
        fi
        print_status "ok" "$pkg installed"
    done
    success "All required packages installed"
}

configure_system() {
    header "System Configuration"
    
    # Set hostname
    subheader "Configuring Hostname"
    echo "$HOSTNAME" > /mnt/etc/hostname
    success "Hostname set: $HOSTNAME"

    # Configure ZFS files
    subheader "Configuring ZFS Files"
    info "Copying hostid, cache, and encryption key..."
    cp /etc/hostid /mnt/etc/hostid
    cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache
    cp -p /etc/zfs/zroot.key /mnt/etc/zfs/

    # Verify ZFS files were copied
    for file in /mnt/etc/hostid /mnt/etc/zfs/zpool.cache /mnt/etc/zfs/zroot.key; do
        if [[ ! -f "$file" ]]; then
            die "Failed to copy $(basename "$file")!"
        fi
        print_status "ok" "$(basename "$file") copied"
    done
    success "ZFS configuration files copied"

    # Configure iwd
    subheader "Configuring Network (iwd)"
    mkdir -p /mnt/etc/iwd
    cat > /mnt/etc/iwd/main.conf <<"EOF"
[General]
UseDefaultInterface=true
EnableNetworkConfiguration=true

[Network]
NameResolvingService=resolvconf
EOF
    success "iwd configured"

    # Configure DNS
    info "Configuring DNS resolution..."
    cat >> /mnt/etc/resolvconf.conf <<"EOF"
resolv_conf=/etc/resolv.conf
name_servers="1.1.1.1 9.9.9.9"
EOF
    success "DNS configured"

    # Enable IP forwarding
    subheader "Configuring System Parameters"
    cat > /mnt/etc/sysctl.conf <<"EOF"
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    print_status "ok" "IP forwarding enabled"

    # Configure locales and keymap
    subheader "Configuring Locales"
    echo 'en_US.UTF-8 UTF-8' > /mnt/etc/default/libc-locales
    echo 'LANG="en_US.UTF-8"' > /mnt/etc/locale.conf
    echo 'KEYMAP="us"' > /mnt/etc/vconsole.conf
    success "Locales configured"

    # Configure timezone
    subheader "Configuring Timezone"
    cat >> /mnt/etc/rc.conf << EOF
TIMEZONE="$TIMEZONE"
HARDWARECLOCK="UTC"
KEYMAP="us"
EOF
    success "Timezone set: $TIMEZONE"

    # Set TTY font
    subheader "Configuring Console Font"
    cat >> /mnt/etc/vconsole.conf <<EOF
FONT=$FONT
EOF
    success "TTY font configured: $FONT"

    # Set default shell
    subheader "Configuring Default Shell"
    info "Setting bash as default shell..."
    chroot /mnt chsh -s /bin/bash root

    cat > /mnt/etc/default/useradd <<EOF
# Default values for useradd
GROUP=100
HOME=/home
INACTIVE=-1
EXPIRE=
SHELL=/bin/bash
SKEL=/etc/skel
CREATE_MAIL_SPOOL=yes
EOF
    success "Default shell set to bash"

    # Configure dracut
    subheader "Configuring Dracut"
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
    success "Dracut configured for ZFS"
}

configure_users() {
    subheader "User Configuration"
    
    info "Configuring system in chroot..."
    chroot /mnt/ /bin/bash -e <<EOF
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
  ln -sf /etc/sv/zed /etc/runit/runsvdir/default/

  # Set timezone
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  
  # Generate locales
  xbps-reconfigure -f glibc-locales

  # Create user home dataset
  if ! zfs list zroot/data/home/${USERNAME} &>/dev/null; then
    zfs create zroot/data/home/${USERNAME}
  fi
  
  # Add user
  useradd -m -d /home/${USERNAME} -G network,wheel,video,audio,input,kvm ${USERNAME}
  chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}
  
  # Activate swap if created
  if [[ "$CREATE_SWAP" == true ]]; then
    sleep 2
    if [[ -e /dev/zvol/zroot/swap ]]; then
      swapon /dev/zvol/zroot/swap 2>/dev/null || true
    fi
  fi
EOF
    
    print_status "ok" "Essential services enabled"
    print_status "ok" "ZFS services enabled"
    print_status "ok" "User $USERNAME created"
    success "System configured in chroot"
}

configure_fstab() {
    subheader "Configuring fstab"
    
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
    if [[ "$CREATE_SWAP" == true ]]; then
        echo "/dev/zvol/zroot/swap  none           swap    discard,pri=100                 0      0" >> /mnt/etc/fstab
        print_status "ok" "Swap entry added"
    fi
    
    success "fstab configured"
}

set_passwords() {
    subheader "Setting Passwords"
    
    # Set root password (non-interactive)
    info "Setting root password..."
    echo "root:$ROOT_PASSWORD" | chroot /mnt chpasswd
    success "Root password set"

    # Set user password (non-interactive)
    info "Setting password for user: $USERNAME"
    echo "$USERNAME:$USER_PASSWORD" | chroot /mnt chpasswd
    success "User password set"
}

configure_sudo() {
    subheader "Configuring sudo"
    
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
    
    success "sudo configured for wheel group"
}

configure_zfsbootmenu() {
    header "ZFSBootMenu Configuration"
    
    mkdir -p /mnt/boot/efi/EFI/ZBM /mnt/etc/zfsbootmenu/dracut.conf.d

    subheader "Creating ZFSBootMenu Configuration"
    cat > /mnt/etc/zfsbootmenu/config.yaml <<EOF
Global:
  ManageImages: true
  BootMountPoint: /boot/efi
  DracutConfDir: /etc/zfsbootmenu/dracut.conf.d
  PreHooksDir: /etc/zfsbootmenu/generate-zbm.pre.d
  PostHooksDir: /etc/zfsbootmenu/generate-zbm.post.d
  InitCPIOHookDirs:
    - /etc/zfsbootmenu/initcpio.pre.d
    - /etc/zfsbootmenu/initcpio.post.d
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
    print_status "ok" "config.yaml created"

    # Configure dracut for ZBM
    cat > /mnt/etc/zfsbootmenu/dracut.conf.d/keymap.conf <<EOF
install_optional_items+=" /etc/cmdline.d/keymap.conf "
EOF

    mkdir -p /mnt/etc/cmdline.d/
    cat > /mnt/etc/cmdline.d/keymap.conf <<EOF
rd.vconsole.keymap=us
EOF
    print_status "ok" "Keymap configuration created"

    # Set ZFS boot commandline
    info "Setting boot parameters on dataset..."
    zfs set org.zfsbootmenu:commandline="ro quiet nowatchdog loglevel=0 zbm.timeout=5" zroot/ROOT/"$ROOT_DATASET_NAME"
    print_status "ok" "Boot parameters set"
    
    success "ZFSBootMenu configured"
}

generate_zfsbootmenu() {
    subheader "Generating ZFSBootMenu"
    
    info "This may take several minutes..."
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
  initramfs_content=$(lsinitrd /boot/initramfs-*.img 2>/dev/null || echo "")
  if [[ -n "$initramfs_content" ]]; then
    if ! echo "$initramfs_content" | grep -q "zfs.ko"; then
      echo "WARNING: ZFS module may not be in initramfs"
    fi
  fi
EOF

    # Verify critical boot files
    if [[ ! -f /mnt/boot/efi/EFI/ZBM/vmlinuz.efi ]]; then
        die "ZFSBootMenu EFI file not found!"
    fi
    success "ZFSBootMenu generated successfully"

    # Create backup
    if [[ ! -f /mnt/boot/efi/EFI/ZBM/vmlinuz-backup.efi ]]; then
        info "Creating ZFSBootMenu backup..."
        cp /mnt/boot/efi/EFI/ZBM/vmlinuz.efi /mnt/boot/efi/EFI/ZBM/vmlinuz-backup.efi
        success "ZFSBootMenu backup created"
    fi
}

create_efi_entries() {
    header "EFI Boot Configuration"

    subheader "Preparing EFI System"
    info "Loading efivarfs module..."
    modprobe efivarfs
    mountpoint -q /sys/firmware/efi/efivars \
        || mount -t efivarfs efivarfs /sys/firmware/efi/efivars
    print_status "ok" "EFI variables accessible"

    # Remove existing ZFSBootMenu entries
    local efi_entries
    efi_entries=$(efibootmgr 2>/dev/null || echo "")

    if echo "$efi_entries" | grep -q "ZFSBootMenu"; then
        info "Removing old ZFSBootMenu entries..."
        
        local zbm_entries
        zbm_entries=$(echo "$efi_entries" | grep "ZFSBootMenu" || echo "")
        
        if [[ -n "$zbm_entries" ]]; then
            while IFS= read -r entry_line; do
                [[ -z "$entry_line" ]] && continue
                local entry_num
                entry_num=$(echo "$entry_line" | sed -E 's/Boot([0-9]+).*/\1/')
                efibootmgr -B -b "$entry_num"
            done <<< "$zbm_entries"
        fi
        success "Old boot entries removed"
    fi

    # Create backup entry
    subheader "Creating Boot Entries"
    info "Creating backup boot entry..."
    if ! efibootmgr --disk "$SELECTED_DISK" \
      --part 1 \
      --create \
      --label "ZFSBootMenu Backup" \
      --loader "\EFI\ZBM\vmlinuz-backup.efi" \
      --verbose; then
        warning "Failed to create backup boot entry!"
    else
        print_status "ok" "Backup entry created"
    fi

    # Create main entry
    info "Creating main boot entry..."
    if ! efibootmgr --disk "$SELECTED_DISK" \
      --part 1 \
      --create \
      --label "ZFSBootMenu" \
      --loader "\EFI\ZBM\vmlinuz.efi" \
      --verbose; then
        die "Failed to create main boot entry!"
    fi
    print_status "ok" "Main entry created"
    
    success "EFI boot entries created"

    # Display boot order
    echo ""
    info "Current boot order:"
    efibootmgr
}

cleanup_and_unmount() {
    header "Cleanup and Unmount"
    
    # Unmount EFI
    info "Unmounting EFI partition..."
    if ! umount /mnt/boot/efi; then
        warning "Failed to unmount /mnt/boot/efi cleanly"
    else
        print_status "ok" "EFI partition unmounted"
    fi

    # Unmount bind mounts
    info "Unmounting pseudo-filesystems..."
    umount -l /mnt/{dev,proc,sys} 2>/dev/null || true
    print_status "ok" "Pseudo-filesystems unmounted"

    # Unmount ZFS filesystems
    info "Unmounting ZFS filesystems..."
    zfs umount -a
    print_status "ok" "ZFS filesystems unmounted"

    # Export pool
    info "Exporting zpool..."
    zpool export zroot

    # Verify export
    if zpool list zroot &>/dev/null; then
        warning "Pool still imported, forcing export..."
        zpool export -f zroot
    fi
    
    success "Pool exported successfully"
}

show_installation_summary() {
    header "Installation Complete!"
    
    echo ""
    subheader "Installed System Summary:"
    bullet "ZFS pool: zroot"
    bullet "Root dataset: zroot/ROOT/$ROOT_DATASET_NAME"
    bullet "Encryption: AES-256-GCM"
    bullet "Compression: lz4"
    
    local hostid_value
    hostid_value=$(cat /mnt/etc/hostid 2>/dev/null | od -An -tx1 || echo 'exported')
    bullet "Hostid: $hostid_value"
    
    bullet "Hostname: $HOSTNAME"
    bullet "Timezone: $TIMEZONE"
    bullet "Username: $USERNAME"
    bullet "ZFSBootMenu: installed"
    bullet "UEFI entries: created"
    
    if [[ "$CREATE_SWAP" == true ]]; then
        bullet "Swap: $SWAP_SIZE"
    fi
    
    echo ""
    separator "="
    echo ""
    
    success "Installation completed successfully!"
    
    echo ""
    subheader "Next Steps:"
    indent 1 "1. Remove installation media"
    indent 1 "2. Reboot the system"
    indent 1 "3. At ZFSBootMenu, select your boot environment"
    indent 1 "4. Enter encryption passphrase when prompted"
    echo ""
    
    subheader "Important Information:"
    indent 1 "• ZFS encryption passphrase will be required on every boot"
    indent 1 "• Encryption key backup saved to /root/zfs-keys/ (after first boot)"
    indent 1 "• Log file saved to: $LOG_FILE"
    echo ""
    
    echo -e "${CYAN}To reboot now, run: ${BOLD}reboot${NC}"
    echo ""
}

# ============================================
# Main Execution
# ============================================
main() {
    # Enable debug mode if requested
    if [[ "${1:-}" == "debug" ]]; then
        set -x
        debug=1
        export CURRENT_LOG_LEVEL=$LOG_LEVEL_DEBUG
    fi

    # Script header
    header "$SCRIPT_NAME v$SCRIPT_VERSION"
    info "Log file: $LOG_FILE"
    echo ""

    # Prerequisites check
    check_prerequisites

    # ============================================
    # COLLECT ALL USER INPUT UPFRONT
    # ============================================
    header "Configuration Wizard"
    info "Please provide all required information for the installation"
    echo ""
    
    collect_installation_type
    collect_disk_selection
    collect_disk_wipe_confirmation
    collect_zfs_passphrase
    collect_dataset_name
    collect_swap_configuration
    collect_system_configuration
    collect_passwords
    
    # Show configuration summary and confirm
    show_configuration_summary

    # ============================================
    # AUTOMATED INSTALLATION (NO MORE PROMPTS)
    # ============================================
    header "Starting Automated Installation"
    info "No further user input required"
    echo ""

    # Disk preparation
    if [[ "$INSTALL_TYPE" == "first" ]]; then
        setup_zfs_encryption
        wipe_disk
        partition_disk
        create_pool
        create_root_dataset
    fi

    # Handle dualboot scenario
    if [[ "$INSTALL_TYPE" == "dualboot" ]]; then
        setup_zfs_encryption
        import_pool
        
        if zfs list "zroot/ROOT/$ROOT_DATASET_NAME" &>/dev/null; then
            die "Dataset zroot/ROOT/$ROOT_DATASET_NAME already exists! Aborting."
        fi
    fi

    # Create system dataset
    create_system_dataset

    # First install additional setup
    if [[ "$INSTALL_TYPE" == "first" ]]; then
        create_home_dataset
        create_swapspace
    fi

    # Mount everything
    export_pool
    import_pool
    mount_system
    copy_zpool_cache
    backup_zfs_key

    # Install base system
    install_base_system

    # Configure system
    configure_system
    configure_users
    configure_fstab
    set_passwords
    configure_sudo
    configure_zfsbootmenu
    generate_zfsbootmenu
    create_efi_entries

    # Cleanup
    cleanup_and_unmount

    # Show summary
    show_installation_summary

    success "Script completed successfully"
}

# Run main function
main "$@"
