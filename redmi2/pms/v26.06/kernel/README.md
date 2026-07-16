# linux-6.12.1-msm8916 docker build environment

Docker-based build environment for the postmarketOS kernel flavor
**postmarketos-qcom-msm8916** (`linux-6.12.1-msm8916`), based on the APKBUILD in
`pmaports/device/testing/linux-postmarketos-qcom-msm8916`.

Target: **aarch64** only.

## Files

| File           | Purpose                                                       |
| -------------- | ------------------------------------------------------------- |
| `Dockerfile`   | `alpine:latest` image with the kernel build deps + aarch64 cross GCC |
| `kbuild.sh`    | in-container entrypoint: prepare/build/package (mirrors APKBUILD) |
| `build.sh`     | host wrapper: builds the image and runs the compile           |
| `config-postmarketos-qcom-msm8916.aarch64` | kernel config (read at runtime)               |
| `.dockerignore`| keeps the build context tiny (source is mounted, not copied) |

v26.06:
https://github.com/msm8916-mainline/linux/archive/v6.12.1-msm8916.tar.gz

## Usage

```sh
# build aarch64 kernel + collect artifacts into out/aarch64/
./build.sh

# only compile the kernel (no install step)
./build.sh build

# clean rebuild
./build.sh all --clean
```

Artifacts land in `out/aarch64/`:

```
out/aarch64/
├── boot/
│   ├── linux.efi        # ZBOOT EFI image (CONFIG_EFI_ZBOOT)
│   ├── vmlinuz          # GZIP'd image for boot.img compatibility
│   └── dtbs/            # device trees
├── lib/modules/6.12.1-msm8916/   # stripped kernel modules
└── usr/share/kernel/postmarketos-qcom-msm8916/kernel.release
```

## How it works

The docker image only carries the toolchain and build dependencies. The pmOS
config (`config-postmarketos-qcom-msm8916.aarch64`) and the output dir are
bind-mounted into the container at runtime, so the image stays small.

The kernel source tree is exposed to the container at `/src`, but how it gets
there depends on the host OS (`uname -s`):

- **Linux** -- bind-mount the local `linux-6.12.1-msm8916/` dir directly. Linux
  host filesystems are case-sensitive, so this works as-is.
- **macOS** -- the host is case-insensitive APFS. The msm8916 source contains
  files that differ only in case (e.g. `net/netfilter/xt_TCPMSS.c` vs
  `xt_tcpmss.c`); extracting onto APFS silently drops one of each pair and breaks
  the build (`No rule to make target xt_TCPMSS.o`). So the source is extracted
  into a **case-sensitive docker named volume** (`ksrc-msm8916`) instead.

On either OS, `build.sh` extracts `v6.12.1-msm8916.tar.gz` on first use (into the
local dir on Linux, into the volume on macOS). Re-extract with
`./build.sh --reextract`.

## Toolchain

pmOS cross-compiles with the musl toolchain (`aarch64-alpine-linux-musl-gcc`),
which is not published in the Alpine repos and whose pmOS repo is unreachable
from this host. Because the kernel is freestanding, this image uses Alpine's
bare-metal cross GCC (`gcc-aarch64-none-elf`) instead. `CONFIG_WERROR` is off in
the pmOS config, so extra toolchain diagnostics do not fail the build.
