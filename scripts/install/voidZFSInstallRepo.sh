#!/usr/bin/env bash

set -e

exec &> >(tee "configureNinstall.log")

# Validation Functions
check_prerequisites() {
    local failed=0
    
    # Check for root privileges
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root" >&2
        failed=1
    fi
    
    # Check for EFI boot mode
    if ! ls /sys/firmware/efi/efivars &>/dev/null; then
        echo "System not booted in EFI mode" >&2
        failed=1
    fi
    
    # Check network connectivity
    if ! ping -c 1 voidlinux.org &>/dev/null; then
        echo "No network connectivity to voidlinux.org" >&2
        failed=1
    fi
    
    # Check for ZFS module
    if ! modprobe zfs &>/dev/null; then
        echo "ZFS kernel module not available" >&2
        failed=1
    fi
    
    if ((failed)); then
        exit 1
    fi
    
    echo "Prerequisites check passed"
}

print () {
    echo -e "\n\033[1m> $1\033[0m\n"
    if [[ -n "$debug" ]]
    then
      read -rp "press enter to continue"
    fi
}

ask () {
    read -p "> $1 " -r
    echo
}

menu () {
    PS3="> Choose a number: "
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
    
    PS3="Select installation disk: "
    select ENTRY in "${disks[@]}"; do
        if [[ -n $ENTRY ]]; then
            DISK="/dev/disk/by-id/$ENTRY"
            echo "$DISK" > /tmp/disk
            echo "Installing on $ENTRY"
            break
        fi
    done
}

wipe () {
    ask "Do you want to wipe all datas on $ENTRY ?"
    if [[ $REPLY =~ ^[Yy]$ ]]
    then
        # Clear disk
        dd if=/dev/zero of="$DISK" bs=512 count=1
        wipefs -af "$DISK"
        sgdisk -Zo "$DISK"
        zpool labelclear -f "$DISK" || true
    fi
}

partition () {
    # EFI part
    print "Creating EFI part"
    sgdisk -n1:1M:+512M -t1:EF00 "$DISK"
    EFI="$DISK-part1"

    # ZFS part
    print "Creating ZFS part"
    sgdisk -n2:0:0 -t2:BF00 "$DISK"
    ZFS="$DISK-part2"
    
    # Inform kernel
    partprobe "$DISK"

    # Format efi part
    until [ -e "$EFI" ]; do sleep 1; done
        
    print "Format EFI part"    
    mkfs.vfat -n "EFI" "$EFI" || { echo "EFI format failed"; exit 1; }
}

zfs_passphrase () {
    # Generate key
    print "Set ZFS passphrase"
    read -r -p "> ZFS passphrase: " -s pass
    echo
    echo "$pass" > /etc/zfs/zroot.key
    chmod 000 /etc/zfs/zroot.key
    

}

zfs_passphrase_backup () {
    print 'Creating encryption key backup'
    mkdir -p /mnt/root/zfs-keys
    zfs get -H -o value keylocation zroot > /mnt/root/zfs-keys/keylocation
    install -m 000 /etc/zfs/zroot.key /mnt/root/zfs-keys/
}    

create_pool () {
    # ZFS part
    ZFS="$DISK-part2"

    # Create ZFS pool
    print "Create ZFS pool"
    zpool create -f -o ashift=12                          \
                 -o autotrim=on                           \
                 -O acltype=posixacl                      \
                 -O compression=lz4                      \
                 -O relatime=on                           \
                 -O xattr=sa                              \
                 -O dnodesize=auto                      \
                 -O encryption=aes-256-gcm                \
                 -O keyformat=passphrase                  \
                 -O keylocation=file:///etc/zfs/zroot.key \
                 -O normalization=formD                   \
                 -O mountpoint=none                       \
                 -O canmount=off                          \
                 -O devices=off                           \
                 -R /mnt                                  \
                 zroot "$ZFS"
}

create_root_dataset () {
    # Slash dataset
    print "Create root dataset"
    zfs create -o mountpoint=none                 zroot/ROOT

    # Set cmdline
    zfs set org.zfsbootmenu:commandline="ro quiet" zroot/ROOT
}

