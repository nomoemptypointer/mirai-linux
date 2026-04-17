#!/usr/bin/env bash
set -euo pipefail

# TODO: Improve this script

cat <<'EOF'
 ███▄ ▄███▓ ██▓ ██▀███   ▄▄▄       ██▓
▓██▒▀█▀ ██▒▓██▒▓██ ▒ ██▒▒████▄    ▓██▒
▓██    ▓██░▒██▒▓██ ░▄█ ▒▒██  ▀█▄  ▒██▒
▒██    ▒██ ░██░▒██▀▀█▄  ░██▄▄▄▄██ ░██░
▒██▒   ░██▒░██░░██▓ ▒██▒ ▓█   ▓██▒░██░
░ ▒░   ░  ░░▓  ░ ▒▓ ░▒▓░ ▒▒   ▓▒█░░▓  
░  ░      ░ ▒ ░  ░▒ ░ ▒░  ▒   ▒▒ ░ ▒ ░
░      ░    ▒ ░  ░░   ░   ░   ▒    ▒ ░
       ░    ░     ░           ░  ░ ░   Live Image Builder
EOF

source ./config.sh
rm -rf builds-cache/*
mkdir -p ${LOCAL_IMAGE_MOUNTPOINT}
mkdir -p builds builds-cache builds-cache/initramfs
mkdir -p builds-cache/initramfs/{proc,sys,tmp,lib,dev,etc/network,usr/share/udhcpc}

CACHE_IMAGE_PATH=./builds-cache/boot.img

if mountpoint -q "${LOCAL_IMAGE_MOUNTPOINT}"; then
    echo "Unmounting ${LOCAL_IMAGE_MOUNTPOINT}"
    umount -R "${LOCAL_IMAGE_MOUNTPOINT}"
else
    echo "${LOCAL_IMAGE_MOUNTPOINT} is not mounted"
fi

truncate -s $IMAGE_SIZE "$CACHE_IMAGE_PATH" # Create blank disk image
LOOPDEV=$(losetup --show --find "$CACHE_IMAGE_PATH") # Set up loop device with partitions

# Partition the image
echo -e "o\ny\nn\n1\n\n+128M\nef00\nn\n2\n\n\n8300\nw\ny" | gdisk "$LOOPDEV"
#o  # Create a new GPT partition table
#y  # Confirm the deletion of existing partitions (if any)
#n  # Create a new partition
#1  # Partition number (1 for EFI)
  # First sector (default)
#+128M  # Partition size (128MB for EFI)
#ef00  # Partition type (EFI System)
#n  # Create another partition
#2  # Partition number (2 for root)
#  # First sector (default)
#  # Partition size (remaining space)
#8300  # Partition type (Linux filesystem)
#w  # Write the changes

losetup -d "${LOOPDEV}" # Detach the loop device

LOOPDEV=$(losetup --find --show --partscan "$CACHE_IMAGE_PATH") # Reattach the loop device with partscan

# Format the partitions
mkfs.vfat -F 32 "${LOOPDEV}p1"
mkfs.ext4 "${LOOPDEV}p2"

# Mount rootfs
mount "${LOOPDEV}p2" "$LOCAL_IMAGE_MOUNTPOINT"

# Now create the boot/EFI mount point *inside* the mounted root
mkdir -p "$EFI_PATH"

# Mount the EFI System Partition
mount "${LOOPDEV}p1" "$EFI_PATH"

# Clone required repos
if [ ! -d linux ]; then
    git clone --depth 1 --branch v6.6 https://github.com/torvalds/linux.git
fi

if [ ! -d busybox ]; then
    git clone --depth 1 https://git.busybox.net/busybox.git
fi

if [ ! -d glibc ]; then
    git clone --depth 1 https://github.com/bminor/glibc.git
fi

cp -a "./linux-config/.config" "./linux/.config"
cp -a "./busybox-config/.config" "./busybox/.config"

# Build the kernel
cd linux
    make -j"$(nproc)"
cd ..

# Copy built kernel image
BZIMAGE_SOURCE="linux/arch/x86/boot/bzImage"
BZIMAGE_TARGET="builds-cache/bzImage"
if [ -f "$BZIMAGE_SOURCE" ]; then
    cp -a "$BZIMAGE_SOURCE" "$BZIMAGE_TARGET"
else
    echo "Kernel image not found: $BZIMAGE_SOURCE"
    exit 1
fi

# Build glibc (required by almost all linux programs)
cd glibc
    mkdir -p build
        cd build
        ../configure \
            --prefix=/usr \
            --disable-multilib \
            --enable-static \
            --disable-nls \
            CC="gcc" CFLAGS="-Os -s" # "gcc -m32" if building for 32bit
        make -j$(nproc)
        make DESTDIR=$(pwd)/install install
        echo "Stripping glibc symbols..."
        find ./install -type f -name "*.so*" -exec file {} \; | grep ELF | cut -d: -f1 | xargs strip --strip-unneeded
        find ./install -type f -executable -exec file {} \; | grep ELF | cut -d: -f1 | xargs strip --strip-all
        echo "Pruning glibc locales, timezones, and NSS modules..."
        rm -rf ./install/usr/share/locale/*
        rm -rf ./install/usr/lib/gconv/*
        rm -rf ./install/usr/lib/*nss*
    cd ../..
cp -a glibc/build/install/* "./builds-cache/initramfs/"

# Build busybox into the initramfs
cd busybox
    make -j"$(nproc)"
    make CONFIG_PREFIX=../builds-cache/initramfs install
cd ..

# Create necessary device nodes
cd builds-cache/initramfs
    sudo mknod -m 622 dev/console c 5 1
    sudo mknod -m 666 dev/null c 1 3
    sudo mknod -m 666 dev/zero c 1 5
    sudo mknod -m 666 dev/tty c 5 0
    sudo mknod -m 666 dev/tty0 c 4 0
    sudo mknod -m 666 dev/random c 1 8
    sudo mknod -m 666 dev/urandom c 1 9
    sudo mknod -m 600 dev/eth0 c 10 1

    ln -s /lib64/ld-linux-x86-64.so.2 lib/ld-linux-x86-64.so.2
    ln -s /lib64/libm.so.6 lib/libm.so.6
    ln -s /lib64/libresolv.so.2 lib/libresolv.so.2
    ln -s /lib64/libc.so.6 lib/libc.so.6
cd ../..

# Set hosts
# 127.0.0.1 is also hostname but idk if it should be "mirai" here too
cat > builds-cache/initramfs/etc/hosts << EOF
127.0.0.1  localhost
::1        localhost
EOF

# Set up all the default users
cat > builds-cache/initramfs/etc/passwd << "EOF"
root:x:0:0:root:/root:/bin/sh
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF

# Set up all the default groups
cat > builds-cache/initramfs/etc/group << "EOF"
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
usb:x:14:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
input:x:24:
mail:x:34:
kvm:x:61:
uuidd:x:80:
wheel:x:97:
users:x:999:
nogroup:x:65534:
EOF

# Set cloudflare as default DNS server
cat > builds-cache/initramfs/etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF
chmod +x builds-cache/initramfs/etc/resolv.conf

# Copy init script into initramfs
cp -a "./initscript/init" "./builds-cache/initramfs/init"
chmod +x ./builds-cache/initramfs/init

# Not needed
rm ./builds-cache/initramfs/linuxrc

# Pack initramfs into init.cpio
(cd ./builds-cache/initramfs/ && find . -print0 | cpio --null -ov --format=newc) > ./builds-cache/init.cpio

# Install GRUB
grub-install \
  --target=x86_64-efi \
  --efi-directory="$EFI_PATH" \
  --boot-directory="$LOCAL_IMAGE_MOUNTPOINT/boot" \
  --bootloader-id=GRUB \
  --removable \
  --recheck

mkdir -p $LOCAL_IMAGE_MOUNTPOINT/boot/grub/x86_64-efi/
cp -a -r /usr/lib/grub/x86_64-efi/*.mod "$LOCAL_IMAGE_MOUNTPOINT/boot/grub/x86_64-efi/"

ESP_UUID=$(blkid -s UUID -o value "${LOOPDEV}p1")
echo "ESP partition UUID is $ESP_UUID"
export ESP_UUID
ROOT_UUID=$(blkid -s UUID -o value "${LOOPDEV}p2")
echo "Root partition UUID is $ROOT_UUID"
export ROOT_UUID

# Generate the GRUB config
mkdir -p "$LOCAL_IMAGE_MOUNTPOINT/boot/grub"
envsubst '$ROOT_UUID' < ./grub-config/live.cfg > "$LOCAL_IMAGE_MOUNTPOINT/boot/grub/grub.cfg"

cp -a ./builds-cache/bzImage $LOCAL_IMAGE_MOUNTPOINT/boot/vmlinuz
cp -a ./builds-cache/init.cpio $LOCAL_IMAGE_MOUNTPOINT/boot/initrd.img

umount -R "$LOCAL_IMAGE_MOUNTPOINT"
losetup -d "$LOOPDEV"

echo "Copying built image to ./builds/$IMAGE_FILENAME"
cp -a "./builds-cache/boot.img" "./builds/$IMAGE_FILENAME"
echo "Done"