cd /home/mybays/develop/build/cmcc-w1a/linux-mainline
make O=../ml-out ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j$(nproc) zImage dtbs

# 无 ramdisk 启动镜像（p33/p21，当前方式）
cd /home/mybays/develop/build/cmcc-w1a
W1A_OUT=<name>.img \
W1A_CMD='w1a.no_dsi_pa root=/dev/mmcblk0p33 rootwait rw log_buf_len=8M ' \
  bash tools/build-boot-img.sh

# 带 Alpine rootfs 的 p21 镜像（kernel.img + rootfs.img）：
#   cd /home/mybays/develop/build/msm_proj/cmcc-w1a/alpine && ./build.sh
# 恢复镜像：cd ..../cmcc-w1a/recovery && ./build-recovery.sh
