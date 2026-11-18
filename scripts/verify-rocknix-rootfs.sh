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
failed=0

missing()
{
	echo "missing required ROCKNIX rootfs path: /$1" >&2
	failed=1
}

require_path()
{
	[[ -e $target/$1 || -L $target/$1 ]] || missing "$1"
}

grep -qx 'OS_NAME="ROCKNIX"' "$target/etc/os-release" 2>/dev/null || {
	echo "rootfs identity is not ROCKNIX" >&2
	failed=1
}
grep -qx 'ID=rocknix' "$target/etc/os-release" 2>/dev/null || {
	echo "ROCKNIX os-release does not declare a stable ID" >&2
	failed=1
}
grep -qx 'distribution=rocknix' "$target/etc/caihong-rootfs-build-info" 2>/dev/null || {
	echo "Caihong build information does not identify ROCKNIX" >&2
	failed=1
}
grep -Eq '^rocknix_release=[0-9]{8}$' "$target/etc/caihong-rootfs-build-info" 2>/dev/null || {
	echo "pinned ROCKNIX release is missing from the build information" >&2
	failed=1
}

required_paths=(
	etc/caihong-rootfs-build-info
	etc/caihong-desktop-account
	etc/fstab
	etc/hostname
	etc/issue.d/20-caihong-rocknix.issue
	usr/share/doc/caihong-rocknix/SOURCES-AND-LICENSES.md
	usr/libexec/caihong-platform/configure-platform
	usr/share/caihong-platform/distribution
	usr/share/caihong-platform/kernel-release
	usr/share/caihong-platform/runtime-dependencies
	usr/share/caihong-npu/libdir
	usr/lib/linux-caihong/kernel-release
	etc/systemd/system/caihong-adbd.service
	etc/systemd/system/caihong-grow-rootfs.service
	etc/systemd/system/caihong-keyboard.service
	usr/lib/systemd/system/caihong-ssc.service
	usr/lib/systemd/system/iio-sensor-proxy.service
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
	usr/lib/libQnnHtpV75Stub.so
	usr/lib/dsp/fastrpc_shell_unsigned_3
	usr/lib/dsp/libcalculator_skel.so
	usr/lib/dsp/libQnnHtpV75Skel.so
	usr/lib/libcamera.so.0.7.2
	usr/lib/gstreamer-1.0/libgstlibcamera.so
	usr/share/alsa/ucm2/Qualcomm/sm8650/Caihong/HiFi.conf
	usr/local/libexec/caihong-ssc/hexagonrpcd
	usr/local/libexec/caihong-ssc/iio-sensor-proxy
	usr/local/lib/caihong-ssc/libhexagonrpc.so.0.5
	usr/local/lib/caihong-ssc/libssc.so.2
	usr/local/lib/caihong-ssc/libgudev-1.0.so.0
	usr/local/lib/caihong-ssc/libmbim-glib.so.4
	usr/local/lib/caihong-ssc/libprotobuf-c.so.1
	usr/local/lib/caihong-ssc/libqmi-glib.so.5
	usr/local/lib/caihong-ssc/libqrtr-glib.so.0
	usr/local/lib/caihong-ssc/runtime
	storage
	storage/.config
	storage/roms
)
for path in "${required_paths[@]}"; do
	require_path "$path"
done

# The SSC payload resolves its helper libraries through SONAME links, so a
# dangling link would be as fatal as a missing file.
while IFS= read -r link; do
	[[ -e $link ]] || {
		echo "dangling SSC library link: ${link#"$target"}" >&2
		failed=1
	}
done < <(find "$target/usr/local/lib/caihong-ssc" -maxdepth 1 -type l)

