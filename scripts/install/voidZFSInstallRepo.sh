#!/usr/bin/env bash
# filepath: voidZFSInstallRepo.sh

export TERM=xterm
 
set -e

exec &> >(tee "configureNinstall.log")

# Colors for output - UPDATED: Consistent with other scripts
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;94m'      # Light Blue (bright blue)
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Validation Functions
check_prerequisites() {
    local failed=0
    
    # Check for root privileges
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}✗ ERROR: This script must be run as root${NC}" >&2
        failed=1
    fi
    
    # Check for EFI boot mode
    if ! ls /sys/firmware/efi/efivars &>/dev/null; then
        echo -e "${RED}✗ ERROR: System not booted in EFI mode${NC}" >&2
        failed=1
    fi
    
    # Check network connectivity
    if ! ping -c 1 voidlinux.org &>/dev/null; then
        echo -e "${RED}✗ ERROR: No network connectivity to voidlinux.org${NC}" >&2
        failed=1
    fi
    
    # Check for ZFS module
    if ! modprobe zfs &>/dev/null; then
        echo -e "${RED}✗ ERROR: ZFS kernel module not available${NC}" >&2
        failed=1
    fi
    
    if ((failed)); then
        exit 1
    fi
    
    echo -e "${GREEN}✓ Prerequisites check passed${NC}"
}

print () {
    echo -e "\n${BOLD}${CYAN}> $1${NC}\n"
    if [[ -n "$debug" ]]
    then
      read -rp "press enter to continue"
    fi
}

ask () {
    read -p "${BLUE}> $1 ${NC}" -r
    echo
}

menu () {
    PS3="${BLUE}> Choose a number: ${NC}"
    select i in "$@"
    do
        echo "$i"
        break
    done
}

select_disk () {
    local disks=()
    while IFS= read -r disk; do
        # Filter out partition entries
        if [[ ! $disk =~ -(part|p)[0-9]+$ ]]; then
            disks+=("$disk")
        fi
    done < <(ls /dev/disk/by-id/)
    
    PS3="${BLUE}Select installation disk: ${NC}"
    select ENTRY in "${disks[@]}"; do
        if [[ -n $ENTRY ]]; then
            DISK="/dev/disk/by-id/$ENTRY"
            echo "$DISK" > /tmp/disk
            echo -e "${GREEN}✓ Installing on $ENTRY${NC}"
            break
        fi
    done
}

wipe () {
    ask "Do you want to wipe all datas on $ENTRY ?"
    if [[ $REPLY =~ ^[Yy]$ ]]
    then
        # Clear disk
        print "Wiping disk..."
        dd if=/dev/zero of="$DISK" bs=512 count=1
        wipefs -af "$DISK"
        sgdisk -Zo "$DISK"
        zpool labelclear -f "$DISK" 2>/dev/null || true
        
        # Wait for kernel to update
        partprobe "$DISK"
        sleep 2
        echo -e "${GREEN}✓ Disk wiped successfully${NC}"
    fi
}

partition () {
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
        echo -e "${RED}✗ ERROR: EFI format failed${NC}" >&2
        exit 1
    }
    
    # Verify partition table
    sgdisk -p "$DISK"
    echo -e "${GREEN}✓ Partitions created successfully${NC}"
}

zfs_passphrase () {
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
                echo -e "${YELLOW}⚠ WARNING: Passphrase must be at least 8 characters!${NC}"
                continue
            fi
            echo "$pass1" > /etc/zfs/zroot.key
            chmod 400 /etc/zfs/zroot.key
            chown root:root /etc/zfs/zroot.key
            
            # Verify key file was created
            if [[ ! -f /etc/zfs/zroot.key ]] || [[ ! -s /etc/zfs/zroot.key ]]; then
                echo -e "${RED}✗ ERROR: Failed to create key file!${NC}" >&2
                exit 1
            fi
            echo -e "${GREEN}✓ Passphrase set successfully${NC}"
            break
        else
            echo -e "${YELLOW}⚠ WARNING: Passphrases do not match. Try again.${NC}"
        fi
    done
}

