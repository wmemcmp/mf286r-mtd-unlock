# Kernel Reverse Engineering Notes — ZTE MF286R SPI-NAND Write Gate

**Scope:** Stock Linux kernel recovered from MTD partition `mtd12` (`"kernel"`), analyzed offline to explain userspace `EPERM` / `illeagl access` on `flash_erase` / `nandwrite`.

**Role context:** Embedded firmware security research (static RE of a production MIPS BE kernel; no exploit development).

**Artifacts:**

| Artifact | Description |
|----------|-------------|
| On-device source | Live dump of `/dev/mtd12` (3 MiB) |
| File | `mtd12_kernel.bin` |
| Decompressed | `vmlinux.bin` (~3.57 MiB raw image) |
| Tooling | IDA Pro (Hex-Rays), manual MIPS BE disassembly, string/xref recovery |

---

## 1. Threat model & research question

**Observation (userspace, stock root):**

```text
flash_erase /dev/mtd12 0 1
→ MEMERASE64 ioctl failed, errno 1 (EPERM)

dmesg
→ illeagl access !!!   (stock typo preserved)
```

**Question:** Is write protection implemented as:

1. a proprietary userspace ioctl “unlock key”, or  
2. a **kernel-enforced policy** on the SPI-NAND driver / MTD path?

**Result:** (2). Policy lives in stock `ath79-spinand` and related MTD glue: two **sysfs store handlers** plus a **range allow-list**, not a magic `ioctl` in ZTE factory tools (`mtd_write`, `facSvr`, etc.).

---

## 2. Kernel image container (uImage)

### 2.1 File layout

```text
Offset   Size        Content
------   ----------  ------------------------------------------
0x0000   64 bytes    U-Boot legacy uImage header
0x0040   8 bytes     Vendor/custom pre-LZMA header
0x0048   ~1.21 MiB   LZMA payload (IH_COMP_LZMA)
…        padding     Remainder of 3 MiB partition (unused / 0x00…0xFF)
```

### 2.2 uImage header (big-endian)

| Field | Value | Notes |
|-------|--------|--------|
| Magic | `0x27051956` | Standard U-Boot image |
| Image size | `0x001276D4` (1 210 068) | Compressed payload length |
| Load / entry | `0x80060000` | MIPS KSEG0 load address |
| OS / arch / type | Linux / MIPS / kernel | |
| Compression | `3` = LZMA | |
| Name | `MIPS OpenWrt Linux-3.3.8` | Stock is QSDK-based OpenWrt 12-era tree |

### 2.3 Custom 8-byte header before LZMA

```text
00 12 76 CC  00 00 00 00
```

Interpreted as big-endian length metadata adjacent to the compressed stream. **LZMA alone stream starts at file offset `0x48` (header 0x40 + 8).**

Decompression (offline):

```text
payload = file[0x40 : 0x40 + image_size]
lzma_stream = payload[8:]
vmlinux.bin = lzma.decompress(lzma_stream, format=FORMAT_ALONE)
```

Resulting `vmlinux.bin` is a **raw linked kernel image** (not ELF). Link / load base used for VA recovery:

```text
VA = 0x80060000 + file_offset
```

---

## 3. Built-in cmdline & MTD topology

String embedded in the image (file offset ≈ `0x408`):

```text
board=AP152 console=ttyS0,115200
mtdparts=
  spi0.0:640k(u-boot),128k(u-boot-env),1280k(reserved1);
  spi0.1:640k(fota-flag),512k(art),512k(mac),768k(reserved2),
         4m(cfg-param),4m(log),640k(oops),5m(reserved3),
         8m(web),3m(kernel),26m(rootfs),25m(data),50m(fota),
         29m@0x1800000(firmware)
```

**Implications:**

- Dual SPI topology: **NOR-class** layout on `spi0.0`, large **SPI-NAND** on `spi0.1` (`ath79-spinand`).
- Live `/proc/mtd` names match this map (`kernel` = 3 MiB, `firmware` = 29 MiB @ chip offset `0x1800000`).
- Combined `firmware` region spans stock kernel + rootfs — relevant for initramfs install methods that `nandwrite` the whole region.

---

## 4. IDA Pro methodology

### 4.1 Load caveats

| Setting | Correct | If wrong |
|---------|---------|----------|
| Processor | MIPS | |
| Endianness | **Big-endian** | LE dword reads break xrefs / decompiler |
| Image base | **`0x80060000`** | String pointers and `lui/addiu` pairs will not match |
| File type | Binary / raw | Not ELF |

Loading at base `0` with little-endian analysis still allows **string inventory** and **raw-byte pattern** work; production notes below use **file offsets** plus **VA = 0x80060000 + off**.

### 4.2 Workflow

1. Extract strings of interest: `bsp_fix`, `change_speed`, `ath79-spinand`, `illeagl access`, `write enable failed`, erase paths.
2. Recover **data pointers** to strings (BE `uint32` = VA) → `device_attribute` tables.
3. Resolve `show` / `store` function pointers → file offsets of handlers.
4. Scan code for `lui $r, 0x8040` + `lw/sw …, -0x1D30(r)` style accesses to global flags.
5. Reconstruct control flow around erase/write and range check (manual BE decode when Hex-Rays fails).

