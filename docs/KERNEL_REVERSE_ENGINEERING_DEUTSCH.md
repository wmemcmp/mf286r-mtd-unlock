# Notizen zum Kernel-Reverse-Engineering — ZTE MF286R SPI-NAND-Schreibsperre

**Geltungsbereich:** Werkseitiger Linux-Kernel, ausgelesen aus der MTD-Partition `mtd12` (`"kernel"`), offline analysiert, um das Userspace-`EPERM` / `illeagl access` bei `flash_erase` / `nandwrite` zu erklären.

**Rollenkontext:** Sicherheitsforschung an eingebetteter Firmware (statisches RE eines produktiven MIPS-BE-Kernels; keine Exploit-Entwicklung).

**Artefakte:**

| Artefakt | Beschreibung |
|----------|-------------|
| Quelle auf dem Gerät | Live-Dump von `/dev/mtd12` (3 MiB) |
| Datei | `mtd12_kernel.bin` |
| Dekomprimiert | `vmlinux.bin` (~3,57 MiB Roh-Image) |
| Werkzeuge | IDA Pro (Hex-Rays), manuelles MIPS-BE-Disassemblieren, String-/Xref-Rekonstruktion |

---

## 1. Bedrohungsmodell und Fragestellung

**Beobachtung (Userspace, Werks-Root):**

```text
flash_erase /dev/mtd12 0 1
→ MEMERASE64 ioctl failed, errno 1 (EPERM)

dmesg
→ illeagl access !!!   (originaler Tippfehler beibehalten)
```

**Frage:** Ist der Schreibschutz implementiert als:

1. ein proprietärer Userspace-`ioctl`-„Entsperrschlüssel" oder  
2. eine **kernelseitig durchgesetzte Richtlinie** im SPI-NAND-Treiber / MTD-Pfad?

**Ergebnis:** (2). Die Richtlinie liegt im Werks-Treiber `ath79-spinand` und im zugehörigen MTD-Glue-Code: zwei **sysfs-Store-Handler** plus eine **Zulassungsliste für Adressbereiche**, nicht ein magischer `ioctl`-Aufruf in den ZTE-Werkswerkzeugen (`mtd_write`, `facSvr` usw.).

---

## 2. Kernel-Image-Container (uImage)

### 2.1 Dateiaufbau

```text
Offset   Größe       Inhalt
------   ----------  ------------------------------------------
0x0000   64 Byte     Legacy-uImage-Header von U-Boot
0x0040   8 Byte      Hersteller-/benutzerdef. Header vor LZMA
0x0048   ~1,21 MiB   LZMA-Nutzdaten (IH_COMP_LZMA)
…        Padding     Rest der 3-MiB-Partition (ungenutzt / 0x00…0xFF)
```

### 2.2 uImage-Header (Big-Endian)

| Feld | Wert | Anmerkungen |
|-------|--------|--------|
| Magic | `0x27051956` | Standard-U-Boot-Image |
| Image-Größe | `0x001276D4` (1 210 068) | Länge der komprimierten Nutzdaten |
| Lade-/Einsprungadresse | `0x80060000` | MIPS-KSEG0-Ladeadresse |
| Betriebssystem / Architektur / Typ | Linux / MIPS / kernel | |
| Komprimierung | `3` = LZMA | |
| Name | `MIPS OpenWrt Linux-3.3.8` | Werksstand ist ein QSDK-basierter OpenWrt-Quellbaum der 12er-Ära |

### 2.3 Benutzerdefinierter 8-Byte-Header vor LZMA

```text
00 12 76 CC  00 00 00 00
```

Interpretiert als Big-Endian-Längenmetadaten unmittelbar angrenzend an den komprimierten Datenstrom. **Der LZMA-alone-Stream beginnt bei Datei-Offset `0x48` (Header 0x40 + 8).**

Dekompression (offline):

```text
payload = file[0x40 : 0x40 + image_size]
lzma_stream = payload[8:]
vmlinux.bin = lzma.decompress(lzma_stream, format=FORMAT_ALONE)
```

