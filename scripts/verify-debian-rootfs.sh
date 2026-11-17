#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Ahaan <ahaan.c@icloud.com>
set -Eeuo pipefail
CDPATH=

target=${1:-}
if [[ -z $target || ! -d $target ]]; then
	echo "usage: $0 ROOTFS_DIR" >&2
	exit 2
fi
target=$(cd -- "$target" && pwd)
account=$(sed -n 's/^desktop_account=//p' \
	"$target/etc/caihong-rootfs-build-info" 2>/dev/null || true)
account=${account:-caihong}
failed=0

missing()
{
	echo "missing required Debian rootfs path: /$1" >&2
	failed=1
}

require_path()
{
	[[ -e $target/$1 || -L $target/$1 ]] || missing "$1"
}

dpkg_status()
{
	# shellcheck disable=SC2016
	chroot "$target" dpkg-query -W -f='${db:Status-Status}' "$1" \
		2>/dev/null || true
}

for package in caihong-platform linux-caihong; do
	[[ $(dpkg_status "$package") == installed ]] || {
		echo "native $package DEB is not registered in Debian" >&2
		failed=1
	}
done

grep -qx 'ID=debian' "$target/usr/lib/os-release" 2>/dev/null || {
	echo "rootfs identity is not Debian" >&2
	failed=1
}
grep -qx 'distribution=debian' "$target/etc/caihong-rootfs-build-info" 2>/dev/null || {
	echo "Caihong build information does not identify Debian" >&2
	failed=1
}
grep -Eq '^debian_suite=[a-z]+$' "$target/etc/caihong-rootfs-build-info" 2>/dev/null || {
	echo "Debian suite is missing from the build information" >&2
	failed=1
}

required_paths=(
	etc/caihong-rootfs-build-info
	etc/caihong-desktop-account
	etc/fstab
	etc/locale.conf
	etc/issue.d/20-caihong-debian.issue
	usr/share/doc/caihong-debian/SOURCES-AND-LICENSES.md
	etc/sudoers.d/10-caihong
	usr/libexec/caihong-platform/configure-platform
	usr/share/caihong-platform/distribution
	usr/share/caihong-platform/kernel-release
	usr/share/caihong-npu/libdir
	usr/lib/linux-caihong/kernel-release
	usr/lib/linux-caihong/install-current-slot
	usr/lib/linux-caihong/boot-linux.img
	usr/lib/linux-caihong/boot-userdata.img
	usr/lib/systemd/system/caihong-adbd.service
	usr/lib/systemd/system/caihong-grow-rootfs.service
	usr/lib/systemd/system/caihong-keyboard.service
	usr/lib/systemd/system/caihong-ssc.service
	usr/lib/systemd/system/caihong-toolbox.service
	usr/bin/caihong-toolbox
	usr/bin/plasma-camera
	usr/bin/cam
	usr/bin/qcam
	usr/bin/adbd
	usr/local/sbin/caihong-npu-info
	usr/local/libexec/caihong-npu-htp-self-test
	usr/local/libexec/caihong-npu-htp-conv-test
	usr/lib/libcdsprpc.so.1
	usr/lib/caihong-npu/libcalculator.so
	usr/lib/caihong-npu/qnn/libQnnHtp.so
	usr/lib/caihong-npu/qnn/libQnnHtpPrepare.so
	usr/lib/caihong-npu/qnn/libQnnHtpV75Stub.so
	usr/lib/libQnnHtp.so
	usr/lib/libQnnHtpPrepare.so
	usr/lib/libQnnHtpV75Stub.so
	usr/lib/dsp/fastrpc_shell_unsigned_3
	usr/lib/dsp/libcalculator_skel.so
	usr/lib/dsp/libQnnHtpV75Skel.so
	usr/lib/libcamera.so.0.7.2
	usr/lib/gstreamer-1.0/libgstlibcamera.so
	usr/share/alsa/ucm2/Qualcomm/sm8650/Caihong/HiFi.conf
	usr/share/wireplumber/wireplumber.conf.d/90-caihong-camera.conf
	usr/local/libexec/caihong-ssc/hexagonrpcd
	usr/local/libexec/caihong-ssc/iio-sensor-proxy
	usr/local/lib/caihong-ssc/libhexagonrpc.so.0.5
	usr/local/lib/caihong-ssc/libssc.so.2
)
for path in "${required_paths[@]}"; do
	require_path "$path"
