#!/usr/bin/env bash
# 01-first-boot-setup.sh — 设备首次启动后系统初始化
#
# 用法（设备上以 root 登录后执行）：
#   bash 01-first-boot-setup.sh [主机名] [用户名]
# 默认：主机名 dsh-box，用户名 dsh
#
# 本脚本检测 /root/.dsh-first-boot 标记；存在则执行，否则提示已初始化。

set -euo pipefail

HOSTNAME="${1:-dsh-box}"
USERNAME="${2:-dsh}"
FIRST_BOOT_MARKER="/root/.dsh-first-boot"

[ "$(id -u)" -eq 0 ] || { echo "请以 root 执行"; exit 1; }

if [ ! -f "$FIRST_BOOT_MARKER" ]; then
  echo "提示：未检测到首启标记 $FIRST_BOOT_MARKER"
  echo "若已初始化过可忽略；强制执行请先 touch $FIRST_BOOT_MARKER"
  read -rp "继续？[y/N] " c; [ "$c" = "y" ] || exit 0
fi

echo "==> 更新软件源与系统"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confold" full-upgrade
apt-get install -y \
  ca-certificates curl git gnupg jq vim htop \
  udev systemd-sysv network-manager \
  serial-console 2>/dev/null || apt-get install -y console-setup

echo "==> 设置主机名与时区"
hostnamectl set-hostname "$HOSTNAME"
timedatectl set-timezone Asia/Shanghai
# 启用 NTP 同步（便携设备断网后 RTC 仍可维持时间）
timedatectl set-ntp true 2>/dev/null || true

echo "==> 创建非 root 用户 $USERNAME"
if ! id -u "$USERNAME" >/dev/null 2>&1; then
  useradd -m -G sudo,dialout,plugdev,netdev -s /bin/bash "$USERNAME"
  echo "请为 $USERNAME 设置密码（用于 sudo 与串口登录）："
  passwd "$USERNAME"
else
  echo "用户 $USERNAME 已存在，跳过"
fi

echo "==> 配置 SSH 公钥登录（把公钥贴下面，空行跳过）"
read -r -p "粘贴 ssh-ed25519/rsa 公钥: " SSHKEY
if [ -n "$SSHKEY" ]; then
  SSHDIR="/home/$USERNAME/.ssh"
  mkdir -p "$SSHDIR"
  echo "$SSHKEY" > "$SSHDIR/authorized_keys"
  chmod 700 "$SSHDIR"; chmod 600 "$SSHDIR/authorized_keys"
  chown -R "$USERNAME:$USERNAME" "$SSHDIR"
  echo "已写入 authorized_keys"
fi

echo "==> 加固 SSH：禁用 root 密码登录与空密码"
SSHD_CFG=/etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CFG"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CFG"
sed -i 's/^#\?PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$SSHD_CFG"
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

echo "==> 配置串口控制台（UART 调试，RK3568 通常为 ttyFIQ0 或 ttyS2）"
# 多数 RK3568 镜像已默认使能；此处仅确认 agetty 存在
for tty in ttyFIQ0 ttyS2 ttyS0; do
  if systemctl list-unit-files | grep -q "serial-getty@${tty}"; then
    systemctl enable "serial-getty@${tty}.service" 2>/dev/null || true
  fi
done

echo "==> 配置外置 SD 卡挂载点（会话日志存储，降低 eMMC 磨损）"
# 实际挂载在 02/03 之后再确认 SD 卡设备名；此处先建目录与 fstab 模板
mkdir -p /mnt/sdcard
# 等设备插卡后由 03 脚本写入实际 fstab 条目

echo "==> 清理首启标记"
rm -f "$FIRST_BOOT_MARKER"

echo "==> 完成。下一步："
echo "    1. 如需远程登录，记录设备 IP（ip a）或配置 USB 网卡"
echo "    2. 执行 02-configure-4g-modem.sh 联网"
echo "    3. 执行 03-install-dsh.sh 安装 dsh"