Das resultierende `vmlinux.bin` ist ein **rohes gelinktes Kernel-Image** (kein ELF). Für die VA-Rekonstruktion verwendete Link-/Ladebasis:

```text
VA = 0x80060000 + file_offset
```

---

## 3. Integrierte cmdline und MTD-Topologie

In das Image eingebetteter String (Datei-Offset ≈ `0x408`):

```text
board=AP152 console=ttyS0,115200
mtdparts=
  spi0.0:640k(u-boot),128k(u-boot-env),1280k(reserved1);
  spi0.1:640k(fota-flag),512k(art),512k(mac),768k(reserved2),
         4m(cfg-param),4m(log),640k(oops),5m(reserved3),
         8m(web),3m(kernel),26m(rootfs),25m(data),50m(fota),
         29m@0x1800000(firmware)
```

**Folgerungen:**

- Duale SPI-Topologie: **NOR-artiges** Layout auf `spi0.0`, großer **SPI-NAND** auf `spi0.1` (`ath79-spinand`).
- Die Namen im laufenden `/proc/mtd` stimmen mit dieser Zuordnung überein (`kernel` = 3 MiB, `firmware` = 29 MiB @ Chip-Offset `0x1800000`).
- Die kombinierte `firmware`-Region umfasst Werks-Kernel + rootfs – relevant für initramfs-Installationsmethoden, die die gesamte Region per `nandwrite` schreiben.

---

## 4. IDA-Pro-Methodik

### 4.1 Hinweise zum Laden

| Einstellung | Korrekt | Falls falsch |
|---------|---------|----------|
| Prozessor | MIPS | |
| Byte-Reihenfolge | **Big-Endian** | LE-Dword-Lesevorgänge zerstören Xrefs / Decompiler |
| Image-Basis | **`0x80060000`** | String-Zeiger und `lui/addiu`-Paare stimmen nicht überein |
| Dateityp | Binär / roh | Kein ELF |

Ein Laden mit Basis `0` und Little-Endian-Analyse ermöglicht weiterhin die **String-Inventarisierung** und die Arbeit mit **rohen Byte-Mustern**; die nachfolgenden Notizen verwenden **Datei-Offsets** zuzüglich **VA = 0x80060000 + off**.

### 4.2 Arbeitsablauf

1. Strings von Interesse extrahieren: `bsp_fix`, `change_speed`, `ath79-spinand`, `illeagl access`, `write enable failed`, Lösch-Pfade.
2. **Daten-Zeiger** auf Strings rekonstruieren (BE-`uint32` = VA) → `device_attribute`-Tabellen.
3. `show`-/`store`-Funktionszeiger auflösen → Datei-Offsets der Handler.
4. Code nach Zugriffen auf globale Flags im Stil `lui $r, 0x8040` + `lw/sw …, -0x1D30(r)` durchsuchen.
5. Kontrollfluss rund um Löschen/Schreiben und Bereichsprüfung rekonstruieren (manuelle BE-Dekodierung, wenn Hex-Rays versagt).

---

## 5. sysfs-Steuerungsebene (`ath79-spinand`)

### 5.1 Treiber-Identität (rodata-Strings)

Cluster um den Datei-Offset **`0x2EB300`**:

```text
VA 0x8034B300  "ath79-spinand"
VA 0x8034B310  "change_speed"
VA 0x8034B320  "bsp_fix"
```

Benachbarte Betriebsmeldungen:

```text
write enable failed!!
error %d lock block
error %d set otp / get otp
erase block failed!
erase fail
zte fixed bad blocks start / end
set 1 / set 2
illeagl access !!!
```

### 5.2 `device_attribute`-Tabelle (Daten)

**Datei-Offset `0x32965C`** (VA `0x8038965C`):