create_system_dataset () {
    print "Create slash dataset"
    zfs create -o mountpoint=/ \
           -o canmount=noauto \
           -o recordsize=128K \
           -o atime=off \
           -o relatime=off \
           -o devices=off \
           zroot/ROOT/"$1"

    # Generate zfs hostid
    print "Generate hostid"
    zgenhostid

    # ADD: Validate hostid per ZFS documentation
    if [[ ! -f /etc/hostid ]]; then
        echo "ERROR: Failed to generate hostid!" >&2
        exit 1
    fi 
	 
    # Set bootfs
    print "Set ZFS bootfs"
    zpool set bootfs="zroot/ROOT/$1" zroot

    # Manually mount slash dataset
    zfs mount zroot/ROOT/"$1"
}

create_home_dataset () {
    print "Create home dataset"
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
}

create_swapspace() {
    ask "Do you want to create a swap space? (y/n)"
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        SWAP_CREATED=true
        print "Creating swap zvol"
        read -p "Enter swap size (e.g., 4G, 8G): " swap_size
        zfs create -V "${swap_size:-4G}" -b $(getconf PAGESIZE) \
            -o compression=zle \
            -o logbias=throughput \
            -o sync=disabled \
            -o primarycache=metadata \
            -o secondarycache=none \
            -o com.sun:auto-snapshot=false \
            zroot/swap

        print "Formatting swap"
        mkswap -f /dev/zvol/zroot/swap
        echo "$SWAP_CREATED" > /tmp/swap_created
    else
        SWAP_CREATED=false
        echo "$SWAP_CREATED" > /tmp/swap_created
    fi
}

export_pool () {
    print "Export zpool"
    zpool export zroot
}

import_pool () {
    print "Import zpool"
    zpool import -d /dev/disk/by-id -R /mnt zroot -N -f || {
        echo "Failed to import pool" >&2
        exit 1
    }
    zfs load-key zroot
}

mount_system () {
    print "Mount slash dataset"
    zfs mount zroot/ROOT/"$1"
    zfs mount -a

    # Mount EFI part
    print "Mount EFI part"
    EFI="$DISK-part1"
    mkdir -p /mnt/boot/efi
    mount "$EFI" /mnt/boot/efi
}

copy_zpool_cache () {
    # Copy ZFS cache
    print "Generate and copy zfs cache"
    mkdir -p /mnt/etc/zfs
    zpool set cachefile=/etc/zfs/zpool.cache zroot
	cp /etc/zfs/zpool.cache /mnt/etc/zfs/
	
	# ADD: Create zpool.cache.d directory per OpenZFS guide
    mkdir -p /mnt/etc/zfs/zpool.cache.d
}

# Main
check_prerequisites

print "Is this the first install or a second install to dualboot ?"
install_reply=$(menu first dualboot)

select_disk
zfs_passphrase

# If first install
if [[ $install_reply == "first" ]]
then
    # Wipe the disk
    wipe
    # Create partition table
    partition
    # Create ZFS pool
    create_pool
    # Create root dataset
    create_root_dataset
fi

ask "Name of the slash dataset ?"

while zfs list "zroot/ROOT/$REPLY" &>/dev/null; do
  echo "Dataset already exists. Choose another name."
  ask "Name of the slash dataset ?"
done

name_reply="$REPLY"

echo "$name_reply" > /tmp/root_dataset

if [[ $install_reply == "dualboot" ]]
then
    import_pool
    if zfs list "zroot/ROOT/$name_reply" &>/dev/null; then
        print "Dataset zroot/ROOT/$name_reply already exists! Aborting."
        exit 1
    fi    
fi

create_system_dataset "$name_reply"

if [[ $install_reply == "first" ]]
then
    create_home_dataset
    create_swapspace
fi

export_pool
import_pool
mount_system "$name_reply"
copy_zpool_cache
zfs_passphrase_backup


# Finish
echo -e "\e[32mConfiguration is completed....."
echo -e "\e[32mBegin Installation"

# Debug
if [[ "$1" == "debug" ]]
then
    set -x
    debug=1
fi

# Root dataset
root_dataset=$(cat /tmp/root_dataset)

# Set mirror and architecture
REPO=https://repo-default.voidlinux.org/current
ARCH=x86_64

# Copy keys
print 'Copy xbps keys'
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/

### Install base system
print 'Install Void Linux'
XBPS_ARCH=$ARCH xbps-install -y -S -r /mnt -R "$REPO" \
  base-system \
  void-repo-nonfree \

