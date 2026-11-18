#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Ahaan <ahaan.c@icloud.com>
#
# The SSC payload (hexagonrpcd, iio-sensor-proxy and libssc) is linked against
# glib, libudev, libqmi, libqrtr and protobuf-c.  Distributions that build those
# from source provide them, but ROCKNIX is Buildroot-based and ships none of
# them.  Install the Debian builds next to the SSC libraries so the service
# units, which already put that directory on LD_LIBRARY_PATH, can resolve them.
set -eu
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
target=${1:-}
if [ -z "$target" ] || [ ! -d "$target" ]; then
	echo "usage: $0 ROOTFS_DIR" >&2
	exit 2
fi
target=$(cd -- "$target" && pwd)

cache=${CAIHONG_SSC_COMPAT_CACHE:-"$project_dir/downloads/caihong-ssc-compat"}
mkdir -p "$cache"

gudev_base=https://deb.debian.org/debian/pool/main/libg/libgudev
mbim_base=https://deb.debian.org/debian/pool/main/libm/libmbim
qmi_base=https://deb.debian.org/debian/pool/main/libq/libqmi
qrtr_base=https://deb.debian.org/debian/pool/main/libq/libqrtr-glib
protobuf_c_base=https://deb.debian.org/debian/pool/main/p/protobuf-c

packages='
libgudev-1.0-0_238-6_arm64.deb f0fec02f1bbc0803c9d044413609d3cd0fde24bfe6a5141a38aabfa86c292b21 GUDEV
libmbim-glib4_1.32.0-1_arm64.deb e73be096b67d32cecfde633bab84bcb8ec15a5219d6bc5c514e74a9c73d078c9 MBIM
libqmi-glib5_1.36.0-1_arm64.deb 3999250f51439530a807174e3dd272402921e16a632848b5acb9528f185a6965 QMI
libqrtr-glib0_1.2.2-1+b2_arm64.deb cceff190cb19d4638d9bf26cd3688f94f04acde21a79b08e7435f4f88222e21e QRTR
libprotobuf-c1_1.5.1-1_arm64.deb 6c34790825abb19889f351938430a1e3a4f263cc55812e00f1ba01399638b94b PROTOBUF_C
'

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/caihong-ssc-compat.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT HUP INT TERM

fetch()
{
	name=$1
	hash=$2
	source=$3
	path=$cache/$name
	if [ ! -f "$path" ] || [ "$(sha256sum "$path" | awk '{ print $1 }')" != "$hash" ]; then
		rm -f -- "$path"
		case "$source" in
			GUDEV) base=$gudev_base ;;
			MBIM) base=$mbim_base ;;
			QMI) base=$qmi_base ;;
			QRTR) base=$qrtr_base ;;
			PROTOBUF_C) base=$protobuf_c_base ;;
			*) echo "unknown package source: $source" >&2; exit 1 ;;
		esac
		curl -fsSL --retry 4 --retry-delay 2 -o "$path" "$base/$name"
	fi
	actual=$(sha256sum "$path" | awk '{ print $1 }')
	[ "$actual" = "$hash" ] || {
		echo "checksum mismatch for $name" >&2
		exit 1
	}
}

extract()
{
	name=$1
	dir=$work_dir/${name%.deb}
	mkdir -p "$dir"
	bsdtar -xOf "$cache/$name" data.tar.xz | tar -xJf - -C "$dir"
}

printf '%s\n' "$packages" | while read -r name hash source; do
	[ -n "$name" ] || continue
	fetch "$name" "$hash" "$source"
	extract "$name"
done

install -d -m 0755 "$target/usr/local/lib/caihong-ssc" \
	"$target/usr/share/licenses/caihong-ssc-compat"

libraries='
libgudev-1.0-0_238-6_arm64 libgudev-1.0.so.0.3.0 libgudev-1.0.so.0
libmbim-glib4_1.32.0-1_arm64 libmbim-glib.so.4.9.0 libmbim-glib.so.4
libqmi-glib5_1.36.0-1_arm64 libqmi-glib.so.5.11.0 libqmi-glib.so.5
libqrtr-glib0_1.2.2-1+b2_arm64 libqrtr-glib.so.0.0.0 libqrtr-glib.so.0
libprotobuf-c1_1.5.1-1_arm64 libprotobuf-c.so.1.0.0 libprotobuf-c.so.1
'

printf '%s\n' "$libraries" | while read -r package file soname; do
	[ -n "$package" ] || continue
	source_file=$work_dir/$package/usr/lib/aarch64-linux-gnu/$file
	[ -f "$source_file" ] || {
		echo "Debian SSC library is missing: $file" >&2
		exit 1
	}
	install -m 0644 "$source_file" \
		"$target/usr/local/lib/caihong-ssc/$file"
	ln -sfn "$file" "$target/usr/local/lib/caihong-ssc/$soname"
done

for package in libgudev-1.0-0 libmbim-glib4 libqmi-glib5 libqrtr-glib0 \
	libprotobuf-c1; do
	dir=$(find "$work_dir" -maxdepth 1 -type d -name "$package*" -print -quit)
	[ -n "$dir" ] || continue
	copyright=$dir/usr/share/doc/$package/copyright
	[ -f "$copyright" ] || continue
	install -D -m 0644 "$copyright" \
		"$target/usr/share/licenses/caihong-ssc-compat/$package-copyright"
done

cat > "$target/usr/local/lib/caihong-ssc/runtime" <<'EOF'
libgudev-1.0-0=238-6
libmbim-glib4=1.32.0-1
libqmi-glib5=1.36.0-1
libqrtr-glib0=1.2.2-1+b2
libprotobuf-c1=1.5.1-1
source=https://deb.debian.org/debian
EOF
chmod 0644 "$target/usr/local/lib/caihong-ssc/runtime"

echo "installed Caihong SSC runtime libraries into $target"
