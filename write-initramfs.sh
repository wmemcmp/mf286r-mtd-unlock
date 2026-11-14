#!/bin/sh
#
# write-initramfs.sh - ZTE MF286R, stock firmware: flash an OpenWrt initramfs
#
# Unlocks the SPI NAND and writes an OpenWrt initramfs-kernel image to the
# stock "firmware" partition (kernel + rootfs, normally mtd16).  U-Boot
# loads it at the next start; the real installation is then done from the
# running initramfs with sysupgrade.
#
# Usage: sh write-initramfs.sh [-y] [-r] [-n] [-b] [-f] IMAGE [MTD]
#
#   IMAGE  openwrt-*-ath79-nand-zte_mf286r-initramfs-kernel.bin, stored in
#          /tmp or on the USB stick.  Take 22.03.x or 24.10 and later: the
#          23.05.x initramfs does not start on this U-Boot (LZMA ERROR 1).
#   MTD    optional, e.g. /dev/mtd16; must be the partition named "firmware"
#   -y     do not ask, assume YES
#   -r     reboot afterwards if everything went well
#   -n     no read-back verification
#   -b     also write 1 to "bsp_fix" when unlocking (see below)
#   -f     go on although the image or the flash layout looks wrong
#
# WARNING: this erases the stock firmware, kernel AND root filesystem.
# Back up all MTD partitions first (the stock firmware cannot be downloaded
# anywhere) and use an image built for the MF286R only.  If the router does
# not start afterwards, only the serial console brings it back.
#
# Unlocking: "echo 102 > .../change_speed" is what ZTE's own updater does
# and what is known to work on the MF286R.  The "bsp_fix" switch next to
# it is not documented anywhere; the kernel answers "zte fixed bad blocks
# end", so it seems to touch the bad block handling.  It is therefore only
# used with -b.  If the flash stays locked without it, the erase has no
# effect; the script notices that and stops with the stock firmware intact.
#
# How it works:
#  1. busybox, flash_erase, nandwrite and their libraries are copied to the
#     RAM disk and the script restarts itself from there.  Erasing
#     "firmware" wipes the running root filesystem, so after that nothing
#     can be loaded from flash any more.
#  2. Partition and image are checked.  Up to the YES prompt nothing on the
#     router is changed.
#  3. Unlock, erase, write, read back and compare.  A failed round is
#     repeated while the router is still running.

set -u

# ---- settings ----------------------------------------------------------

PART_NAME=firmware
EXPECT_SIZE=01d00000    # stock MF286A/R: mtd16: 01d00000 00020000 "firmware"
EXPECT_ERASE=00020000

# ZTE write protection of the SPI NAND (spi0.1)
SPI=/sys/devices/platform/ath79-spi/spi_master/spi0/spi0.1
SENSOR_ID=/proc/driver/sensor_id

DEV_DIR=/dev
PROC_MTD=/proc/mtd
PROC_MOUNTS=/proc/mounts
SYSRQ=/proc/sysrq-trigger
RAM_BASES="/tmp /var"   # the first one that is a RAM disk (tmpfs) is used

MAX_ATTEMPTS=3          # rounds of erase + write + verify
MAX_SKIP=8              # bad blocks accepted inside the image area
# Blocks compared before and after the erase to recognize a flash that is
# still locked: the start of the kernel, which holds data and never changes
# while the stock firmware runs.
PROBE_BLOCKS="0 1 2 3 4 5 6 7"

# busybox applets used once the root filesystem may be gone; each gets a
# link in the RAM disk
APPLETS="sh [ test echo printf cat dd md5sum sha256sum hexdump od tr wc id"
APPLETS="$APPLETS sync sleep dmesg tail rm reboot"

# ---- state -------------------------------------------------------------

