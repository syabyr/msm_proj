#!/bin/bash
# build-kernel.sh - build the W1A mainline kernel (step 1, standalone)
#
# Usage: tools/build-kernel.sh [--no-config] [defconfig]
#   --no-config  skip the config sync (raw make only)
#   defconfig    default: cmcc_w1a_defconfig (the board's own minimal
#                defconfig, committed in arch/arm/configs/)
#   env: W1A_KERNEL  kernel tree   (default: ../linux-mainline)
#        W1A_KOUT    build output  (default: ../ml-out)
# Runs sync-kernel-config.sh first (W1A required options check), then
# builds zImage + DTBs.

set -e

AST="$(cd "$(dirname "$0")/.." && pwd)"
KERN="${W1A_KERNEL:-$AST/linux-mainline}"
[ -d "$KERN" ] || KERN="$AST/../linux-mainline"   # old layout fallback
CROSS="${CROSS_COMPILE:-arm-linux-gnueabihf-}"
KOUT="${W1A_KOUT:-$KERN/../ml-out}"
DEFCONFIG="${DEFCONFIG:-cmcc_w1a_defconfig}"

# optional flags
while [ $# -gt 0 ]; do
    case "$1" in
        --no-config) NOCONFIG=1; shift ;;
        *) DEFCONFIG="$1"; shift ;;
    esac
done

if [ -z "$NOCONFIG" ]; then
    W1A_KERNEL="$KERN" W1A_KOUT="$KOUT" CROSS_COMPILE="$CROSS" \
        "$AST/tools/sync-kernel-config.sh"
fi

if [ ! -f "$KOUT/.config" ]; then
    make -C "$KERN" O="$KOUT" ARCH=arm CROSS_COMPILE=$CROSS \
        "$DEFCONFIG"
fi

make -C "$KERN" O="$KOUT" ARCH=arm \
    CROSS_COMPILE=$CROSS -j"$(nproc)" zImage dtbs

echo "=== kernel ready:"
ls -la "$KOUT/arch/arm/boot/zImage" \
       "$KOUT/arch/arm/boot/dts/qcom/qcom-msm8909-cmcc-w1a.dtb"
