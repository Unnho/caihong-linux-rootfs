# Upstream imports: ROCKNIX and Armada OS

This branch (`caihong-distro-tuning`) folds device customizations that upstream
ROCKNIX and Armada OS already ship for SM8650 / Snapdragon 8 Gen 3 hardware into
the Caihong tree. Everything below is userspace or boot-command-line level, so
it works with our direct-root, no-initramfs images on all four distributions and
does not need a kernel rebuild.

Provenance for each item is recorded in the file header it touches.

## Boot command line — `config/caihong-direct-root-*-cmdline.txt`

| Token | Source | Why |
|---|---|---|
| `irqaffinity=0-1` | ROCKNIX `projects/ROCKNIX/devices/SM8650/options` | Keep IRQ delivery on the efficiency cores so the big cluster stays free for foreground work. |
| `cgroup.memory=nokmem,nosocket` | same | Drop per-cgroup kmem and socket accounting for a small battery-powered device. |
| `nosoftlockup` | same | ROCKNIX ships this on SM8650. |

ROCKNIX also sets `usbcore.interrupt_interval_override=045e:028e:2`, which is an
Xbox controller quirk and is intentionally not imported.

## Memory and I/O — `rootfs/archlinuxarm/usr/lib/sysctl.d/60-caihong-gaming.conf`

Derived from Armada OS `system_files/usr/lib/sysctl.d/60-armada-gaming.conf` and
ROCKNIX `projects/ROCKNIX/packages/sysutils/systemd/sysctl.d/60-rocknix.conf`:
swappiness 180 with `page-cluster=0` for zram, tuned writeback/watermarks,
`max_map_count`, inotify limits, watchdog and BBR knobs.

## zram swap — `usr/local/sbin/caihong-zram` + `usr/lib/systemd/system/caihong-zram.service`

ROCKNIX enables zram on SM8650 with `ZRAM_COMPRESSION_ALGO="zstd"` and
`ZRAM_SWAP_SIZE="Auto"`; Armada OS pairs zram with the swappiness above. Our
unit brings up a zstd zram device sized to half of RAM and is enabled on Arch
Linux ARM, Armada and Debian. ROCKNIX is skipped because its memory manager
already owns zram there; the helper also backs off if a zram device is already
configured.

## Storage and USB — `rootfs/archlinuxarm/usr/lib/udev/rules.d/`

- `60-caihong-block-scheduler.rules`: adapted from Armada OS
  `60-armada-block-scheduler.rules`, retargeted at our UFS LUNs (`sd*` instead
  of `mmcblk*`) and the blk-mq `none` scheduler.
- `60-caihong-usb-autosuspend.rules`: verbatim from Armada OS
  `60-armada-usb-autosuspend.rules`; lets the DWC3 controller runtime-suspend so
  the USB-to-DDR interconnect vote does not block DDR low-power tiers.

## Networking — `rootfs/archlinuxarm/etc/NetworkManager/conf.d/40-caihong-connectivity.conf`

Imported from Armada OS `99-armada-dhcp-timeout.conf`: shorten the DHCP timeout
so NetworkManager retries immediately.

## libssc — `packaging/libssc/`

Armada OS patches `0002` (sample-rate override), `0003` (client reference leak)
and `0005` (use-after-free while logging a failed disable) are applied in
`scripts/install-caihong-ssc-stage.sh`. See `packaging/libssc/PATCHES.md` for the
full table and for why `0004` is deferred.

## Considered but not imported

- **Armada `60-armada-perf-acls.rules`** — grants a group write access to
  cpufreq/devfreq/backlight. We already drive these through the
  power-profiles-daemon build in `packaging/power-profiles-daemon-caihong`, and
  Arch/Debian group names differ from Armada's `wheel`, so it would fight the
  existing policy.
- **Armada `70-armada-low-battery.conf`** — forces `CriticalPowerAction=PowerOff`.
  Reasonable for a handheld that drains in s2idle; we keep the distribution
  default until suspend behaviour on Caihong is confirmed on hardware.
- **ROCKNIX kernel patches** (`projects/ROCKNIX/devices/SM8650/patches/linux/`)
  — GPU/DPU/audio/power fixes for SM8650 belong in the kernel fork
  (`Osilvfe/linux`, branch `caihong-v7.3`), not in this rootfs repository. The
  notable non-upstream one is `0121-pmdomain-qcom-rpmhpd-presync-floor-gmu-rails`
  (floor the GFX/GMXC rails before `sync_state`); it is not present in
  `caihong-v7.3` and is a candidate for a separate kernel change.
- **ROCKNIX handheld quirks** (joypad, fan, analog LEDs, `inputplumber`, fake
  suspend) — tied to gamepad hardware and ROCKNIX's `/storage` layout.