# ROCKNIX normally resolves firmware and modules through an initramfs overlay.
# A direct root must carry both in the filesystem itself.
[[ -d $target/usr/lib/firmware && ! -L $target/usr/lib/firmware ]] || {
	echo "/usr/lib/firmware must be a real directory in a direct-root image" >&2
	failed=1
}
[[ ! -e $target/usr/lib/kernel-overlays ]] || {
	echo "upstream kernel overlays must not survive in a direct-root image" >&2
	failed=1
}
if [[ -n $(find "$target/etc" -type l -lname '/*' -print -quit 2>/dev/null) ]]; then
	echo "absolute symlinks under /etc escape the staged rootfs" >&2
	failed=1
fi
[[ -n $(find "$target/usr/lib/firmware/qcom/sm8650" -type f -print -quit 2>/dev/null) ]] || {
	echo "Caihong SM8650 firmware is missing" >&2
	failed=1
}
[[ ! -L $target/etc/resolv.conf ]] || {
	echo "resolv.conf still points into the ROCKNIX initramfs runtime" >&2
	failed=1
}

grep -qx 'rocknix' "$target/usr/share/caihong-platform/distribution" 2>/dev/null || {
	echo "platform payload does not target ROCKNIX" >&2
	failed=1
}
grep -qx 'lib' "$target/usr/share/caihong-npu/libdir" 2>/dev/null || {
	echo "NPU payload uses the wrong library directory" >&2
	failed=1
}
grep -qx 'root' "$target/etc/caihong-desktop-account" 2>/dev/null || {
	echo "ROCKNIX should keep its root session" >&2
	failed=1
}

mapfile -t module_releases < <(
	find "$target/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d \
		-printf '%f\n' 2>/dev/null
)
if (( ${#module_releases[@]} != 1 )); then
	echo "ROCKNIX rootfs must contain exactly one kernel module release" >&2
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

grep -qx 'LABEL=linux / ext4 rw,noatime 0 1' "$target/etc/fstab" || {
	echo "ROCKNIX root filesystem is not LABEL=linux" >&2
	failed=1
}
grep -qx '/storage /storage none bind 0 0' "$target/etc/fstab" || {
	echo "ROCKNIX /storage is not a mount point" >&2
	failed=1
}
[[ -f $target/storage/.cache/shadow ]] || {
	echo "ROCKNIX /storage/.cache/shadow was not seeded" >&2
	failed=1
}
[[ -e $target/etc/firmware/ath12k/WCN7850/hw2.0/amss.bin ]] || {
	echo "ROCKNIX /etc/firmware does not reach the firmware tree" >&2
	failed=1
}
while IFS= read -r -d '' link; do
	resolved=$(readlink -m -- "$link")
	case $resolved in
		"$target"/*) ;;
		*)
			echo "ROCKNIX /etc symlink escapes the image: ${link#"$target"}" >&2
			failed=1
			;;
	esac
done < <(find "$target/etc" -type l -print0)
for unit in caihong-adbd.service caihong-grow-rootfs.service \
	caihong-keyboard.service caihong-ssc.service iio-sensor-proxy.service; do
	link="$target/etc/systemd/system/multi-user.target.wants/$unit"
	[[ -L $link ]] || {
		echo "Caihong service is not enabled in ROCKNIX: $unit" >&2
		failed=1
	}
done
[[ ! -e $target/etc/systemd/system/display-manager.service ]] || {
	echo "ROCKNIX must keep its own session instead of a display manager" >&2
	failed=1
}
[[ ! -e $target/etc/sudoers.d/10-alarm ]] || {
	echo "Arch Linux ARM sudo policy leaked into ROCKNIX" >&2
	failed=1
}

for file in "$target"/usr/local/sbin/caihong-clean-pogo-kde \
	"$target"/usr/local/sbin/caihong-fix-kwin-brightness \
	"$target"/etc/systemd/system/caihong-adbd.service.d/20-user.conf; do
	[[ -e $file ]] || continue
	if grep -q '/home/alarm\|machine=alarm@\|^User=alarm$\|^ADBD_USER=alarm$' "$file"; then
		echo "unadapted Arch Linux ARM account in ${file#"$target"}" >&2
		failed=1
	fi
done

if (( failed )); then
	exit 1
fi
echo "verified Caihong ROCKNIX rootfs: $target"