zfs_passphrase_backup () {
    print 'Creating encryption key backup'
    mkdir -p /mnt/root/zfs-keys
    chmod 700 /mnt/root/zfs-keys
    chown root:root /mnt/root/zfs-keys
    
    # Save key location
    zfs get -H -o value keylocation zroot > /mnt/root/zfs-keys/keylocation
    chmod 400 /mnt/root/zfs-keys/keylocation
    
    # Copy key with secure permissions
    install -m 400 /etc/zfs/zroot.key /mnt/root/zfs-keys/
    
    # Verify backup
    if ! diff /etc/zfs/zroot.key /mnt/root/zfs-keys/zroot.key &>/dev/null; then
        echo -e "${RED}✗ ERROR: Key backup verification failed!${NC}" >&2
        exit 1
    fi
    
    echo -e "${GREEN}✓ Key backup secured at /root/zfs-keys/${NC}"
}    

create_pool () {
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
    
    # Verify pool was created
    if ! zpool list zroot &>/dev/null; then
        echo -e "${RED}✗ ERROR: Pool creation failed!${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}✓ ZFS pool 'zroot' created successfully${NC}"
}

create_root_dataset () {
    # Slash dataset
    print "Creating root dataset"
    zfs create -o mountpoint=none zroot/ROOT

    # Set cmdline
    zfs set org.zfsbootmenu:commandline="ro quiet loglevel=0" zroot/ROOT
    echo -e "${GREEN}✓ Root dataset created${NC}"
}

create_system_dataset () {
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
        echo -e "${RED}✗ ERROR: Failed to generate hostid!${NC}" >&2
        exit 1
    fi
    
    # Verify hostid is exactly 4 bytes
    if [[ $(stat -c%s /etc/hostid 2>/dev/null) -ne 4 ]]; then
        echo -e "${RED}✗ ERROR: Hostid file corrupted (wrong size)!${NC}" >&2
        exit 1
    fi
    
    # Display hostid for verification
    echo -e "${BLUE}ℹ INFO: Generated hostid: $(hostid)${NC}"
     
    # Set bootfs
    print "Setting ZFS bootfs"
    zpool set bootfs="zroot/ROOT/$1" zroot

    # Manually mount slash dataset
    zfs mount zroot/ROOT/"$1"
    
    # Verify mount
    if ! mountpoint -q /mnt; then
        echo -e "${RED}✗ ERROR: Failed to mount root dataset!${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}✓ System dataset created and mounted${NC}"
}

create_home_dataset () {
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
    echo -e "${GREEN}✓ Home datasets created${NC}"
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
                echo -e "${YELLOW}⚠ WARNING: Invalid format. Use format like 4G or 8G${NC}"
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
            echo -e "${RED}✗ ERROR: Swap zvol device did not appear!${NC}" >&2
            exit 1
        fi

        print "Formatting swap"
        mkswap -f /dev/zvol/zroot/swap
        echo -e "${GREEN}✓ Swap space created: ${swap_size}${NC}"
        echo "$SWAP_CREATED" > /tmp/swap_created
    else
        SWAP_CREATED=false
        echo -e "${BLUE}ℹ INFO: Skipping swap space creation${NC}"
        echo "$SWAP_CREATED" > /tmp/swap_created
    fi
}

export_pool () {
    print "Exporting zpool"
    zpool export zroot
    
    # Verify export
    if zpool list zroot &>/dev/null; then
        echo -e "${RED}✗ ERROR: Pool export failed!${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}✓ Pool exported successfully${NC}"
}

import_pool () {
    print "Importing zpool"
    zpool import -d /dev/disk/by-id -R /mnt zroot -N -f || {
        echo -e "${RED}✗ ERROR: Failed to import pool${NC}" >&2
        exit 1
    }
    
    zfs load-key zroot || {
        echo -e "${RED}✗ ERROR: Failed to load encryption key${NC}" >&2
        exit 1
    }
    
    # Verify import
    if ! zpool list zroot &>/dev/null; then
        echo -e "${RED}✗ ERROR: Pool not imported!${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}✓ Pool imported successfully${NC}"
}