ASSUME_YES=0 AUTO_REBOOT=0 VERIFY=1 USE_BSP_FIX=0 FORCE=0
IMG='' MTD_ARG='' FLAGS='' RAM='' RAM_BASE='' SELF=${WI_SELF:-${0##*/}}
UNLOCKED=0 MODIFIED=0 KEEP_RAM=0 KEEP_UNLOCKED=0 PROBLEMS=0
HAVE_VERIFY=0 HAVE_PROBE=0 FP_BEFORE='' SKIPPED=0 ATTEMPT=1 FAILED_AT=''
ANSWER='' CR=$(printf '\r')

# ---- helpers -----------------------------------------------------------

say()     { printf '%s\n' "$*"; }
warn()    { printf 'WARNING: %s\n' "$*" >&2; }
die()     { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
problem() { PROBLEMS=$((PROBLEMS + 1)); printf 'PROBLEM: %s\n' "$*" >&2; }

usage() {
    say "Usage: sh $SELF [-y] [-r] [-n] [-b] [-f] IMAGE [MTD]"
    say "  IMAGE  openwrt-*-zte_mf286r-initramfs-kernel.bin (in /tmp or on USB)"
    say "  MTD    optional, must be the \"$PART_NAME\" partition (see: cat $PROC_MTD)"
    say "  -y     do not ask, assume YES"
    say "  -r     reboot afterwards if everything went well"
    say "  -n     no read-back verification"
    say "  -b     also write 1 to \"bsp_fix\" when unlocking (undocumented switch)"
    say "  -f     go on although the image or the flash layout looks wrong"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            -y) ASSUME_YES=1 ;;
            -r) AUTO_REBOOT=1 ;;
            -n) VERIFY=0 ;;
            -b) USE_BSP_FIX=1 ;;
            -f) FORCE=1 ;;
            -h|--help) usage; exit 0 ;;
            --) shift; break ;;
            -*) usage >&2; exit 2 ;;
            *)  break ;;
        esac
        FLAGS="$FLAGS $1"
        shift
    done
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then
        usage >&2
        exit 2
    fi
    IMG=$1
    MTD_ARG=${2:-}
    case $MTD_ARG in -*) usage >&2; exit 2 ;; esac
    case $IMG in /*) ;; *) IMG=$PWD/$IMG ;; esac
}

ask() {                 # ask PROMPT - read one line into $ANSWER
    printf '%s ' "$1"
    read -r ANSWER || ANSWER=''
    ANSWER=${ANSWER%"$CR"}      # a raw network shell may send CR LF
}

confirm() {             # confirm QUESTION - only the answer YES counts
    [ "$ASSUME_YES" = 1 ] && return 0
    ask "$1 [type YES]:"
    [ "$ANSWER" = YES ]
}

find_cmd() {            # find_cmd NAME - print the full path of a program
    _oifs=$IFS
    IFS=:
    for _d in $PATH; do
        IFS=$_oifs
        if [ -f "$_d/$1" ] && [ -x "$_d/$1" ]; then
            printf '%s\n' "$_d/$1"
            return 0
        fi
    done
    IFS=$_oifs
    return 1
}

is_ram_fs() {           # is_ram_fs MOUNTPOINT
    while read -r _dev _mp _type _rest; do
        if [ "$_mp" = "$1" ]; then
            case $_type in tmpfs|ramfs) return 0 ;; esac
        fi
    done < "$PROC_MOUNTS"
    return 1
}

is_chardev() { [ -c "$1" ]; }

hex_at() {              # hex_at FILE OFFSET LENGTH - bytes as hex digits
    _h=$(hexdump -v -s "$2" -n "$3" -e '1/1 "%02x"' "$1" 2>/dev/null)
    [ -n "$_h" ] || _h=$(dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null |
                         od -An -tx1 2>/dev/null | tr -d ' \n')
    printf '%s' "$_h"
}

on_exit() {             # runs through the EXIT trap
    _status=$?
    trap - EXIT
    [ "$KEEP_UNLOCKED" = 1 ] || relock
    if [ "$KEEP_RAM" != 1 ]; then
        case $RAM in
            "$RAM_BASE"/write-initramfs.[0-9]*) rm -rf "$RAM" ;;
        esac
    fi
    exit "$_status"
}

# ---- stage 1: move to the RAM disk ---------------------------------------

ram_ok() {              # ram_ok DIR - does the busybox copy in DIR run?
    # with the library copies in DIR if they work, else with those on flash
    if [ -s "$1/libs" ] &&
       LD_LIBRARY_PATH=$1/lib "$1/bin/busybox" sh -c 'exit 0' 2>/dev/null; then
        LD_LIBRARY_PATH=$1/lib
        export LD_LIBRARY_PATH
        return 0
    fi
    "$1/bin/busybox" sh -c 'exit 0' 2>/dev/null || return 1
    [ ! -s "$1/libs" ] || warn "the library copies in $1/lib do not work, using those on flash"
    return 0
}

put() {                 # put FILE COPY - copy a file to the RAM disk or give up
    cp "$1" "$2" || die "cannot copy $1 to $RAM - RAM disk full?"
}

run_from_ram() {        # run_from_ram DIR FRESH ARGS... - does not return
    WI_RAM=$1
    WI_FRESH=$2
    WI_SELF=$SELF
    export WI_RAM WI_FRESH WI_SELF
    shift 2
    exec "$WI_RAM/bin/busybox" sh "$WI_RAM/write-initramfs.sh" "$@"
}

to_ram() {
    # Tools left in RAM by an earlier run are used again: after a failed
    # round the originals on flash may be gone.
    for _old in "$RAM_BASE"/write-initramfs.[0-9]*; do
        [ -x "$_old/bin/busybox" ] && [ -f "$_old/write-initramfs.sh" ] || continue
        ram_ok "$_old" || continue
        say "using the tools already in $_old"
        cp "$0" "$_old/new.sh" 2>/dev/null &&
            mv "$_old/new.sh" "$_old/write-initramfs.sh" 2>/dev/null
        run_from_ram "$_old" 0 "$@"
    done

    [ -f "$0" ] || die "start the script from a file: sh /tmp/write-initramfs.sh ..."
    _bb=$(find_cmd busybox) || _bb=/bin/busybox
    [ -x "$_bb" ] || die "busybox not found - is this the ZTE stock firmware?"
    _fe=$(find_cmd flash_erase) || die "flash_erase not found in PATH ($PATH)"
    _nw=$(find_cmd nandwrite) || die "nandwrite not found in PATH ($PATH)"

    _new=$RAM_BASE/write-initramfs.$$
    mkdir "$_new" || die "cannot create $_new (remove it if it is a leftover)"
    RAM=$_new
    mkdir "$RAM/bin" "$RAM/lib" || die "cannot create $RAM/bin"
    put "$_bb" "$RAM/bin/busybox"
    put "$_fe" "$RAM/bin/flash_erase"
    put "$_nw" "$RAM/bin/nandwrite"
    put "$0" "$RAM/write-initramfs.sh"
    chmod 755 "$RAM/bin/busybox" "$RAM/bin/flash_erase" "$RAM/bin/nandwrite" ||
        die "chmod failed in $RAM/bin"
    for _a in $APPLETS; do
        ln -s busybox "$RAM/bin/$_a" || die "cannot create $RAM/bin/$_a"
    done

    # Shared libraries: the dynamic loader lists what the three programs
    # need (nothing is executed while LD_TRACE_LOADED_OBJECTS is set).
    for _t in busybox flash_erase nandwrite; do
        LD_TRACE_LOADED_OBJECTS=1 "$RAM/bin/$_t" --help 2>/dev/null </dev/null
    done | sed -n 's/^[^=]*=> *\(\/[^ ]*\).*/\1/p' > "$RAM/libs"
    while read -r _lib; do
        [ -e "$RAM/lib/${_lib##*/}" ] || put "$_lib" "$RAM/lib/${_lib##*/}"
    done < "$RAM/libs"
    # the loader itself stays on flash; pull it into the page cache
    cat /lib/ld-*.so* > /dev/null 2>&1

    ram_ok "$RAM" ||
        die "the busybox copy in $RAM does not run - is $RAM_BASE mounted noexec?"
    say "tools copied to $RAM, continuing from RAM"
    run_from_ram "$RAM" 1 "$@"
}

