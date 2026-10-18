#!/system/bin/sh
# SM-J727P per-device CSID clock fix boot PREPARATION ONLY (never flashes).
# Preserves currently installed Magisk ramdisk and verified corrected DTBs.
set -eu
ZIP="${1:-/sdcard/Download/j727p-camera-clock-errno-4.zip}"
BOOT=/dev/block/by-name/boot
M=/data/adb/magisk/magiskboot
UNZIP=/data/data/com.termux/files/usr/bin/unzip
PY=/data/data/com.termux/files/usr/bin/python
OUT=/sdcard/Download/J727P-CSID-clockfix-UNFLASHED.img
BACK=/sdcard/Download/J727P-before-CSID-clockfix.img
ZIP_SHA=cd9240f45df54974b3e481b6231d654c71ef571fac87e5de6cd7e57fa5f61fb8
DTB_SHA=bd43c6a38e592df361a8610ac7ea73dd8d6efbf3935d3c8714fb2369a5745542
RUNNING_SHA=311a8a0d36f3cbaa2462c3818a541461b3b46d632f1f06b74abe494e4a53ccf7
GITHUB_COMMIT=2a397df2158b7d6f7d05e67851f21197c43adee2
fail() { echo "STOP: $*" >&2; exit 1; }
sha() { line="$(sha256sum "$1")" || return 1; printf '%s\n' "${line%% *}"; }

[ "$(id -u)" -eq 0 ] || fail "Root required"
[ "$(getprop ro.product.device)" = j7popltespr ] || fail "Unexpected device"
[ "$(getprop ro.build.version.sdk)" = 28 ] || fail "Android 9 required"
[ -b "$BOOT" ] || fail "Boot partition not found"
[ -x "$M" ] || fail "MagiskBoot not found"
[ -x "$UNZIP" ] || fail "Termux unzip missing"
[ -x "$PY" ] || fail "Termux Python missing"
[ -r "$ZIP" ] || fail "Artifact ZIP missing: $ZIP"
[ ! -e "$BACK" ] || fail "Backup already exists: $BACK (refuse overwrite)"
[ ! -e "$OUT" ] || fail "Output already exists: $OUT (refuse overwrite)"
[ "$(sha "$ZIP")" = "$ZIP_SHA" ] || fail "GitHub Actions archive SHA-256 mismatch"
[ "$(sha "$BOOT")" = "$RUNNING_SHA" ] || fail "Current boot image differs from verified camera diagnostic boot; STOP"
COMMIT=$("$UNZIP" -p "$ZIP" commit.txt) || fail "CI commit.txt missing"
[ "$COMMIT" = "$GITHUB_COMMIT" ] || fail "Unexpected CI commit SHA"
echo "===== VERIFIED GITHUB ACTIONS ARTIFACT ====="
echo "Artifact archive: $ZIP"

W=/data/local/tmp/j727p-errno-stage-$$
umask 077
mkdir -p "$W/repack" "$W/check"
trap 'rm -rf "$W"' EXIT
"$UNZIP" -p "$ZIP" Image.gz-dtb > "$W/Image.gz-dtb" || fail "Missing Image.gz-dtb inside downloaded artifact"

echo "===== EXTRACT CSID-REPAIR KERNEL, VALIDATE SIX APPENDED DTBS ====="
"$PY" - "$W/Image.gz-dtb" "$W/newkernel" <<'PYCODE'
import gzip
import struct
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_bytes()
magic = b'\xd0\x0d\xfe\xed'
start = 0
accepted = None
while True:
    start = raw.find(magic, start)
    if start == -1:
        break
    pos = start
    sizes = []
    valid = True
    for i in range(6):
        if pos + 40 > len(raw) or raw[pos:pos+4] != magic:
            valid = False
            break
        h = struct.unpack_from('>10I', raw, pos)
        total, structs, strings, version, last, slen, tlen = (
            h[1], h[2], h[3], h[5], h[6], h[8], h[9])
        if not (40 <= total <= len(raw)-pos and
                40 <= structs < total and 40 <= strings < total and
                strings+slen <= total and structs+tlen <= total and
                version >= last >= 1):
            valid = False
            break
        sizes.append(total)
        pos += total
    if valid and pos == len(raw):
        accepted = start
        break
    start += 4
