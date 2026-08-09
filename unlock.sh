#!/bin/sh
# MF286R stock: unlock SPI-NAND write/erase
# dmesg should show: set 2 + zte fixed bad blocks end
# (cat on these sysfs nodes is fake: 100 / 1000)

echo 102 > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed
echo 1   > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
dmesg | tail -5
