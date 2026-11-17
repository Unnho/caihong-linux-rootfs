#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Ahaan <ahaan.c@icloud.com>
#
# Build the native Debian kernel package.  It carries the same direct-root
# boot images and dependency-closed module tree as the pacman and RPM
# packages, so a Debian rootfs boots from the identical Android boot image.
set -eu
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
module_tree=${1:-"$project_dir/modules-current"}
release_dir=${2:-"$project_dir/release"}

for tool in bsdtar depmod dpkg-deb sha256sum; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "missing tool: $tool" >&2
		exit 1
	}
done

release=
for candidate in "$module_tree"/lib/modules/*; do
	[ -d "$candidate" ] || continue
	[ -z "$release" ] || {
		echo "module tree contains more than one kernel release" >&2
		exit 1
	}
	release=${candidate##*/}
done
[ -n "$release" ] || { echo "module tree contains no kernel release" >&2; exit 1; }

boot_linux="$release_dir/caihong-boot-linux-$release.img"
boot_userdata="$release_dir/caihong-boot-userdata-$release.img"
for input in "$boot_linux" "$boot_userdata"; do
	[ -f "$input" ] || { echo "missing package input: $input" >&2; exit 1; }
done

version=$(printf '%s' "$release" | sed 's/[^[:alnum:].+~^]/./g')
package_name="linux-caihong_${version}-1_arm64.deb"
output="$release_dir/$package_name"
temporary="$output.new"
mkdir -p "$project_dir/build"
work_dir=$(mktemp -d "$project_dir/build/linux-caihong-deb.XXXXXX")
stage="$work_dir/stage"

cleanup()
{
	rm -rf -- "$work_dir"
	rm -f -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

module_stage="$work_dir/module-stage"
CAIHONG_EXPECTED_RELEASE=$release \
	"$project_dir/scripts/install-caihong-modules.sh" "$module_tree" "$module_stage"
install -d -m 0755 "$stage/usr/lib/linux-caihong/modules"
mv -- "$module_stage/lib/modules/$release" \
	"$stage/usr/lib/linux-caihong/modules/$release"
install -D -m 0644 "$project_dir/rootfs/archlinuxarm/etc/modules-load.d/caihong.conf" \
	"$stage/usr/lib/modules-load.d/caihong.conf"
install -D -m 0755 \
	"$project_dir/packaging/linux-caihong/install-current-slot" \
	"$stage/usr/lib/linux-caihong/install-current-slot"
install -m 0644 "$boot_linux" "$stage/usr/lib/linux-caihong/boot-linux.img"
install -m 0644 "$boot_userdata" "$stage/usr/lib/linux-caihong/boot-userdata.img"
printf '%s\n' "$release" > "$stage/usr/lib/linux-caihong/kernel-release"
install -D -m 0644 "$project_dir/linux/COPYING" \
	"$stage/usr/share/doc/linux-caihong/copyright"

installed_size=$(du -sk "$stage" | awk '{ print $1 }')
debian="$stage/DEBIAN"
mkdir -p "$debian"
cat > "$debian/control" <<EOF
Package: linux-caihong
Version: ${version}-1
Architecture: arm64
Maintainer: Ahaan <ahaan.c@icloud.com>
Section: kernel
Priority: optional
Installed-Size: $installed_size
Depends: bash, coreutils, findutils, grep, kmod, util-linux
Description: Mainline Linux kernel and modules for OnePlus Pad Pro (caihong)
 Mainline Linux kernel, direct-root boot images and the matching module
 tree for the OnePlus Pad Pro (caihong).
EOF
cat > "$debian/postinst" <<'EOF'
#!/bin/sh
set -e
if [ -x /usr/lib/linux-caihong/install-current-slot ]; then
	/usr/lib/linux-caihong/install-current-slot || true
fi
EOF
cat > "$debian/prerm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = remove ] && [ -x /usr/lib/linux-caihong/install-current-slot ]; then
	/usr/lib/linux-caihong/install-current-slot --remove-modules || true
fi
EOF
chmod 0755 "$debian/postinst" "$debian/prerm"

dpkg-deb --build --root-owner-group "$stage" "$temporary" >/dev/null
mv -- "$temporary" "$output"
printf '%s\n' "${output##*/}" > "$release_dir/LINUX_CAIHONG_DEB"

[ "$(dpkg-deb -f "$output" Package)" = linux-caihong ]
[ "$(dpkg-deb -f "$output" Architecture)" = arm64 ]
dpkg-deb -c "$output" | awk '{ print $6 }' | grep -qx './usr/lib/linux-caihong/kernel-release'
if dpkg-deb -c "$output" | awk '{ print $6 }' | grep -q '^./usr/lib/modules/'; then
	echo "DEB must not own the activated module directory" >&2
	exit 1
fi
archived_release=$(dpkg-deb --fsys-tarfile "$output" |
	bsdtar -xOf - ./usr/lib/linux-caihong/kernel-release)
[ "$archived_release" = "$release" ] || {
	echo "packaged kernel release does not match $release" >&2
	exit 1
}
for root_partlabel in linux userdata; do
	source_hash=$(sha256sum "$release_dir/caihong-boot-$root_partlabel-$release.img" |
		awk '{ print $1 }')
	archive_hash=$(dpkg-deb --fsys-tarfile "$output" |
		bsdtar -xOf - "./usr/lib/linux-caihong/boot-$root_partlabel.img" |
		sha256sum | awk '{ print $1 }')
	[ "$source_hash" = "$archive_hash" ] || {
		echo "packaged $root_partlabel boot image failed verification" >&2
		exit 1
	}
done

rm -rf -- "$work_dir"
trap - EXIT HUP INT TERM
echo "created DEB package: $output"
sha256sum "$output"
