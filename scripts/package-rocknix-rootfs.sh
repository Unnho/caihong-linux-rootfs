#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Ahaan <ahaan.c@icloud.com>
#
# Assemble a direct-root ROCKNIX image for the OnePlus Pad Pro (caihong).
#
# ROCKNIX is Buildroot-based and normally boots a squashfs SYSTEM payload from
# a FAT partition through its own initramfs.  This builder unpacks the pinned
# upstream SYSTEM payload, installs the Caihong kernel modules and platform
# runtime, and repacks the result as an ext4 image labelled "linux".  The image
# therefore flashes exactly like the Arch Linux ARM and Armada images and boots
# from the same Android boot images.
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=../config/rocknix.env
# shellcheck disable=SC1091
source "$project_dir/config/rocknix.env"

output=${1:-"$project_dir/caihong-rocknix-rootfs.img"}
rocknix_tar=${ROCKNIX_IMAGE_TAR:-"$project_dir/downloads/$ROCKNIX_IMAGE_NAME"}
module_tree=${MODULE_TREE:-"$project_dir/modules-current"}
release_dir=${RELEASE_DIR:-"$project_dir/release"}
platform_package=${CAIHONG_PLATFORM_PACKAGE:-}
# The image is flashed straight into a fixed-size Android partition, so it must
# stay smaller than the smallest supported one (a 7.5 GB decimal "linux"
# partition).  First boot grows the filesystem to fill the partition anyway.
image_min_free_mib=${IMAGE_MIN_FREE_MIB:-512}
image_slack_percent=${IMAGE_SLACK_PERCENT:-5}
sparse_image=${SPARSE_IMAGE:-1}

fail()
{
	echo "package-rocknix-rootfs: $*" >&2
	exit 1
}

if (( EUID != 0 )); then
	fail "run this script as root"
fi
case "$image_min_free_mib:$image_slack_percent:$sparse_image" in
	*[!0-9:]*|:*|*:) fail "invalid image sizing option" ;;
esac
(( image_min_free_mib >= 512 )) || fail "IMAGE_MIN_FREE_MIB must be at least 512"
(( image_slack_percent >= 5 )) || fail "IMAGE_SLACK_PERCENT must be at least 5"
[[ $sparse_image == 0 || $sparse_image == 1 ]] || fail "SPARSE_IMAGE must be 0 or 1"

required_tools=(blkid bsdtar chroot debugfs depmod du e2fsck find img2simg
	kmod mkfs.ext4 mount mountpoint rsync sha256sum systemctl tar truncate
	umount unsquashfs)
for tool in "${required_tools[@]}"; do
	command -v "$tool" >/dev/null 2>&1 || fail "missing host tool: $tool"
done
[[ -d $module_tree/lib/modules ]] || fail "missing module tree: $module_tree"
[[ -f $release_dir/KERNEL_RELEASE ]] || fail "missing release/KERNEL_RELEASE"