mount_system () {
    print "Mounting system datasets"
    zfs mount zroot/ROOT/"$1"
    zfs mount -a

    # Verify root mount
    if ! mountpoint -q /mnt; then
        echo -e "${RED}✗ ERROR: Root dataset not mounted!${NC}" >&2
        exit 1
    fi

    # Mount EFI partition
    print "Mounting EFI partition"
    EFI="$DISK-part1"
    mkdir -p /mnt/boot/efi
    mount "$EFI" /mnt/boot/efi
    
    # Verify EFI mount
    if ! mountpoint -q /mnt/boot/efi; then
        echo -e "${RED}✗ ERROR: EFI partition not mounted!${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}✓ System mounted successfully${NC}"
}

copy_zpool_cache () {
    print "Generating and copying ZFS cache"
    mkdir -p /mnt/etc/zfs
    
    # Set cachefile on pool BEFORE copying
    zpool set cachefile=/etc/zfs/zpool.cache zroot
    
    
    # Wait for cache file to be written
    sleep 5
    
    # Verify cache file exists and is not empty
    if [[ ! -s /etc/zfs/zpool.cache ]]; then
        echo -e "${RED}✗ ERROR: zpool.cache is missing or empty!${NC}" >&2
        exit 1
    fi
    
    cp /etc/zfs/zpool.cache /mnt/etc/zfs/
    
    # Verify copy succeeded
    if ! diff /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache &>/dev/null; then
        echo -e "${RED}✗ ERROR: Cache file copy verification failed!${NC}" >&2
        exit 1
    fi
    
    echo -e "${GREEN}✓ ZFS cache configured${NC}"
    echo -e "${BLUE}ℹ INFO: cachefile property set${NC}"
}

# Debug mode
if [[ "$1" == "debug" ]]; then
    set -x
    debug=1
fi

# Main Installation Flow
echo -e "\n${BOLD}${CYAN}=========================================="
echo "Void Linux ZFS Installation"
echo "==========================================${NC}\n"

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

while zfs list "zroot/ROOT/$REPLY" &>/dev/null; do
  echo -e "${YELLOW}⚠ WARNING: Dataset already exists. Choose another name.${NC}"
  ask "Name of the root dataset?"
done

name_reply="$REPLY"
echo "$name_reply" > /tmp/root_dataset

if [[ $install_reply == "dualboot" ]]; then
    import_pool
    if zfs list "zroot/ROOT/$name_reply" &>/dev/null; then
        echo -e "${RED}✗ ERROR: Dataset zroot/ROOT/$name_reply already exists! Aborting.${NC}"
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
echo ""
echo -e "${BOLD}${CYAN}=========================================="
echo "Beginning System Installation"
echo "==========================================${NC}"
echo ""

# Root dataset
root_dataset=$(cat /tmp/root_dataset)

# Set mirror and architecture
REPO=https://repo-default.voidlinux.org/current
ARCH=x86_64

# Copy xbps keys
print 'Copying xbps keys'
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
echo -e "${GREEN}✓ XBPS keys copied${NC}"

# Install base system
print 'Installing Void Linux base system'
XBPS_ARCH=$ARCH xbps-install -y -S -r /mnt -R "$REPO" \
  base-system \
  void-repo-nonfree

# Verify base system installation
if [[ ! -f /mnt/usr/bin/xbps-install ]]; then
    echo -e "${RED}✗ ERROR: Base system installation failed!${NC}" >&2
    exit 1
fi
echo -e "${GREEN}✓ Base system installed${NC}"

# Init chroot mounts
print 'Initializing chroot environment'
mount --rbind /sys /mnt/sys && mount --make-rslave /mnt/sys
mount --rbind /dev /mnt/dev && mount --make-rslave /mnt/dev
mount --rbind /proc /mnt/proc && mount --make-rslave /mnt/proc
echo -e "${GREEN}✓ Chroot environment initialized${NC}"

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

# Verify critical packages
for pkg in zfs zfsbootmenu dracut; do
    if ! chroot /mnt xbps-query $pkg &>/dev/null; then
        echo -e "${RED}✗ ERROR: Package $pkg not installed!${NC}" >&2
        exit 1
    fi
done
echo -e "${GREEN}✓ Required packages installed${NC}"

# Set hostname
read -r -p "${BLUE}Please enter hostname: ${NC}" hostname
echo "$hostname" > /mnt/etc/hostname
echo -e "${GREEN}✓ Hostname set: $hostname${NC}"

