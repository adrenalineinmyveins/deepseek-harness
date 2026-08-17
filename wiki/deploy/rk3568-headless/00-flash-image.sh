#!/usr/bin/env bash
# 00-flash-image.sh — 宿主机侧：下载并烧录 Armbian/Debian 镜像到 eMMC/SD
#
# 用法：
#   ./00-flash-image.sh <目标块设备> [镜像URL] [SHA256]
# 示例：
#   ./00-flash-image.sh /dev/sdX
#   ./00-flash-image.sh /dev/mmcblk0 https://.../Armbian.img.xz <sha256>
#
# 在宿主机（x86 Linux 或 macOS）执行。目标设备先不接电。

set -euo pipefail

DEVICE="${1:?用法: $0 <目标块设备如/dev/sdX> [镜像URL] [SHA256]}"
IMAGE_URL="${2:-https://dl.armbian.com/orangepi3b/Bookworm_current_kernel6.1.img.xz}"
EXPECTED_SHA256="${3:-}"

# 依赖检查
for cmd in curl xz dd; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "缺少 $cmd，请先安装"; exit 1; }
done

# 危险操作：确认设备
if [ ! -b "$DEVICE" ]; then
  echo "错误：$DEVICE 不是块设备" >&2
  exit 1
fi
echo "即将把镜像烧录到 $DEVICE，该设备所有数据将被覆盖！"
read -rp "确认继续？输入大写 YES: " CONFIRM
[ "$CONFIRM" = "YES" ] || { echo "已取消"; exit 1; }

# 必须卸载目标已挂载分区，否则 dd 失败
lsblk -o NAME,MOUNTPOINT -n "$DEVICE" 2>/dev/null | awk '$2!=""{print $1}' | while read -r part; do
  echo "卸载 $part"
  sudo umount "/dev/$part" 2>/dev/null || true
done

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
IMAGE_XZ="$WORKDIR/image.img.xz"
IMAGE="$WORKDIR/image.img"

echo "==> 下载镜像: $IMAGE_URL"
curl -fL --retry 3 -o "$IMAGE_XZ" "$IMAGE_URL"

# 校验
if [ -n "$EXPECTED_SHA256" ]; then
  echo "==> 校验 SHA256"
  ACTUAL="$(sha256sum "$IMAGE_XZ" | awk '{print $1}')"
  [ "$ACTUAL" = "$EXPECTED_SHA256" ] || { echo "SHA256 不匹配: 期望 $EXPECTED_SHA256 实际 $ACTUAL"; exit 1; }
  echo "校验通过"
fi

echo "==> 解压"
xz -dc "$IMAGE_XZ" > "$IMAGE"

echo "==> 烧录到 $DEVICE（sudo dd，进度可见）"
sudo dd if="$IMAGE" of="$DEVICE" bs=4M status=progress conv=fsync
sync

# 烧录后向 rootfs 注入首启标记，触发 01 脚本自检环境
echo "==> 挂载 rootfs 注入首启钩子"
BOOT_MOUNT="$WORKDIR/rootfs"
mkdir -p "$BOOT_MOUNT"

# 找 rootfs 分区：多数 Armbian 是第 1 个分区为 rootfs（或第 2 个，依镜像）。
# 依次尝试挂载第 1/2 个分区，找到含 /etc/os-release 的即 rootfs。
for part in "${DEVICE}1" "${DEVICE}2" "${DEVICE}p1" "${DEVICE}p2"; do
  [ -b "$part" ] || continue
  sudo mount "$part" "$BOOT_MOUNT" 2>/dev/null && [ -f "$BOOT_MOUNT/etc/os-release" ] && break
  sudo umount "$BOOT_MOUNT" 2>/dev/null || true
done

if [ ! -f "$BOOT_MOUNT/etc/os-release" ]; then
  echo "警告：未能自动定位 rootfs 分区，跳过首启钩子注入" >&2
else
  # 写入一个标记文件，01 脚本检测到后自动执行初始化（可手动删除跳过）
  sudo mkdir -p "$BOOT_MOUNT/root"
  echo "dsh-box first-boot pending" | sudo tee "$BOOT_MOUNT/root/.dsh-first-boot" >/dev/null
  echo "已写入首启标记 /root/.dsh-first-boot"
fi

sudo umount "$BOOT_MOUNT" 2>/dev/null || true
sync
echo "==> 完成。拔下介质插入 RK3568 设备启动。"
echo "    首启后用串口或 HDMI 登录，执行 01-first-boot-setup.sh"
