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

## Power — `rootfs/archlinuxarm/etc/UPower/UPower.conf.d/70-caihong-low-battery.conf`

Imported from Armada OS `70-armada-low-battery.conf`. UPower's automatic action
would suspend, and SM8650 s2idle is not reliable yet, so power off at the
critical level instead of draining to a brown-out. Only the distributions that
ship UPower (Debian, Arch, Armada) read it; ROCKNIX ignores the dangling path.

## Device features verified against Caihong's own hardware

A read-only audit (`/root/caihong-agent-log/7-feature-parity.md`) compared every
Armada/ROCKNIX device feature against Caihong's DTS and driver. Findings:

- **Charge control — already better than upstream.** The Caihong
  `qcom_battmgr` driver (enabled by `of_machine_is_compatible("oneplus,caihong")`)
  exposes `qcom-battmgr-bat` with `charge_control_{start,end}_threshold`,
  `charge_behaviour` (`auto`/`inhibit-charge`) and
  `device/oneplus_charge_control_status`. Its setter accepts 0–100 with no 55 %
  clamp, and `end=100` clears the limit, which our `caihong-charge`/
  `caihong-autocharge` already drive. Armada's `power_supply` method and its
  55 % minimum are therefore not imported, and ROCKNIX's battery rename is
  explicitly rejected because it would break every `qcom-battmgr-bat` path.
- **Audio — WCD939x, not WCD938x.** Caihong is `qcom,wcd9395/9390-codec` on
  `swr1` (0x6ad0000) and `swr2` (0x6d30000) with six `awinic,aw88261` TDM amps;
  Armada's `99-wcd938x-nosleep.rules` / WSA881x / Konkr rules use different
  codecs and a different SoundWire address and are not portable verbatim. A
  Keep-awake rule for jack detection is deferred until hardware confirms MBHC
  events are actually lost, since it costs power.
- **Suspend — untouched.** ROCKNIX disables sleep on SM8650 and our charge
  driver already carries a suspend PM notifier, so no suspend configuration is
  changed.
- **Power profiles, MAC handling, sensors, panels, backlight** — our tree
  already supersedes the upstream equivalents (PPD, NVRAM MAC reader, own SSC
  bundle, KWin brightness curve).

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
  notable non-upstream ones are:
  - `0121-pmdomain-qcom-rpmhpd-presync-floor-gmu-rails` (floor the GFX/GMXC
    rails before `sync_state`) — not present in `caihong-v7.3`;
  - the ADSP FastRPC remote heap Armada added to `sm8650.dtsi` in commit
    `81ee9ff` (12 MiB reusable heap, `memory-region`/`qcom,vmids` on the ADSP
    `fastrpc` node). Our `sm8650.dtsi` fastrpc node lacks both, and the ADSP
    sensors process is documented to fail without the heap.
  Both are kernel-fork follow-ups, tracked in
  `packaging/linux-caihong/` review notes and `1c-2d-history-mining.md`.
- **ROCKNIX handheld quirks** (joypad, fan, analog LEDs, `inputplumber`, fake
  suspend) — tied to gamepad hardware and ROCKNIX's `/storage` layout.
