# ZTE MF286R — stock MTD unlock & OpenWrt initramfs flash

Unlock SPI-NAND write/erase on **stock** ZTE MF286R firmware and install **OpenWrt** by writing an `initramfs-kernel.bin` to the combined **`firmware`** MTD partition (same approach used on the MF286A forum guides), then reboot and `sysupgrade`.

**Target:** ZTE MF286R (ath79 / QCA, stock QSDK Linux 3.3.8, SPI-NAND `ath79-spinand`)  
**Not for:** blind use on other ZTE models without checking `/proc/mtd` and image names.

---

## Warning

- Wrong image or partition can **brick** the router.
- No serial console is assumed — recovery is hard if boot fails.
- Use **MF286R** OpenWrt builds, **not** MF286A.
- Writing `firmware` **overwrites stock kernel and part of stock rootfs**.
- `sysupgrade` on **stock** firmware cannot install OpenWrt images (`missing rootfs` / `platform_check_image` failed). That is expected.

---

## Background (why stock `flash_erase` fails)

On stock, `flash_erase` / `nandwrite` often return:

```text
MEMERASE64 ioctl failed ... error 1 (Operation not permitted)
```

Kernel `dmesg` may show:

```text
illeagl access !!!
```

Two **sysfs** knobs on the SPI-NAND device control this (driver `ath79-spinand`):

| Sysfs node | Write | Effect |
|------------|--------|--------|
| `.../spi0.1/change_speed` | `102` | Disables absolute-address **range check** (factory-style). |
| `.../spi0.1/change_speed` | `101` | Normal mode; range check **on** → `illeagl access` for many ops. |
| `.../spi0.1/bsp_fix` | `1` | Enables erase/write path. |
| `.../spi0.1/bsp_fix` | `0` | Restricts that path again. |

Full paths (stock):

```text
/sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed
/sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
```

**Important:** `cat` on these nodes is **not** the real flag. Stock **show** handlers always print fixed values (`100` / `1000`). Confirm with **`dmesg`**:

| You write | Expected `dmesg` |
|-----------|------------------|
| `echo 102 > change_speed` | `set 2` |
| `echo 101 > change_speed` | `set 1` |
| `echo 1 > bsp_fix` | `zte fixed bad blocks end` |
| `echo 0 > bsp_fix` | `zte fixed bad blocks start` |

### Typical stock MTD map (MF286R)

```text
mtd12  3 MiB   "kernel"     — too small for OpenWrt initramfs (~7+ MiB)
mtd13 26 MiB   "rootfs"
mtd16 29 MiB   "firmware"   — combined kernel+rootfs region (use for initramfs)
```

Confirm on device:

```sh
cat /proc/mtd
```

---

## Method A — raw commands (no scripts)

Run as **root** on stock (telnet/SSH).

### 1) Unlock MTD

```sh
dmesg -c >/dev/null 2>&1 || true

echo 102 > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed
echo 1   > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix

dmesg | tail -10
# expect: set 2
# expect: zte fixed bad blocks end
```

### 2) Optional: single-block smoke test

```sh
# erases only first 128 KiB of kernel — do not reboot without restoring if you stop here
flash_erase /dev/mtd12 0 1
```

### 3) Write OpenWrt initramfs to `firmware`

```sh
# copy image to the router first, e.g. /tmp/openwrt-...-mf286r-initramfs-kernel.bin
ls -l /tmp/openwrt-*-mf286r-initramfs-kernel.bin
grep firmware /proc/mtd

flash_erase /dev/mtd16 0 0
nandwrite -p /dev/mtd16 /tmp/openwrt-*-mf286r-initramfs-kernel.bin

sync
sync
```

### 4) Re-lock (optional) and reboot

```sh
echo 0   > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
echo 101 > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed

reboot
```

### 5) After OpenWrt initramfs boots

```sh
# permanent install — run under OpenWrt, NOT stock
sysupgrade -n /tmp/openwrt-*-mf286r-squashfs-sysupgrade.bin
```

---

## Method B — helper scripts

Copy this repo to the router (USB, scp, etc.), then:

```sh
cd /path/to/zte-mf286r-openwrt-flash
chmod +x unlock.sh lock.sh write-initramfs.sh
```

### Unlock only

```sh
./unlock.sh
```

### Lock only

```sh
./lock.sh
```

### Unlock + erase + `nandwrite` initramfs

```sh
./write-initramfs.sh /tmp/openwrt-25.12.5-ath79-nand-zte_mf286r-initramfs-kernel.bin

# or explicit mtd:
./write-initramfs.sh /tmp/image.bin firmware
./write-initramfs.sh /tmp/image.bin mtd16
```

Options:

```sh
DRY_RUN=1 ./write-initramfs.sh /tmp/image.bin     # print steps only
SKIP_UNLOCK=1 ./write-initramfs.sh /tmp/image.bin # you already unlocked
SKIP_LOCK=1 ./write-initramfs.sh /tmp/image.bin   # leave unlocked after write
```

Then:

```sh
reboot
```

---

## What does *not* work

| Action | Result |
|--------|--------|
| `sysupgrade` OpenWrt image on **stock** | `missing rootfs` / platform check fail |
| `sysupgrade -F` on stock | Still wrong installer/format — brick risk |
| `nandwrite` initramfs to **mtd12 kernel** | Image larger than 3 MiB |
| `echo 101` then erase kernel/firmware | Often `illeagl access` + EPERM |
| Trusting `cat change_speed` / `cat bsp_fix` | Fake show values (`1000` / `100`) |

---

## Files

| File | Purpose |
|------|---------|
| `unlock.sh` | Set `change_speed=102` and `bsp_fix=1` |
| `lock.sh` | Set `bsp_fix=0` and `change_speed=101` |
| `write-initramfs.sh` | Unlock, `flash_erase` + `nandwrite -p` to firmware, optional re-lock |
| `README.md` | This document |

---

## Safety checklist

1. Confirm model is **MF286R**.
2. Confirm OpenWrt file name contains **`mf286r`** and `initramfs-kernel`.
3. Confirm target from `/proc/mtd` is **`firmware`** (often `mtd16`).
4. Prefer keeping a dump of stock `mtd12` (kernel) before experiments.
5. After initramfs boot, use OpenWrt’s own `sysupgrade` for the squashfs image.

---

## License

Scripts and docs are provided as-is, without warranty. You are solely responsible for any damage to your device.

---

## Credits / notes

- Unlock behaviour reverse-engineered from stock `ath79-spinand` sysfs (`change_speed`, `bsp_fix`) and confirmed on-device.
- Writing initramfs to the combined **firmware** MTD follows the same high-level approach discussed for related ZTE CPE models (e.g. MF286A forum guides); partition numbers and unlock sysfs are **MF286R-specific** as documented above.
