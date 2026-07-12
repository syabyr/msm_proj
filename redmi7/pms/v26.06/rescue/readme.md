  # 默认生成（使用 chroot 下的 kernel + initramfs + DTB）
  ./build-rescue.sh

  # 自定义组件
  ./build-rescue.sh -k /path/to/vmlinuz -r /path/to/initramfs -d /path/to/device.dtb

  # 加额外内核参数
  ./build-rescue.sh -a "console=ttyMSM0,115200n8"

  # 指定输出文件名
  ./build-rescue.sh -o my-rescue.img

