#!/system/bin/sh
# J727P Camera CSIPHY DTB-only repair candidate; does not flash.
# Requires the user's verified running boot backup and CI artifact.
set -eu
ART="${1:-/sdcard/Download/j727p-zram-camera-v2-3.zip}"
BOOT=/dev/block/by-name/boot
BASE=/sdcard/Download/J727P-active-boot-before-DTB-repair.img
OUT=/sdcard/Download/J727P-camera-DTB-fixed-UNFLASHED.img
MAGISK=/data/adb/magisk/magiskboot
UNZIP=/data/data/com.termux/files/usr/bin/unzip
PY=/data/data/com.termux/files/usr/bin/python
COMPARE=/data/data/com.termux/files/home/j727p-dtb-compare.py
BOOT_SHA=498bcaa463967bf46095d41e2f28be0e2ff324c74f82727b2f819f804c5db08c
ART_SHA=774ec8396a90cdfae10826ac390f6b032236cb61411969bb6e72fdff30c74f2f
NEW_DTB_SHA=bd43c6a38e592df361a8610ac7ea73dd8d6efbf3935d3c8714fb2369a5745542
fail() { echo "STOP: $*" >&2; exit 1; }
sha() { H="$(sha256sum "$1")" || return 1; printf '%s\n' "${H%% *}"; }
[ "$(id -u)" = 0 ] || fail "Run as root"
[ "$(getprop ro.product.device)" = "j7popltespr" ] || fail "Not the expected J727P device"
[ "$(getprop ro.build.version.sdk)" = "28" ] || fail "Not Android 9"
[ -b "$BOOT" ] || fail "Boot partition not found"
[ -f "$BASE" ] || fail "Original running boot backup missing"
[ "$(wc -c < "$BASE")" -eq 33554432 ] || fail "Unexpected boot backup size"
[ "$(sha "$BASE")" = "$BOOT_SHA" ] || fail "Boot backup hash mismatch"
echo "===== COMPARE RUNNING BOOT WITH VERIFIED BACKUP ====="
[ "$(sha "$BOOT")" = "$BOOT_SHA" ] || fail "Running boot changed since backup: STOP. Do not flash or repack."
[ -f "$ART" ] || fail "Required camera-zram artifact missing"
[ -x "$UNZIP" ] || fail "Install unzip in Termux"
[ -x "$PY" ] || fail "Install python in Termux"
[ -x "$MAGISK" ] || fail "MagiskBoot executable missing"
[ -r "$COMPARE" ] || fail "j727p-dtb-compare.py is missing from Termux HOME"
[ ! -e "$OUT" ] || fail "Output exists; refusing overwrite: $OUT"
W=/data/local/tmp/j727p-camera-dtb-verify-$$
umask 077
mkdir -p "$W/repack" "$W/verify"
trap 'rm -rf "$W"' EXIT
echo "===== EXTRACT PINNED CAMERA-REPAIRED DTB ====="
"$UNZIP" -p "$ART" Image.gz-dtb > "$W/Image.gz-dtb" || fail "Unable to read CI kernel artifact"
[ "$(sha "$W/Image.gz-dtb")" = "$ART_SHA" ] || fail "CI artifact mismatch"
[ "$(wc -c < "$W/Image.gz-dtb")" -eq 12544301 ] || fail "CI artifact size mismatch"
dd if="$W/Image.gz-dtb" of="$W/fixed-dtb.bin" bs=11000154 skip=1 2>/dev/null || fail "Failed extracting appended DTBs"
[ "$(wc -c < "$W/fixed-dtb.bin")" -eq 1544147 ] || fail "Corrected DTB length mismatch"
[ "$(sha "$W/fixed-dtb.bin")" = "$NEW_DTB_SHA" ] || fail "Corrected DTB hash mismatch"
echo "===== UNPACK VERIFIED CURRENT BOOT ====="
cd "$W/repack"
"$MAGISK" unpack -n -h "$BASE" || fail "Cannot unpack current boot"
[ -f kernel ] && [ -f kernel_dtb ] && [ -f ramdisk.cpio ] || fail "Boot parts missing"
[ "$(wc -c < kernel_dtb)" -eq 1543859 ] || fail "Old DTB size changed"
cp kernel "$W/original-kernel"
cp ramdisk.cpio "$W/original-ramdisk"
echo "===== VERIFY ALL SIX DTBS AND EXACT CAMERA-ONLY CHANGES ====="
"$PY" - "$COMPARE" "$W/repack/kernel_dtb" "$W/fixed-dtb.bin" <<'PYCODE'
import hashlib, runpy, struct, sys
from pathlib import Path
module = runpy.run_path(sys.argv[1])
old = module['blobs'](Path(sys.argv[2]).read_bytes())
new = module['blobs'](Path(sys.argv[3]).read_bytes())
old_sizes = [257424,257514,257470,257351,257533,256567]
old_prefixes = ['80710f2c6a880418','5bdc26c48cb02e26','67d285aa045666dd','708abde9c29d03d7','1f2b0097bf151a5d','fcfafe9a5a33a45c']
assert len(old) == len(new) == 6, "Unexpected FDT count"
expected = set()
for i in range(3):
    node = f'/soc/qcom,csiphy@1b3{i+4}000'
    expected.add(node + ':clock-names')
    expected.add(node + ':qcom,clock-rates')