# Init chroot
print 'Init chroot'
mount --rbind /sys /mnt/sys && mount --make-rslave /mnt/sys
mount --rbind /dev /mnt/dev && mount --make-rslave /mnt/dev
mount --rbind /proc /mnt/proc && mount --make-rslave /mnt/proc

# Disable gummiboot post install hooks, only installs for generate-zbm
echo "GUMMIBOOT_DISABLE=1" > /mnt/etc/default/gummiboot

# Install packages
print 'Install packages'
packages=(
  zfs
  zfsbootmenu
  efibootmgr
  gummiboot # required by zfsbootmenu
  chrony # ntp
  cronie # cron
  acpid # power management
  iwd # wifi daemon
  dhclient
  openresolv # dns
  )

XBPS_ARCH=$ARCH xbps-install -y -S -r /mnt -R "$REPO" "${packages[@]}"

# Set hostname
read -r -p 'Please enter hostname : ' hostname
echo "$hostname" > /mnt/etc/hostname

# Configure zfs
print 'Copy ZFS files'
cp /etc/hostid /mnt/etc/hostid
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache
cp -p /etc/zfs/zroot.key /mnt/etc/zfs

# Configure iwd
cat > /mnt/etc/iwd/main.conf <<"EOF"
[General]
UseDefaultInterface=true
EnableNetworkConfiguration=true
EOF

# Configure DNS
cat >> /mnt/etc/resolvconf.conf <<"EOF"
resolv_conf=/etc/resolv.conf
name_servers_append="1.1.1.1 9.9.9.9"
name_server_blacklist="192.168.*"
EOF

# Enable ip forward
cat > /mnt/etc/sysctl.conf <<"EOF"
net.ipv4.ip_forward = 1
EOF

# Prepare locales and keymap
print 'Prepare locales and keymap'
echo 'en_US.UTF-8 UTF-8' > /mnt/etc/default/libc-locales
echo 'LANG="en_US.UTF-8"' > /mnt/etc/locale.conf

print 'Set timezone'
read -r -p "Enter timezone (e.g., Asia/Singapore): " timezone
timezone=${timezone:-"Asia/Singapore"}


# Configure system
cat >> /mnt/etc/rc.conf << EOF
TIMEZONE="$timezone"
HARDWARECLOCK="UTC"
EOF

# Configure dracut
print 'Configure dracut'
cat > /mnt/etc/dracut.conf.d/zfs.conf <<"EOF"
hostonly="yes"
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs resume "
install_items+=" /etc/zfs/zroot.key "
force_drivers+=" zfs "
filesystems+=" zfs "
EOF

### Configure username
print 'Set your username'
read -r -p "Username: " user

### Chroot
print 'Chroot to configure services'
chroot /mnt/ /bin/bash -e <<EOF
  set -e
  # Configure DNS
  resolvconf -u

  # Configure services
  ln -s /etc/sv/dhcpcd /etc/runit/runsvdir/default/
  ln -s /etc/sv/iwd /etc/runit/runsvdir/default/
  ln -s /etc/sv/chronyd /etc/runit/runsvdir/default/
  ln -s /etc/sv/crond /etc/runit/runsvdir/default/
  ln -s /etc/sv/dbus /etc/runit/runsvdir/default/
  ln -s /etc/sv/acpid /etc/runit/runsvdir/default/

  # Symlink for the timezone.
  ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime
  hwclock --systohc
  
  # Generates locales
  xbps-reconfigure -f glibc-locales

  # Add user
  zfs create zroot/data/home/${user}
  useradd -m -d /home/${user} -G network,wheel,socklog,video,audio,_seatd,input ${user}
  chown -R ${user}:${user} /home/${user}
  
  # Enable swap in chroot.
  if [[ -f /tmp/swap_created ]] && [[ "\$(cat /tmp/swap_created)" == "true" ]]; then
    swapon /dev/zvol/zroot/swap
  fi
EOF

# Configure fstab
print 'Configure fstab'
EFI_UUID=$(blkid -s UUID -o value "$EFI")
cat > /mnt/etc/fstab <<EOF
UUID=$EFI_UUID /boot/efi vfat defaults 0 2
tmpfs     /dev/shm                  tmpfs     rw,nosuid,nodev,noexec,inode64  0 0
tmpfs     /tmp                      tmpfs     defaults,nosuid,nodev           0 0
efivarfs  /sys/firmware/efi/efivars efivarfs  defaults                        0 0
EOF