# ---- stage 2: checks -----------------------------------------------------

selftest() {            # do the RAM copies work?  nothing here touches flash
    for _t in flash_erase nandwrite; do
        "$RAM/bin/$_t" --help > /dev/null 2>&1
        [ $? -lt 126 ] || die "the RAM copy of $_t does not run"
    done
    printf 'aaaabbbbcccc' > "$RAM/t"
    _s=$(dd if="$RAM/t" bs=4 skip=1 count=1 2>/dev/null | md5sum 2>/dev/null)
    [ "${_s%% *}" = 65ba841e01d6db7733e90a5b7f9e6f80 ] && HAVE_VERIFY=1    # md5 of "bbbb"
    _n=$(printf '\377a\377\377' | tr -d '\377' 2>/dev/null | wc -c 2>/dev/null)
    [ "$HAVE_VERIFY" = 1 ] && [ "$((_n + 0))" -eq 1 ] && HAVE_PROBE=1
    rm -f "$RAM/t"
}

check_target() {
    [ -r "$PROC_MTD" ] || die "cannot read $PROC_MTD"
    _found=''
    while read -r _dev _size _erase _name; do
        [ "$_name" = "\"$PART_NAME\"" ] || continue
        [ -z "$_found" ] || die "more than one \"$PART_NAME\" partition in $PROC_MTD"
        _found=${_dev%:}
        PART_SIZE_HEX=$_size
        EB_HEX=$_erase
    done < "$PROC_MTD"
    [ -n "$_found" ] ||
        die "no \"$PART_NAME\" partition in $PROC_MTD - not the MF286R stock firmware?"
    MTD=$DEV_DIR/$_found
    if [ -n "$MTD_ARG" ] && [ "$MTD_ARG" != "$MTD" ]; then
        die "$MTD_ARG is not the \"$PART_NAME\" partition, that is $MTD (see: cat $PROC_MTD)"
    fi
    is_chardev "$MTD" || die "$MTD is not a character device"
    PART_SIZE=$((0x$PART_SIZE_HEX))
    EB=$((0x$EB_HEX))
    [ "$EB" -gt 0 ] && [ "$PART_SIZE" -ge $((EB * 8)) ] ||
        die "strange size of $MTD in $PROC_MTD: $PART_SIZE_HEX $EB_HEX"
    if [ "$PART_SIZE_HEX" != "$EXPECT_SIZE" ] || [ "$EB_HEX" != "$EXPECT_ERASE" ]; then
        problem "\"$PART_NAME\" is \"$PART_SIZE_HEX $EB_HEX\", the MF286R stock layout has \"$EXPECT_SIZE $EXPECT_ERASE\" - a different model?"
    fi
}

