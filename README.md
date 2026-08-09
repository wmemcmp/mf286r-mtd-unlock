# ZTE MF286R — MTD unlock & OpenWrt initramfs

**Language / Dil:** [English](#english) · [Türkçe](#türkçe)

**RE notes:** [docs/KERNEL_REVERSE_ENGINEERING.md](docs/KERNEL_REVERSE_ENGINEERING.md) — IDA Pro / MIPS BE kernel write-gate analysis (offsets, sysfs, range table).

Stock root shell → unlock SPI-NAND → `nandwrite` OpenWrt initramfs to **`firmware`** → reboot → `sysupgrade`.

---

# English

## Warning

- Can **brick** the device. No serial assumed.
- Use **MF286R** images only (not MF286A).
- Writing `firmware` overwrites stock **kernel + part of rootfs**.
- Stock `sysupgrade` **cannot** install OpenWrt (`missing rootfs` is normal).

## Why unlock?

Stock erase/write often fails with `EPERM` / `illeagl access !!!`.

| Write | Meaning | dmesg |
|-------|---------|--------|
| `change_speed` **102** | range-check **off** | `set 2` |
| `change_speed` **101** | range-check **on** | `set 1` |
| `bsp_fix` **1** | allow erase/write | `zte fixed bad blocks end` |
| `bsp_fix` **0** | restrict again | `zte fixed bad blocks start` |

```text
/sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed
/sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
```

`cat` on these files is **fake** (`100` / `1000`). Trust **dmesg** only.

### MTD map (check on device)

```sh
cat /proc/mtd
```

```text
mtd12  3 MiB   kernel     ← too small for initramfs
mtd16 29 MiB   firmware   ← use this for initramfs
```

---

## Quick path (copy-paste)

```sh
# 1) unlock
echo 102 > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed
echo 1   > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
dmesg | tail -5
# set 2 + zte fixed bad blocks end

# 2) erase + write firmware (image must be on the router)
flash_erase /dev/mtd16 0 0
nandwrite -p /dev/mtd16 /tmp/openwrt-*-mf286r-initramfs-kernel.bin
echo "nandwrite_rc=$?"
sync

# 3) lock (optional)
echo 0   > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
echo 101 > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed

# 4) boot initramfs
reboot
```

After OpenWrt boots:

```sh
sysupgrade -n /tmp/openwrt-*-mf286r-squashfs-sysupgrade.bin
```

Optional smoke test (1× 128 KiB only):

```sh
# after unlock
flash_erase /dev/mtd12 0 1
```

---

## Scripts

```sh
chmod +x unlock.sh lock.sh write-initramfs.sh

./unlock.sh
./write-initramfs.sh /tmp/openwrt-*-mf286r-initramfs-kernel.bin
# optional: ./write-initramfs.sh /tmp/image.bin /dev/mtd16
reboot
```

| Script | Does |
|--------|------|
| `unlock.sh` | `102` + `bsp_fix=1` |
| `lock.sh` | `bsp_fix=0` + `101` |
| `write-initramfs.sh` | unlock → erase → nandwrite → lock |
| `docs/KERNEL_REVERSE_ENGINEERING.md` | IDA Pro analysis: uImage layout, VAs, `bsp_fix` / `change_speed`, range allow-list |

---

## Do not

| Don’t | Why |
|-------|-----|
| Stock `sysupgrade` / `-F` | Wrong format, brick risk |
| initramfs → **mtd12** | Image > 3 MiB |
| Unlock with **101** only | Often `illeagl access` |
| Trust `cat` on sysfs | Fake values |

---

## License

As-is, no warranty. You break it, you keep both pieces.

---

# Türkçe

## Uyarı

- Cihaz **brick** olabilir. Serial yok varsayımı.
- Sadece **MF286R** imajı (MF286A değil).
- `firmware` yazımı stok **kernel + rootfs başını** ezer.
- Stok `sysupgrade` OpenWrt kurmaz (`missing rootfs` normal).

## Neden kilit açılır?

Stokta silme/yazma sıkça `EPERM` / `illeagl access !!!` verir.

| Yaz | Anlam | dmesg |
|-----|--------|--------|
| `change_speed` **102** | range-check **kapalı** | `set 2` |
| `change_speed` **101** | range-check **açık** | `set 1` |
| `bsp_fix` **1** | sil/yaz serbest | `zte fixed bad blocks end` |
| `bsp_fix` **0** | tekrar kısıtla | `zte fixed bad blocks start` |

```text
/sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed
/sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
```

`cat` **sahte** (`100` / `1000`). Sadece **dmesg**’e bak.

### MTD (cihazda kontrol)

```sh
cat /proc/mtd
```

```text
mtd12  3 MiB   kernel     ← initramfs sığmaz
mtd16 29 MiB   firmware   ← initramfs buraya
```

---

## Hızlı yol (kopyala-yapıştır)

```sh
# 1) kilit aç
echo 102 > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed
echo 1   > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
dmesg | tail -5
# set 2 + zte fixed bad blocks end

# 2) firmware sil + yaz (imaj cihazda olmalı)
flash_erase /dev/mtd16 0 0
nandwrite -p /dev/mtd16 /tmp/openwrt-*-mf286r-initramfs-kernel.bin
echo "nandwrite_rc=$?"
sync

# 3) kilidi kapat (isteğe bağlı)
echo 0   > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
echo 101 > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed

# 4) initramfs boot
reboot
```

OpenWrt açılınca:

```sh
sysupgrade -n /tmp/openwrt-*-mf286r-squashfs-sysupgrade.bin
```

Tek block test (isteğe bağlı):

```sh
# kilit açıkken
flash_erase /dev/mtd12 0 1
```

---

## Scriptler

```sh
chmod +x unlock.sh lock.sh write-initramfs.sh

./unlock.sh
./write-initramfs.sh /tmp/openwrt-*-mf286r-initramfs-kernel.bin
reboot
```

| Script | Ne yapar |
|--------|----------|
| `unlock.sh` | `102` + `bsp_fix=1` |
| `lock.sh` | `bsp_fix=0` + `101` |
| `write-initramfs.sh` | unlock → erase → nandwrite → lock |
| `docs/KERNEL_REVERSE_ENGINEERING.md` | IDA Pro analizi (İngilizce): offset, VA, sysfs, range tablosu |

---

## Yapma

| Yapma | Neden |
|--------|--------|
| Stok `sysupgrade` / `-F` | Format uymaz, brick |
| initramfs → **mtd12** | 3 MiB’den büyük |
| Sadece **101** ile unlock | `illeagl access` |
| sysfs `cat`’e güven | Sahte değer |

---

## Lisans

Olduğu gibi, garanti yok. Sorumluluk size aittir.

[↑ Top / Başa dön](#zte-mf286r--mtd-unlock--openwrt-initramfs)