# Configure ZFS files
print 'Copying ZFS configuration files'
cp /etc/hostid /mnt/etc/hostid
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache
cp -p /etc/zfs/zroot.key /mnt/etc/zfs/

# Verify ZFS files were copied
for file in /mnt/etc/hostid /mnt/etc/zfs/zpool.cache /mnt/etc/zfs/zroot.key; do
    if [[ ! -f "$file" ]]; then
        echo -e "${RED}✗ ERROR: Failed to copy $(basename $file)!${NC}" >&2
        exit 1
    fi
done
echo -e "${GREEN}✓ ZFS configuration files copied${NC}"

# Configure iwd
mkdir -p /mnt/etc/iwd
cat > /mnt/etc/iwd/main.conf <<"EOF"
[General]
UseDefaultInterface=true
EnableNetworkConfiguration=true

[Network]
NameResolvingService=resolvconf
EOF
echo -e "${GREEN}✓ iwd configured${NC}"

# Configure DNS
cat >> /mnt/etc/resolvconf.conf <<"EOF"
resolv_conf=/etc/resolv.conf
name_servers="1.1.1.1 9.9.9.9"
EOF
echo -e "${GREEN}✓ DNS configured${NC}"

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
echo -e "${GREEN}✓ Timezone set: $timezone${NC}"

# Set TTY font to smallest monospaced (Terminus size 8)
print 'Configuring TTY font (Terminus 8x16)'
cat >> /mnt/etc/vconsole.conf <<EOF
FONT=ter-v16n
EOF
echo -e "${GREEN}✓ TTY font configured${NC}"

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
echo -e "${GREEN}✓ Default shell set to bash${NC}"

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
echo -e "${GREEN}✓ dracut configured${NC}"

# Configure username
print 'Set your username'
read -r -p "${BLUE}Username: ${NC}" user

