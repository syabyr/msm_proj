#!/bin/sh
# =============================================================================
# In-container build entrypoint for linux-6.12.1-msm8916 (aarch64).
#
# Reproduces the prepare() / build() / package() steps of the pmOS APKBUILD at
# pmaports/device/testing/linux-postmarketos-qcom-msm8916/APKBUILD
#
# Expected bind-mounts (set up by build.sh):
#   /src   kernel source tree (linux-6.12.1-msm8916), read-write
#   /out   artifact destination, read-write
#   /cfg   dir holding config-postmarketos-qcom-msm8916.aarch64, read-only
#
# Environment:
#   MODE    all (default) | config | build | install
#   CLEAN   1 -> run `make mrproper` before configuring (fresh tree)
#   JOBS    parallel jobs (default: nproc)
# =============================================================================
set -eu

SRC="${SRC:-/src}"
OUT="${OUT:-/out}"
CFG_DIR="${CFG_DIR:-/cfg}"
FLAVOR="postmarketos-qcom-msm8916"
PKGREL=5                                 # from APKBUILD pkgrel
JOBS="${JOBS:-$(nproc)}"
MODE="${MODE:-all}"
CLEAN="${CLEAN:-0}"

# aarch64 only
KARCH=arm64
CROSS_COMPILE=aarch64-none-elf-
CARCH=aarch64

CONFIG_SRC="$CFG_DIR/config-$FLAVOR.$CARCH"
# unquoted on purpose: ARCH=.. and CROSS_COMPILE=.. must split into make args
MAKE="make ARCH=$KARCH CROSS_COMPILE=$CROSS_COMPILE"

log()  { printf '\n\033[1;34m[kbuild]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[kbuild]\033[0m %s\n' "$*" >&2; }

cd "$SRC"

# --- prepare() ---------------------------------------------------------------
# default_prepare + copy the pmOS config onto .config
prepare() {
    if [ ! -f "$CONFIG_SRC" ]; then
        echo "ERROR: config not found: $CONFIG_SRC" >&2
        echo "       mount the dir holding config-$FLAVOR.$CARCH at $CFG_DIR" >&2
        exit 1
    fi

    if [ "$CLEAN" = "1" ]; then
        log "make mrproper (CLEAN=1)"
        $MAKE mrproper
    fi

    log "copy config: $CONFIG_SRC -> .config"
    cp -f "$CONFIG_SRC" "$SRC/.config"

    log "make olddefconfig (resolve config against this toolchain)"
    $MAKE olddefconfig
}

# --- build() -----------------------------------------------------------------
# Mirrors APKBUILD build(): unset LDFLAGS, KBUILD_BUILD_VERSION = pkgrel + 1
build() {
    log "building kernel: ARCH=$KARCH  CC=${CROSS_COMPILE}gcc  -j$JOBS"
    unset LDFLAGS
    $MAKE -j"$JOBS" KBUILD_BUILD_VERSION=$((PKGREL + 1))
}

# --- package() ---------------------------------------------------------------
# Mirrors APKBUILD package(): install kernel image(s), modules and dtbs.
# Named package() (not install()) so the external `install` command used below
# is not shadowed by this function -- otherwise `install -D ...` would recurse
# into the function forever and never copy any file.
package() {
    log "collecting artifacts -> $OUT"
    mkdir -p "$OUT/boot" "$OUT/usr/share/kernel/$FLAVOR"

    ZBOOT_IMG="$SRC/arch/$KARCH/boot/vmlinuz.efi"

    # kernel image(s) -- same branching as the APKBUILD
    if [ -e "$ZBOOT_IMG" ]; then
        # ZBOOT EFI decompressor (CONFIG_EFI_ZBOOT) for EFI booting
        install -D -m 0644 "$ZBOOT_IMG" "$OUT/boot/linux.efi"
        # Old GZIP'd kernel image for boot.img compatibility
        install -D -m 0644 "$SRC/arch/$KARCH/boot/vmlinuz" "$OUT/boot/vmlinuz"
    elif [ "$KARCH" = "arm64" ]; then
        warn "CONFIG_ZBOOT not enabled!"
        install -D -m 0644 "$SRC/arch/$KARCH/boot/Image.gz" "$OUT/boot/vmlinuz"
    fi

    $MAKE modules_install dtbs_install \
        INSTALL_PATH="$OUT/boot" \
        INSTALL_MOD_PATH="$OUT" \
        INSTALL_MOD_STRIP=1 \
        INSTALL_DTBS_PATH="$OUT/boot/dtbs"

    # drop build/source symlinks from the modules tree (like the APKBUILD)
    rm -f "$OUT"/lib/modules/*/build "$OUT"/lib/modules/*/source

    # kernel.release -- consumed by postmarketos-mkinitfs etc.
    install -D "$SRC/include/config/kernel.release" \
        "$OUT/usr/share/kernel/$FLAVOR/kernel.release"

    log "kernel.release: $(cat "$OUT/usr/share/kernel/$FLAVOR/kernel.release" 2>/dev/null || echo '?')"
    log "artifacts (first 50):"
    ( cd "$OUT" && find . -type f | sed 's#^\./##' | sort | head -50 | sed 's/^/    /' )
}

case "$MODE" in
    config)  prepare ;;
    build)   prepare; build ;;
    install) package ;;
    all)     prepare; build; package ;;
    *) echo "ERROR: unknown MODE=$MODE (use all|config|build|install)" >&2; exit 1 ;;
esac

log "done (MODE=$MODE)."
