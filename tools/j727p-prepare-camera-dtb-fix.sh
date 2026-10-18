#!/system/bin/sh
# SM-J727P / LineageOS 16: prepare corrected camera DTB boot image.
# READ boot partition; WRITE only SD-card backup/output; NEVER flash.
set -eu

ART="${1:-/sdcard/Download/j727p-zram-camera-v2-3.zip}"
M=/data/adb/magisk/magiskboot
UNZIP=/data/data/com.termux/files/usr/bin/unzip
BACKUP=/sdcard/Download/J727P-active-boot-before-DTB-repair.img
OUT=/sdcard/Download/J727P-camera-DTB-fixed-UNFLASHED.img
IMAGE_SHA=774ec8396a90cdfae10826ac390f6b032236cb61411969bb6e72fdff30c74f2f
OLD_DTB_SHA=dba2efdf760f9ba305f572171722b774911047e5748187db65026bf718489779
NEW_DTB_SHA=bd43c6a38e592df361a8610ac7ea73dd8d6efbf3935d3c8714fb2369a5745542

fail() { echo "STOP: $*" >&2; exit 1; }
sha() { line="$(sha256sum "$1")" || return 1; printf '%s\n' "${line%% *}"; }
[ "$(id -u)" = 0 ] || fail "Run as root through su -c"
[ "$(getprop ro.build.version.release)" = 9 ] || fail "Android 9 required"
case "$(getprop ro.product.device) $(getprop ro.build.product)" in
  *j7popltespr*) : ;;
  *) fail "Device not identified as j7popltespr" ;;
esac
[ -f "$ART" ] || fail "Kernel artifact missing: $ART"
[ -x "$UNZIP" ] || fail "Install unzip in Termux: pkg install unzip"
[ -x "$M" ] || fail "MagiskBoot unavailable: $M"
[ ! -e "$BACKUP" ] || fail "Existing backup: $BACKUP (refusing overwrite)"
[ ! -e "$OUT" ] || fail "Existing output: $OUT (refusing overwrite)"

# Accept only an explicitly named boot-partition symlink, never arbitrary blocks.
BOOT=""
for C in \
 /dev/block/by-name/boot \
 /dev/block/bootdevice/by-name/boot \
 /dev/block/platform/*/by-name/boot \
 /dev/block/platform/*/*/by-name/boot \
 /dev/block/by-name/BOOT \
 /dev/block/bootdevice/by-name/BOOT \
 /dev/block/platform/*/by-name/BOOT \
 /dev/block/platform/*/*/by-name/BOOT
do
 [ -b "$C" ] || continue
 BOOT="$C"
 break
done
[ -n "$BOOT" ] || fail "Boot partition path not found; no changes made"

echo "===== SOURCE ====="
echo "Device: $(getprop ro.product.device)"
echo "Kernel: $(uname -r)"
echo "Boot partition (READ ONLY): $BOOT"
echo "Artifact: $ART"

W=/data/local/tmp/j727p-dtb-repair-$$
[ ! -e "$W" ] || fail "Temporary workspace already exists"
umask 077
mkdir -p "$W/repack" "$W/verify" || fail "Cannot create workspace"
trap 'rm -rf "$W"' EXIT

echo "===== VALIDATE PINNED ARTIFACT ====="
"$UNZIP" -p "$ART" Image.gz-dtb > "$W/Image.gz-dtb" || fail "Artifact extraction failed"
[ "$(sha "$W/Image.gz-dtb")" = "$IMAGE_SHA" ] || fail "Wrong artifact Image.gz-dtb SHA256"
[ "$(wc -c < "$W/Image.gz-dtb")" -eq 12544301 ] || fail "Unexpected artifact size"
# CI artifact layout: compressed kernel (11000154 bytes) + 6 DTBs (1544147 bytes).
dd if="$W/Image.gz-dtb" of="$W/new-kernel_dtb" bs=11000154 skip=1 2>/dev/null || fail "DTB extraction failed"
[ "$(wc -c < "$W/new-kernel_dtb")" -eq 1544147 ] || fail "Unexpected new DTB size"
[ "$(sha "$W/new-kernel_dtb")" = "$NEW_DTB_SHA" ] || fail "New device-tree SHA256 mismatch"

echo "===== BACK UP EXACT RUNNING BOOT PARTITION ====="
dd if="$BOOT" of="$BACKUP" bs=1048576 2>/dev/null || fail "Cannot read current boot partition"
[ "$(wc -c < "$BACKUP")" -eq 33554432 ] || fail "Boot backup is not the expected 32 MiB; STOP"
echo "Backup: $BACKUP"
echo "Backup SHA256: $(sha "$BACKUP")"

cd "$W/repack"
"$M" unpack -n -h "$BACKUP" || fail "Cannot unpack current boot"
[ -f kernel ] && [ -f kernel_dtb ] && [ -f ramdisk.cpio ] || fail "Missing split boot parts"
[ "$(sha kernel_dtb)" = "$OLD_DTB_SHA" ] || fail "Running boot DTB differs from expected old DTB; STOP. Do not replace blindly."
cp kernel "$W/current-kernel"
cp ramdisk.cpio "$W/current-ramdisk"
cp "$W/new-kernel_dtb" kernel_dtb

echo "===== REPACK ONLY THE DEVICE TREE ====="
"$M" repack -n "$BACKUP" "$W/new-boot.img" || fail "MagiskBoot repack failed"
[ -f "$W/new-boot.img" ] || fail "No new boot image produced"
[ "$(wc -c < "$W/new-boot.img")" -le 33554432 ] || fail "Repacked boot exceeds boot partition"
cd "$W/verify"
"$M" unpack -n -h "$W/new-boot.img" || fail "Cannot independently unpack repacked image"
[ -f kernel ] && [ -f kernel_dtb ] && [ -f ramdisk.cpio ] || fail "Repacked boot missing parts"
cmp -s kernel "$W/current-kernel" || fail "Kernel changed unexpectedly"
cmp -s ramdisk.cpio "$W/current-ramdisk" || fail "Ramdisk changed unexpectedly"
[ "$(sha kernel_dtb)" = "$NEW_DTB_SHA" ] || fail "Corrected DTB not found in repacked boot"

cp "$W/new-boot.img" "$OUT" || fail "Cannot save final image"
chmod 0644 "$OUT"
echo "===== PREPARED (NOT FLASHED) ====="
echo "Output: $OUT"
echo "SHA256: $(sha "$OUT")"
echo "Original boot preserved at: $BACKUP"
echo "Kernel: byte-identical to current running boot image"
echo "Magisk ramdisk: byte-identical to current running boot image"
echo "Device tree: corrected 7-name CSIPHY version (artifact hash pinned)"
echo "NO FLASHING WAS PERFORMED. Review the image before any flashing."
