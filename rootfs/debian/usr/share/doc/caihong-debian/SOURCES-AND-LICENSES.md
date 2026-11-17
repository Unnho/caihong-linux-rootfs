<!-- SPDX-License-Identifier: GPL-2.0-only -->
<!-- Copyright (c) 2026 Ahaan <ahaan.c@icloud.com> -->

# Caihong Debian sources and licences

This experimental image is assembled with
[mmdebstrap](https://salsa.debian.org/debian/mmdebstrap) from the official
Debian archive. Debian packages retain their individual licences and terms,
recorded under `/usr/share/doc/*/copyright`.

The Caihong kernel source is maintained at
[Osilvfe/linux](https://github.com/Osilvfe/linux). Project-authored Caihong
build scripts and utilities use the SPDX licence stated in each file. Device
firmware retains its vendor terms.

The image installs the Caihong kernel and platform packages built from this
repository; it does not install a distribution kernel or distribution
firmware package.
