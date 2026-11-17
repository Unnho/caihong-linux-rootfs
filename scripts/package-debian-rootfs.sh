#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Ahaan <ahaan.c@icloud.com>
#
# Assemble a bootable Debian rootfs for the OnePlus Pad Pro (caihong).
# The image uses the same direct-root Android boot images as the Arch Linux
# ARM and Armada images, so it flashes to the "linux" or "userdata" partition
# without a separate bootloader.
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=../config/debian.env
# shellcheck disable=SC1091
source "$project_dir/config/debian.env"

output=${1:-"$project_dir/caihong-debian-rootfs.img"}
module_tree=${MODULE_TREE:-"$project_dir/modules-current"}
release_dir=${RELEASE_DIR:-"$project_dir/release"}
platform_package=${CAIHONG_PLATFORM_PACKAGE:-}
kernel_deb=${KERNEL_DEB:-}
account=${DEBIAN_ACCOUNT:-caihong}
image_min_free_mib=${IMAGE_MIN_FREE_MIB:-2048}
image_slack_percent=${IMAGE_SLACK_PERCENT:-25}
sparse_image=${SPARSE_IMAGE:-1}

packages=(
	bash coreutils findutils systemd systemd-sysv util-linux kmod
	sudo locales tzdata ca-certificates curl rsync zstd less nano htop
	network-manager wpasupplicant hostapd dnsmasq-base nftables iw
	iproute2 wireless-regdb bluez polkitd openssh-server
	usbutils pciutils i2c-tools ethtool evtest strace lsof tcpdump
	plasma-desktop plasma-workspace sddm konsole dolphin
	mesa-utils vulkan-tools libgl1-mesa-dri libegl-mesa0 libgles2
	libdrm2 libva2 vainfo
	pipewire pipewire-pulse wireplumber alsa-utils v4l-utils iio-sensor-proxy
	krita firefox-esr xdg-user-dirs fonts-noto-core fonts-noto-cjk
	e2fsprogs
)
if [[ -n ${EXTRA_PACKAGES:-} ]]; then
	# EXTRA_PACKAGES is a whitespace-separated list of Debian packages.
	read -r -a extra_packages <<< "$EXTRA_PACKAGES"
	packages+=("${extra_packages[@]}")
fi

