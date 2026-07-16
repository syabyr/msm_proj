# linux-6.12.1-msm8916 docker build environment (armv7)

Docker-based build environment for the postmarketOS kernel flavor
**postmarketos-qcom-msm8916** (`linux-6.12.1-msm8916`), based on the APKBUILD in
`pmaports/device/testing/linux-postmarketos-qcom-msm8916`.

Target: **armv7** only (32-bit ARM, e.g. MSM8909-class devices).

## Files

| File           | Purpose                                                       |
| -------------- | ------------------------------------------------------------- |
| `Dockerfile`   | `alpine:latest` image with the kernel build deps + armv7 bare-metal cross GCC |
| `kbuild.sh`    | in-container entrypoint: prepare/build/package (mirrors APKBUILD) |
| `build.sh`     | host wrapper: builds the image and runs the compile           |
| `config-postmarketos-qcom-msm8916.armv7` | kernel config (read at runtime)               |
| `.dockerignore`| keeps the build context tiny (source is mounted, not copied) |

v26.06:
https://github.com/msm8916-mainline/linux/archive/v6.12.1-msm8916.tar.gz

## Usage

```sh
# build armv7 kernel + collect artifacts into out/armv7/
./build.sh

# only compile the kernel (no install step)
./build.sh build

# resolve .config only (olddefconfig)
./build.sh config

# clean rebuild
./build.sh all --clean
```

Artifacts land in `out/armv7/`:

```
out/armv7/
├── boot/
│   ├── vmlinuz-6.12.1-msm8916   # compressed kernel (zImage), via `make zinstall`
│   ├── System.map-6.12.1-msm8916
│   └── dtbs/                    # device trees
├── lib/modules/6.12.1-msm8916/  # stripped kernel modules
└── usr/share/kernel/postmarketos-qcom-msm8916/kernel.release
```

## How it works

The docker image only carries the toolchain and build dependencies. The kernel
source tree (`linux-6.12.1-msm8916/`), the pmOS config
(`config-postmarketos-qcom-msm8916.armv7`) and the output dir are bind-mounted
into the container at runtime, so the image stays small and the host working
tree is shared.

## Toolchain

pmOS cross-compiles with the musl toolchain (`armv7-alpine-linux-musleabihf-gcc`),
which is not published in the Alpine repos and whose pmOS repo is unreachable
from this host. Because the kernel is freestanding, this image uses Alpine's
bare-metal cross GCC (`gcc-arm-none-eabi`) instead. Its EABI target matches
`CONFIG_AEABI=y` in the pmOS config. `CONFIG_WERROR` is off, so extra toolchain
diagnostics do not fail the build.

The docker image is tagged `pmos-kbuild-msm8909:latest` (set in `build.sh`).
