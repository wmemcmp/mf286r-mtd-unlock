#!/bin/sh
# MF286R stock: unlock + flash OpenWrt initramfs to "firmware" (usually mtd16)
# Usage: ./write-initramfs.sh /tmp/openwrt-*-mf286r-initramfs-kernel.bin
# WARNING: overwrites stock kernel + start of rootfs. Use MF286R image only.

IMG="${1:?usage: $0 /path/to/initramfs-kernel.bin}"
MTD="${2:-/dev/mtd16}"

[ -f "$IMG" ] || { echo "missing image: $IMG"; exit 1; }
[ -c "$MTD" ] || { echo "missing mtd: $MTD (check: cat /proc/mtd)"; exit 1; }

# 1) unlock
echo 102 > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed
echo 1   > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
dmesg | tail -5
# expect: set 2 + zte fixed bad blocks end

# 2) erase + write firmware
flash_erase "$MTD" 0 0
nandwrite -p "$MTD" "$IMG"
echo "nandwrite_rc=$?"
sync

# 3) lock (optional)
echo 0   > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
echo 101 > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed

echo "done — reboot to try OpenWrt initramfs"