```text
Offset (Datei)   Inhalt (BE-Interpretation)
-------------    ----------------------------------------------
0x32965C         name  → VA 0x8034B310  "change_speed"
0x329660         mode  → 0x01A40000, gepackte Darstellung von umode 0x01A4
0x329664         show  → VA 0x801FDF54  → Datei 0x19DF54
0x329668         store → VA 0x801FDEC0  → Datei 0x19DEC0
0x32966C         name  → VA 0x8034B320  "bsp_fix"
0x329670         mode  → 0x01A40000
0x329674         show  → VA 0x801FDF40  → Datei 0x19DF40
0x329678         store → VA 0x801FDE44  → Datei 0x19DE44
```

Auf dem Gerät beobachtete Userspace-Pfade:

```text
/sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed
/sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
```

### 5.3 Globale Richtlinien-Flags (.bss / Daten)

Zugriff erfolgt wie folgt:

```asm
lui  $r, 0x8040
lw/sw $t, -0x1D30($r)   # bsp_fix-Flag
lw/sw $t, -0x1D24($r)   # change_speed-Flag  (imm 0xE2DC)
```

| Flag | VA | Ungef. Datei-Offset | Gesetzt durch store |
|------|-----|---------------------|--------------|
| `bsp_fix_flag` | `0x803FE2D0` | `0x39E2D0` | `bsp_fix`-store |
| `change_speed_flag` | `0x803FE2DC` | `0x39E2DC` | `change_speed`-store |

---

## 6. Handler-Semantik (Datei-Offsets)

### 6.1 `bsp_fix`-store – `0x19DE44`

Aus dem Disassemblat rekonstruierter Pseudocode:

```c
// ssize_t bsp_fix_store(..., const char *buf, size_t count)
long v = simple_strtol(buf, /* Basis 10 */);

if (v == 0) {
    printk("zte fixed bad blocks start\n");
    bsp_fix_flag = 0;
} else if (v == 1) {
    printk("zte fixed bad blocks end\n");
    bsp_fix_flag = 1;
}
return count;
```

**Bestätigung auf dem Gerät:** `echo 1 > bsp_fix` → dmesg: `zte fixed bad blocks end`.

### 6.2 `change_speed`-store – `0x19DEC0`

```c
long v = simple_strtol(buf, 10);

if (v == 101) {
    printk("set 1\n");
    change_speed_flag = 1;   // "normal"
} else if (v == 102) {
    printk("set 2\n");
    change_speed_flag = 0;   // "werksartig" für Flash-Werkzeuge
}
return count;
```

### 6.3 show-Handler – absichtlich nicht aussagekräftig

| Funktion | Datei-Offset | Verhalten |
|----------|-------------|----------|
| `bsp_fix_show` | `0x19DF40` | Gibt die Konstante **`100`** aus (liest das Flag nicht) |
| `change_speed_show` | `0x19DF54` | Gibt die Konstante **`1000`** aus |

Sicherheitshinweis für Betreiber: **Vertrauen Sie dem `cat` dieser Attribute nicht**, wenn es um den Zustand geht. Nutzen Sie die dmesg-Seiteneffekte des store.

### 6.4 Vom Flash-Pfad verwendeter `change_speed`-Getter – `0x19F354`

```asm
lui     $v0, 0x8040
lw      $v0, -0x1D24($v0)    # change_speed_flag
xori    $v0, $v0, 1
jr      $ra
sltiu   $v0, $v0, 1          # Delay Slot: Rückgabe (flag == 1)
```

| `change_speed` geschrieben | flag | Getter gibt zurück |
|------------------------|------|----------------|
| `101` | 1 | **1** |
| `102` | 0 | **0** |
| BSS-Standard 0 | 0 | **0** |

---

## 7. Adressbereichs-Zulassungsliste (`illeagl access`)

### 7.1 Prüffunktion – Datei `0x19AA34`

- Durchläuft **3** Tabelleneinträge zu je **16 Byte**.
- Tabellenbasis: `lui 0x8038` + `addiu 0x53C0` → VA **`0x803853C0`**, Datei **`0x3253C0`**.

