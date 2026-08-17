#!/usr/bin/env bash
# 03-install-dsh.sh — 安装 Node 24 + dsh，注册任务服务
#
# 用法（设备上 root 执行）：
#   bash 03-install-dsh.sh [DSH_REPO_PATH] [SD_DEVICE]
# 示例：
#   bash 03-install-dsh.sh /opt/dsh-src /dev/mmcblk1p1
#   # 或从 git 克隆：
#   bash 03-install-dsh.sh git /dev/mmcblk1p1
#
# DSH_REPO_PATH:
#   - "git"：从远端克隆（需自行指定仓库 URL，见下方 DSH_REPO_URL）
#   - 本地路径：复用已存在的源码树（推荐，离线构建）
#   - 省略：默认 /opt/dsh-src

set -euo pipefail

DSH_REPO_PATH="${1:-/opt/dsh-src}"
SD_DEVICE="${2:-}"               # 会话日志所在 SD 卡分区，如 /dev/mmcblk1p1
DSH_REPO_URL="${DSH_REPO_URL:-}" # 若路径为 git，需设此变量
DSH_INSTALL_DIR="/opt/dsh"
ENV_CONF_DIR="/etc/environment.d"
ENV_CONF="$ENV_CONF_DIR/10-dsh-env.conf"

[ "$(id -u)" -eq 0 ] || { echo "请以 root 执行"; exit 1; }

echo "==> 安装 Node 24"
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | cut -dv -f1 | cut -d. -f1)" -lt 22 ]; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
  apt-get install -y nodejs
fi
echo "Node: $(node -v)"

echo "==> 安装 pnpm 11.7"
npm install -g pnpm@11.7.0
echo "pnpm: $(pnpm -v)"

echo "==> 构建 dsh（构建期依赖：python3 make g++，native addon 需要）"
apt-get install -y python3 make g++ build-essential

if [ "$DSH_REPO_PATH" = "git" ]; then
  [ -n "$DSH_REPO_URL" ] || { echo "DSH_REPO_URL 未设置"; exit 1; }
  rm -rf "$DSH_REPO_PATH"
  git clone --depth 1 "$DSH_REPO_URL" "$DSH_REPO_PATH"
fi

[ -d "$DSH_REPO_PATH" ] || { echo "源码树不存在: $DSH_REPO_PATH"; exit 1; }
cd "$DSH_REPO_PATH"
echo "==> pnpm install（解析工作区依赖）"
pnpm install
echo "==> pnpm run build（产出 lib/ 与 web dist）"
pnpm run build

echo "==> 部署构建产物到 $DSH_INSTALL_DIR"
rm -rf "$DSH_INSTALL_DIR"
mkdir -p "$DSH_INSTALL_DIR"
# 复制运行所需：lib/ types/ package.json 与 apps/ 入口
cp -a packages apps lib types package.json pnpm-lock.yaml "$DSH_INSTALL_DIR/" 2>/dev/null || true
# node_modules 按需保留（生产模式可用 pnpm prune --prod）
cp -a node_modules "$DSH_INSTALL_DIR/" 2>/dev/null || true
chown -R dsh:dsh "$DSH_INSTALL_DIR"

echo "==> 配置外置 SD 卡作为 DSH_HOME（降低 eMMC 磨损）"
mkdir -p /mnt/sdcard
if [ -n "$SD_DEVICE" ] && [ -b "$SD_DEVICE" ]; then
  echo "格式化 $SD_DEVICE 为 ext4（会清空数据）"
  read -rp "确认格式化 $SD_DEVICE？[y/N] " c; [ "$c" = "y" ] || { echo "跳过，DSH_HOME 用 eMMC"; SD_DEVICE=""; }
  if [ -n "$SD_DEVICE" ]; then
    mkfs.ext4 -F -L dsh-data "$SD_DEVICE"
    # 写入 fstab：noatime 减少写入磨损
    grep -q "$SD_DEVICE" /etc/fstab || \
      echo "$SD_DEVICE /mnt/sdcard ext4 defaults,noatime,x-systemd.requires=modprobe@qmi_wwan 0 2" >> /etc/fstab
    systemctl daemon-reload
    mount /mnt/sdcard
  fi
fi

DSH_HOME_DIR="${DSH_HOME_DIR:-/mnt/sdcard/dsh}"
[ "$DSH_HOME_DIR" = "/mnt/sdcard/dsh" ] && [ ! -d /mnt/sdcard/dsh ] && mkdir -p /mnt/sdcard/dsh
mkdir -p "$DSH_HOME_DIR"
chown -R dsh:dsh /mnt/sdcard 2>/dev/null || true

echo "==> 注入环境变量到 $ENV_CONF"
mkdir -p "$ENV_CONF_DIR"
install -m 600 -o root -g root files/10-dsh-env.conf "$ENV_CONF"
# 用实际值替换占位
sed -i "s#^DSH_HOME=.*#DSH_HOME=$DSH_HOME_DIR#" "$ENV_CONF"

echo "==> 填写 DEEPSEEK_API_KEY（真实运行必需，见 base/cordis.patch.yml）"
read -rsp "粘贴 DEEPSEEK_API_KEY: " APIKEY
if [ -n "$APIKEY" ]; then
  sed -i "s#^DEEPSEEK_API_KEY=.*#DEEPSEEK_API_KEY=$APIKEY#" "$ENV_CONF"
fi
chmod 600 "$ENV_CONF"

echo "==> 安装触发器与服务文件"
install -m 755 files/dsh-run.sh /usr/local/bin/dsh-run
install -m 644 files/dsh-task-default.service /etc/systemd/system/
install -m 644 files/dsh-gpio-trigger.service /etc/systemd/system/ 2>/dev/null || true
install -m 755 files/dsh-gpio-watch.sh /usr/local/bin/ 2>/dev/null || true

# 默认任务占位（GPIO 按钮跑这个）
mkdir -p /etc/dsh
echo '总结当前 /mnt/sdcard/dsh 目录下的会话日志' > /etc/dsh/default-task

# 任务日志
mkdir -p /var/log
touch /var/log/dsh-task.log
chown dsh:dsh /var/log/dsh-task.log 2>/dev/null || true

systemctl daemon-reload

echo "==> 完成。验证："
echo "  1. 触发一次任务: sudo -u dsh dsh-run \"查看当前时间并说明\""
echo "  2. 或跑默认任务: sudo systemctl start dsh-task-default.service"
echo "  3. 查日志:       journalctl -u dsh-task-default -f"
echo "  4. 接 GPIO 按钮后: sudo systemctl enable --now dsh-gpio-trigger"
echo "  5. 加固:          bash 04-hardening.sh"
