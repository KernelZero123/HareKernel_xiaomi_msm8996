#!/usr/bin/env bash
#
# build-lithium.sh - build the BakaSU-enabled kernel for Xiaomi Mi MIX (lithium)
#
# Why this script exists
# ----------------------
# mi8996_defconfig is shared by every msm8996 Xiaomi device. The per-device
# options live in a separate fragment under
# arch/arm64/configs/vendor/xiaomi/<device>.config and MUST be merged on top
# of the base defconfig.
#
# Building with mi8996_defconfig alone produces a kernel that links fine but
# lacks
#   CONFIG_TOUCHSCREEN_FT5X46_I2C   touchscreen
#   CONFIG_FINGERPRINT_FPC1020_TA   fingerprint
#   CONFIG_LEDS_QPNP_HAPTICS        vibration
#   CONFIG_MACH_XIAOMI_A8           device match
# so it boots to a dead screen with no fingerprint.
#
# Usage
# -----
#   ./build-lithium.sh                  build Image for lithium
#   DEVICE=gemini ./build-lithium.sh    any other msm8996 fragment
#   OUT=out JOBS=8 ./build-lithium.sh   custom output dir / job count
#
# Override CC / LD / HOSTCC / HOSTLD / CROSS_COMPILE / CROSS_COMPILE_ARM32
# from the environment if your toolchain lives somewhere else.
#
set -euo pipefail

KERNEL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$KERNEL_DIR"

DEVICE=${DEVICE:-lithium}
OUT=${OUT:-$KERNEL_DIR/out}
JOBS=${JOBS:-$(nproc)}

CC=${CC:-clang}
LD=${LD:-ld.lld}
HOSTCC=${HOSTCC:-gcc}
HOSTLD=${HOSTLD:-ld.lld}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
CROSS_COMPILE_ARM32=${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}

BASE_DEFCONFIG=arch/arm64/configs/vendor/xiaomi/mi8996_defconfig
DEVICE_FRAGMENT=arch/arm64/configs/vendor/xiaomi/${DEVICE}.config

MAKE_ARGS=(
	O="$OUT"
	ARCH=arm64
	CC="$CC"
	LD="$LD"
	HOSTCC="$HOSTCC"
	HOSTLD="$HOSTLD"
	CROSS_COMPILE="$CROSS_COMPILE"
	CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32"
)

die() { echo "error: $*" >&2; exit 1; }

[ -f "$BASE_DEFCONFIG" ] || die "missing $BASE_DEFCONFIG"

if [ ! -f "$DEVICE_FRAGMENT" ]; then
	known=$(cd arch/arm64/configs/vendor/xiaomi && ls ./*.config 2>/dev/null |
		xargs -n1 basename | sed 's/\.config$//' | tr '\n' ' ')
	die "missing $DEVICE_FRAGMENT (known devices: ${known})"
fi

# BakaSU's Kbuild shells out to git to derive its version string, so the
# submodule has to be populated or the build dies halfway through.
if [ ! -f KernelSU/kernel/Kconfig ]; then
	die "KernelSU submodule is empty - run: git submodule update --init"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# mi8996_defconfig does not enable F2FS, but the stock boot.img for these
# devices ships a kernel with it built in, so a userdata partition formatted
# f2fs would fail to mount. Keep parity with stock instead of gambling on the
# filesystem the ROM happens to use.
cat > "$TMP/zz-extras.config" <<'EOF'
CONFIG_F2FS_FS=y
CONFIG_F2FS_STAT_FS=y
CONFIG_F2FS_FS_XATTR=y
CONFIG_F2FS_FS_POSIX_ACL=y
CONFIG_F2FS_FS_SECURITY=y
EOF

echo ">> merging config: mi8996_defconfig + ${DEVICE}.config + extras"
mkdir -p "$OUT"
ARCH=arm64 scripts/kconfig/merge_config.sh -m -O "$TMP" \
	"$BASE_DEFCONFIG" "$DEVICE_FRAGMENT" "$TMP/zz-extras.config" >/dev/null

# merge_config.sh -m only concatenates the fragments, it does not resolve
# dependencies or drop stale symbols, so run olddefconfig on the result.
cp "$TMP/.config" "$OUT/.config"

echo ">> olddefconfig"
make "${MAKE_ARGS[@]}" olddefconfig

echo ">> prepare"
make "${MAKE_ARGS[@]}" prepare

echo ">> building Image (-j$JOBS)"
make -j"$JOBS" "${MAKE_ARGS[@]}" Image

IMAGE="$OUT/arch/arm64/boot/Image"
[ -f "$IMAGE" ] || die "build finished but $IMAGE is missing"

# Post-build sanity check. A kernel that silently lost its device drivers
# still links and still boots, so confirm the drivers actually made it in
# instead of trusting that the config merge worked.
#
# Note: dump the strings once into a variable and grep that. Piping straight
# into `grep -q` looks correct but trips over `set -o pipefail`: grep exits as
# soon as it matches, strings takes SIGPIPE, and the pipeline is reported as
# failed even though the symbol was found.
echo ">> verifying device drivers in Image"
IMAGE_STRINGS="$TMP/image.strings"
strings -a "$IMAGE" > "$IMAGE_STRINGS"
missing=0
for sym in ft5x46 fpc1020 qpnp_haptics f2fs; do
	if grep -qi -- "$sym" "$IMAGE_STRINGS"; then
		printf '   %-16s ok\n' "$sym"
	else
		printf '   %-16s MISSING\n' "$sym"
		missing=$((missing + 1))
	fi
done

[ "$missing" -eq 0 ] ||
	die "$missing driver(s) missing - the device fragment was probably not applied"

echo
echo "done: $IMAGE"
echo "note: pack it into boot.img with the stock header/ramdisk for your device."
