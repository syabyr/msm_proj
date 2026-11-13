#!/bin/bash
# sync-kernel-config.sh - sync/check the W1A kernel config (step 0)
#
# Usage: tools/sync-kernel-config.sh [--check] [--fresh]
#   --check  only verify required options, no changes
#   --fresh  re-seed .config from arch/arm/configs/cmcc_w1a_defconfig
#            (then still verifies + olddefconfig - a freshly seeded
#            minimal defconfig MUST be expanded before building)
#
# The canonical board config is cmcc_w1a_defconfig (committed, minimal
# savedefconfig output).  ml-out/.config is the live build input; this
# script guarantees every W1A driver option is present in it (they were
# enabled piecemeal during bring-up).

set -e

AST="$(cd "$(dirname "$0")/.." && pwd)"
KERN="${W1A_KERNEL:-$AST/linux-mainline}"
[ -d "$KERN" ] || KERN="$AST/../linux-mainline"   # old layout fallback
CROSS="${CROSS_COMPILE:-arm-linux-gnueabihf-}"
KOUT="${W1A_KOUT:-$KERN/../ml-out}"
DEF="$KERN/arch/arm/configs/cmcc_w1a_defconfig"
CFG="$KOUT/.config"

MODE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE=check; shift ;;
        --fresh) MODE=fresh; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -f "$DEF" ] || { echo "ERROR: board defconfig missing: $DEF" >&2; exit 1; }

if [ "$MODE" = "fresh" ] || [ ! -f "$CFG" ]; then
    [ "$MODE" = "fresh" ] && echo "re-seeding from cmcc_w1a_defconfig" \
        || echo "no existing .config - seeding from board defconfig"
    make -C "$KERN" O="$KOUT" ARCH=arm CROSS_COMPILE=$CROSS \
        cmcc_w1a_defconfig
fi

# key options added during W1A bring-up (must stay set; a fresh .config
# seeded from an older defconfig would silently lose drivers)
W1A_REQUIRED="
CONFIG_DRM_MSM_MDP3
CONFIG_TOUCHSCREEN_FT3267
CONFIG_INPUT_PM8941_PWRKEY
CONFIG_POWER_RESET_QCOM_PON
CONFIG_BATTERY_CW2015
CONFIG_AK8975
CONFIG_BMP280
CONFIG_IIO_ST_LSM6DSX
CONFIG_IIO_ST_LSM6DSX_SPI
CONFIG_BT
CONFIG_BT_QCOMSMD
CONFIG_WCN36XX
CONFIG_QCOM_WCNSS_PIL
CONFIG_QCOM_WCNSS_CTRL
CONFIG_QCOM_SPM
CONFIG_ARM_QCOM_SPM_CPUIDLE
CONFIG_QCOM_CLK_APCS_MSM8916
CONFIG_ARM_QCOM_CPUFREQ_NVMEM
CONFIG_SND_SOC_QCOM
CONFIG_SND_SOC_APQ8016_SBC
CONFIG_SND_SOC_MSM8916_WCD_ANALOG
CONFIG_SND_SOC_MSM8916_WCD_DIGITAL
CONFIG_SPI_QUP
CONFIG_QRTR
CONFIG_QCOM_Q6V5_MSS
CONFIG_QRTR_SMD
CONFIG_I2C_CHARDEV
CONFIG_INPUT_EVDEV
"

DRIFT=0
for opt in $W1A_REQUIRED; do
    val=$(grep -m1 "^$opt=" "$CFG" 2>/dev/null | cut -d= -f2)
    if [ -z "$val" ] && grep -q "^# $opt is not set" "$CFG" 2>/dev/null; then
        val=n
    fi
    if [ "$val" != "y" ]; then
        if [ "$MODE" = "check" ]; then
            echo "DRIFT: $opt is '$val' (expected y)"
            DRIFT=1
        else
            echo "enabling $opt"
            "$KERN/scripts/config" --file "$CFG" -e "${opt#CONFIG_}"
        fi
    fi
done

if [ "$MODE" = "check" ]; then
    [ "$DRIFT" = 0 ] && echo "check complete: no drift" \
        || { echo "check complete: DRIFT FOUND"; exit 1; }
    exit 0
fi

# expand the (possibly minimal/re-seeded) config to a full .config
make -C "$KERN" O="$KOUT" ARCH=arm \
    CROSS_COMPILE=$CROSS olddefconfig
echo "=== config synced: $CFG"