---

## 5. Sysfs control plane (`ath79-spinand`)

### 5.1 Driver identity (rodata strings)

Cluster around file offset **`0x2EB300`**:

```text
VA 0x8034B300  "ath79-spinand"
VA 0x8034B310  "change_speed"
VA 0x8034B320  "bsp_fix"
```

Nearby operational messages:

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

### 5.2 `device_attribute` table (data)

**File offset `0x32965C`** (VA `0x8038965C`):

```text
Off (file)   Content (BE interpretation)
-----------  ----------------------------------------------
0x32965C     name  → VA 0x8034B310  "change_speed"
0x329660     mode  → 0x01A40000 packing of umode 0x01A4
0x329664     show  → VA 0x801FDF54  → file 0x19DF54
0x329668     store → VA 0x801FDEC0  → file 0x19DEC0
0x32966C     name  → VA 0x8034B320  "bsp_fix"
0x329670     mode  → 0x01A40000
0x329674     show  → VA 0x801FDF40  → file 0x19DF40
0x329678     store → VA 0x801FDE44  → file 0x19DE44
```

Userspace paths observed on device:

```text
/sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed
/sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
```

### 5.3 Global policy flags (.bss / data)

Accessed as:

```asm
lui  $r, 0x8040
lw/sw $t, -0x1D30($r)   # bsp_fix flag
lw/sw $t, -0x1D24($r)   # change_speed flag  (imm 0xE2DC)
```

| Flag | VA | Approx. file offset | Set by store |
|------|-----|---------------------|--------------|
| `bsp_fix_flag` | `0x803FE2D0` | `0x39E2D0` | `bsp_fix` store |
| `change_speed_flag` | `0x803FE2DC` | `0x39E2DC` | `change_speed` store |

---

## 6. Handler semantics (file offsets)

### 6.1 `bsp_fix` store — `0x19DE44`

Pseudocode reconstructed from disassembly:

```c
// ssize_t bsp_fix_store(..., const char *buf, size_t count)
long v = simple_strtol(buf, /* base 10 */);

if (v == 0) {
    printk("zte fixed bad blocks start\n");
    bsp_fix_flag = 0;
} else if (v == 1) {
    printk("zte fixed bad blocks end\n");
    bsp_fix_flag = 1;
}
return count;
```

**On-device confirmation:** `echo 1 > bsp_fix` → dmesg `zte fixed bad blocks end`.

### 6.2 `change_speed` store — `0x19DEC0`

```c
long v = simple_strtol(buf, 10);

if (v == 101) {
    printk("set 1\n");
    change_speed_flag = 1;   // "normal"
} else if (v == 102) {
    printk("set 2\n");
    change_speed_flag = 0;   // "factory-style" for flash tooling
}
return count;
```

### 6.3 Show handlers — **intentionally non-informative**

| Function | File offset | Behavior |
|----------|-------------|----------|
| `bsp_fix_show` | `0x19DF40` | Formats constant **`100`** (does not read flag) |
| `change_speed_show` | `0x19DF54` | Formats constant **`1000`** |

Security note for operators: **do not trust `cat` of these attributes** for state. Use dmesg side effects of store.

### 6.4 `change_speed` getter used by flash path — `0x19F354`

```asm
lui     $v0, 0x8040
lw      $v0, -0x1D24($v0)    # change_speed_flag
xori    $v0, $v0, 1
jr      $ra
sltiu   $v0, $v0, 1          # delay slot: return (flag == 1)
```

| `change_speed` written | flag | getter returns |
|------------------------|------|----------------|
| `101` | 1 | **1** |
| `102` | 0 | **0** |
| default BSS 0 | 0 | **0** |

---

## 7. Range allow-list (`illeagl access`)

### 7.1 Checker — file `0x19AA34`

- Walks **3** table entries, **16 bytes** each.
- Table base: `lui 0x8038` + `addiu 0x53C0` → VA **`0x803853C0`**, file **`0x3253C0`**.

### 7.2 Table contents (big-endian words)

```text
Entry 0:  0x00000000  0x01800000  0x00000000  0x01B00000
          → chip range [0x1800000, 0x1B00000)  = 3 MiB   ("kernel" window)

Entry 1:  0x00000000  0x01B00000  0x00000000  0x03500000
          → chip range [0x1B00000, 0x3500000)  = 26 MiB  ("rootfs" window)

Entry 2:  control / sentinel words (0x3, 0, 1, 2)
```

Matches cmdline `29m@0x1800000(firmware)` = kernel+rootfs.

### 7.3 Gate in write/erase parent — file `0x19AB90`

```c
if (change_speed_getter() != 0) {          // true when flag == 1 (echo 101)
    if (range_check(addr, len) == -1) {
        printk("illeagl access !!!\n");
        return -EPERM;                     // -1
    }
}
// continue erase/write setup
```