read_block() {          # read_block N - erase block N of $MTD -> $RAM/blk
    dd if="$MTD" of="$RAM/blk" bs="$EB" skip="$1" count=1 2>/dev/null || return 1
    _sz=$(wc -c < "$RAM/blk" 2>/dev/null)
    [ "$((_sz + 0))" -eq "$EB" ]
}

fingerprint() {         # one md5 line per probe block
    for _b in $PROBE_BLOCKS; do
        if read_block "$_b"; then
            md5sum < "$RAM/blk"
        else
            echo unreadable
        fi
    done
}

probe_setup() {         # first read of the partition, with the tools used later
    if [ "$HAVE_VERIFY" = 1 ] && ! read_block 0; then
        warn "cannot read $MTD with dd"
        HAVE_VERIFY=0
    fi
    [ "$HAVE_VERIFY" = 1 ] || HAVE_PROBE=0
    if [ "$HAVE_PROBE" = 1 ]; then
        # only blocks that hold data now can show later that nothing was erased
        _list=''
        _n=0
        for _b in $PROBE_BLOCKS; do
            read_block "$_b" || continue
            _sz=$(tr -d '\377' < "$RAM/blk" | wc -c)
            [ "$((_sz + 0))" -gt 0 ] || continue
            _list="$_list $_b"
            _n=$((_n + 1))
        done
        PROBE_BLOCKS=$_list
        [ "$_n" -ge 2 ] && FP_BEFORE=$(fingerprint)
        case $FP_BEFORE in ''|*unreadable*) HAVE_PROBE=0 ;; esac
    fi
    if [ "$VERIFY" = 1 ] && [ "$HAVE_VERIFY" != 1 ]; then
        warn "read-back verification is not possible here (dd/md5sum), continuing without"
        VERIFY=0
    fi
}