done

grep -qx 'debian' "$target/usr/share/caihong-platform/distribution" 2>/dev/null || {
	echo "platform payload does not target Debian" >&2
	failed=1
}
grep -qx 'lib' "$target/usr/share/caihong-npu/libdir" 2>/dev/null || {
	echo "NPU payload uses the wrong library directory" >&2
	failed=1
}

mapfile -t module_releases < <(
	find "$target/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d \
		-printf '%f\n' 2>/dev/null
)
if (( ${#module_releases[@]} != 1 )); then
	echo "Debian rootfs must contain exactly one kernel module release" >&2
	failed=1
else
	kernel_release=${module_releases[0]}
	module_dir="$target/usr/lib/modules/$kernel_release"
	for metadata in modules.dep modules.alias modules.builtin; do
		[[ -s $module_dir/$metadata ]] || missing "usr/lib/modules/$kernel_release/$metadata"
	done
	cmp -s "$target/usr/lib/linux-caihong/kernel-release" \
		<(printf '%s\n' "$kernel_release") || {
		echo "kernel metadata does not match the module tree" >&2
		failed=1
	}
	cmp -s "$target/usr/share/caihong-platform/kernel-release" \
		<(printf '%s\n' "$kernel_release") || {
		echo "platform payload does not match the module tree" >&2
		failed=1
	}
	for module in oneplus_pogo nt36532e_ts sc8547_cp caihong_pen_power \
		sc820cs sc1320cs gt9772 ath12k_wifi7 qcom_q6v5_pas qcom-iris \
		qcom_camera_icp qcom-camera-icp-bps; do
		module_file=$(find "$module_dir" -type f -name "$module.ko" -print -quit)
		if [[ -z $module_file ]]; then
			echo "missing release kernel module: $module" >&2
			failed=1
			continue
		fi
		vermagic=$(modinfo -F vermagic "$module_file" 2>/dev/null || true)
		[[ $vermagic == "$kernel_release "* ]] || {
			echo "kernel module release mismatch: $module" >&2
			failed=1
		}
	done
fi

if [[ -n $(dpkg-query --admindir="$target/var/lib/dpkg" -W \
	-f='${Package}\n' 'linux-image-*' 2>/dev/null) ]]; then
	echo "a distribution kernel leaked into the Debian rootfs" >&2
	failed=1
fi

if ! chroot "$target" id "$account" >/dev/null 2>&1; then
	echo "missing Debian desktop account: $account" >&2
	failed=1
else
	groups=$(chroot "$target" id -nG "$account")
	for group in audio input video render netdev sudo; do
		[[ " $groups " == *" $group "* ]] || {
			echo "Debian account $account is not in group $group" >&2
			failed=1
		}
	done
fi

grep -qx 'LANG=en_US.UTF-8' "$target/etc/locale.conf" || {
	echo "Debian default locale must be en_US.UTF-8" >&2
	failed=1
}
grep -qx 'LABEL=linux / ext4 rw,noatime 0 1' "$target/etc/fstab" || {
	echo "Debian root filesystem is not LABEL=linux" >&2
	failed=1
}

if [[ ! -L $target/etc/systemd/system/display-manager.service ||
	$(readlink "$target/etc/systemd/system/display-manager.service") != \
	/usr/lib/systemd/system/sddm.service ]]; then
	echo "Debian display manager is not SDDM" >&2
	failed=1
fi
for unit in caihong-adbd.service caihong-grow-rootfs.service \
	caihong-keyboard.service caihong-ssc.service; do
	link="$target/etc/systemd/system/multi-user.target.wants/$unit"
	[[ -L $link ]] || {
		echo "Caihong service is not enabled in Debian: $unit" >&2
		failed=1
	}
done

for file in "$target"/usr/local/sbin/caihong-clean-pogo-kde \
	"$target"/usr/local/sbin/caihong-fix-kwin-brightness; do
	[[ -e $file ]] || continue
	if grep -q '/home/alarm\|machine=alarm@' "$file"; then
		echo "unadapted Arch Linux ARM account in ${file#"$target"}" >&2
		failed=1
	fi
done

if (( failed )); then
	exit 1
fi
echo "verified Caihong Debian rootfs: $target"