old_expected = ('camss_top_ahb_clk','ispif_ahb_clk','csiphy_timer_src_clk','csiphy_timer_clk','camss_ahb_src','camss_ahb_clk')
def strings(raw):
    return tuple(p.decode('ascii') for p in raw.rstrip(b'\x00').split(b'\x00'))
def rates(raw):
    assert len(raw) % 4 == 0
    return struct.unpack('>' + 'I'*(len(raw)//4),raw)
for index, ((old_off,a),(new_off,b)) in enumerate(zip(old,new)):
    assert len(a)==old_sizes[index] and len(b)==len(a)+48, (index, len(a),len(b))
    assert hashlib.sha256(a).hexdigest().startswith(old_prefixes[index]), f'Old FDT {index} changed'
    ap,bp=module['properties'](a),module['properties'](b)
    changed={k for k in (ap.keys() | bp.keys()) if ap.get(k)!=bp.get(k)}
    assert changed==expected, (index, sorted(changed ^ expected))
    for i in range(3):
        prefix=f'/soc/qcom,csiphy@1b3{i+4}000:'
        before=strings(ap[prefix+'clock-names'])
        after=strings(bp[prefix+'clock-names'])
        assert before==old_expected, (index,i,before)
        assert after==before[:5]+(f'csi{i}_phy_clk',)+before[5:], (index,i,after)
        old_rates=rates(ap[prefix+'qcom,clock-rates'])
        new_rates=rates(bp[prefix+'qcom,clock-rates'])
        assert old_rates==(0,61540000,200000000,0,0,0), (index,i,old_rates)
        assert new_rates==old_rates[:5]+(0,)+old_rates[5:], (index,i,new_rates)
    print(f'FDT #{index}: verified exactly 6 intended changes; no unrelated property changes')
print('PASS: all six device trees match pinned original structures and corrected clock arrays')
PYCODE
echo "===== REPACK CURRENT KERNEL + MAGISK RAMDISK + CORRECTED DTB ====="
cp "$W/fixed-dtb.bin" "$W/repack/kernel_dtb"
"$MAGISK" repack -n "$BASE" "$W/new-boot.img" || fail "MagiskBoot repack failed"
[ -f "$W/new-boot.img" ] || fail "No boot image produced"
[ "$(wc -c < "$W/new-boot.img")" -le 33554432 ] || fail "Image exceeds boot partition"
echo "===== VERIFY REPACKED CONTENTS ====="
cd "$W/verify"
"$MAGISK" unpack -n -h "$W/new-boot.img" || fail "Cannot verify repacked boot"
[ -f kernel ] && [ -f kernel_dtb ] && [ -f ramdisk.cpio ] || fail "Repack is missing required sections"
cmp -s kernel "$W/original-kernel" || fail "Kernel changed unexpectedly"
cmp -s ramdisk.cpio "$W/original-ramdisk" || fail "Magisk ramdisk changed unexpectedly"
[ "$(sha kernel_dtb)" = "$NEW_DTB_SHA" ] || fail "Repacked DTB mismatch"
cp "$W/new-boot.img" "$OUT" || fail "Failed writing final output"
chmod 0644 "$OUT"
echo "===== CANDIDATE READY: NOT FLASHED ====="
echo "Backup: $BASE"
echo "Backup SHA256: $BOOT_SHA"
echo "Candidate: $OUT"
echo "Candidate SHA256: $(sha "$OUT")"
echo "Preserved: current kernel + Magisk ramdisk"
echo "Changed: only the validated camera CSIPHY DTB properties"
echo "STOP HERE. Inspect results before any boot partition write."
