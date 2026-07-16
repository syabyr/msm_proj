#!/usr/bin/env bash
# =============================================================================
# Build linux-6.12.1-msm8916 (aarch64) inside the alpine-based docker image
# produced by the sibling Dockerfile.
#
# The docker image only carries the toolchain + build deps. The pmOS config and
# the output dir are bind-mounted into the container at runtime, so the image
# stays small.
#
# Source tree handling depends on the HOST (uname -s):
#   Linux    bind-mount the local source dir linux-6.12.1-msm8916/ directly.
#            Linux host filesystems are case-sensitive, so the case-colliding
#            files in this tree (xt_TCPMSS.c vs xt_tcpmss.c, ...) survive.
#   macOS    host APFS is case-insensitive and would silently drop those files
#            and break the build, so the source is extracted into a case-
#            sensitive docker named volume instead.
#
# Usage:
#   ./build.sh [MODE] [OPTIONS]
#
#   MODE    all (default) | config | build | install
#
# Options:
#   --rebuild       rebuild the docker image even if it already exists
#   --reextract     recreate the source (volume on macOS / dir on Linux) from
#                   the tarball
#   --clean         make mrproper before building (regenerate .config + objects)
#   -j N, --jobs N  parallel make jobs (default: nproc inside the container)
#   -h, --help      show this help
#
# Examples:
#   ./build.sh                # build + collect artifacts -> out/aarch64
#   ./build.sh build          # only compile the kernel (no install step)
#   ./build.sh all --clean    # clean rebuild
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$HERE/linux-6.12.1-msm8916"
OUT_DIR="$HERE/out"
CONFIG_FILE="$HERE/config-postmarketos-qcom-msm8916.aarch64"
TARBALL="$HERE/v6.12.1-msm8916.tar.gz"
IMAGE="${IMAGE:-pmos-kbuild-msm8916}"
IMAGE_REF="$IMAGE:latest"
# case-sensitive docker volume used for the source tree ON macOS only.
SRC_VOLUME="${SRC_VOLUME:-ksrc-msm8916}"
OS_KIND="$(uname -s)"   # Darwin | Linux

MODE="all"
REBUILD=0
REEXTRACT=0
CLEAN=0
JOBS_ENV=()
SRC_MOUNT=()
TTY=()
[ -t 1 ] && TTY=(-t)

usage() {
    sed -n '/^# Usage:/,/^# ====/p' "$0" | sed 's/^# \?//' | sed 's/^#=====#//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        config|build|install|all) MODE="$1" ;;
        --rebuild) REBUILD=1 ;;
        --reextract) REEXTRACT=1 ;;
        --clean)   CLEAN=1 ;;
        -j|--jobs) shift; JOBS_ENV=(-e "JOBS=$1") ;;
        -j*)       JOBS_ENV=(-e "JOBS=${1#-j}") ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

# --- sanity checks -----------------------------------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config not found: $CONFIG_FILE" >&2
    exit 1
fi
if [ ! -f "$TARBALL" ]; then
    echo "ERROR: source tarball not found: $TARBALL" >&2
    exit 1
fi

# --- build the image if missing or --rebuild ---------------------------------
if [ "$REBUILD" = "1" ] || ! docker image inspect "$IMAGE_REF" >/dev/null 2>&1; then
    echo ">> building docker image $IMAGE_REF"
    docker build -t "$IMAGE_REF" -f "$HERE/Dockerfile" "$HERE"
fi

# --- source tree -------------------------------------------------------------
# Ensure the kernel source is available and case-correct, and set SRC_MOUNT to
# the -v argument for the build container. Linux bind-mounts the local dir;
# macOS uses a case-sensitive docker volume (host APFS is case-insensitive and
# would drop the tree's case-colliding files). --reextract rebuilds it.
ensure_source() {
    case "$OS_KIND" in
        Linux)
            if [ "$REEXTRACT" = "1" ]; then
                echo ">> --reextract: removing $KERNEL_DIR"
                rm -rf "$KERNEL_DIR"
            fi
            if [ ! -f "$KERNEL_DIR/Makefile" ]; then
                echo ">> extracting $TARBALL -> $KERNEL_DIR (host, case-sensitive)"
                mkdir -p "$KERNEL_DIR"
                tar xzf "$TARBALL" -C "$KERNEL_DIR" --strip-components=1
            fi
            # guard against an unexpectedly case-insensitive Linux mount (exFAT,
            # FAT, ...): same silent failure mode as macOS APFS otherwise.
            local f1="$KERNEL_DIR/net/netfilter/xt_TCPMSS.c"
            local f2="$KERNEL_DIR/net/netfilter/xt_tcpmss.c"
            if [ -e "$f1" ] && [ -e "$f2" ] && \
               [ "$(stat -c %i "$f1")" = "$(stat -c %i "$f2")" ]; then
                echo "ERROR: $KERNEL_DIR is on a CASE-INSENSITIVE filesystem" >&2
                echo "       ($f1 and $f2 share an inode)." >&2
                echo "       Re-extract onto a case-sensitive FS, or build on macOS" >&2
                echo "       where build.sh uses a case-sensitive docker volume." >&2
                exit 1
            fi
            SRC_MOUNT=(-v "$KERNEL_DIR:/src")
            ;;
        Darwin)
            if [ "$REEXTRACT" = "1" ]; then
                echo ">> --reextract: recreating volume $SRC_VOLUME"
                docker volume rm "$SRC_VOLUME" >/dev/null 2>&1 || true
            fi
            docker volume create "$SRC_VOLUME" >/dev/null
            if ! docker run --rm --entrypoint sh \
                    -v "$SRC_VOLUME:/src" "$IMAGE_REF" -c '[ -f /src/Makefile ]' 2>/dev/null; then
                echo ">> extracting $TARBALL -> volume $SRC_VOLUME (case-sensitive, ~1.5 GiB)"
                docker run --rm \
                    -v "$TARBALL:/tb.tar.gz:ro" \
                    -v "$SRC_VOLUME:/src" \
                    --entrypoint tar "$IMAGE_REF" xzf /tb.tar.gz -C /src --strip-components=1
            fi
            SRC_MOUNT=(-v "$SRC_VOLUME:/src")
            ;;
        *)
            echo "ERROR: unsupported OS: $OS_KIND (expected Linux or Darwin)" >&2
            exit 1
            ;;
    esac
}
ensure_source

# --- output dir --------------------------------------------------------------
mkdir -p "$OUT_DIR/aarch64"

# --- run the container -------------------------------------------------------
echo ">> running: MODE=$MODE  (host: $OS_KIND)"
docker run --rm "${TTY[@]+"${TTY[@]}"}" \
    "${SRC_MOUNT[@]+"${SRC_MOUNT[@]}"}" \
    -v "$OUT_DIR/aarch64:/out" \
    -v "$HERE:/cfg:ro" \
    -e MODE="$MODE" \
    -e CLEAN="$CLEAN" \
    "${JOBS_ENV[@]+"${JOBS_ENV[@]}"}" \
    "$IMAGE_REF"
