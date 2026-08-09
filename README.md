# ZTE MF286R — unlock flash & drop OpenWrt initramfs

**[English](#english)** · **[Türkçe](#türkçe)**

Kernel write-gate RE (IDA / offsets): [docs/KERNEL_REVERSE_ENGINEERING.md](docs/KERNEL_REVERSE_ENGINEERING.md)

---

# English

## The problem

On stock firmware you have root, but:

```text
flash_erase /dev/mtd12 0 1
# MEMERASE64 ... error 1 (Operation not permitted)

dmesg
# illeagl access !!!
```

That is **not** missing root. The stock `ath79-spinand` driver refuses erase/write until two sysfs knobs are set. ZTE’s own `mtd_write` / `facSvr` do not implement a secret ioctl unlock either — they call the same MTD ioctls and hit the same wall unless those knobs are set (FOTA paths set `change_speed` themselves).

Also:

- `cat` on the sysfs nodes is useless (`100` / `1000` are hardcoded show stubs).
- Use **dmesg** after `echo` to confirm the store handlers ran.
- OpenWrt **initramfs** is ~7–8 MiB; stock **`kernel` (mtd12)** is only **3 MiB**. Write initramfs to **`firmware` (mtd16, 29 MiB)** — same idea as MF286A forum installs. Use an **mf286r** image, not mf286a.

Stock `sysupgrade` of an OpenWrt `.bin` will fail (`missing rootfs`). That is expected. Boot initramfs first, then `sysupgrade` from OpenWrt.

**This can brick the router.** No serial → hard recovery. You own the risk.

---

## Unlock (copy-paste)

```sh
echo 102 > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed
echo 1   > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
dmesg | tail -5
```

You want:

```text
set 2
zte fixed bad blocks end
```

| Knob | Value | Role |
|------|--------|------|
| `change_speed` | **102** | turn **off** the address range check (101 turns it **on** → `illeagl access`) |
| `bsp_fix` | **1** | allow the SPI-NAND erase/write path |

Lock again when done:

```sh
echo 0   > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
echo 101 > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed
```

Or: `./unlock.sh` / `./lock.sh`

---

## Write OpenWrt initramfs → firmware

Confirm layout:

```sh
cat /proc/mtd
# mtd16 ... "firmware"   (name/number can vary — grep firmware)
```

```sh
# unlock first (above)

flash_erase /dev/mtd16 0 0
nandwrite -p /dev/mtd16 /tmp/openwrt-*-mf286r-initramfs-kernel.bin
echo "nandwrite_rc=$?"
sync
reboot
```

One-shot script (unlock + erase + write + lock):

```sh
chmod +x write-initramfs.sh
./write-initramfs.sh /tmp/openwrt-*-mf286r-initramfs-kernel.bin
# default target /dev/mtd16 — or: ./write-initramfs.sh /tmp/img.bin /dev/mtd16
reboot
```

After OpenWrt comes up (LAN often `192.168.1.1`):

```sh
sysupgrade -n /tmp/openwrt-*-mf286r-squashfs-sysupgrade.bin
```

Optional: single 128 KiB erase test on kernel after unlock — `flash_erase /dev/mtd12 0 1` (don’t reboot mid-test without a plan).

---

## Partitions (typical MF286R)

```text
mtd12  3 MiB   kernel      too small for initramfs
mtd13 26 MiB   rootfs
mtd16 29 MiB   firmware    kernel+rootfs window — nandwrite initramfs here
```

`firmware` is not a magic install format; it’s the same flash starting at the kernel region. U-Boot still cares about a bootable image at that start.

---

## Don’t bother

- Stock `sysupgrade` / `sysupgrade -F` for OpenWrt images  
- `nandwrite` initramfs onto **mtd12**  
- Only `bsp_fix=1` with `change_speed=101` if you still see `illeagl access`  
- Believing `cat change_speed` / `cat bsp_fix`

---

## Repo files

| File | |
|------|--|
| `unlock.sh` | `102` + `bsp_fix=1` |
| `lock.sh` | `0` + `101` |
| `write-initramfs.sh` | unlock → `flash_erase` → `nandwrite -p` → lock |
| `docs/KERNEL_REVERSE_ENGINEERING.md` | IDA notes: uImage, VAs, stores, range table |

No warranty. Brick risk is yours.

---

# Türkçe

## Sorun

Stokta root var ama:

```text
flash_erase /dev/mtd12 0 1
# Operation not permitted

dmesg
# illeagl access !!!
```

Bu “root yok” değil. Stok **`ath79-spinand`** sürücüsü, iki sysfs ayarı olmadan silme/yazmayı kesiyor. `mtd_write` / `facSvr` gizli ioctl ile kilidi açmıyor; aynı MTD yoluna gidiyorlar.

Ek notlar:

- Sysfs’te `cat` **işe yaramaz** (show hep `100` / `1000`).
- `echo` sonrası **`dmesg`** ile doğrula.
- OpenWrt **initramfs** ~7–8 MiB; stok **`kernel` (mtd12)** sadece **3 MiB**. Initramfs’i **`firmware` (mtd16, 29 MiB)** üzerine yaz (MF286A forumlarıyla aynı fikir). İmaj **mf286r** olsun, mf286a değil.
- Stokta OpenWrt `sysupgrade` → `missing rootfs` normal. Önce initramfs boot, sonra OpenWrt içinden `sysupgrade`.

**Brick riski var.** Serial yoksa kurtarma zor. Sorumluluk sende.

---

## Kilit aç (kopyala-yapıştır)

```sh
echo 102 > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed
echo 1   > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
dmesg | tail -5
```

İstediğin satırlar:

```text
set 2
zte fixed bad blocks end
```

| Ayar | Değer | İş |
|------|--------|-----|
| `change_speed` | **102** | range-check **kapalı** (101 açık → `illeagl access`) |
| `bsp_fix` | **1** | SPI-NAND sil/yaz yolu açık |

İş bitince:

```sh
echo 0   > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
echo 101 > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed
```

veya `./unlock.sh` / `./lock.sh`

---

## OpenWrt initramfs → firmware

```sh
cat /proc/mtd
# mtd16 ... "firmware"
```

```sh
# önce unlock (yukarı)

flash_erase /dev/mtd16 0 0
nandwrite -p /dev/mtd16 /tmp/openwrt-*-mf286r-initramfs-kernel.bin
echo "nandwrite_rc=$?"
sync
reboot
```

Hepsi bir arada:

```sh
chmod +x write-initramfs.sh
./write-initramfs.sh /tmp/openwrt-*-mf286r-initramfs-kernel.bin
reboot
```

OpenWrt açılınca:

```sh
sysupgrade -n /tmp/openwrt-*-mf286r-squashfs-sysupgrade.bin
```

---

## Partition özeti

```text
mtd12  3 MiB   kernel     initramfs sığmaz
mtd16 29 MiB   firmware   initramfs buraya
```

---

## Boşuna deneme

- Stok `sysupgrade` / `-F` ile OpenWrt  
- initramfs → **mtd12**  
- Sadece `101` + erase  
- sysfs `cat`’e güvenmek  

---

## Dosyalar

| Dosya | |
|--------|--|
| `unlock.sh` / `lock.sh` | kilit aç / kapa |
| `write-initramfs.sh` | unlock + sil + yaz + lock |
| `docs/KERNEL_REVERSE_ENGINEERING.md` | IDA / offset notları |

Garanti yok; brick riski size aittir.

[↑ top](#zte-mf286r--unlock-flash--drop-openwrt-initramfs)
