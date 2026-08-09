# 🚀 ZTE MF286R — Flash Kilidini Aç & OpenWrt Initramfs Yaz

_Tek satırda: stok shell üzerinden (serial yok) MF286R NAND yazma kilidini açıp OpenWrt initramfs yüklemenizi sağlar. Risk yüksek — dikkatli olun!_

---

## Özet

Bu depo, ZTE MF286R cihazındaki stok `ath79-spinand` sürücüsünün silme/yazma yollarını engelleyen korumayı geçip OpenWrt initramfs imajını (boot için) flash’a aktarmanız için gereken kısa ve güvenli adımları sağlar. Stok firmware üzerinde root erişiminiz olsa bile kısıtlamalar yüzünden `flash_erase` / `nandwrite` hatası alırsınız — burada o kilidi nasıl açacağınızı, imajı nereye yazacağınızı ve işlemi nasıl kapatacağınızı bulacaksınız.

> Uyarı: Bu işlem ROUTER'ı tuğla yapabilir. Cihazda seri konsol yoksa kurtarma zor veya imkânsız olabilir. Tüm sorumluluk size aittir.

---

## Hızlı Bakış (ne yapıyoruz)

- Stok kernel sürücüsündeki iki sysfs "anahtarı" (`change_speed`, `bsp_fix`) doğru değerlere ayarlanarak yazma/erase yolu açılır.
- OpenWrt initramfs (7–8 MiB) doğrudan `firmware` bölümüne (ör. `/dev/mtd16`) yazılır — stok `kernel` bölümü (`mtd12`) genelde çok küçük.
- İlk önce initramfs ile cihazı boot edip OpenWrt'e geçtikten sonra `sysupgrade` ile kalıcı kurulum yapılır.

---

## Hızlı Komutlar — Kopyala/Yapıştır

İlk olarak kilidi aç:

```sh
# Kilidi aç
echo 102 > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed
echo 1   > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
# Loglarda handler'ın çalıştığını kontrol et
dmesg | tail -5
```

Aradığınız çıktı (örnek):

```text
set 2
zte fixed bad blocks end
```

İş bitince tekrar kilitle:

```sh
echo 0   > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
echo 101 > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed
```

Alternatif: depo içindeki `unlock.sh` / `lock.sh` script'lerini kullanın.

---

## OpenWrt initramfs Yazma Adımları

1. Partition tablosunu doğrulayın:

```sh
cat /proc/mtd
# mtd16 … "firmware" olan satırı bulun (isim/numara farklı olabilir — grep firmware ile doğrulayın)
```

2. Kilidi açın (yukarıdaki adımlar).

3. `firmware` bölümünü silin ve initramfs'i yazın:

```sh
# örnek: /tmp/openwrt-*-mf286r-initramfs-kernel.bin
flash_erase /dev/mtd16 0 0
nandwrite -p /dev/mtd16 /tmp/openwrt-*-mf286r-initramfs-kernel.bin
echo "nandwrite_rc=$?"
sync
reboot
```

Tek komutta: (depo içindeki yardımcı script'i kullan)

```sh
chmod +x write-initramfs.sh
./write-initramfs.sh /tmp/openwrt-*-mf286r-initramfs-kernel.bin
reboot
```

4. OpenWrt initramfs ile cihaz açıldıktan sonra (çoğunlukla LAN: 192.168.1.1):

```sh
# OpenWrt boot ettikten sonra sysupgrade ile kalıcı kurulum
sysupgrade -n /tmp/openwrt-*-mf286r-squashfs-sysupgrade.bin
```

---

## Hangi bölüm? (typical)

```text
mtd12  3 MiB   kernel      -> genelde initramfs sığmaz
mtd13 26 MiB   rootfs
mtd16 29 MiB   firmware    -> burada kernel+rootfs penceresi, initramfs buraya yazılır
```

Not: `firmware` özel bir format değildir — fiziksel flash aynı bölgenin farklı bir görüntüsüdür. U-Boot, boot edilebilir imajın o başlangıçta olmasını bekler.

---

## Mevcut script'ler

- `unlock.sh` — sysfs anahtarlarını uygun değerlere ayarlar (102 & bsp_fix=1).
- `lock.sh` — anahtarları eski, güvenli değerlere geri alır (101 & bsp_fix=0).
- `write-initramfs.sh` — unlock → flash_erase → nandwrite -p → lock; parametre alır (imaj yolu, hedef mtd opsiyonel).
- `docs/KERNEL_REVERSE_ENGINEERING.md` — kernel içinde store/permission mekanizmasının tersine mühendislik notları (IDA/offsetler).

---

## Sık Yapılan Hatalar / Dikkat Edilecekler

- Stok `sysupgrade` ile doğrudan OpenWrt `.bin` yüklemeye çalışmak → `missing rootfs` hatası (beklenen davranış). Önce initramfs ile boot edin.
- `nandwrite` ile initramfs'i `mtd12` üzerine yazmaya çalışma — çoğu zaman sığmaz.
- `cat` ile sysfs değerlerine güvenme — bazı `show` fonksiyonları sabit değer döndürür (100/1000 gibi).
- `echo` komutundan sonra mutlaka `dmesg` ile handlers'ın çağrıldığını kontrol edin.

---

## Güvenlik & Risk

Bu repo bilgi amaçlıdır. Yaptığınız her işlem fiziksel donanımı etkiler ve geri dönüşü olmayabilir. Seri konsol olmadan brick olmuş cihazı kurtarma çok zor olabilir. Devam etmeden önce:

- Yedek boot/uboot bilgilerinizi alın (mümkünse).
- İmaj dosyasının bütünlüğünü doğrulayın.
- Şarj/elektrik kesintisinden korunmuş ortamda çalışın.

---

## Katkılar & Kaynaklar

- Orijinal tersine mühendislik notları: `docs/KERNEL_REVERSE_ENGINEERING.md`.
- Forumlarda MF286A tecrübeleri ve benzer cihaz kurulum notları.

---

## Lisans

Bu proje "AS-IS" sunulur. Herhangi bir garanti yoktur. Brick riski tamamen kullanıcıya aittir.

---

Hazır. README'yi şu an repoya kaydettim ve daha okunaklı, Türkçe hızlı başlangıç odaklı bir rehber hâline getirdim. İsterseniz şimdi README'yi İngilizce ile eşleştireyim ya da görsellik için birkaç rozet (shields.io) ve kısa GIF/diagram ekleyebilirim.