# Validate username
if [[ ! $user =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo -e "${RED}✗ ERROR: Invalid username!${NC}" >&2
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
  
  # Enable ZFS services (CRITICAL FIX)
  ln -sf /etc/sv/zfs-import /etc/runit/runsvdir/default/
  ln -sf /etc/sv/zfs-mount /etc/runit/runsvdir/default/
  ln -sf /etc/sv/zfs-zed /etc/runit/runsvdir/default/

  # Set timezone
  ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime
  
  # Generate locales
  xbps-reconfigure -f glibc-locales

  # Create user home dataset
  if ! zfs list zroot/data/home/${user} &>/dev/null; then
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
echo -e "${GREEN}✓ System configured in chroot${NC}"

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
echo -e "${GREEN}✓ fstab configured${NC}"

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
    echo -e "${RED}✗ ERROR: Invalid sudo configuration!${NC}" >&2
    exit 1
fi
echo -e "${GREEN}✓ sudo configured${NC}"

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
echo -e "${GREEN}✓ ZFSBootMenu configured${NC}"

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
  
  # Verify initramfs contains ZFS module
  if ! lsinitrd /boot/initramfs-*.img 2>/dev/null | grep -q "zfs.ko"; then
    echo "WARNING: ZFS module may not be in initramfs!"
  fi
EOF

# Verify critical boot files
if [[ ! -f /mnt/boot/efi/EFI/ZBM/vmlinuz.efi ]]; then
    echo -e "${RED}✗ ERROR: ZFSBootMenu EFI file not found!${NC}" >&2
    exit 1
fi
echo -e "${GREEN}✓ ZFSBootMenu generated successfully${NC}"

# Create backup if needed
if [[ ! -f /mnt/boot/efi/EFI/ZBM/vmlinuz-backup.efi ]]; then
    print "Creating ZFSBootMenu backup"
    cp /mnt/boot/efi/EFI/ZBM/vmlinuz.efi /mnt/boot/efi/EFI/ZBM/vmlinuz-backup.efi
    echo -e "${GREEN}✓ ZFSBootMenu backup created${NC}"
fi

# Set DISK for UEFI entries
if [[ -f /tmp/disk ]]; then
    DISK=$(cat /tmp/disk)
else
    print 'Select the disk for boot entries:'
    select ENTRY in $(ls /dev/disk/by-id/); do
        DISK="/dev/disk/by-id/$ENTRY"
        echo -e "${BLUE}ℹ INFO: Creating boot entries on $ENTRY.${NC}"
        break
    done
fi

# Create UEFI boot entries
print 'Creating EFI boot entries'
modprobe efivarfs
mountpoint -q /sys/firmware/efi/efivars \
    || mount -t efivarfs efivarfs /sys/firmware/efi/efivars

# Remove existing ZFSBootMenu entries
if efibootmgr | grep -q "ZFSBootMenu"; then
    print "Removing old ZFSBootMenu entries"
    for entry in $(efibootmgr | grep "ZFSBootMenu" | sed -E 's/Boot([0-9]+).*/\1/'); do   
        efibootmgr -B -b "$entry"
    done
    echo -e "${GREEN}✓ Old boot entries removed${NC}"
fi

# Create backup entry
print "Creating backup boot entry"
if ! efibootmgr --disk "$DISK" \
  --part 1 \
  --create \
  --label "ZFSBootMenu Backup" \
  --loader "\EFI\ZBM\vmlinuz-backup.efi" \
  --verbose; then
    echo -e "${YELLOW}⚠ WARNING: Failed to create backup boot entry!${NC}"
fi

# Create main entry
print "Creating main boot entry"
if ! efibootmgr --disk "$DISK" \
  --part 1 \
  --create \
  --label "ZFSBootMenu" \
  --loader "\EFI\ZBM\vmlinuz.efi" \
  --verbose; then
    echo -e "${RED}✗ ERROR: Failed to create main boot entry!${NC}" >&2
    exit 1
fi
echo -e "${GREEN}✓ EFI boot entries created${NC}"

# Display boot order
print "Current boot order:"
efibootmgr

# Cleanup and unmount
print 'Cleaning up and unmounting'

# Unmount EFI
umount /mnt/boot/efi || {
    echo -e "${YELLOW}⚠ WARNING: Failed to unmount /mnt/boot/efi${NC}"
}

# Unmount bind mounts
umount -l /mnt/{dev,proc,sys} 2>/dev/null || true

# Unmount ZFS filesystems
zfs umount -a

# Export pool
print 'Exporting zpool'
zpool export zroot

# Verify export
if zpool list zroot &>/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ WARNING: Pool still imported, forcing export...${NC}"
    zpool export -f zroot
fi
echo -e "${GREEN}✓ Pool exported successfully${NC}"

# Final verification
echo ""
echo -e "${BOLD}${CYAN}=========================================="
echo "Installation Verification"
echo "==========================================${NC}"
echo -e "${GREEN}✓ ZFS pool created: zroot${NC}"
echo -e "${GREEN}✓ Root dataset: zroot/ROOT/$root_dataset${NC}"
echo -e "${GREEN}✓ Encryption: AES-256-GCM${NC}"
echo -e "${GREEN}✓ Hostid: $(cat /mnt/etc/hostid 2>/dev/null | od -An -tx1 || echo 'exported')${NC}"
echo -e "${GREEN}✓ Cachefile: configured${NC}"
echo -e "${GREEN}✓ ZFSBootMenu: installed${NC}"
echo -e "${GREEN}✓ UEFI entries: created${NC}"
if [[ -f /tmp/swap_created ]] && [[ "$(cat /tmp/swap_created)" == "true" ]]; then
    echo -e "${GREEN}✓ Swap: configured${NC}"
fi
echo -e "${BOLD}${CYAN}==========================================${NC}"
echo ""

# Finish
echo -e "\n${GREEN}${BOLD}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  Installation completed successfully!  ║${NC}"
echo -e "${GREEN}${BOLD}╚════════════════════════════════════════╝${NC}\n"

print "Next steps:"
echo -e "${BLUE}1. Remove installation media${NC}"
echo -e "${BLUE}2. Reboot the system${NC}"
echo -e "${BLUE}3. At ZFSBootMenu, select your boot environment${NC}"
echo -e "${BLUE}4. Enter encryption passphrase when prompted${NC}"
echo ""
echo -e "${CYAN}To reboot now, run: ${BOLD}reboot${NC}"

# Cleanup temp files
rm -f /tmp/disk /tmp/root_dataset /tmp/swap_created

exit 0