resolve_input()
{
	local input=$1 label=$2
	input=$(cd -- "$(dirname -- "$input")" && pwd)/${input##*/}
	[[ -f $input ]] || fail "$label not found: $input"
	printf '%s\n' "$input"
}

platform_pointer=$release_dir/CAIHONG_PLATFORM_PACKAGE_ROCKNIX
[[ -f $platform_pointer ]] || fail "missing ROCKNIX platform package pointer"
[[ -n $platform_package ]] || platform_package=$release_dir/$(<"$platform_pointer")
platform_package=$(resolve_input "$platform_package" platform package)

kernel_release=$(<"$release_dir/KERNEL_RELEASE")
[[ -d $module_tree/lib/modules/$kernel_release ]] || \
	fail "module tree does not contain $kernel_release"

payload_distribution=$(bsdtar -xOf "$platform_package" \
	usr/share/caihong-platform/distribution)
[[ $payload_distribution == rocknix ]] || \
	fail "platform package targets $payload_distribution, expected rocknix"
payload_libdir=$(bsdtar -xOf "$platform_package" usr/share/caihong-npu/libdir)
[[ $payload_libdir == lib ]] || \
	fail "NPU package uses $payload_libdir, expected lib"

mkdir -p "$(dirname -- "$rocknix_tar")" "$project_dir/downloads"
if [[ ! -f $rocknix_tar ]]; then
	command -v curl >/dev/null 2>&1 || fail "missing host tool: curl"
	temporary="$rocknix_tar.part"
	rm -f -- "$temporary"
	curl -fL --retry 4 --retry-delay 2 -o "$temporary" "$ROCKNIX_IMAGE_URL" || {
		rm -f -- "$temporary"
		fail "failed to download $ROCKNIX_IMAGE_URL"
	}
	mv -- "$temporary" "$rocknix_tar"
fi
if [[ -n ${ROCKNIX_IMAGE_SHA256:-} ]]; then
	actual=$(sha256sum "$rocknix_tar" | awk '{ print $1 }')
	[[ $actual == "$ROCKNIX_IMAGE_SHA256" ]] || \
		fail "ROCKNIX image checksum mismatch: $actual"
fi

output_dir=$(dirname -- "$output")
mkdir -p "$output_dir" "$project_dir/build"
output_dir=$(cd -- "$output_dir" && pwd)
output="$output_dir/$(basename -- "$output")"
temporary="$output.part"
if [[ -e $output || -e $temporary ]]; then
	[[ ${FORCE:-0} == 1 ]] || {
		echo "refusing to overwrite existing output: $output" >&2
		echo "set FORCE=1 to replace it, or choose another output path" >&2
		exit 1
	}
	rm -f -- "$output" "$temporary"
fi

work_dir=$(mktemp -d "$project_dir/build/rocknixroot-package.XXXXXX")
rootfs="$work_dir/rootfs"
image_mount="$work_dir/image-mount"
raw_image="$work_dir/rootfs.raw.img"
image_mounted=0

cleanup()
{
	status=$?
	trap - EXIT HUP INT TERM
	if (( image_mounted )) && mountpoint -q "$image_mount"; then
		umount "$image_mount" || true
	fi
	rm -f -- "$temporary"
	rm -rf -- "$work_dir"
	exit "$status"
}
trap cleanup EXIT HUP INT TERM

echo "extracting ROCKNIX $ROCKNIX_RELEASE SYSTEM payload"
system_image="$work_dir/SYSTEM"
tar -xf "$rocknix_tar" -C "$work_dir" --strip-components=2 \
	--wildcards '*/target/SYSTEM'
[[ -f $system_image ]] || fail "ROCKNIX archive does not contain target/SYSTEM"
unsquashfs -no-progress -d "$rootfs" "$system_image" >/dev/null
grep -qx 'OS_NAME="ROCKNIX"' "$rootfs/etc/os-release" || \
	fail "extracted payload is not ROCKNIX"
grep -qx "HW_DEVICE=\"$ROCKNIX_SOC\"" "$rootfs/etc/os-release" || \
	fail "ROCKNIX payload does not target $ROCKNIX_SOC"

# ROCKNIX points many /etc entries at /storage and at its runtime mounts with
# absolute links.  The staging tree is assembled on the host, where such links
# resolve outside the image, so rewrite them relative to their own directory.
# They still resolve to the same paths once the image is booted.
normalize_etc_links()
{
	while IFS= read -r -d '' link; do
		link_target=$(readlink -- "$link")
		[[ $link_target == /* ]] || continue
		parent=${link%/*}
		# Strip symlinks: an absolute link such as /etc/firmware points at
		# /usr/lib/firmware, which is itself an absolute link into the
		# initramfs overlay.  Following that chain would resolve against the
		# host root and bake host paths into the image.
		relative=$(realpath -ms --relative-to="$parent" "$rootfs$link_target")
		ln -sfn -- "$relative" "$link"
	done < <(find "$rootfs/etc" -type l -print0)
}
normalize_etc_links

# These storage-backed directories receive Caihong configuration during the
# build.  Create them first so the rewritten links can be followed safely.
install -d -m 0755 "$rootfs/storage/.cache" \
	"$rootfs/storage/.config/modules-load.d" \
	"$rootfs/storage/.config/udev.rules.d"

echo "installing Caihong kernel modules for $kernel_release"
# ROCKNIX provides /lib as an absolute symlink to /usr/lib.  Installing
# straight into the staged tree would let that link resolve against the host,
# so stage the modules in a plain directory and copy them into /usr/lib.
module_stage="$work_dir/module-stage"
CAIHONG_EXPECTED_RELEASE=$kernel_release \
	"$project_dir/scripts/install-caihong-modules.sh" \
	"$module_tree" "$module_stage"
# /usr/lib/modules is another absolute link into the initramfs overlay.
if [[ -L $rootfs/usr/lib/modules || ! -d $rootfs/usr/lib/modules ]]; then
	rm -f -- "$rootfs/usr/lib/modules"
	install -d -m 0755 "$rootfs/usr/lib/modules"
fi
rsync -aHAX --numeric-ids "$module_stage/lib/modules/." \
	"$rootfs/usr/lib/modules/"
install -D -m 0644 "$module_stage/etc/modules-load.d/caihong.conf" \
	"$rootfs/etc/modules-load.d/caihong.conf"

# ROCKNIX resolves /usr/lib/firmware through an initramfs overlay.  A direct
# root has no initramfs, so replace the link with a real directory and keep the
# firmware that shipped in the base overlay.
if [[ -L $rootfs/usr/lib/firmware || ! -d $rootfs/usr/lib/firmware ]]; then
	rm -f -- "$rootfs/usr/lib/firmware"
	install -d -m 0755 "$rootfs/usr/lib/firmware"
	if [[ -d $rootfs/usr/lib/kernel-overlays/base/lib/firmware ]]; then
		cp -a "$rootfs/usr/lib/kernel-overlays/base/lib/firmware/." \
			"$rootfs/usr/lib/firmware/"
	fi
fi
# The base overlay kernel modules belong to the upstream ROCKNIX kernel and
# cannot be mixed with the Caihong module tree.
rm -rf -- "$rootfs/usr/lib/kernel-overlays"

echo "installing the Caihong platform payload"
bsdtar -xpf "$platform_package" -C "$rootfs"
CAIHONG_PLATFORM_ROOT="$rootfs" CAIHONG_PLATFORM_IMAGE_BUILD=1 \
	"$rootfs/usr/libexec/caihong-platform/configure-platform"
# The platform defaults add their own absolute links under /etc, so normalize
# the tree once more after they have been copied into place.
normalize_etc_links
[[ $(<"$rootfs/usr/share/caihong-platform/kernel-release") == "$kernel_release" ]] || \
	fail "platform payload does not match $kernel_release"

install -d -m 0755 "$rootfs/etc/ld.so.conf.d"
printf '/usr/local/lib\n' > "$rootfs/etc/ld.so.conf.d/caihong-platform.conf"
ldconfig -r "$rootfs"

# ROCKNIX normally receives its fstab from the initramfs and keeps /storage on
# a separate partition.  A direct root has /storage inside the rootfs, so bind
# it onto itself: rocknix-memory-manager (and the first-boot growth logic)
# require /storage to be a mount point.
cat > "$rootfs/etc/fstab" <<'EOF'
LABEL=linux / ext4 rw,noatime 0 1
/storage /storage none bind 0 0
EOF
printf 'caihong\n' > "$rootfs/etc/hostname"
# /etc/resolv.conf is an absolute symlink into ROCKNIX's runtime directory.
# Replace the link itself so the write cannot escape the staged rootfs.
rm -f -- "$rootfs/etc/resolv.conf"
printf '%s\n' 'nameserver 1.1.1.1' > "$rootfs/etc/resolv.conf"
ln -sfn ../usr/share/zoneinfo/Asia/Shanghai "$rootfs/etc/localtime"
printf 'root\n' > "$rootfs/etc/caihong-desktop-account"
install -d -m 0755 "$rootfs/usr/lib/linux-caihong"
printf '%s\n' "$kernel_release" > "$rootfs/usr/lib/linux-caihong/kernel-release"
rm -f -- "$rootfs/etc/machine-id"
: > "$rootfs/etc/machine-id"
install -d -m 0755 "$rootfs/storage/.cache" "$rootfs/storage/.config" \
	"$rootfs/storage/roms" "$rootfs/storage/.update"
# /etc/shadow is an absolute link to /storage/.cache/shadow, which usercache
# only populates later during boot.  Seed it from the packaged copy so that
# PAM consumers never see a dangling /etc/shadow during early startup.
if [[ -f $rootfs/usr/cache/shadow ]]; then
	cp -a "$rootfs/usr/cache/shadow" "$rootfs/storage/.cache/shadow"
fi

for line in 'ID=rocknix' 'ID_LIKE=libreelec' 'VARIANT="Caihong"' \
	'VARIANT_ID=caihong'; do
	grep -qx "$line" "$rootfs/etc/os-release" ||
		printf '%s\n' "$line" >> "$rootfs/etc/os-release"
done

enable_unit()
{
	local unit=$1
	systemctl --root="$rootfs" enable "$unit" >/dev/null || \
		fail "failed to enable $unit in the ROCKNIX rootfs"
}

for unit in caihong-adbd.service caihong-grow-rootfs.service \
	caihong-keyboard.service caihong-bluetooth-autostart.service \
	caihong-hardware-mac.service \
	caihong-mark-boot-successful.service caihong-ssc.service \
	caihong-pen-autoconnect.timer caihong-pen-charge.timer \
	caihong-pen-pair.timer; do
	enable_unit "$unit"
done
# The platforms that use SDDM get a display-manager alias from their packages.
# ROCKNIX starts its own session through rocknix.target, so never take over.
rm -f -- "$rootfs/etc/systemd/system/display-manager.service"

cat > "$rootfs/etc/caihong-rootfs-build-info" <<EOF
device=caihong
architecture=aarch64
distribution=rocknix
rocknix_release=$ROCKNIX_RELEASE
rocknix_device=$ROCKNIX_SOC
rocknix_image=$ROCKNIX_IMAGE_NAME
kernel_release=$kernel_release
boot_roots=PARTLABEL=linux,PARTLABEL=userdata
boot_kernel=android-boot-v2-direct-root
rootfs_update_mode=rebuilt-image
desktop_account=root
EOF
chmod 0644 "$rootfs/etc/caihong-rootfs-build-info"
: > "$rootfs/etc/machine-id"

# systemctl writes absolute enablement links under /etc; normalize them last.
normalize_etc_links

"$project_dir/scripts/verify-rocknix-rootfs.sh" "$rootfs"

# A directory listing can silently omit entries on a damaged or unusual host
# filesystem, which would ship an image without /usr/lib/modules and boot into
# a system with no Wi-Fi, Bluetooth or audio.  Check the payload explicitly in
# both the staging tree and, below, the final image.
verify_image_contents()
{
	local target=$1 relative count missing=0
	for relative in \
		"usr/lib/modules/$kernel_release/modules.dep" \
		"usr/lib/modules/$kernel_release/modules.builtin" \
		usr/lib/firmware/ath12k/WCN7850/hw2.0/caihong/amss.bin \
		usr/lib/firmware/qca/hmtbtfw20.tlv \
		etc/shadow etc/fstab etc/hostname \
		usr/lib/systemd/system/rocknix.target; do
		[[ -e $target/$relative ]] && continue
		echo "package-rocknix-rootfs: $target is missing /$relative" >&2
		missing=1
	done
	count=$(find "$target/usr/lib/modules/$kernel_release" -name '*.ko' \
		2>/dev/null | wc -l)
	if (( count < 1000 )); then
		echo "package-rocknix-rootfs: $target holds only $count kernel modules" >&2
		missing=1
	fi
	(( missing == 0 )) || {
		echo "package-rocknix-rootfs: refusing to build an incomplete image" >&2
		ls -la "$target/usr/lib" >&2 || true
		exit 1
	}
}

verify_image_contents "$rootfs"

echo "creating $output"
used_bytes=$(du -sx --block-size=1 "$rootfs" | awk 'NR == 1 { print $1 }')
percent_free=$((used_bytes * image_slack_percent / 100))
minimum_free=$((image_min_free_mib * 1024 * 1024))
if (( percent_free < minimum_free )); then
	free_bytes=$minimum_free
else
	free_bytes=$percent_free
fi
required_bytes=$((used_bytes + free_bytes))
round_bytes=$((256 * 1024 * 1024))
image_bytes=$(((required_bytes + round_bytes - 1) / round_bytes * round_bytes))

mkdir -p "$image_mount"
truncate -s "$image_bytes" "$raw_image"
mkfs.ext4 -q -F -L linux -m 0 \
	-E lazy_itable_init=0,lazy_journal_init=0 "$raw_image"
mount -o loop "$raw_image" "$image_mount"
image_mounted=1
rsync -aHAX --numeric-ids "$rootfs/" "$image_mount/"
verify_image_contents "$image_mount"
sync -f "$image_mount"
umount "$image_mount"
image_mounted=0
e2fsck -fy "$raw_image" >/dev/null
[[ $(blkid -s LABEL -o value "$raw_image") == linux ]] || \
	fail "generated ext4 image does not have LABEL=linux"
# Read the finished filesystem back with a second, independent tool so a lossy
# directory listing during the copy cannot go unnoticed.
debugfs -R "stat /usr/lib/modules/$kernel_release/modules.dep" "$raw_image" \
	2>/dev/null | grep -q '^Inode:' || \
	fail "generated image does not contain /usr/lib/modules/$kernel_release/modules.dep"

rm -f -- "$temporary"
if [[ $sparse_image == 1 ]]; then
	img2simg "$raw_image" "$temporary"
else
	mv -- "$raw_image" "$temporary"
fi
mv -- "$temporary" "$output"
trap - EXIT HUP INT TERM
rm -rf -- "$work_dir"

echo "created $output"
echo "ROCKNIX source: $ROCKNIX_IMAGE_NAME"
echo "ext4 logical size: $image_bytes bytes"
du -h "$output"
sha256sum "$output"