check_image() {
    [ -f "$IMG" ] && [ -r "$IMG" ] || die "image not found: $IMG"
    IMG_SIZE=$(wc -c < "$IMG")
    IMG_SIZE=$((IMG_SIZE + 0))
    [ "$IMG_SIZE" -gt 64 ] || die "image is empty: $IMG"
    [ "$IMG_SIZE" -le "$PART_SIZE" ] ||
        die "image ($IMG_SIZE bytes) is larger than $MTD ($PART_SIZE bytes)"

    # U-Boot starts the partition with "nboot", so it must begin with a
    # uImage header (magic 27 05 19 56)
    [ "$(dd if="$IMG" bs=1 count=4 2>/dev/null)" = "$(printf '\047\005\031\126')" ] ||
        die "not a uImage: $IMG - take the *-initramfs-kernel.bin file, not sysupgrade or factory"

    # the header says how long the image has to be (data size + 64)
    _h=$(hex_at "$IMG" 12 4)
    if [ "${#_h}" -eq 8 ]; then
        _need=$((0x$_h + 64))
        [ "$IMG_SIZE" -ge "$_need" ] ||
            die "image is incomplete: $IMG_SIZE of $_need bytes - download it again"
    else
        warn "no hexdump/od here, cannot check that the image is complete"
    fi

    IMG_NAME=$(dd if="$IMG" bs=1 skip=32 count=32 2>/dev/null | tr -d '\000')
    case $(dd if="$IMG" bs=1 skip=31 count=1 2>/dev/null | tr '\000\001\002\003' '0123') in
        0) IMG_COMP=none ;;
        1) IMG_COMP=gzip ;;
        2) IMG_COMP=bzip2 ;;
        3) IMG_COMP=lzma ;;
        *) IMG_COMP=unknown ;;
    esac
    # Can the stock U-Boot start it?  It unpacks LZMA uImages itself and
    # that only works up to the size of the 22.03 images.  From 24.10 on
    # the image carries its own loader and is not compressed for U-Boot.
    case $IMG_COMP:$IMG_NAME in
        none:*) ;;
        lzma:*Linux-5.10.*|lzma:*Linux-5.4.*|lzma:*Linux-4.*) ;;
        lzma:*)
            problem "\"$IMG_NAME\" is an LZMA uImage newer than 22.03, the stock U-Boot cannot unpack these (23.05.x stops with \"LZMA ERROR 1\") - take the 22.03.x or 24.10+ initramfs"
            ;;
        *)  warn "unusual uImage compression ($IMG_COMP), U-Boot may not start it" ;;
    esac

    case ${IMG##*/} in
        *mf286r*initramfs*) ;;
        *)  warn "the file name does not look like an MF286R initramfs image: ${IMG##*/}" ;;
    esac

    if _s=$(sha256sum "$IMG" 2>/dev/null) && [ -n "$_s" ]; then
        IMG_SUM="sha256 ${_s%% *}"
    elif _s=$(md5sum "$IMG" 2>/dev/null) && [ -n "$_s" ]; then
        IMG_SUM="md5 ${_s%% *}"
    else
        IMG_SUM=''
    fi
}

check_unlock() {
    [ -e "$SPI/change_speed" ] || [ -r "$SENSOR_ID" ] ||
        die "neither $SPI/change_speed nor $SENSOR_ID exists - not the MF286R stock firmware?"
    UNLOCK_HOW=''
    [ -e "$SPI/change_speed" ] && UNLOCK_HOW=" change_speed=102"
    if [ "$USE_BSP_FIX" = 1 ]; then
        [ -e "$SPI/bsp_fix" ] || die "-b given, but there is no $SPI/bsp_fix"
        UNLOCK_HOW="$UNLOCK_HOW bsp_fix=1"
    fi
    [ -r "$SENSOR_ID" ] && UNLOCK_HOW="$UNLOCK_HOW sensor_id"
    return 0
}

show_plan() {
    say ""
    say "  image   $IMG"
    say "          $IMG_SIZE bytes, \"$IMG_NAME\", compression: $IMG_COMP"
    [ -n "$IMG_SUM" ] && say "          $IMG_SUM"
    say "  target  $MTD \"$PART_NAME\", $PART_SIZE bytes, erase block $EB"
    say "  unlock $UNLOCK_HOW"
    say "  tools   $RAM (RAM disk)"
    if [ "$VERIFY" = 1 ]; then say "  verify  yes"; else say "  verify  NO"; fi
    say ""
    say "The stock firmware (kernel and root filesystem) will be ERASED - it"
    say "cannot be downloaded anywhere, so have a backup of all MTD partitions."
    say "Nothing has been changed so far."
}

# ---- stage 2: flashing ---------------------------------------------------

unlock() {              # unlock [again] - "again" leaves bsp_fix as it is
    UNLOCKED=1
    if [ -e "$SPI/change_speed" ]; then
        echo 102 > "$SPI/change_speed" || warn "writing change_speed failed"
    fi
    if [ "$USE_BSP_FIX" = 1 ] && [ "${1:-}" != again ]; then
        echo 1 > "$SPI/bsp_fix" || warn "writing bsp_fix failed"
    fi
    # the unlock named in the OpenWrt wiki: reading this file, if it exists
    if [ -r "$SENSOR_ID" ]; then
        cat "$SENSOR_ID" > /dev/null 2>&1
    fi
    return 0
}

