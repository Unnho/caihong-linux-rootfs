# Upstream imports: ROCKNIX and Armada OS

This branch (`caihong-distro-tuning`) folds device customizations that upstream
ROCKNIX and Armada OS already ship for SM8650 / Snapdragon 8 Gen 3 hardware into
the Caihong tree. Most of it is userspace or boot-command-line level, so it
works with our direct-root, no-initramfs images on all four distributions
without a kernel rebuild. The kernel-level imports live in our Linux fork
(`Unnho/linux`, branch `caihong-sm8650-performance`) and are listed in the
"Kernel fork" section below.

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

## Kernel fork — `Unnho/linux`, branch `caihong-sm8650-performance`

`config/dependencies.env` now points the build at our Linux fork
(`https://github.com/Unnho/linux.git`, branch `caihong-sm8650-performance`),
which is `Osilvfe/linux` `caihong-v7.3` plus the SM8650 kernel-level fixes
below. Each is one Ahaan-authored commit with the upstream source recorded in
its message; the full table, including the skipped candidates and why, is in
`/root/caihong-agent-log/6-kernel-fork.md`.

| Commit | Upstream source | What it changes |
|---|---|---|
| `df74301bef3f` | ROCKNIX `0001-pcie-update-sm8650-dtsi` | Move the PCIe PHY reference to the port node. |
| `a3546f574903` | Armada `8dc0be9` | Let the PCIe GDSCs collapse instead of staying retained in suspend. |
| `b2a312c79367` | ROCKNIX `0006-...-hdmi_audio_ops` | Add the `hw_params` callback to `drm_connector_hdmi_audio_ops`. |
| `3f692084a417` | Armada `560b556` | Route the SM8650 WSA2 AudioReach backends through the WSA interface. |
| `9c22d0f5038b` | ROCKNIX `0066-...-inline-rotation` | Enable true inline rotation (90/270) on the SM8650 VIG/QSEED pipes. |
| `ab02ea54b2f9` | ROCKNIX `0067-...-qseed-detail-enhancer` | Enable the QSEED3Lite detail enhancer and directional filter while scaling. |
| `ed2d14bc1ae2` | ROCKNIX `0120-...-gpucc-power-domains` | Declare the GPU_CC power plumbing (`RPMHPD_CX`, `RPMHPD_MX`, `RPMHPD_MXC`). |
| `0bd032676896` | ROCKNIX `20260424_..._cx_power_domain_to_gcc` | Add the missing CX power domain to GCC so GCC votes reach CX. |
| `9a3696ecf5cc` | Armada `81ee9ff` (`0623-...-ADSP-FastRPC-remote-heap`) | Reserve the 12 MiB reusable ADSP FastRPC remote heap and reference it from the `fastrpc` node. |
| `0e3ee0fbe605` | ROCKNIX `0071-HACK-fix-usb-boot-hang` | Drop the 5-second xHCI ready wait that hangs SM8650 boot. |
| `d21a9b21afb1` | ROCKNIX `0504-Enable-64-bit-processes-to-use-compat-input-syscalls` | Let 64-bit processes use the compat input syscalls via `prctl`. |
| `1db7eb9aaed8` | ROCKNIX `0505-msm_gem-lock-before-put_iova_spaces` | Take the GPU VM/object lock before `put_iova_spaces()`. |
| `b3c4090ca7cf` | ROCKNIX `0506-usbcore-add-interrupt-interval-override` | Add the `usbcore.interrupt_interval_override` knob. |
| `57ea70f5bea1` | ROCKNIX `0013-drm-msm-dpu-fix-inline-rotation` (common 7.3) | Fix the inline-rotation direction checks. |
| `a027f257815f` | ROCKNIX `0010-msm-resource-cleanup` (common 7.3) | DPU resource cleanup and encoder state handling series. |
| `276568bd1efe` | ROCKNIX `9998-silence-initramfs-unpack-warn` (common 7.3) | Demote the initramfs unpack message to `KERN_DEBUG`. |
| `d9eeb5f39162` | — | Reverts the ROCKNIX battery rename; see below. |

The ROCKNIX battery rename (`0503-ROCKNIX-battery-name`) was imported and then
reverted in `d9eeb5f39162`: it renames the power supply to `battery`, but our
`caihong-charge`/`caihong-autocharge` helpers and the `caihong-charge.service`
guard all address `/sys/class/power_supply/qcom-battmgr-bat`, and the driver's
`device/oneplus_charge_control_status` diagnostic lives under that directory
too. The upstream `qcom-battmgr-bat` name is kept.

## Considered but not imported

- **Armada `60-armada-perf-acls.rules`** — grants a group write access to
  cpufreq/devfreq/backlight. We already drive these through the
  power-profiles-daemon build in `packaging/power-profiles-daemon-caihong`, and
  Arch/Debian group names differ from Armada's `wheel`, so it would fight the
  existing policy.
- **ROCKNIX `0121-pmdomain-qcom-rpmhpd-presync-floor-gmu-rails`** (floor the
  GFX/GMXC rails before `sync_state`) — the upstream patch targets a newer
  `rpmhpd.c` that carries `skip_retention_level`/`presync_floor` fields our tree
  does not have, and the patch itself would not compile as written (it assigns
  `skip_retention_level` without a designator). Our tree already has the
  `floor_corner` mechanism, so this needs a careful manual port before it can
  be adopted; it is not in the kernel fork yet.
- **Armada `08e4571` pm8150b charger** — adds new `qcom_fg`/`qcom_pm8150b_charger`
  drivers for a different charger; Caihong uses the southchip SC8547.
- **ROCKNIX handheld quirks** (joypad, fan, analog LEDs, `inputplumber`, fake
  suspend) — tied to gamepad hardware and ROCKNIX's `/storage` layout.
