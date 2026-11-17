#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
# Copyright (c) 2026 Ahaan <ahaan.c@icloud.com>
set -eu
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
release_dir=${1:-"$project_dir/release"}
version=${CAIHONG_PLATFORM_VERSION:-0.$(git -C "$project_dir" log -1 --format=%ct).g$(git -C "$project_dir" rev-parse --short HEAD)}
kernel_release=${KERNEL_RELEASE:-}
distribution=${DISTRIBUTION:-archlinuxarm}
if [ "$distribution" = debian ]; then
	# shellcheck source=../config/debian.env
	# shellcheck disable=SC1091
	. "$project_dir/config/debian.env"
fi
case $distribution in
	archlinuxarm) libdir=${LIBDIR:-lib} ;;
	armada) libdir=${LIBDIR:-lib64} ;;
	debian) libdir=${LIBDIR:-lib} ;;
	rocknix) libdir=${LIBDIR:-lib} ;;
	*) echo "DISTRIBUTION must be archlinuxarm, armada, debian or rocknix" >&2; exit 2 ;;
esac
build_root=${CAIHONG_BUILD_ROOT:-"$project_dir/build/platform-build-root-$distribution"}

for tool in bsdtar file git install python3 sha256sum zstd; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "missing build tool: $tool" >&2
		exit 1
	fi
done
case $libdir in
	lib|lib64) ;;
	*) echo "LIBDIR must be lib or lib64" >&2; exit 2 ;;
esac
if { [ "$distribution" = archlinuxarm ] && [ "$libdir" != lib ]; } ||
	{ [ "$distribution" = armada ] && [ "$libdir" != lib64 ]; } ||
	{ [ "$distribution" = debian ] && [ "$libdir" != lib ]; } ||
	{ [ "$distribution" = rocknix ] && [ "$libdir" != lib ]; }; then
	echo "incorrect library layout for $distribution: $libdir" >&2
	exit 2
fi
if [ -n "$kernel_release" ] && [ ! -d "$project_dir/modules-current/lib/modules/$kernel_release" ]; then
	echo "KERNEL_RELEASE does not exist in modules-current: $kernel_release" >&2
	exit 1
fi
if [ -z "$kernel_release" ]; then
	kernel_release=$(cat "$project_dir/release/KERNEL_RELEASE" 2>/dev/null || true)
fi
if [ -z "$kernel_release" ]; then
	for candidate in "$project_dir"/modules-current/lib/modules/*; do
		[ -d "$candidate" ] || continue
		[ -z "${found_release:-}" ] || {
			echo "module tree contains multiple kernel releases; set KERNEL_RELEASE" >&2
			exit 1
		}
		found_release=${candidate##*/}
	done
	kernel_release=${found_release:-}
fi
[ -n "$kernel_release" ] || echo "warning: kernel release is unknown; installer will not enforce it" >&2

mkdir -p "$project_dir/build"
work_dir=$(mktemp -d "$project_dir/build/caihong-platform-package.XXXXXX") || exit 1
stage="$work_dir/stage"
mkdir -p "$release_dir" "$stage/usr" "$stage/etc"
find "$stage" -xdev -type d -exec chmod 0755 {} +
find "$stage" -xdev -type f -exec chmod go-w {} +

cleanup()
{
	"$project_dir/scripts/caihong-build-root.sh" cleanup "$build_root" \
		>/dev/null 2>&1 || true
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

cp -a "$project_dir/rootfs/archlinuxarm/." "$stage/"
case $distribution in
	armada)
		cp -a "$project_dir/rootfs/armada/." "$stage/"
		account=armada home=/var/home/armada
		;;
	debian)
		cp -a "$project_dir/rootfs/debian/." "$stage/"
		account=$DEBIAN_ACCOUNT home=/home/$DEBIAN_ACCOUNT
		;;
	rocknix)
		cp -a "$project_dir/rootfs/rocknix/." "$stage/"
		# ROCKNIX has no desktop account; its session runs as root.
		account=root home=/root
		;;
	*)
		account=alarm home=/home/alarm
		;;
esac
if [ "$account" != alarm ]; then
	for path in \
		etc/systemd/system/caihong-clean-pogo-kde.service \
		etc/systemd/system/caihong-adbd.service.d/20-user.conf \
		usr/local/sbin/caihong-clean-pogo-kde \
		usr/local/sbin/caihong-fix-kwin-brightness; do
		[ -e "$stage/$path" ] || continue
		sed -i \
			-e "s#/home/alarm#$home#g" \
			-e "s#machine=alarm@#machine=$account@#g" \
			-e "s#-o alarm -g alarm#-o $account -g $account#g" \
			-e "s#chown alarm:alarm#chown $account:$account#g" \
			-e "s#^User=alarm\$#User=$account#" \
			-e "s#^Group=alarm\$#Group=$account#" \
			-e "s#^ADBD_USER=alarm\$#ADBD_USER=$account#" \
			"$stage/$path"
		if grep -Eq '/home/alarm|machine=alarm@|^User=alarm$|^Group=alarm$|^ADBD_USER=alarm$' \
			"$stage/$path"; then
			echo "unadapted account reference: $path" >&2
			exit 1
		fi
	done
	# Each distribution keeps its own sudo policy file.
	if [ "$account" = root ]; then
		# A root session does not need a sudoers entry.
		rm -f -- "$stage/etc/sudoers.d/10-alarm"
	else
		if [ -f "$stage/etc/sudoers.d/10-alarm" ]; then
			sed "s/^alarm /$account /" "$stage/etc/sudoers.d/10-alarm" \
				> "$stage/etc/sudoers.d/10-$account"
			chmod 0440 "$stage/etc/sudoers.d/10-$account"
			rm -f -- "$stage/etc/sudoers.d/10-alarm"
		fi
	fi
