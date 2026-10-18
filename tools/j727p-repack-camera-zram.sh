#!/system/bin/sh
# J727P ZRAM + camera repair: build verified boot image, NEVER flashes.
set -eu
ART="$1"
BASE=/sdcard/Download/J727P-pre-zram-boot.img
OUT=/sdcard/Download/J727P-zram-camera-v2-boot.img
M=/data/adb/magisk/magiskboot
UNZIP=/data/data/com.termux/files/usr/bin/unzip
BASE_SHA=f81ff20675f58f40d521059428e234656f6d4e099c6c1d485893454709cf86f6
IMAGE_SHA=774ec8396a90cdfae10826ac390f6b032236cb61411969bb6e72fdff30c74f2f
KERNEL_SHA=ee45f8b9d0290f052691b751fcf2992bf6c0d2dda466511696e311d8f3ccc359
DTB_SHA=dba2efdf760f9ba305f572171722b774911047e5748187db65026bf718489779
RAMDISK_SHA=270047fe7ded50ea38d629e9d7c1fa0c12d58463a68dc7b587f07c689420d950

die() { echo "STOP: $*" >&2; exit 1; }
hash() { sha256sum "$1" | cut -d ' ' -f 1; }

[ "$(id -u)" = 0 ] || die "Run with su -c."
[ -f "$ART" ] || die "Pass path to downloaded j727p-zram-camera-v2-3.zip"
# Accept only the exact, previously verified camera-v2 boot image.
# A mismatched backup is never modified, replaced, or used as a fallback.
BASE=""
for CANDIDATE in \
 /sdcard/Download/J727P-pre-zram-boot.img \
 /data/local/tmp/j727p-v2-repack-19639/new-boot.img
do
 [ -f "$CANDIDATE" ] || continue
 ACTUAL="$(hash "$CANDIDATE")" || die "Cannot hash $CANDIDATE"
 SIZE="$(wc -c < "$CANDIDATE")" || die "Cannot check size: $CANDIDATE"
 if [ "$ACTUAL" = "$BASE_SHA" ] && [ "$SIZE" -eq 33554432 ]; then
  BASE="$CANDIDATE"
  echo "Verified known-good camera boot: $BASE"
  break
 else
  echo "Skipping mismatched backup (NOT modified): $CANDIDATE"
  echo " Actual SHA256: $ACTUAL, size: $SIZE"
 fi
done
[ -n "$BASE" ] || die "No camera-v2 boot backup matched the pinned SHA256; no changes made"
[ -x "$M" ] || die "MagiskBoot not executable: $M"
[ -x "$UNZIP" ] || die "Install unzip in Termux: pkg install unzip"
[ ! -e "$OUT" ] || die "Output already exists. Refusing to overwrite $OUT"

W=/data/local/tmp/j727p-camera-zram-repack-$$
[ ! -e "$W" ] || die "Temporary workspace collision"
umask 077
mkdir -p "$W/split" "$W/repack" "$W/verify" || die "Could not create workspace"
trap 'rm -rf "$W"' EXIT

echo "===== EXTRACT VERIFIED GITHUB ACTIONS IMAGE ====="
"$UNZIP" -p "$ART" Image.gz-dtb > "$W/Image.gz-dtb" || die "Unable to extract kernel"
[ "$(hash "$W/Image.gz-dtb")" = "$IMAGE_SHA" ] || die "Wrong/altered camera-repair kernel artifact"

echo "===== SPLIT NEW KERNEL AND DEVICE TREES ====="
cd "$W/split"
"$M" split -n "$W/Image.gz-dtb" || die "MagiskBoot cannot split Image.gz-dtb"
[ -f kernel ] && [ -f kernel_dtb ] || die "Split did not produce kernel + kernel_dtb"
[ "$(hash kernel)" = "$KERNEL_SHA" ] || die "Unexpected new kernel payload"
echo "New kernel SHA256: $(hash kernel)"
echo "Artifact DTB SHA256: $(hash kernel_dtb)"

echo "===== UNPACK KNOWN-GOOD CAMERA BOOT ====="
cd "$W/repack"
"$M" unpack -n -h "$BASE" || die "Could not unpack original boot"
[ -f kernel_dtb ] && [ -f ramdisk.cpio ] || die "Missing known-good boot components"
[ "$(hash kernel_dtb)" = "$DTB_SHA" ] || die "Known-good device tree does not match"
[ "$(hash ramdisk.cpio)" = "$RAMDISK_SHA" ] || die "Known-good ramdisk does not match"

# Replace ONLY the compressed kernel. Keep current camera DTB and Magisk ramdisk.
cp "$W/split/kernel" "$W/repack/kernel"
echo "===== REPACK WITHOUT FLASHING ====="
"$M" repack -n "$BASE" "$W/new-boot.img" || die "MagiskBoot repack failed"
[ -f "$W/new-boot.img" ] || die "Repacked boot is missing"
[ "$(wc -c < "$W/new-boot.img")" -le 33554432 ] || die "Repacked image exceeds 32 MiB boot partition"

echo "===== VERIFY REPACKED CONTENTS ====="
cd "$W/verify"
"$M" unpack -n -h "$W/new-boot.img" || die "Could not independently unpack repacked boot"
cmp -s kernel "$W/split/kernel" || die "Kernel payload changed unexpectedly"
cmp -s kernel_dtb "$W/repack/kernel_dtb" || die "Known-good camera device tree was not preserved"
cmp -s ramdisk.cpio "$W/repack/ramdisk.cpio" || die "Original Magisk ramdisk was not preserved"

# No writes to /dev/block/* anywhere in this script.
cp "$W/new-boot.img" "$OUT" || die "Unable to copy final boot image"
chmod 0644 "$OUT"
echo "===== SUCCESS ====="
echo "Created: $OUT"
echo "Size: $(wc -c < "$OUT") bytes"
echo "SHA256: $(hash "$OUT")"
echo "Kernel: new ZRAM + camera clock repair"
echo "Device tree: original known-good camera DTB"
echo "Ramdisk/header: based on original known-good Magisk boot"
echo "NO BOOT PARTITION WRITTEN. DO NOT FLASH UNTIL CAMERA BINDER MODULE CHECKED."
