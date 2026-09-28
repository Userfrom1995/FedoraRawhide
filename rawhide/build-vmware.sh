#!/bin/bash
# Fedora Rawhide VMware OVA / VMDK builder and packager.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$SCRIPT_DIR/build-vmware-tmp"
EXPORT_DIR="$WORK_DIR/rootfs"
OVERLAY_DIR="$SCRIPT_DIR/vmware-overlay"
OUTPUT_OVA="$SCRIPT_DIR/Fedora-Rawhide-VMware.ova"
OUTPUT_VMDK="$SCRIPT_DIR/Fedora-Rawhide-VMware.vmdk"
RELEASE_VER="rawhide"
OWNER_UID="$(id -u)"
OWNER_GID="$(id -g)"

# Use sudo when running as regular user, skip when already root.
SUDO=""
if [ "$OWNER_UID" -ne 0 ]; then SUDO="sudo"; fi

cleanup() {
    echo "Cleaning up build directory..."
    if [ -d "$EXPORT_DIR" ]; then
        $SUDO umount "$EXPORT_DIR/dev" 2>/dev/null || true
        $SUDO umount "$EXPORT_DIR/sys" 2>/dev/null || true
        $SUDO umount "$EXPORT_DIR/proc" 2>/dev/null || true
    fi
    if [ -d "$WORK_DIR" ]; then
        $SUDO rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT INT TERM

# Ensure required host packages/tools are available
echo "Checking required host tools..."
NEEDED_TOOLS=()
command -v qemu-img >/dev/null 2>&1 || NEEDED_TOOLS+=(qemu-img)
command -v sfdisk >/dev/null 2>&1 || NEEDED_TOOLS+=(util-linux)
command -v mkfs.vfat >/dev/null 2>&1 || NEEDED_TOOLS+=(dosfstools)
command -v mcopy >/dev/null 2>&1 || NEEDED_TOOLS+=(mtools)
command -v mke2fs >/dev/null 2>&1 || NEEDED_TOOLS+=(e2fsprogs)

if [ "${#NEEDED_TOOLS[@]}" -gt 0 ]; then
    echo "Installing missing host tools: ${NEEDED_TOOLS[*]}..."
    $SUDO dnf5 install -y --setopt=install_weak_deps=False "${NEEDED_TOOLS[@]}"
fi

if [ ! -d /usr/share/distribution-gpg-keys/fedora ]; then
    echo "Installing distribution-gpg-keys..."
    $SUDO dnf5 install -y --setopt=install_weak_deps=False distribution-gpg-keys
fi

echo "Creating build workspace in $WORK_DIR..."
$SUDO rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$EXPORT_DIR"

# Bootstrap rpmdb and import the current Rawhide signing key
$SUDO rpm --root "$EXPORT_DIR" --initdb
$SUDO rpm --root "$EXPORT_DIR" --import /usr/share/distribution-gpg-keys/fedora/RPM-GPG-KEY-fedora-rawhide-primary

echo "Initializing rootfs with fedora-release and fedora-repos..."
$SUDO dnf5 install --installroot="$EXPORT_DIR" \
  --use-host-config \
  --releasever="$RELEASE_VER" \
  --setopt=install_weak_deps=False \
  --disablerepo="*" --enablerepo="rawhide" \
  --nodocs -y fedora-release fedora-repos

echo "Installing base packages, kernel, bootloader, and VMware tools..."
$SUDO dnf5 install --installroot="$EXPORT_DIR" \
  --use-host-config \
  --releasever="$RELEASE_VER" \
  --setopt=install_weak_deps=False \
  --disablerepo="*" --enablerepo="rawhide" \
  --nodocs -y \
  @core sudo passwd shadow-utils util-linux dnf5 iputils cracklib-dicts \
  wget tar gzip findutils which procps-ng \
  dbus-broker dbus-daemon polkit systemd-pam \
  kernel-core kernel-modules dracut grub2-efi-x64 shim-x64 efibootmgr \
  open-vm-tools NetworkManager dosfstools e2fsprogs

# Verify essential files
if [ ! -f "$EXPORT_DIR/usr/bin/bash" ]; then
    echo "ERROR: /usr/bin/bash not found in rootfs! Build failed."
    exit 1
fi

KVER="$(ls -1 "$EXPORT_DIR/lib/modules" 2>/dev/null | sort -V | tail -n 1)"
if [ -z "$KVER" ]; then
    echo "ERROR: No kernel found in /lib/modules! Build failed."
    exit 1
fi
echo "Detected kernel version: $KVER"

# Apply overlay configuration
echo "Applying VMware overlay..."
if [ -d "$OVERLAY_DIR" ]; then
    $SUDO cp -a "$OVERLAY_DIR"/. "$EXPORT_DIR"/
fi

# Ensure correct permissions on overlay files
$SUDO chmod 0440 "$EXPORT_DIR/etc/sudoers.d/99-fedora" 2>/dev/null || true
$SUDO chmod 0755 "$EXPORT_DIR/etc/profile.d/welcome-vmware.sh" 2>/dev/null || true

# Setup default fedora user with password fedora and sudo rights
echo "Setting up default 'fedora' user..."
$SUDO chroot "$EXPORT_DIR" useradd -m -u 1000 -G wheel -s /bin/bash fedora 2>/dev/null || true
echo "fedora:fedora" | $SUDO chroot "$EXPORT_DIR" chpasswd
echo "root:fedora" | $SUDO chroot "$EXPORT_DIR" chpasswd

# Enable required system services
echo "Enabling system services..."
$SUDO chroot "$EXPORT_DIR" systemctl enable NetworkManager.service
$SUDO chroot "$EXPORT_DIR" systemctl enable vmtoolsd.service 2>/dev/null || \
$SUDO chroot "$EXPORT_DIR" systemctl enable open-vm-tools.service 2>/dev/null || true
$SUDO chroot "$EXPORT_DIR" systemctl enable systemd-resolved.service

# Generate generic (no-hostonly) initramfs with VMware storage/network drivers
echo "Generating generic initramfs for VMware..."
$SUDO mount -t proc proc "$EXPORT_DIR/proc"
$SUDO mount -t sysfs sys "$EXPORT_DIR/sys"
$SUDO mount --bind /dev "$EXPORT_DIR/dev"

$SUDO chroot "$EXPORT_DIR" dracut --force --no-hostonly "/boot/initramfs-${KVER}.img" "$KVER"

$SUDO umount "$EXPORT_DIR/dev" "$EXPORT_DIR/sys" "$EXPORT_DIR/proc"

# Generate filesystem UUIDs and /etc/fstab
echo "Generating fstab..."
ROOT_UUID="$(cat /proc/sys/kernel/random/uuid)"
ESP_UUID="4A2B-1C3D"

cat <<EOF | $SUDO tee "$EXPORT_DIR/etc/fstab" > /dev/null
# /etc/fstab: static file system information.
UUID=${ROOT_UUID}  /          ext4  defaults,noatime  0  1
UUID=${ESP_UUID}   /boot/efi  vfat  umask=0077,shortname=winnt  0  2
EOF

# Setup GRUB2 configuration and fallback UEFI bootloader
echo "Configuring GRUB2 EFI bootloader..."
$SUDO mkdir -p "$EXPORT_DIR/boot/grub2" "$EXPORT_DIR/boot/efi/EFI/fedora" "$EXPORT_DIR/boot/efi/EFI/BOOT"

cat <<EOF | $SUDO tee "$EXPORT_DIR/boot/grub2/grub.cfg" > /dev/null
set default=0
set timeout=3

insmod part_gpt
insmod ext2
insmod fat

search --no-floppy --fs-uuid --set=root ${ROOT_UUID}

menuentry "Fedora Rawhide" {
    linux /boot/vmlinuz-${KVER} root=UUID=${ROOT_UUID} ro quiet rhgb console=tty1
    initrd /boot/initramfs-${KVER}.img
}
EOF

$SUDO cp -p "$EXPORT_DIR/boot/grub2/grub.cfg" "$EXPORT_DIR/boot/efi/EFI/fedora/grub.cfg"
$SUDO cp -p "$EXPORT_DIR/boot/grub2/grub.cfg" "$EXPORT_DIR/boot/efi/EFI/BOOT/grub.cfg"

# Provide fallback boot binary for generic UEFI firmware boot
if [ -f "$EXPORT_DIR/boot/efi/EFI/fedora/shimx64.efi" ]; then
    $SUDO cp -p "$EXPORT_DIR/boot/efi/EFI/fedora/shimx64.efi" "$EXPORT_DIR/boot/efi/EFI/BOOT/BOOTX64.EFI"
fi
if [ -f "$EXPORT_DIR/boot/efi/EFI/fedora/grubx64.efi" ]; then
    $SUDO cp -p "$EXPORT_DIR/boot/efi/EFI/fedora/grubx64.efi" "$EXPORT_DIR/boot/efi/EFI/BOOT/grubx64.efi"
fi

# Clean up dnf cache
echo "Cleaning up rootfs cache..."
$SUDO dnf5 --installroot="$EXPORT_DIR" clean all
$SUDO rm -rf "$EXPORT_DIR/var/cache/dnf" "$EXPORT_DIR/var/cache/libdnf5"

# Assembling Virtual Disk (without requiring loop devices)
echo "Assembling disk partitions..."
ESP_IMG="$WORK_DIR/esp.img"
ROOT_IMG="$WORK_DIR/root.img"
RAW_DISK="$WORK_DIR/disk.raw"

# 1. Format ESP (512MB FAT32) and copy EFI tree into it
echo "Formatting EFI System Partition..."
mkfs.vfat -F 32 -i "${ESP_UUID//-/}" -C "$ESP_IMG" 524288
mcopy -s -p -i "$ESP_IMG" "$EXPORT_DIR/boot/efi/EFI" ::/

# Empty the /boot/efi directory in rootfs so mount point is clean
$SUDO rm -rf "$EXPORT_DIR/boot/efi"/*

# 2. Format ext4 root partition (19.5 GB sparse)
echo "Formatting ext4 root filesystem from rootfs..."
$SUDO mke2fs -t ext4 -U "$ROOT_UUID" -d "$EXPORT_DIR" "$ROOT_IMG" 19960M
$SUDO chown "$OWNER_UID:$OWNER_GID" "$ROOT_IMG"

# 3. Create 20GB sparse raw disk image and partition with GPT
echo "Creating partitioned raw disk image..."
truncate -s 20480M "$RAW_DISK"

sfdisk "$RAW_DISK" <<EOF
label: gpt
first-lba: 2048
start=2048, size=1048576, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI System Partition"
start=1050624, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name="Root"
EOF

# Copy partitions into place preserving sparseness
echo "Writing partitions into raw disk..."
dd if="$ESP_IMG" of="$RAW_DISK" bs=1M seek=1 conv=notrunc,sparse status=none
dd if="$ROOT_IMG" of="$RAW_DISK" bs=1M seek=513 conv=notrunc,sparse status=none

# Convert to Stream-Optimized VMDK
echo "Converting raw disk to stream-optimized VMDK: $OUTPUT_VMDK..."
rm -f "$OUTPUT_VMDK"
qemu-img convert -O vmdk -o subformat=streamOptimized "$RAW_DISK" "$OUTPUT_VMDK"
$SUDO chown "$OWNER_UID:$OWNER_GID" "$OUTPUT_VMDK"
chmod 0644 "$OUTPUT_VMDK"

# Package into OVA appliance
echo "Packaging OVA appliance: $OUTPUT_OVA..."
OVA_STAGING="$WORK_DIR/ova_stage"
mkdir -p "$OVA_STAGING"
cp "$OUTPUT_VMDK" "$OVA_STAGING/fedora-rawhide-disk1.vmdk"

VMDK_SIZE="$(stat -c %s "$OVA_STAGING/fedora-rawhide-disk1.vmdk")"

cat <<EOF > "$OVA_STAGING/fedora-rawhide.ovf"
<?xml version="1.0" encoding="UTF-8"?>
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:cim="http://schemas.dmtf.org/wbem/wscim/1/common"
          xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
          xmlns:vmw="http://www.vmware.com/schema/ovf"
          xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <References>
    <File ovf:href="fedora-rawhide-disk1.vmdk" ovf:id="file1" ovf:size="${VMDK_SIZE}"/>
  </References>
  <DiskSection>
    <Info>Virtual disk information</Info>
    <Disk ovf:capacity="20480" ovf:capacityAllocationUnits="byte * 2^20" ovf:diskId="vmdisk1" ovf:fileRef="file1" ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamVmdk"/>
  </DiskSection>
  <NetworkSection>
    <Info>The list of logical networks</Info>
    <Network ovf:name="nat">
      <Description>NAT Network</Description>
    </Network>
  </NetworkSection>
  <VirtualSystem ovf:id="Fedora-Rawhide">
    <Info>Fedora Rawhide VMware Virtual Machine</Info>
    <Name>Fedora-Rawhide</Name>
    <OperatingSystemSection ovf:id="101" vmw:osType="fedora64Guest">
      <Info>The kind of installed guest operating system</Info>
      <Description>Fedora (64-bit)</Description>
    </OperatingSystemSection>
    <VirtualHardwareSection ovf:transport="iso">
      <Info>Virtual hardware requirements</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemIdentifier>Fedora-Rawhide</vssd:VirtualSystemIdentifier>
        <vssd:VirtualSystemType>vmx-19</vssd:VirtualSystemType>
      </System>
      <Item>
        <rasd:AllocationUnits>hertz * 10^6</rasd:AllocationUnits>
        <rasd:Description>Number of Virtual CPUs</rasd:Description>
        <rasd:ElementName>2 virtual CPU(s)</rasd:ElementName>
        <rasd:InstanceID>1</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>2</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits>
        <rasd:Description>Memory Size</rasd:Description>
        <rasd:ElementName>4096MB of memory</rasd:ElementName>
        <rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>4096</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:Address>0</rasd:Address>
        <rasd:Description>SCSI Controller</rasd:Description>
        <rasd:ElementName>scsiController0</rasd:ElementName>
        <rasd:InstanceID>3</rasd:InstanceID>
        <rasd:ResourceSubType>lsilogicsas</rasd:ResourceSubType>
        <rasd:ResourceType>6</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:Description>Hard Disk Image</rasd:Description>
        <rasd:ElementName>harddisk0</rasd:ElementName>
        <rasd:HostResource>ovf:/disk/vmdisk1</rasd:HostResource>
        <rasd:InstanceID>4</rasd:InstanceID>
        <rasd:Parent>3</rasd:Parent>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AddressOnParent>1</rasd:AddressOnParent>
        <rasd:AutomaticAllocation>true</rasd:AutomaticAllocation>
        <rasd:Connection>nat</rasd:Connection>
        <rasd:Description>Ethernet Adapter</rasd:Description>
        <rasd:ElementName>ethernet0</rasd:ElementName>
        <rasd:InstanceID>5</rasd:InstanceID>
        <rasd:ResourceSubType>VMXNET3</rasd:ResourceSubType>
        <rasd:ResourceType>10</rasd:ResourceType>
      </Item>
      <vmw:Config ovf:required="false" vmw:key="firmware" vmw:value="efi"/>
    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>
EOF

(
    cd "$OVA_STAGING"
    OVF_HASH="$(sha256sum fedora-rawhide.ovf | awk '{print $1}')"
    VMDK_HASH="$(sha256sum fedora-rawhide-disk1.vmdk | awk '{print $1}')"
    cat <<EOF > fedora-rawhide.mf
SHA256(fedora-rawhide.ovf)= ${OVF_HASH}
SHA256(fedora-rawhide-disk1.vmdk)= ${VMDK_HASH}
EOF
    rm -f "$OUTPUT_OVA"
    tar -cf "$OUTPUT_OVA" fedora-rawhide.ovf fedora-rawhide.mf fedora-rawhide-disk1.vmdk
)

$SUDO chown "$OWNER_UID:$OWNER_GID" "$OUTPUT_OVA"
chmod 0644 "$OUTPUT_OVA"

echo
echo "=========================================================="
echo " VMware build completed successfully!"
echo " • OVA Appliance: $OUTPUT_OVA"
echo " • VMDK Disk:     $OUTPUT_VMDK"
echo "=========================================================="