if accepted is None:
    raise SystemExit("STOP: expected six contiguous appended DTBs were not found")
kernel = raw[:accepted]
if not kernel.startswith(b'\x1f\x8b'):
    raise SystemExit("STOP: kernel is not gzip-compressed")
uncompressed = gzip.decompress(kernel)
if not (b'J727P_CAMCLK_GET_FAIL' in uncompressed and
        b'J727P_CSID_CLOCK_FAIL' in uncompressed):
    raise SystemExit("STOP: compiled kernel lacks expected diagnostics")
if not (10_000_000 <= len(kernel) <= 12_000_000):
    raise SystemExit("STOP: unexpected diagnostic kernel length")
Path(sys.argv[2]).write_bytes(kernel)
print("Gzip kernel bytes:", len(kernel))
print("Device-tree sizes in CI artifact:", sizes)
print("Both diagnostic error markers found in compiled kernel")
PYCODE

echo "===== READ-ONLY BACKUP OF CURRENT BOOT ====="
dd if="$BOOT" of="$BACK" bs=1048576 2>/dev/null || fail "Cannot back up running boot"
[ "$(wc -c < "$BACK")" -eq 33554432 ] || fail "Unexpected boot partition size"
[ "$(sha "$BACK")" = "$RUNNING_SHA" ] || fail "Backup did not match expected running boot; STOP"
echo "Original boot backup SHA256: $(sha "$BACK")"

echo "===== UNPACK CURRENT BOOT ====="
cd "$W/repack"
"$M" unpack -n -h "$BACK" || fail "Current boot could not be unpacked"
[ -f kernel ] && [ -f kernel_dtb ] && [ -f ramdisk.cpio ] || fail "Missing original boot sections"
[ "$(sha kernel_dtb)" = "$DTB_SHA" ] || fail "Running camera-corrected DTB changed; no repack"
cp kernel_dtb "$W/old-dtb"
cp ramdisk.cpio "$W/old-ramdisk"

echo "===== REPACK WITH CURRENT VERIFIED DTB AND RAMDISK ====="
cp "$W/newkernel" kernel
"$M" repack -n "$BACK" "$W/boot.img" || fail "MagiskBoot repack failed"
[ -f "$W/boot.img" ] || fail "No repacked boot"
[ "$(wc -c < "$W/boot.img")" -le 33554432 ] || fail "Output exceeds boot partition"

echo "===== INDEPENDENT CONTENT VERIFICATION ====="
cd "$W/check"
"$M" unpack -n -h "$W/boot.img" || fail "Repacked image could not be unpacked"
[ -f kernel ] && [ -f kernel_dtb ] && [ -f ramdisk.cpio ] || fail "Repacked parts missing"
cmp -s kernel "$W/newkernel" || fail "Diagnostic kernel content changed"
cmp -s kernel_dtb "$W/old-dtb" || fail "Corrected DTB was not preserved"
cmp -s ramdisk.cpio "$W/old-ramdisk" || fail "Magisk ramdisk was not preserved"
cp "$W/boot.img" "$OUT" || fail "Could not save candidate"
chmod 0644 "$OUT"
echo "===== VERIFIED CSID CLOCK REPAIR CANDIDATE (NOT FLASHED) ====="
echo "Backup: $BACK"
echo "Backup SHA256: $(sha "$BACK")"
echo "Candidate: $OUT"
echo "Candidate SHA256: $(sha "$OUT")"
echo "Preserved: corrected CSI clock DTBs, original Magisk ramdisk"
echo "Replaced: kernel only, with per-CSID clock-array repair build"
echo "DO NOT FLASH UNTIL RECOVERY AND BACKUP ARE VERIFIED"