### 7.2 Tabelleninhalt (Big-Endian-Wörter)

```text
Eintrag 0:  0x00000000  0x01800000  0x00000000  0x01B00000
            → Chip-Bereich [0x1800000, 0x1B00000)  = 3 MiB   ("kernel"-Fenster)

Eintrag 1:  0x00000000  0x01B00000  0x00000000  0x03500000
            → Chip-Bereich [0x1B00000, 0x3500000)  = 26 MiB  ("rootfs"-Fenster)

Eintrag 2:  Steuer-/Sentinel-Wörter (0x3, 0, 1, 2)
```

Entspricht der cmdline `29m@0x1800000(firmware)` = kernel+rootfs.

### 7.3 Sperre in der übergeordneten Schreib-/Lösch-Funktion – Datei `0x19AB90`

```c
if (change_speed_getter() != 0) {          // wahr, wenn flag == 1 (echo 101)
    if (range_check(addr, len) == -1) {
        printk("illeagl access !!!\n");
        return -EPERM;                     // -1
    }
}
// weiter mit Lösch-/Schreib-Setup
```

**Empirische Zuordnung:**

| Betreiber setzt | Getter | Bereichsprüfung | Typisches Ergebnis bei `mtd12`-Löschung @ 0 |
|---------------|--------|-------------|--------------------------------------|
| `change_speed=101` | 1 | **läuft** | `illeagl access` + EPERM (partitionsrelative 0 wird oft nicht als absolute 0x1800000 akzeptiert) |
| `change_speed=102` | 0 | **übersprungen** | Fährt mit dem tieferliegenden Lösch-Pfad fort |

### 7.4 Aufrufstellen der Bereichsprüfung (`jal` nach `0x19AA34`)

Datei-Offsets (nicht vollständig): `0x19ABAC`, `0x19ACF8`, `0x19AF5C` – Flash-I/O-Pfade, keine Werks-Userspace-Binärdateien.

---

## 8. `bsp_fix`-Verwender (Lösch-Pfad)

Lesezugriffe auf `bsp_fix_flag` wurden bei Datei **`0x19B0F4`** und **`0x19B1C4`** innerhalb der SPI-NAND-Lösch-/Scan-Logik beobachtet:

- Wenn flag `== 1` ist, führt ein Zweig eine zusätzliche Behandlung von Block-Map / Statusbits durch und gibt `zte fix i=%d, left badblocks=%d` aus.
- In Kombination mit `change_speed=102` ist dies das **beobachtete funktionierende Entsperr-Paar** für das massenhafte Löschen/Schreiben der kernel-/firmware-Regionen.

Die genaue Programmierung der Hardware-Statusregister erfolgt im herstellerspezifischen SPI-NAND-Sequenzcode desselben Treibers (Strings: write enable, set/get otp, lock block); die sysfs-Flags sind die **Richtlinien-Stellschrauben**, die root zur Verfügung stehen.

---

## 9. Userspace-Werkzeuge (Negativbefunde)

Statisches RE des Werks-Userspace (gleicher Firmware-Baum):

| Binärdatei | Befund |
|--------|---------|
| `mtd_write` | Nur Standard-`MEMGETINFO` / `MEMUNLOCK` / `MEMERASE` – kein proprietärer Entsperr-ioctl |
| `facSvr` | Ruft `flash_erase` / `nandwrite` auf `mtd11`–`mtd13` per Shell auf, ohne sysfs-Entsperrung |
| `mainControl` | Kein MTD-Flash-Pfad für den Kernel |
| `update_control` | Verwendet `change_speed` 101/102 im Umfeld von FOTA; stützt sich weiterhin auf dieselbe Kernel-Richtlinie |

Schlussfolgerung für die Installationsdokumentation: **Das Kernel-sysfs ist die Entsperr-Schnittstelle**, nicht ein versteckter ioctl in den ZTE-CLI-Werkzeugen.

---