relock() {
    [ "$UNLOCKED" = 1 ] || return 0
    UNLOCKED=0
    if [ "$USE_BSP_FIX" = 1 ]; then
        echo 0 > "$SPI/bsp_fix"
    fi 2>/dev/null
    if [ -e "$SPI/change_speed" ]; then
        echo 101 > "$SPI/change_speed"
    fi 2>/dev/null
    return 0
}

verify_flash() {        # compare the flash with the image, block by block
    # nandwrite skips bad blocks, so a block that does not match is taken
    # for a skipped one and the search goes on in the next block.
    _blocks=$(( (IMG_SIZE + EB - 1) / EB ))
    _total=$((PART_SIZE / EB))
    _i=0
    _j=0
    SKIPPED=0
    printf 'verifying '
    while [ "$_i" -lt "$_blocks" ]; do
        _len=$((IMG_SIZE - _i * EB))
        [ "$_len" -le "$EB" ] || _len=$EB
        _want=$(dd if="$IMG" bs="$EB" skip="$_i" count=1 2>/dev/null | md5sum)
        case $_want in
            ''|d41d8cd98f00b204e9800998ecf8427e*)
                say " FAILED: cannot read the image"
                return 1 ;;
        esac
        while :; do
            if [ "$_j" -ge "$_total" ]; then
                say " FAILED: end of the partition reached"
                return 1
            fi
            _got=unreadable
            if read_block "$_j"; then
                _got=$(dd if="$RAM/blk" bs="$_len" count=1 2>/dev/null | md5sum)
            fi
            _j=$((_j + 1))
            [ "$_got" = "$_want" ] && break
            SKIPPED=$((SKIPPED + 1))
            if [ "$SKIPPED" -gt "$MAX_SKIP" ]; then
                say " FAILED: block $_i of the image is not on the flash"
                return 1
            fi
        done
        _i=$((_i + 1))
        [ $((_i % 8)) -eq 0 ] && printf .
    done
    say " OK"
    return 0
}

flash_once() {          # 0 = written, 1 = failed, 2 = still locked, nothing changed
    say ""
    say "[$ATTEMPT/$MAX_ATTEMPTS] erasing $MTD"
    "$RAM/bin/flash_erase" "$MTD" 0 0
    _rc=$?
    say ""
    [ "$_rc" -eq 0 ] || warn "flash_erase returned $_rc"

    # Still locked?  Only if the probe blocks are provably the same as
    # before; in every other case the write has to follow the erase.
    if [ "$HAVE_PROBE" = 1 ] && [ "$MODIFIED" = 0 ] &&
       [ "$(fingerprint)" = "$FP_BEFORE" ]; then
        return 2
    fi
    MODIFIED=1
    KEEP_RAM=1          # from now on the RAM tools are the only ones left

    say "[$ATTEMPT/$MAX_ATTEMPTS] writing ${IMG##*/}"
    "$RAM/bin/nandwrite" -p "$MTD" "$IMG"
    _rc=$?
    sync
    say ""
    if [ "$_rc" -ne 0 ]; then
        FAILED_AT='write'
        say "nandwrite failed (exit code $_rc)"
        return 1
    fi
    [ "$VERIFY" = 1 ] || return 0
    FAILED_AT='verify'
    verify_flash
}

still_locked() {
    say ""
    say "The flash is still write-protected: nothing was erased, the first"
    say "blocks of $MTD are the same as before.  The stock firmware is"
    say "untouched.  Last kernel messages:"
    dmesg | tail -n 5
    say "Switch the router off and on and try again."
    if [ "$USE_BSP_FIX" != 1 ] && [ -e "$SPI/bsp_fix" ]; then
        say "If it stays locked: -b also sets the undocumented bsp_fix switch."
    fi
    say "Otherwise use the serial console method of the OpenWrt wiki."
    exit 1
}

