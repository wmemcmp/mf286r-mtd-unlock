#!/bin/sh
# MF286R stock: re-lock SPI-NAND
# dmesg should show: zte fixed bad blocks start + set 1

echo 0   > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
echo 101 > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed
dmesg | tail -5