# Add swap entry only if created
if [[ -f /tmp/swap_created ]] && [[ "$(cat /tmp/swap_created)" == "true" ]]; then
    echo "/dev/zvol/zroot/swap none swap defaults 0 0" >> /mnt/etc/fstab
fi

# Set root passwd
print 'Set root password'
chroot /mnt /bin/passwd
 
# Set user passwd
print 'Set user password'
chroot /mnt /bin/passwd "$user"

# Configure sudo
print 'Configure sudo'
cat > /mnt/etc/sudoers <<EOF
root ALL=(ALL) ALL
$user ALL=(ALL) ALL
Defaults rootpw
EOF

### Configure zfsbootmenu

# Create dirs
mkdir -p /mnt/boot/efi/EFI/ZBM /mnt/etc/zfsbootmenu/dracut.conf.d

# Generate zfsbootmenu efi
print 'Configure zfsbootmenu'
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
  CommandLine: ro quiet loglevel=0
  Prefix: vmlinuz
EOF

# Add keymap to dracut
cat > /mnt/etc/zfsbootmenu/dracut.conf.d/keymap.conf <<EOF
install_optional_items+=" /etc/cmdline.d/keymap.conf "
EOF

mkdir -p /mnt/etc/cmdline.d/
cat > /mnt/etc/cmdline.d/keymap.conf <<EOF
rd.vconsole.keymap=en
EOF

# Set cmdline
zfs set org.zfsbootmenu:commandline="ro quiet nowatchdog net.ifnames=0 zswap.enabled=0" zroot/ROOT/"$root_dataset"

# Generate ZBM
print 'Generate zbm'
chroot /mnt/ /bin/bash -e <<"EOF"

  # Export locale
  export LANG="en_US.UTF-8"

  # Generate initramfs, zfsbootmenu
  xbps-reconfigure -fa
EOF

# Set DISK
if [[ -f /tmp/disk ]]
then
  DISK=$(cat /tmp/disk)
else
  print 'Select the disk you installed on:'
  select ENTRY in $(ls /dev/disk/by-id/);
  do
      DISK="/dev/disk/by-id/$ENTRY"
      echo "Creating boot entries on $ENTRY."
      break
  done
fi

# Create UEFI entries
print 'Create efi boot entries'
modprobe efivarfs
mountpoint -q /sys/firmware/efi/efivars \
    || mount -t efivarfs efivarfs /sys/firmware/efi/efivars

# Validate EFI files exist before creating entries
if [[ ! -f /mnt/boot/efi/EFI/ZBM/vmlinuz.efi ]]; then
    echo "ERROR: ZFSBootMenu EFI file not found!" >&2
    exit 1
fi

if [[ ! -f /mnt/boot/efi/EFI/ZBM/vmlinuz-backup.efi ]]; then
    echo "WARNING: ZFSBootMenu backup EFI file not found!"
    echo "Creating backup copy..."
    cp /mnt/boot/efi/EFI/ZBM/vmlinuz.efi /mnt/boot/efi/EFI/ZBM/vmlinuz-backup.efi
fi

# Remove existing ZFSBootMenu entries
if efibootmgr | grep ZFSBootMenu; then
    for entry in $(efibootmgr | grep ZFSBootMenu | sed -E 's/Boot([0-9]+).*/\1/'); do   
        efibootmgr -B -b "$entry"
    done
fi

# Create new entries with error checking
if ! efibootmgr --disk "$DISK" \
  --part 1 \
  --create \
  --label "ZFSBootMenu Backup" \
  --loader "\EFI\ZBM\vmlinuz-backup.efi" \
  --verbose; then
    echo "ERROR: Failed to create backup boot entry!" >&2
fi

if ! efibootmgr --disk "$DISK" \
  --part 1 \
  --create \
  --label "ZFSBootMenu" \
  --loader "\EFI\ZBM\vmlinuz.efi" \
  --verbose; then
    echo "ERROR: Failed to create main boot entry!" >&2
    exit 1
fi

# Umount all parts
print 'Umount all parts'
umount /mnt/boot/efi
umount -l /mnt/{dev,proc,sys}
zfs umount -a

# Export zpool
print 'Export zpool'
zpool export zroot

# Finish
echo -e '\e[32mAll OK\033[0m'
print "Installation complete. You may reboot with:"
echo -e "\n  umount -R /mnt && reboot\n"     