<!-- SPDX-License-Identifier: GPL-2.0-only -->
<!-- Copyright (c) 2026 Ahaan <ahaan.c@icloud.com> -->

# Caihong ROCKNIX sources and licences

This experimental image is derived from the upstream
[ROCKNIX](https://github.com/ROCKNIX/distribution) release
`ROCKNIX-SM8650.aarch64` (`20261101`). ROCKNIX is a Buildroot-based
distribution; its components retain their individual licences and terms,
which are shipped in the upstream `/licenses` directory of the release.

The image keeps ROCKNIX's complete gaming userspace and session. The Caihong
kernel modules, firmware and platform runtime are installed from this
repository into that userspace, and the result is repacked as a direct-root
ext4 image that boots from the same Android boot images as the Arch Linux ARM
and Armada images.

The Caihong kernel source is maintained at
[Osilvfe/linux](https://github.com/Osilvfe/linux). Project-authored Caihong
build scripts and utilities use the SPDX licence stated in each file. Device
firmware retains its vendor terms.