failed() {
    KEEP_RAM=1
    KEEP_UNLOCKED=1
    say ""
    say "FAILED after $MAX_ATTEMPTS attempts.  In the last one"
    if [ "$FAILED_AT" = verify ]; then
        say "nandwrite reported no error, but what was read back from the flash"
        say "is not the image."
    else
        say "nandwrite reported an error."
    fi
    say "The stock firmware is erased; the router only starts again when the"
    say "image is completely on the flash:"
    say ""
    say "  DO NOT REBOOT AND DO NOT SWITCH THE ROUTER OFF NOW."
    say ""
    say "The flash is left unlocked and the tools stay in RAM.  Try by hand:"
    say "  export PATH=$RAM/bin:\$PATH${LD_LIBRARY_PATH:+ LD_LIBRARY_PATH=$LD_LIBRARY_PATH}"
    say "  flash_erase $MTD 0 0"
    say "  nandwrite -p $MTD \"$IMG\""
    say "or start the script again:"
    say "  $RAM/bin/busybox sh $RAM/write-initramfs.sh$FLAGS \"$IMG\""
    if [ "$FAILED_AT" = verify ]; then
        say "(-n leaves out the read-back comparison)"
    fi
    exit 1
}

do_reboot() {
    say "rebooting ..."
    sync
    sleep 2
    reboot -f 2>/dev/null
    sleep 5
    if [ -e "$SYSRQ" ]; then
        echo b > "$SYSRQ"
    fi 2>/dev/null
    sleep 5
    say "The reboot did not work."
}

# ---- main ----------------------------------------------------------------

if [ $# -eq 0 ]; then
    usage >&2
    exit 2
fi
parse_args "$@"

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# stage 2 if run_from_ram started us, stage 1 otherwise
if [ -n "${WI_RAM:-}" ] && [ -x "$WI_RAM/bin/busybox" ] &&
   [ -f "$WI_RAM/write-initramfs.sh" ]; then
    RAM=$WI_RAM
    [ "${WI_FRESH:-0}" = 1 ] || KEEP_RAM=1      # not ours to delete
    PATH=$RAM/bin:$PATH
    export PATH
fi

_uid=$(id -u 2>/dev/null) || _uid=0
[ "${_uid:-0}" = 0 ] || die "this has to be run as root"
[ -f "$IMG" ] || die "image not found: $IMG"
for _base in $RAM_BASES; do
    if is_ram_fs "$_base"; then
        RAM_BASE=$_base
        break
    fi
done
[ -n "$RAM_BASE" ] || die "no RAM disk (tmpfs) found, tried: $RAM_BASES"
[ -n "$RAM" ] || to_ram "$@"

selftest
check_target
probe_setup
check_image
check_unlock
if [ "$PROBLEMS" -gt 0 ]; then
    [ "$FORCE" = 1 ] ||
        die "$PROBLEMS problem(s) found, nothing was changed (-f overrides, at your own risk)"
    warn "$PROBLEMS problem(s) found, going on because of -f"
fi
show_plan
confirm "Erase $MTD and write the image?" || die "stopped, nothing was changed"

# From here on the job has to run to its end: neither Ctrl-C nor a lost
# telnet/network session may stop the erase or the write half way.
trap '' HUP PIPE INT TERM QUIT

unlock
say ""
say "kernel log after unlocking:"       # expected: "set 2", and with -b
dmesg | tail -n 5                       # also "zte fixed bad blocks end"

while :; do
    flash_once
    case $? in
        0) break ;;
        2) still_locked ;;
    esac
    [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ] || failed
    ATTEMPT=$((ATTEMPT + 1))
    say "trying again ..."
    sleep 2
    unlock again
done

relock
KEEP_RAM=1              # the RAM busybox is still needed for the reboot
trap 'exit 130' INT
trap 'exit 143' TERM
trap - QUIT

say ""
if [ "$VERIFY" = 1 ]; then
    say "SUCCESS: the image is on $MTD and was read back correctly."
else
    say "DONE: nandwrite reported no error (not verified)."
fi
if [ "$SKIPPED" -gt 0 ]; then
    warn "$SKIPPED bad block(s) inside the image area were skipped. The image is complete, but if U-Boot cannot cope with that the router will not start."
fi
say "After the reboot OpenWrt answers on 192.168.1.1 (ssh root@192.168.1.1);"
say "finish there with: sysupgrade -n /tmp/openwrt-*-zte_mf286r-squashfs-sysupgrade.bin"
say ""

if [ "$AUTO_REBOOT" = 1 ]; then
    do_reboot
elif [ "$ASSUME_YES" != 1 ]; then
    ask "Reboot now? [y/N]:"
    case $ANSWER in y|Y|yes|YES) do_reboot ;; esac
fi
say "The stock commands went with the root filesystem.  To reboot run"
say "  ${LD_LIBRARY_PATH:+LD_LIBRARY_PATH=$LD_LIBRARY_PATH }$RAM/bin/busybox reboot -f"
say "or switch the router off and on."
exit 0