fail()
{
	echo "package-debian-rootfs: $*" >&2
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

required_tools=(blkid bsdtar chroot dpkg-deb du e2fsck find img2simg
	mkfs.ext4 mmdebstrap mount mountpoint python3 rsync sha256sum systemctl
	truncate umount)
for tool in "${required_tools[@]}"; do
	command -v "$tool" >/dev/null 2>&1 || fail "missing host tool: $tool"
done
[[ $(uname -m) == aarch64 || $(uname -m) == arm64 ]] || \
	fail "the Debian rootfs must be assembled on an AArch64 host"
[[ -d $module_tree/lib/modules ]] || fail "missing module tree: $module_tree"
[[ -f $release_dir/KERNEL_RELEASE ]] || fail "missing release/KERNEL_RELEASE"

resolve_input()
{
	local input=$1 label=$2
	input=$(cd -- "$(dirname -- "$input")" && pwd)/${input##*/}
	[[ -f $input ]] || fail "$label not found: $input"
	printf '%s\n' "$input"
}

platform_pointer=$release_dir/CAIHONG_PLATFORM_PACKAGE_DEBIAN
[[ -f $platform_pointer ]] || fail "missing Debian platform package pointer"
[[ -n $platform_package ]] || platform_package=$release_dir/$(<"$platform_pointer")
platform_package=$(resolve_input "$platform_package" platform package)

kernel_pointer=$release_dir/LINUX_CAIHONG_DEB
[[ -n $kernel_deb ]] || {
	[[ -f $kernel_pointer ]] || fail "missing linux-caihong DEB pointer"
	kernel_deb=$release_dir/$(<"$kernel_pointer")
}
kernel_deb=$(resolve_input "$kernel_deb" kernel DEB)

kernel_release=$(<"$release_dir/KERNEL_RELEASE")
[[ -d $module_tree/lib/modules/$kernel_release ]] || \
	fail "module tree does not contain $kernel_release"

platform_distribution=$(dpkg-deb --fsys-tarfile "$platform_package" |
	bsdtar -xOf - ./usr/share/caihong-platform/distribution)
[[ $platform_distribution == debian ]] || \
	fail "platform package targets $platform_distribution, expected debian"
platform_libdir=$(dpkg-deb --fsys-tarfile "$platform_package" |
	bsdtar -xOf - ./usr/share/caihong-npu/libdir)
[[ $platform_libdir == lib ]] || \
	fail "NPU package uses $platform_libdir, expected lib"

output_dir=$(dirname -- "$output")
mkdir -p "$output_dir" "$project_dir/build"
output_dir=$(cd -- "$output_dir" && pwd)
output="$output_dir/$(basename -- "$output")"
temporary="$output.part"
if [[ -e $output || -e $temporary ]]; then
	[[ ${FORCE:-0} == 1 ]] || fail "refusing to overwrite $output (set FORCE=1)"
	rm -f -- "$output" "$temporary"
fi

work_dir=$(mktemp -d "$project_dir/build/debianroot-package.XXXXXX")
rootfs="$work_dir/rootfs"
image_mount="$work_dir/image-mount"
raw_image="$work_dir/rootfs.raw.img"
rootfs_mounted=0
image_mounted=0

unmount_rootfs()
{
	(( rootfs_mounted )) || return 0
	for api_directory in run sys proc dev; do
		if mountpoint -q "$rootfs/$api_directory"; then
			umount --lazy "$rootfs/$api_directory" || true
		fi
	done
	if mountpoint -q "$rootfs"; then
		umount --lazy "$rootfs" || true
	fi
	rootfs_mounted=0
}

cleanup()
{
	status=$?
	trap - EXIT HUP INT TERM
	if (( image_mounted )) && mountpoint -q "$image_mount"; then
		umount "$image_mount" || true
	fi
	unmount_rootfs
	rm -f -- "$temporary"
	rm -rf -- "$work_dir"
	exit "$status"
}
trap cleanup EXIT HUP INT TERM

echo "bootstrapping Debian $DEBIAN_SUITE"
components=$(printf '%s' "$DEBIAN_COMPONENTS" | tr ' ' ',')
mmdebstrap \
	--variant=apt \
	--architectures="$DEBIAN_ARCH" \
	--components="$components" \
	--include="$(IFS=,; printf '%s' "${packages[*]}")" \
	"$DEBIAN_SUITE" "$rootfs" "$DEBIAN_MIRROR"

# A self bind mount anchors the API filesystems below the temporary rootfs.
mount --bind "$rootfs" "$rootfs"
rootfs_mounted=1
mount --make-private "$rootfs"
for api_directory in dev proc sys; do
	mount --bind "/$api_directory" "$rootfs/$api_directory"
	mount --make-private "$rootfs/$api_directory"
done
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$rootfs/run"

rm -f -- "$rootfs/etc/resolv.conf"
cp -L -- /etc/resolv.conf "$rootfs/etc/resolv.conf"

chroot_env=(/usr/bin/env -i HOME=/root LANG=C
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
	DEBIAN_FRONTEND=noninteractive)

if [[ -n ${DEBIAN_SECURITY_MIRROR:-} ]]; then
	install -d -m 0755 "$rootfs/etc/apt/sources.list.d"
	printf 'deb %s %s-security %s\n' "$DEBIAN_SECURITY_MIRROR" "$DEBIAN_SUITE" \
		"$DEBIAN_COMPONENTS" \
		> "$rootfs/etc/apt/sources.list.d/caihong-security.list"
	chroot "$rootfs" "${chroot_env[@]}" apt-get update
fi

# The platform payload replaces the distribution camera stack and power
# profile daemon with the vendor-matched Caihong builds.
purge=()
for package in libcamera-tools libcamera-ipa libspa-0.2-libcamera \
	pipewire-libcamera power-profiles-daemon; do
	# shellcheck disable=SC2016
	if [[ $(chroot "$rootfs" "${chroot_env[@]}" dpkg-query -W \
		-f='${db:Status-Status}' "$package" 2>/dev/null) == installed ]]; then
		purge+=("$package")
	fi
done
if ((${#purge[@]})); then
	echo "purging distribution packages replaced by the Caihong payload: ${purge[*]}"
	chroot "$rootfs" "${chroot_env[@]}" apt-get purge -y "${purge[@]}"
fi

echo "installing linux-caihong and caihong-platform DEBs"
install -d -m 0755 "$rootfs/tmp/caihong-packages" "$rootfs/run/caihong"
install -m 0644 "$kernel_deb" "$rootfs/tmp/linux-caihong.deb"
install -m 0644 "$platform_package" \
	"$rootfs/tmp/caihong-packages/${platform_package##*/}"
touch "$rootfs/run/caihong/offline-rootfs-build"
chroot "$rootfs" "${chroot_env[@]}" env CAIHONG_SKIP_BOOT_FLASH=1 \
	CAIHONG_PLATFORM_IMAGE_BUILD=1 \
	apt-get install -y --allow-downgrades --no-install-recommends \
	/tmp/caihong-packages/"${platform_package##*/}" /tmp/linux-caihong.deb
rm -f -- "$rootfs/run/caihong/offline-rootfs-build"

# shellcheck disable=SC2016
[[ $(chroot "$rootfs" "${chroot_env[@]}" dpkg-query -W \
	-f='${db:Status-Status}' caihong-platform 2>/dev/null) == installed ]] || \
	fail "caihong-platform was not registered"
# shellcheck disable=SC2016
[[ $(chroot "$rootfs" "${chroot_env[@]}" dpkg-query -W \
	-f='${db:Status-Status}' linux-caihong 2>/dev/null) == installed ]] || \
	fail "linux-caihong was not registered"
[[ $(<"$rootfs/usr/lib/linux-caihong/kernel-release") == "$kernel_release" ]] || \
	fail "installed linux-caihong DEB does not match $kernel_release"
[[ -d $rootfs/usr/lib/modules/$kernel_release ]] || \
	fail "linux-caihong DEB did not activate the matching modules"

rm -f -- "$rootfs/tmp/linux-caihong.deb"
rm -rf -- "$rootfs/tmp/caihong-packages"

# The platform payload installs its shared objects below /usr/local, which is
# not refreshed by the dpkg ldconfig trigger.
install -d -m 0755 "$rootfs/etc/ld.so.conf.d"
printf '/usr/local/lib\n' > "$rootfs/etc/ld.so.conf.d/caihong-platform.conf"
chroot "$rootfs" "${chroot_env[@]}" ldconfig

echo "configuring locale, timezone and the desktop account"
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$rootfs/etc/locale.gen"
grep -qx 'en_US.UTF-8 UTF-8' "$rootfs/etc/locale.gen" ||
	printf 'en_US.UTF-8 UTF-8\n' >> "$rootfs/etc/locale.gen"
chroot "$rootfs" "${chroot_env[@]}" locale-gen
printf 'LANG=en_US.UTF-8\n' > "$rootfs/etc/locale.conf"
ln -sfn /usr/share/zoneinfo/Asia/Shanghai "$rootfs/etc/localtime"
printf 'caihong\n' > "$rootfs/etc/hostname"
printf '%s\n' "$account" > "$rootfs/etc/caihong-desktop-account"

if ! chroot "$rootfs" "${chroot_env[@]}" id "$account" >/dev/null 2>&1; then
	chroot "$rootfs" "${chroot_env[@]}" useradd --create-home \
		--groups audio,input,video,render,netdev,sudo --shell /bin/bash \
		"$account"
fi
printf '%s:%s\n' "$account" "$account" |
	chroot "$rootfs" "${chroot_env[@]}" chpasswd

enable_unit()
{
	local unit=$1
	chroot "$rootfs" "${chroot_env[@]}" systemctl enable "$unit" >/dev/null || \
		fail "failed to enable $unit in the Debian rootfs"
}

for unit in NetworkManager.service bluetooth.service \
	power-profiles-daemon.service sddm.service \
	caihong-adbd.service caihong-grow-rootfs.service \
	caihong-fix-kwin-brightness.service caihong-clean-pogo-kde.service \
	caihong-keyboard.service caihong-bluetooth-autostart.service \
	caihong-hardware-mac.service \
	caihong-mark-boot-successful.service caihong-ssc.service \
	caihong-pen-autoconnect.timer caihong-pen-charge.timer \
	caihong-pen-pair.timer; do
	enable_unit "$unit"
done
chroot "$rootfs" "${chroot_env[@]}" systemctl set-default graphical.target \
	>/dev/null

cat > "$rootfs/etc/fstab" <<'EOF'
LABEL=linux / ext4 rw,noatime 0 1
EOF
{
	printf 'device=caihong\n'
	printf 'architecture=aarch64\n'
	printf 'distribution=debian\n'
	printf 'debian_suite=%s\n' "$DEBIAN_SUITE"
	printf 'debian_mirror=%s\n' "$DEBIAN_MIRROR"
	printf 'kernel_release=%s\n' "$kernel_release"
	printf 'boot_roots=PARTLABEL=linux,PARTLABEL=userdata\n'
	printf 'boot_kernel=android-boot-v2-direct-root\n'
	printf 'rootfs_update_mode=rebuilt-image\n'
	printf 'desktop_account=%s\n' "$account"
} > "$rootfs/etc/caihong-rootfs-build-info"
chmod 0644 "$rootfs/etc/caihong-rootfs-build-info"

: > "$rootfs/etc/machine-id"
rm -f -- "$rootfs/etc/resolv.conf"

unmount_rootfs

"$project_dir/scripts/verify-debian-rootfs.sh" "$rootfs"

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
image_blocks=$(((required_bytes + round_bytes - 1) / round_bytes))
image_bytes=$((image_blocks * 256 * 1024 * 1024))

mkdir -p "$image_mount"
truncate -s "$image_bytes" "$raw_image"
mkfs.ext4 -q -F -L linux -m 0 \
	-E lazy_itable_init=0,lazy_journal_init=0 "$raw_image"
mount -o loop "$raw_image" "$image_mount"
image_mounted=1
rsync -aHAX --numeric-ids "$rootfs/" "$image_mount/"
sync -f "$image_mount"
umount "$image_mount"
image_mounted=0
e2fsck -fy "$raw_image" >/dev/null
[[ $(blkid -s LABEL -o value "$raw_image") == linux ]] || \
	fail "generated ext4 image does not have LABEL=linux"

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
echo "ext4 logical size: $image_bytes bytes"
du -h "$output"
sha256sum "$output"