## 10. Entsperr-Anleitung für Betreiber (validiert)

```sh
echo 102 > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed
echo 1   > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
dmesg | tail -5
# set 2
# zte fixed bad blocks end

flash_erase /dev/mtd16 0 0
nandwrite -p /dev/mtd16 /tmp/openwrt-*-mf286r-initramfs-kernel.bin
```

Fehlerfall, wenn nur `bsp_fix=1` + `change_speed=101` gesetzt ist:

```text
dmesg: illeagl access !!!
flash_erase: Operation not permitted
```

---

## 11. Offset-Schnellreferenz

| Element | Datei-Offset | VA (Basis `0x80060000`) |
|------|-------------|-------------------------|
| uImage-Header | `0x0` | — |
| LZMA-Beginn | `0x48` | — |
| Integrierte cmdline | ~`0x408` | ~`0x80060408` |
| `ath79-spinand`-String | `0x2EB300` | `0x8034B300` |
| `change_speed`-String | `0x2EB310` | `0x8034B310` |
| `bsp_fix`-String | `0x2EB320` | `0x8034B320` |
| `illeagl access`-String | `0x2EA654` | `0x8034A654` |
| `dev_attr`-Tabelle | `0x32965C` | `0x8038965C` |
| Bereichstabelle | `0x3253C0` | `0x803853C0` |
| `bsp_fix`-store | `0x19DE44` | `0x801FDE44` |
| `change_speed`-store | `0x19DEC0` | `0x801FDEC0` |
| `bsp_fix`-show | `0x19DF40` | `0x801FDF40` |
| `change_speed`-show | `0x19DF54` | `0x801FDF54` |
| `change_speed`-Getter | `0x19F354` | `0x801FF354` |
| `range_check` | `0x19AA34` | `0x801FAA34` |
| Bereichssperre (Aufrufer) | `0x19AB90` | `0x801FAB90` |
| `bsp_fix_flag` | ~`0x39E2D0` | `0x803FE2D0` |
| `change_speed_flag` | ~`0x39E2DC` | `0x803FE2DC` |

---

## 12. Hinweise zur IDA-Pro-Sitzung (Reproduktion)

1. Datei → Öffnen: `vmlinux.bin` (dekomprimiert), oder vom uImage ausgehen und wie in §2 dekomprimieren.
2. Prozessor: **MIPS**, **Big-Endian**, ROM-Startadresse **`0x80060000`**.
3. Zu `0x801FDE44` / `0x801FDEC0` (stores) springen, oder zu Datei `0x19DE44`, wenn die Basis null ist.
4. Querverweis (Xref) auf den String `bsp_fix` über den Daten-Zeiger bei `0x8038966C` (oder Datei `0x32966C`).
5. Für die Bereichs-Richtlinie: `0x801FAA34` + Daten bei `0x803853C0`.

Wurde die Datenbank als Little-Endian / mit Basis 0 angelegt, die IDB neu erstellen, bevor man sich auf die Decompiler-Ausgabe verlässt; das rohe BE-Disassemblat bleibt maßgeblich.

---

## 13. Verantwortungsvolle Nutzung

Diese Ausarbeitung dokumentiert das **defensive Verständnis** einer herstellerseitigen Schreibschutz-Richtlinie auf einem Gerät, das sich im Besitz des Betreibers befindet, um eine legitime Firmware-Migration (z. B. OpenWrt) zu unterstützen. Sie stellt keine Exploit-Ketten, keine Umgehungen zum Einspielen unsignierter Remote-Updates und keine Angriffe auf Systeme Dritter bereit.

---

## 14. Zugehörige Repo-Skripte

Siehe Wurzelverzeichnis des Repositorys:

- `unlock.sh` / `lock.sh` – Umschalter für die sysfs-Richtlinie  
- `write-initramfs.sh` – Löschen + `nandwrite` in die `firmware`-Partition  
- [README.md](../README.md) – Installationshinweise für Betreiber (EN/TR)
