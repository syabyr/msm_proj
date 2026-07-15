#!/usr/bin/env bash
# =============================================================================
# Build linux-6.12.1-msm8916 (armv7) inside the alpine-based docker image
# produced by the sibling Dockerfile.
#
# The docker image only carries the toolchain + build deps; the kernel source
# tree, the pmOS config and the output dir are bind-mounted into the container
# at runtime, so the image stays small and the host working tree is shared.
#
# Usage:
#   ./build.sh [MODE] [OPTIONS]
#
#   MODE    all (default) | config | build | install
#
# Options:
#   --rebuild       rebuild the docker image even if it already exists
#   --clean         make mrproper before building (fresh source tree)
#   -j N, --jobs N  parallel make jobs (default: nproc inside the container)
#   -h, --help      show this help
#
# Examples:
#   ./build.sh                # build + collect artifacts -> out/armv7
#   ./build.sh build          # only compile the kernel (no install step)
#   ./build.sh all --clean    # clean rebuild
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$HERE/linux-6.12.1-msm8916"
OUT_DIR="$HERE/out"
CONFIG_FILE="$HERE/config-postmarketos-qcom-msm8916.armv7"
IMAGE="${IMAGE:-pmos-kbuild-msm8909}"
IMAGE_REF="$IMAGE:latest"

MODE="all"
REBUILD=0
CLEAN=0
JOBS_ENV=()
TTY=()
[ -t 1 ] && TTY=(-t)

usage() {
    sed -n '/^# Usage:/,/^# ====/p' "$0" | sed 's/^# \?//' | sed 's/^#=====#//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        config|build|install|all) MODE="$1" ;;
        --rebuild) REBUILD=1 ;;
        --clean)   CLEAN=1 ;;
        -j|--jobs) shift; JOBS_ENV=(-e "JOBS=$1") ;;
        -j*)       JOBS_ENV=(-e "JOBS=${1#-j}") ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

# --- sanity checks -----------------------------------------------------------
if [ ! -d "$KERNEL_DIR" ]; then
    echo "ERROR: kernel source not found: $KERNEL_DIR" >&2
    exit 1
fi
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config not found: $CONFIG_FILE" >&2
    exit 1
fi

# --- build the image if missing or --rebuild ---------------------------------
if [ "$REBUILD" = "1" ] || ! docker image inspect "$IMAGE_REF" >/dev/null 2>&1; then
    echo ">> building docker image $IMAGE_REF"
    docker build -t "$IMAGE_REF" -f "$HERE/Dockerfile" "$HERE"
fi

# --- output dir --------------------------------------------------------------
mkdir -p "$OUT_DIR/armv7"

# --- run the container -------------------------------------------------------
echo ">> running: MODE=$MODE"
docker run --rm "${TTY[@]}" \
    -v "$KERNEL_DIR:/src" \
    -v "$OUT_DIR/armv7:/out" \
    -v "$HERE:/cfg:ro" \
    -e MODE="$MODE" \
    -e CLEAN="$CLEAN" \
    "${JOBS_ENV[@]}" \
    "$IMAGE_REF"
