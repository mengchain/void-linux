#!/usr/bin/env bash
# filepath: voidZFSInstallRepo.sh

export TERM=xterm
 
set -euo pipefail

exec &> >(tee "configureNinstall.log")

# Colors for output - Consistent with other scripts
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[1;94m'      # Light Blue (bright blue)
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "configureNinstall.log"
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

print() {
    echo -e "\n${BOLD}${CYAN}> $1${NC}\n"
    if [[ -n "${debug:-}" ]]; then
        read -rp "press enter to continue"
    fi
}

ask() {
    read -p "${BLUE}> $1 ${NC}" -r
    echo
}

menu() {
    PS3="${BLUE}> Choose a number: ${NC}"
    select i in "$@"; do
        echo "$i"
        break
    done
}

# Validation Functions
check_prerequisites() {
    local failed=0
    
    # Check for root privileges
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        failed=1
    fi
    
    # Check for EFI boot mode - FIXED SIGPIPE
    local efi_check
    efi_check=$(ls /sys/firmware/efi/efivars 2>/dev/null || echo "")
    if [[ -z "$efi_check" ]]; then
        error "System not booted in EFI mode"
        failed=1
    fi
    
    # Check network connectivity
    if ! ping -c 1 voidlinux.org &>/dev/null; then
        error "No network connectivity to voidlinux.org"
        failed=1
    fi
    
    # Check for ZFS module
    if ! modprobe zfs &>/dev/null; then
        error "ZFS kernel module not available"
        failed=1
    fi
    
    if ((failed)); then
        exit 1
    fi
    
    success "Prerequisites check passed"
}

select_disk() {
    local disks=()
    local disk_list
    
    # FIXED SIGPIPE: Capture ls output first
    disk_list=$(ls /dev/disk/by-id/ 2>/dev/null || echo "")
    
    while IFS= read -r disk; do
        [[ -z "$disk" ]] && continue
        # Filter out partition entries
        if [[ ! $disk =~ -(part|p)[0-9]+$ ]]; then
            disks+=("$disk")
        fi
    done <<< "$disk_list"
    
    if [[ ${#disks[@]} -eq 0 ]]; then
        error "No suitable disks found"
        exit 1
    fi
    
    PS3="${BLUE}Select installation disk: ${NC}"
    select ENTRY in "${disks[@]}"; do
        if [[ -n $ENTRY ]]; then
            DISK="/dev/disk/by-id/$ENTRY"
            echo "$DISK" > /tmp/disk
            success "Installing on $ENTRY"
            break
        fi
    done
}

wipe() {
    ask "Do you want to wipe all datas on $ENTRY ?"
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Clear disk
        print "Wiping disk..."
        dd if=/dev/zero of="$DISK" bs=512 count=1
        wipefs -af "$DISK"
        sgdisk -Zo "$DISK"
        zpool labelclear -f "$DISK" 2>/dev/null || true
        
        # Wait for kernel to update
        partprobe "$DISK"
        sleep 2
        success "Disk wiped successfully"
    fi
}

partition() {
    # EFI part
    print "Creating EFI partition"
    sgdisk -n1:1M:+512M -t1:EF00 "$DISK"
    EFI="$DISK-part1"

    # ZFS part
    print "Creating ZFS partition"
    sgdisk -n2:0:0 -t2:BF00 "$DISK"
    ZFS="$DISK-part2"
    
    # Inform kernel
    partprobe "$DISK"
    sleep 2

    # Wait for partition devices
    until [ -e "$EFI" ]; do sleep 1; done
    until [ -e "$ZFS" ]; do sleep 1; done
        
    print "Formatting EFI partition"    
    mkfs.vfat -F32 -n "EFI" "$EFI" || { 
        error "EFI format failed"
        exit 1
    }
    
    # Verify partition table
    sgdisk -p "$DISK"
    success "Partitions created successfully"
}

zfs_passphrase() {
    # Generate key
    print "Set ZFS passphrase"
    
    # Secure directory creation
    if [[ ! -d /etc/zfs ]]; then
        mkdir -p /etc/zfs
        chmod 700 /etc/zfs
        chown root:root /etc/zfs
    fi
    
    while true; do
        read -r -p "${BLUE}> ZFS passphrase: ${NC}" -s pass1
        echo
        read -r -p "${BLUE}> Confirm passphrase: ${NC}" -s pass2
        echo
        
        if [[ "$pass1" == "$pass2" ]]; then
            if [[ ${#pass1} -lt 8 ]]; then
                warning "Passphrase must be at least 8 characters!"
                continue
            fi
            echo "$pass1" > /etc/zfs/zroot.key
            chmod 400 /etc/zfs/zroot.key
            chown root:root /etc/zfs/zroot.key
            
            # Verify key file was created
            if [[ ! -f /etc/zfs/zroot.key ]] || [[ ! -s /etc/zfs/zroot.key ]]; then
                error "Failed to create key file!"
                exit 1
            fi
            success "Passphrase set successfully"
            break
        else
            warning "Passphrases do not match. Try again."
        fi
    done
}

zfs_passphrase_backup() {
    print 'Creating encryption key backup'
    mkdir -p /mnt/root/zfs-keys
    chmod 700 /mnt/root/zfs-keys
    chown root:root /mnt/root/zfs-keys
    
    # Save key location - FIXED SIGPIPE
    local keylocation
    keylocation=$(zfs get -H -o value keylocation zroot 2>/dev/null || echo "")
    echo "$keylocation" > /mnt/root/zfs-keys/keylocation
    chmod 400 /mnt/root/zfs-keys/keylocation
    
    # Copy key with secure permissions
    install -m 400 /etc/zfs/zroot.key /mnt/root/zfs-keys/
    
    # Verify backup
    if ! diff /etc/zfs/zroot.key /mnt/root/zfs-keys/zroot.key &>/dev/null; then
        error "Key backup verification failed!"
        exit 1
    fi
    
    success "Key backup secured at /root/zfs-keys/"
}    

create_pool() {
    # ZFS part
    ZFS="$DISK-part2"

    # Create ZFS pool
    print "Creating ZFS pool"
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
                 zroot "$ZFS"
    
    # Verify pool was created - FIXED SIGPIPE
    local pool_check
    pool_check=$(zpool list zroot 2>/dev/null || echo "")
    if [[ -z "$pool_check" ]]; then
        error "Pool creation failed!"
        exit 1
    fi
    success "ZFS pool 'zroot' created successfully"
}

create_root_dataset() {
    # Slash dataset
    print "Creating root dataset"
    zfs create -o mountpoint=none zroot/ROOT

    # Set cmdline
    zfs set org.zfsbootmenu:commandline="ro quiet loglevel=0" zroot/ROOT
    success "Root dataset created"
}

create_system_dataset() {
    print "Creating system dataset: $1"
    zfs create -o mountpoint=/ \
           -o canmount=noauto \
           -o recordsize=128K \
           -o atime=off \
           -o relatime=off \
           -o devices=off \
           zroot/ROOT/"$1"

    # Generate zfs hostid with force flag
    print "Generating hostid"
    zgenhostid -f

    # Validate hostid per ZFS documentation
    if [[ ! -f /etc/hostid ]]; then
        error "Failed to generate hostid!"
        exit 1
    fi
    
    # Verify hostid is exactly 4 bytes
    if [[ $(stat -c%s /etc/hostid 2>/dev/null) -ne 4 ]]; then
        error "Hostid file corrupted (wrong size)!"
        exit 1
    fi
    
    # Display hostid for verification
    info "Generated hostid: $(hostid)"
     
    # Set bootfs
    print "Setting ZFS bootfs"
    zpool set bootfs="zroot/ROOT/$1" zroot

    # Manually mount slash dataset
    zfs mount zroot/ROOT/"$1"
    
    # Verify mount
    if ! mountpoint -q /mnt; then
        error "Failed to mount root dataset!"
        exit 1
    fi
    success "System dataset created and mounted"
}

create_home_dataset() {
    print "Creating home datasets"
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
    ask "Do you want to create a swap space? (y/n)"
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        SWAP_CREATED=true
        print "Creating swap zvol"
        
        # Get swap size with validation
        while true; do
            read -p "${BLUE}Enter swap size (e.g., 4G, 8G): ${NC}" swap_size
            if [[ $swap_size =~ ^[0-9]+[GMgm]$ ]]; then
                break
            else
                warning "Invalid format. Use format like 4G or 8G"
            fi
        done
        
        zfs create -V "${swap_size}" -b $(getconf PAGESIZE) \
            -o compression=zle \
            -o logbias=throughput \
            -o sync=disabled \
            -o primarycache=metadata \
            -o secondarycache=none \
            -o com.sun:auto-snapshot=false \
            zroot/swap

        # Wait for zvol device to appear
        print "Waiting for zvol device..."
        local count=0
        until [[ -e /dev/zvol/zroot/swap ]] || [[ $count -ge 30 ]]; do
            sleep 1
            ((count++))
        done
        
        if [[ ! -e /dev/zvol/zroot/swap ]]; then
            error "Swap zvol device did not appear!"
            exit 1
        fi

        print "Formatting swap"
        mkswap -f /dev/zvol/zroot/swap
        success "Swap space created: ${swap_size}"
        echo "$SWAP_CREATED" > /tmp/swap_created
    else
        SWAP_CREATED=false
        info "Skipping swap space creation"
        echo "$SWAP_CREATED" > /tmp/swap_created
    fi
}

export_pool() {
    print "Exporting zpool"
    zpool export zroot
    
    # Verify export - FIXED SIGPIPE
    local pool_check
    pool_check=$(zpool list zroot 2>/dev/null || echo "")
    if [[ -n "$pool_check" ]]; then
        error "Pool export failed!"
        exit 1
    fi
    success "Pool exported successfully"
}

import_pool() {
    print "Importing zpool"
    zpool import -d /dev/disk/by-id -R /mnt zroot -N -f || {
        error "Failed to import pool"
        exit 1
    }
    
    zfs load-key zroot || {
        error "Failed to load encryption key"
        exit 1
    }
    
    # Verify import - FIXED SIGPIPE
    local pool_check
    pool_check=$(zpool list zroot 2>/dev/null || echo "")
    if [[ -z "$pool_check" ]]; then
        error "Pool not imported!"
        exit 1
    fi
    success "Pool imported successfully"
}

mount_system() {
    print "Mounting system datasets"
    zfs mount zroot/ROOT/"$1"
    zfs mount -a

    # Verify root mount
    if ! mountpoint -q /mnt; then
        error "Root dataset not mounted!"
        exit 1
    fi

    # Mount EFI partition
    print "Mounting EFI partition"
    EFI="$DISK-part1"
    mkdir -p /mnt/boot/efi
    mount "$EFI" /mnt/boot/efi
    
    # Verify EFI mount
    if ! mountpoint -q /mnt/boot/efi; then
        error "EFI partition not mounted!"
        exit 1
    fi
    success "System mounted successfully"
}

copy_zpool_cache() {
    print "Generating and copying ZFS cache"
    mkdir -p /mnt/etc/zfs
    
    # Set cachefile on pool BEFORE copying
    zpool set cachefile=/etc/zfs/zpool.cache zroot
    
    # Wait for cache file to be written
    sleep 5
    
    # Verify cache file exists and is not empty
    if [[ ! -s /etc/zfs/zpool.cache ]]; then
        error "zpool.cache is missing or empty!"
        exit 1
    fi
    
    cp /etc/zfs/zpool.cache /mnt/etc/zfs/
    
    # Verify copy succeeded
    if ! diff /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache &>/dev/null; then
        error "Cache file copy verification failed!"
        exit 1
    fi
    
    success "ZFS cache configured"
    info "cachefile property set"
}

# Debug mode
if [[ "${1:-}" == "debug" ]]; then
    set -x
    debug=1
fi

# Main Installation Flow
header "Void Linux ZFS Installation"

check_prerequisites

print "Is this the first install or a second install to dualboot?"
install_reply=$(menu first dualboot)

select_disk
zfs_passphrase

# If first install
if [[ $install_reply == "first" ]]; then
    wipe
    partition
    create_pool
    create_root_dataset
fi

ask "Name of the root dataset?"

# FIXED SIGPIPE: Capture zfs list output first
while true; do
    local dataset_check
    dataset_check=$(zfs list "zroot/ROOT/$REPLY" 2>/dev/null || echo "")
    if [[ -n "$dataset_check" ]]; then
        warning "Dataset already exists. Choose another name."
        ask "Name of the root dataset?"
    else
        break
    fi
done

name_reply="$REPLY"
echo "$name_reply" > /tmp/root_dataset

if [[ $install_reply == "dualboot" ]]; then
    import_pool
    
    # FIXED SIGPIPE: Capture zfs list output first
    local dataset_check
    dataset_check=$(zfs list "zroot/ROOT/$name_reply" 2>/dev/null || echo "")
    if [[ -n "$dataset_check" ]]; then
        error "Dataset zroot/ROOT/$name_reply already exists! Aborting."
        exit 1
    fi
fi

create_system_dataset "$name_reply"

if [[ $install_reply == "first" ]]; then
    create_home_dataset
    create_swapspace
fi

export_pool
import_pool
mount_system "$name_reply"
copy_zpool_cache
zfs_passphrase_backup

# Begin System Installation
header "Beginning System Installation"

# Root dataset
root_dataset=$(cat /tmp/root_dataset)

# Set mirror and architecture
REPO=https://repo-default.voidlinux.org/current
ARCH=x86_64

# Copy xbps keys
print 'Copying xbps keys'
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
success "XBPS keys copied"

# Install base system
print 'Installing Void Linux base system'
XBPS_ARCH=$ARCH xbps-install -y -S -r /mnt -R "$REPO" \
  base-system \
  void-repo-nonfree

# Verify base system installation
if [[ ! -f /mnt/usr/bin/xbps-install ]]; then
    error "Base system installation failed!"
    exit 1
fi
success "Base system installed"

# Init chroot mounts
print 'Initializing chroot environment'
mount --rbind /sys /mnt/sys && mount --make-rslave /mnt/sys
mount --rbind /dev /mnt/dev && mount --make-rslave /mnt/dev
mount --rbind /proc /mnt/proc && mount --make-rslave /mnt/proc
success "Chroot environment initialized"

# Disable gummiboot post install hooks
echo "GUMMIBOOT_DISABLE=1" > /mnt/etc/default/gummiboot

# Install packages
print 'Installing required packages'
packages=(
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

# Verify critical packages - FIXED SIGPIPE
for pkg in zfs zfsbootmenu dracut; do
    local pkg_check
    pkg_check=$(chroot /mnt xbps-query "$pkg" 2>/dev/null || echo "")
    if [[ -z "$pkg_check" ]]; then
        error "Package $pkg not installed!"
        exit 1
    fi
done
success "Required packages installed"

# Set hostname
read -r -p "${BLUE}Please enter hostname: ${NC}" hostname
echo "$hostname" > /mnt/etc/hostname
success "Hostname set: $hostname"

# Configure ZFS files
print 'Copying ZFS configuration files'
cp /etc/hostid /mnt/etc/hostid
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache
cp -p /etc/zfs/zroot.key /mnt/etc/zfs/

# Verify ZFS files were copied
for file in /mnt/etc/hostid /mnt/etc/zfs/zpool.cache /mnt/etc/zfs/zroot.key; do
    if [[ ! -f "$file" ]]; then
        error "Failed to copy $(basename "$file")!"
        exit 1
    fi
done
success "ZFS configuration files copied"

# Configure iwd
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
cat >> /mnt/etc/resolvconf.conf <<"EOF"
resolv_conf=/etc/resolv.conf
name_servers="1.1.1.1 9.9.9.9"
EOF
success "DNS configured"

# Enable IP forwarding
cat > /mnt/etc/sysctl.conf <<"EOF"
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

# Prepare locales and keymap
print 'Configuring locales and keymap'
echo 'en_US.UTF-8 UTF-8' > /mnt/etc/default/libc-locales
echo 'LANG="en_US.UTF-8"' > /mnt/etc/locale.conf
echo 'KEYMAP="us"' > /mnt/etc/vconsole.conf

# Set timezone
print 'Set timezone'
read -r -p "${BLUE}Enter timezone (e.g., Asia/Singapore): ${NC}" timezone
timezone=${timezone:-"Asia/Singapore"}

# Configure system
cat >> /mnt/etc/rc.conf << EOF
TIMEZONE="$timezone"
HARDWARECLOCK="UTC"
KEYMAP="us"
EOF
success "Timezone set: $timezone"

# Set TTY font to smallest monospaced (Terminus size 8)
print 'Configuring TTY font (Terminus 8x16)'
cat >> /mnt/etc/vconsole.conf <<EOF
FONT=ter-v16n
EOF
success "TTY font configured"

# Set default shell to bash for root and new users
print 'Setting default shell to bash'
# Change root shell to bash
chroot /mnt chsh -s /bin/bash root

# Set default shell for new users
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

# Configure dracut for ZFS
print 'Configuring dracut'
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

# Configure base dracut settings
cat > /mnt/etc/dracut.conf <<"EOF"
hostonly="yes"
compress="zstd"
add_drivers+=" zfs "
omit_dracutmodules+=" network plymouth "
EOF
success "dracut configured"

# Configure username
print 'Set your username'
read -r -p "${BLUE}Username: ${NC}" user

# Validate username
if [[ ! $user =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    error "Invalid username!"
    exit 1
fi

# Chroot and configure system
print 'Configuring system in chroot'
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
  
  # Set timezone
  ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime
  
  # Generate locales
  xbps-reconfigure -f glibc-locales

  # Create user home dataset - FIXED SIGPIPE
  dataset_check=\$(zfs list zroot/data/home/${user} 2>/dev/null || echo "")
  if [[ -z "\$dataset_check" ]]; then
    zfs create zroot/data/home/${user}
  fi
  
  # Add user
  useradd -m -d /home/${user} -G network,wheel,video,audio,input,kvm ${user}
  chown -R ${user}:${user} /home/${user}
  
  # Activate swap if created
  if [[ -f /tmp/swap_created ]] && [[ "\$(cat /tmp/swap_created)" == "true" ]]; then
    # Wait for zvol device
    sleep 2
    if [[ -e /dev/zvol/zroot/swap ]]; then
      swapon /dev/zvol/zroot/swap 2>/dev/null || true
    fi
  fi
EOF
success "System configured in chroot"

# Configure fstab
print 'Configuring fstab'
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
    echo "/dev/zvol/zroot/swap  none           swap    discard,pri=100                 0      0" >> /mnt/etc/fstab
fi
success "fstab configured"

# Set root password
print 'Set root password'
chroot /mnt /bin/passwd

# Set user password
print "Set password for user: $user"
chroot /mnt /bin/passwd "$user"

# Configure sudo
print 'Configuring sudo'
cat > /mnt/etc/sudoers.d/99-wheel <<EOF
## Allow members of group wheel to execute any command
%wheel ALL=(ALL:ALL) ALL

## Uncomment to allow members of group wheel to execute any command without password
# %wheel ALL=(ALL:ALL) NOPASSWD: ALL
EOF

chmod 0440 /mnt/etc/sudoers.d/99-wheel

# Verify sudo configuration
if ! chroot /mnt visudo -c -f /etc/sudoers.d/99-wheel; then
    error "Invalid sudo configuration!"
    exit 1
fi
success "sudo configured"

# Configure ZFSBootMenu
print 'Configuring ZFSBootMenu'

mkdir -p /mnt/boot/efi/EFI/ZBM /mnt/etc/zfsbootmenu/dracut.conf.d

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

# Configure dracut for ZBM
cat > /mnt/etc/zfsbootmenu/dracut.conf.d/keymap.conf <<EOF
install_optional_items+=" /etc/cmdline.d/keymap.conf "
EOF

mkdir -p /mnt/etc/cmdline.d/
cat > /mnt/etc/cmdline.d/keymap.conf <<EOF
rd.vconsole.keymap=us
EOF

# Set ZFS boot commandline
zfs set org.zfsbootmenu:commandline="ro quiet nowatchdog loglevel=0 zbm.timeout=5" zroot/ROOT/"$root_dataset"
success "ZFSBootMenu configured"

# Generate ZFSBootMenu
print 'Generating ZFSBootMenu and initramfs'
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
  
  # Verify initramfs contains ZFS module - FIXED SIGPIPE
  initramfs_content=$(lsinitrd /boot/initramfs-*.img 2>/dev/null || echo "")
  if [[ -n "$initramfs_content" ]]; then
    if ! echo "$initramfs_content" | grep -q "zfs.ko"; then
      echo "WARNING: ZFS module may not be in initramfs"
    fi
  fi
EOF

# Verify critical boot files
if [[ ! -f /mnt/boot/efi/EFI/ZBM/vmlinuz.efi ]]; then
    error "ZFSBootMenu EFI file not found!"
    exit 1
fi
success "ZFSBootMenu generated successfully"

# Create backup if needed
if [[ ! -f /mnt/boot/efi/EFI/ZBM/vmlinuz-backup.efi ]]; then
    print "Creating ZFSBootMenu backup"
    cp /mnt/boot/efi/EFI/ZBM/vmlinuz.efi /mnt/boot/efi/EFI/ZBM/vmlinuz-backup.efi
    success "ZFSBootMenu backup created"
fi

# Set DISK for UEFI entries
if [[ -f /tmp/disk ]]; then
    DISK=$(cat /tmp/disk)
else
    print 'Select the disk for boot entries:'
    
    # FIXED SIGPIPE: Capture ls output first
    local disk_list
    disk_list=$(ls /dev/disk/by-id/ 2>/dev/null || echo "")
    
    select ENTRY in $disk_list; do
        DISK="/dev/disk/by-id/$ENTRY"
        info "Creating boot entries on $ENTRY."
        break
    done
fi

# Create UEFI boot entries
print 'Creating EFI boot entries'
modprobe efivarfs
mountpoint -q /sys/firmware/efi/efivars \
    || mount -t efivarfs efivarfs /sys/firmware/efi/efivars

# Remove existing ZFSBootMenu entries - FIXED SIGPIPE
local efi_entries
efi_entries=$(efibootmgr 2>/dev/null || echo "")

if echo "$efi_entries" | grep -q "ZFSBootMenu"; then
    print "Removing old ZFSBootMenu entries"
    
    # FIXED SIGPIPE: Capture grep output first
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
print "Creating backup boot entry"
if ! efibootmgr --disk "$DISK" \
  --part 1 \
  --create \
  --label "ZFSBootMenu Backup" \
  --loader "\EFI\ZBM\vmlinuz-backup.efi" \
  --verbose; then
    warning "Failed to create backup boot entry!"
fi

# Create main entry
print "Creating main boot entry"
if ! efibootmgr --disk "$DISK" \
  --part 1 \
  --create \
  --label "ZFSBootMenu" \
  --loader "\EFI\ZBM\vmlinuz.efi" \
  --verbose; then
    error "Failed to create main boot entry!"
    exit 1
fi
success "EFI boot entries created"

# Display boot order
print "Current boot order:"
efibootmgr

# Cleanup and unmount
print 'Cleaning up and unmounting'

# Unmount EFI
umount /mnt/boot/efi || {
    warning "Failed to unmount /mnt/boot/efi"
}

# Unmount bind mounts
umount -l /mnt/{dev,proc,sys} 2>/dev/null || true

# Unmount ZFS filesystems
zfs umount -a

# Export pool
print 'Exporting zpool'
zpool export zroot

# Verify export - FIXED SIGPIPE
local final_pool_check
final_pool_check=$(zpool list zroot 2>/dev/null || echo "")
if [[ -n "$final_pool_check" ]]; then
    warning "Pool still imported, forcing export..."
    zpool export -f zroot
fi
success "Pool exported successfully"

# Final verification
header "Installation Verification"
success "ZFS pool created: zroot"
success "Root dataset: zroot/ROOT/$root_dataset"
success "Encryption: AES-256-GCM"
success "Hostid: $(cat /mnt/etc/hostid 2>/dev/null | od -An -tx1 || echo 'exported')"
success "Cachefile: configured"
success "ZFSBootMenu: installed"
success "UEFI entries: created"
if [[ -f /tmp/swap_created ]] && [[ "$(cat /tmp/swap_created)" == "true" ]]; then
    success "Swap: configured"
fi

# Finish
echo ""
echo -e "${GREEN}${BOLD}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  Installation completed successfully!  ║${NC}"
echo -e "${GREEN}${BOLD}╚════════════════════════════════════════╝${NC}"
echo ""

print "Next steps:"
info "1. Remove installation media"
info "2. Reboot the system"
info "3. At ZFSBootMenu, select your boot environment"
info "4. Enter encryption passphrase when prompted"
echo ""
echo -e "${CYAN}To reboot now, run: ${BOLD}reboot${NC}"

# Cleanup temp files
rm -f /tmp/disk /tmp/root_dataset /tmp/swap_created

exit 0
