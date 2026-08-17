#!/usr/bin/env bash
# 02-configure-4g-modem.sh — 4G 模块（移远 EC20 / EG912N）拨号联网
#
# 用法（设备上 root 执行）：
#   bash 02-configure-4g-modem.sh [APN]
# 默认 APN: cmnet（移动）；电信用 ctnet，联通用 3gnet
#
# 依赖 qmi_wwan 内核驱动 + libqmi-utils + ModemManager/NetworkManager。
# EC20/EG912N 在 Linux 下为 cdc-wdm / qmi 设备，免驱。

set -euo pipefail

APN="${1:-cmnet}"

[ "$(id -u)" -eq 0 ] || { echo "请以 root 执行"; exit 1; }

echo "==> 安装依赖"
apt-get update -y
apt-get install -y libqmi-utils modemmanager network-manager udhcpc

echo "==> 启用 ModemManager 与 NetworkManager"
systemctl enable --now ModemManager
systemctl enable --now NetworkManager

echo "==> 检测 4G 模块（USB 设备）"
# EC20 USB VID:PID 多为 2c7c:0125 / 2c7c:0121；EG912N 类似
if ! lsusb | grep -i -E '2c7c|quectel'; then
  echo "警告：未检测到 Quectel 模块。检查："
  echo "  - M.2 B-key 是否插紧、天线是否接好"
  echo "  - 内核是否加载 option/qmi_wwan 驱动：lsmod | grep -E 'option|qmi'"
  echo "  - dmesg | grep -i quectel 查看枚举"
  read -rp "强制继续？[y/N] " c; [ "$c" = "y" ] || exit 1
fi

# 加载所需内核模块
modprobe qmi_wwan 2>/dev/null || true
modprobe option 2>/dev/null || true

echo "==> 等待 cdc-wdm 设备出现（最多 30s）"
for i in $(seq 1 30); do
  if [ -c /dev/cdc-wdm0 ]; then break; fi
  sleep 1
done
[ -c /dev/cdc0 ] || [ -c /dev/cdc-wdm0 ] || { echo "未出现 cdc-wdm 设备，退出"; exit 1; }

echo "==> 重置调制解调器并打开 QMI 通道"
# 关闭电源管理（低功耗模式会断网）
qmicli -d /dev/cdc-wdm0 --dms-set-operating-mode=online 2>/dev/null || true

echo "==> 创建 NetworkManager GSM 连接（APN=$APN）"
nmcli con delete dsh-4g 2>/dev/null || true
nmcli con add type gsm ifname cdc-wdm0 con-name dsh-4g apn "$APN" connection.autoconnect yes
nmcli con modify dsh-4g gsm.username "" gsm.password "" 2>/dev/null || true

echo "==> 拨号"
nmcli con up dsh-4g || {
  echo "NetworkManager 拨号失败，回退到 qmi-network 原始拨号"
  qmi-network /dev/cdc-wdm0 start || true
  # 用 udhcpc 取地址
  udhcpc -i wwan0 -q -t 30 || true
}

echo "==> 等待 wwan0 取得 IP（最多 30s）"
for i in $(seq 1 30); do
  if ip -4 addr show wwan0 2>/dev/null | grep -q inet; then break; fi
  sleep 1
done

echo "==> 联网自检：尝试访问 DeepSeek API 域名"
if curl -sS --connect-timeout 15 -o /dev/null -w "HTTP %{http_code} 耗时%{time_total}s\n" https://api.deepseek.com 2>/dev/null; then
  echo "4G 联网就绪，DeepSeek API 可达"
else
  echo "警告：DeepSeek API 不可达。检查：流量卡是否激活、信号、APN、"
  echo "      若用代理设置 DEEPSEEK_BASE_URL 见 files/10-dsh-env.conf"
fi

echo "==> 完成。下一步执行 03-install-dsh.sh"