**Empirical mapping:**

| Operators set | Getter | Range check | Typical result on `mtd12` erase @ 0 |
|---------------|--------|-------------|--------------------------------------|
| `change_speed=101` | 1 | **runs** | `illeagl access` + EPERM (partition-relative 0 often not accepted as absolute 0x1800000) |
| `change_speed=102` | 0 | **skipped** | Proceeds to lower-level erase path |

### 7.4 Call sites of range check (`jal` to `0x19AA34`)

File offsets (non-exhaustive): `0x19ABAC`, `0x19ACF8`, `0x19AF5C` — flash I/O paths, not factory userspace binaries.

---

## 8. `bsp_fix` consumers (erase path)

`bsp_fix_flag` loads observed at file **`0x19B0F4`** and **`0x19B1C4`** inside SPI-NAND erase/scan logic:

- When flag `== 1`, a branch performs extra block-map / status bit handling and prints `zte fix i=%d, left badblocks=%d`.
- Combined with `change_speed=102`, this is the **observed working unlock pair** for bulk erase/write of kernel/firmware regions.

Exact hardware status-register programming is vendor SPI-NAND sequence code in the same driver (strings: write enable, set/get otp, lock block); the sysfs flags are the **policy knobs** exposed to root.

---

## 9. Userspace tools (negative findings)

Static RE of stock userspace (same firmware tree):

| Binary | Finding |
|--------|---------|
| `mtd_write` | Standard `MEMGETINFO` / `MEMUNLOCK` / `MEMERASE` only — no proprietary unlock ioctl |
| `facSvr` | Shells out to `flash_erase` / `nandwrite` on `mtd11`–`mtd13` without sysfs unlock |
| `mainControl` | No MTD flash path for kernel |
| `update_control` | Uses `change_speed` 101/102 around FOTA; still relies on same kernel policy |

Conclusion for install docs: **kernel sysfs is the unlock surface**, not a hidden ioctl in ZTE CLI tools.

---

## 10. Operator unlock recipe (validated)

```sh
echo 102 > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/change_speed
echo 1   > /sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1/bsp_fix
dmesg | tail -5
# set 2
# zte fixed bad blocks end

flash_erase /dev/mtd16 0 0
nandwrite -p /dev/mtd16 /tmp/openwrt-*-mf286r-initramfs-kernel.bin
```

Failure mode when only `bsp_fix=1` + `change_speed=101`:

```text
dmesg: illeagl access !!!
flash_erase: Operation not permitted
```

---

## 11. Offset quick reference

| Item | File offset | VA (base `0x80060000`) |
|------|-------------|-------------------------|
| uImage header | `0x0` | — |
| LZMA start | `0x48` | — |
| Built-in cmdline | ~`0x408` | ~`0x80060408` |
| `ath79-spinand` str | `0x2EB300` | `0x8034B300` |
| `change_speed` str | `0x2EB310` | `0x8034B310` |
| `bsp_fix` str | `0x2EB320` | `0x8034B320` |
| `illeagl access` str | `0x2EA654` | `0x8034A654` |
| dev_attr table | `0x32965C` | `0x8038965C` |
| range table | `0x3253C0` | `0x803853C0` |
| `bsp_fix` store | `0x19DE44` | `0x801FDE44` |
| `change_speed` store | `0x19DEC0` | `0x801FDEC0` |
| `bsp_fix` show | `0x19DF40` | `0x801FDF40` |
| `change_speed` show | `0x19DF54` | `0x801FDF54` |
| change_speed getter | `0x19F354` | `0x801FF354` |
| range_check | `0x19AA34` | `0x801FAA34` |
| range gate (caller) | `0x19AB90` | `0x801FAB90` |
| `bsp_fix_flag` | ~`0x39E2D0` | `0x803FE2D0` |
| `change_speed_flag` | ~`0x39E2DC` | `0x803FE2DC` |

---

## 12. IDA Pro session tips (reproduce)

1. File → Open `vmlinux.bin` (decompressed), or start from uImage and decompress as in §2.
2. Processor: **MIPS**, **Big-endian**, ROM start address **`0x80060000`**.
3. Jump to `0x801FDE44` / `0x801FDEC0` (stores) or file `0x19DE44` if base is zero.
4. Xref string `bsp_fix` via data pointer at `0x8038966C` (or file `0x32966C`).
5. For range policy: `0x801FAA34` + data at `0x803853C0`.

If the database was created little-endian / base 0, re-create the IDB before relying on decompiler output; raw BE disassembly remains authoritative.

---

## 13. Responsible use

This write-up documents **defensive understanding** of a vendor write-protect policy on a device the operator owns, to support legitimate firmware migration (e.g. OpenWrt). It does not provide exploit chains, unsigned remote update bypasses, or attacks against third-party systems.

---

## 14. Related repo scripts

See repository root:

- `unlock.sh` / `lock.sh` — sysfs policy toggles  
- `write-initramfs.sh` — erase + `nandwrite` to `firmware`  
- [README.md](../README.md) — operator-facing install notes (EN/TR)