fi
if [ "$distribution" != archlinuxarm ]; then
	# Debian and Buildroot keep filesystem utilities in /usr/sbin.
	sed -i 's#/usr/bin/resize2fs#/usr/sbin/resize2fs#g' \
		"$stage/etc/systemd/system/caihong-grow-rootfs.service"
fi

if [ "$distribution" = archlinuxarm ] || [ "$distribution" = armada ] ||
	[ "$distribution" = debian ] || [ "$distribution" = rocknix ]; then
	"$project_dir/scripts/caihong-build-root.sh" prepare \
		"$build_root" "$distribution"
	CAIHONG_BUILD_ROOT="$build_root" \
	"$project_dir/scripts/install-caihong-toolbox-rootfs.sh" "$stage"
	CAIHONG_BUILD_ROOT="$build_root" LIBDIR="$libdir" \
	"$project_dir/scripts/install-caihong-vaapi-stage.sh" "$stage"
	CAIHONG_BUILD_ROOT="$build_root" LIBCAMERA_LIBDIR="$libdir" \
	"$project_dir/scripts/install-caihong-libcamera-stage.sh" "$stage"
	CAIHONG_BUILD_ROOT="$build_root" \
	"$project_dir/scripts/install-caihong-plasma-camera-stage.sh" "$stage"
	CAIHONG_BUILD_ROOT="$build_root" \
	"$project_dir/scripts/install-caihong-qbootctl-stage.sh" "$stage"
	CAIHONG_BUILD_ROOT="$build_root" \
	"$project_dir/scripts/install-caihong-utilities-stage.sh" "$stage"
	CAIHONG_BUILD_ROOT="$build_root" \
	"$project_dir/scripts/install-caihong-ppd-stage.sh" "$stage"
fi

(
	cd "$project_dir/firmware" && sha256sum -c SHA256SUMS >/dev/null
)
install -d -m 0755 "$stage/usr/lib/firmware"
cp -a "$project_dir/firmware/." "$stage/usr/lib/firmware/"
rm -f "$stage/usr/lib/firmware/SOURCE.md" "$stage/usr/lib/firmware/SHA256SUMS"

mkdir -p "$stage/usr/lib/firmware/qcom/sm8650"
if command -v alsatplg >/dev/null 2>&1; then
	"$project_dir/scripts/build-caihong-audioreach-topology.sh" \
		"$stage/usr/lib/firmware/qcom/sm8650/SM8650-MTP-tplg.bin" >/dev/null
else
	install -m 0644 "$project_dir/firmware/qcom/sm8650/SM8650-MTP-tplg.bin" \
		"$stage/usr/lib/firmware/qcom/sm8650/SM8650-MTP-tplg.bin"
fi

CAIHONG_ADBD_CACHE="$project_dir/downloads/caihong-adbd" \
	"$project_dir/scripts/install-caihong-adbd.sh" "$stage" >/dev/null
FORCE=1 "$project_dir/scripts/ssc/install-rootfs.sh" \
	"$project_dir/firmware-assets/caihong-ssc" "$stage" >/dev/null
install -d -m 0755 "$stage/usr/share/caihong-ssc"
mv -- "$stage/var/lib/caihong-ssc/root" "$stage/usr/share/caihong-ssc/root"
CAIHONG_BUILD_ROOT="$build_root" \
	"$project_dir/scripts/install-caihong-ssc-stage.sh" "$stage"

"$project_dir/scripts/install-caihong-npu.sh" \
	"$project_dir/firmware-assets/caihong-npu" "$stage" "$libdir"
printf '%s\n' "$libdir" > "$stage/usr/share/caihong-npu/libdir"
install -d -m 0755 "$stage/usr/share/caihong-platform"
"$project_dir/scripts/caihong-build-root.sh" cleanup "$build_root"
printf '%s\n' "$distribution" > "$stage/usr/share/caihong-platform/distribution"
[ -z "$kernel_release" ] || printf '%s\n' "$kernel_release" \
	> "$stage/usr/share/caihong-platform/kernel-release"
printf '%s\n' "libdir=$libdir" \
	> "$stage/usr/share/caihong-platform/layout"

python3 "$project_dir/scripts/package-caihong-platform.py" "$stage" "$release_dir" \
	--distribution "$distribution" --version "$version"

rm -rf "$work_dir"
trap - EXIT HUP INT TERM
