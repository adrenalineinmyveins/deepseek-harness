#!/usr/bin/env bash
# 04-hardening.sh — 系统加固：硬件看门狗、日志轮转、防火墙
#
# 用法（设备上 root 执行）：
#   bash 04-hardening.sh

set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "请以 root 执行"; exit 1; }

echo "==> 启用内核硬件看门狗（系统挂死自动复位）"
# RK3568 有硬件 WDT，内核若编进则为 /dev/watchdog0
if [ -c /dev/watchdog0 ] || [ -c /dev/watchdog ]; then
  apt-get install -y watchdog systemd
  # 看门狗守护：默认 10s 不喂狗即复位（便携盒够用，可调）
  sed -i 's/^#\?watchdog-device.*/watchdog-device = \/dev\/watchdog0/' /etc/watchdog.conf 2>/dev/null || \
    { echo "watchdog-device = /dev/watchdog0" >> /etc/watchdog.conf; }
  sed -i 's/^#\?interval.*/interval = 10/' /etc/watchdog.conf 2>/dev/null || true
  systemctl enable --now watchdog 2>/dev/null || true
  # systemd 自身的 runtime 看门狗（单位秒），服务级死锁触发重启
  mkdir -p /etc/systemd/system.conf.d
  cat > /etc/systemd/system.conf.d/10-watchdog.conf <<'EOF'
[Manager]
RuntimeWatchdogSec=15
RebootWatchdogSec=2min
ShutdownWatchdogSec=2min
EOF
  systemctl daemon-reexec
  echo "硬件看门狗已启用（/dev/watchdog0，10s 喂狗周期）"
else
  echo "警告：未发现 /dev/watchdog，内核可能未编入 wdt 驱动；跳过"
fi

echo "==> journald 日志大小限制（便携盒存储有限）"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/10-size.conf <<'EOF'
[Journal]
SystemMaxUse=80M
SystemMaxFileSize=10M
RuntimeMaxUse=40M
MaxRetentionSec=7day
EOF
systemctl restart systemd-journald

echo "==> 会话日志轮转（DSH_HOME 下的 JSONL 会增长，定期压缩清理）"
cat > /etc/logrotate.d/dsh-sessions <<'EOF'
/mnt/sdcard/dsh/sessions/*.jsonl {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    maxsize 50M
}
EOF

echo "==> 防火墙（ufw）：仅放行 SSH 与 ICMP，默认拒绝入站"
apt-get install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 22/tcp
# ICMP 放行（便携盒用于 ping 探测）
sed -i 's/^#\?icmp.*-no-track//g' /etc/ufw/before.rules 2>/dev/null || true
echo "y" | ufw enable
echo "ufw 状态:"; ufw status verbose

echo "==> 关闭不必要的 getty（无屏设备省资源）"
# 保留串口 getty（调试用），关 HDMI/tty1
systemctl disable getty@tty1.service 2>/dev/null || true
systemctl mask getty@tty1.service 2>/dev/null || true

echo "==> SD 卡 noatime 确认"
# 03 脚本已写 noatime；此处校验，缺失则补
if mountpoint -q /mnt/sdcard; then
  mount | grep '/mnt/sdcard' | grep -q noatime || {
    echo "提示：/mnt/sdcard 未带 noatime，建议在 /etc/fstab 该行加 noatime 后 remount"
    mount -o remount,noatime /mnt/sdcard 2>/dev/null || true
  }
fi

echo "==> 完成。便携盒加固就绪。"
echo "  - 硬件看门狗守护系统级挂死"
echo "  - journald 上限 80M、会话日志 7 天轮转"
echo "  - 防火墙仅 SSH + ICMP"
