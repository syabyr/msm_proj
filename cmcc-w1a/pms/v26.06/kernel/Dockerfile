# =============================================================================
# Build environment for linux-6.12.1-msm8916 (flavor: postmarketos-qcom-msm8916)
#
# Mirrors the APKBUILD at:
#   pmaports/device/testing/linux-postmarketos-qcom-msm8916/APKBUILD
#
# Base image : alpine:latest   (postmarketOS packaging requirement)
# Target     : armv7 only (32-bit ARM)
# Toolchain  : cross-compiled with the bare-metal GCC toolchain
#              (gcc-arm-none-eabi) shipped by Alpine.
#
# The kernel is freestanding, so the bare-metal toolchain is sufficient.
# pmOS itself uses the musl cross gcc (armv7-alpine-linux-musleabihf-gcc), but
# that package is not published in the Alpine repos and the pmOS repo is
# unreachable from this host; the bare-metal one produces an equivalent kernel
# image (its EABI target matches CONFIG_AEABI=y in the pmOS config).
# CONFIG_WERROR is off in the pmOS config, so extra diagnostics from the newer
# toolchain do not fail the build.
#
# The kernel source tree is NOT copied into the image; it is bind-mounted at
# runtime by build.sh (see .dockerignore) so the image stays small.
# =============================================================================

FROM alpine:latest

# Build dependencies: `makedepends` from the APKBUILD (postmarketos-installkernel
# is a pmOS-only install hook, not needed to compile) + standard kernel host
# tools + the armv7 (32-bit ARM) bare-metal cross toolchain. build-base provides
# the host C compiler (HOSTCC) used for kconfig/scripts helpers.
RUN apk add --no-cache \
        build-base \
        bc bison flex findutils perl python3 \
        openssl-dev gmp-dev mpc1-dev mpfr-dev zstd \
        bash diffutils cpio xz gzip tar \
        gcc-arm-none-eabi binutils-arm-none-eabi

COPY kbuild.sh /usr/local/bin/kbuild.sh
RUN chmod +x /usr/local/bin/kbuild.sh

WORKDIR /src
ENTRYPOINT ["/usr/local/bin/kbuild.sh"]
