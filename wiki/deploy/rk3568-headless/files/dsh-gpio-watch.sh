#!/usr/bin/env bash
# dsh-gpio-watch.sh — 监听 GPIO 按钮，按下触发 dsh-task-default.service
#
# 用法（root）：通过 dsh-gpio-trigger.service 启动
#   编辑本脚本顶部的 GPIO_CHIP / GPIO_OFFSET 为你板子的按钮引脚
#   sudo systemctl enable --now dsh-gpio-trigger
#
# 依赖 libgpiod：apt-get install -y gpiod
# 监听用 gpiomon（libgpiod 1.x 与 2.x 均提供，参数语义略有差异，
# 若 --falling 不被识别，改用 --mode falling）。

set -euo pipefail

# ===== 按板子原理图改这两项 =====
GPIO_CHIP="${GPIO_CHIP:-gpiochip0}"
GPIO_OFFSET="${GPIO_OFFSET:-48}"   # 占位：RK3568 的某个 GPIO 线号

# 去抖
DEBOUNCE_S=0.2

command -v gpiomon >/dev/null 2>&1 || { echo "缺 gpiod（gpiomon），先 apt-get install -y gpiod"; exit 1; }

echo "dsh GPIO trigger：监听 $GPIO_CHIP offset=$GPIO_OFFSET"
echo "按下按钮触发 dsh-task-default.service（任务见 /etc/dsh/default-task）"

while true; do
  # gpiomon 阻塞等待一次下降沿事件（按钮按下接地）
  # libgpiod 2.x 用 --falling；1.x 用 --mode falling
  if gpiomon --falling --num-events=1 "/dev/$GPIO_CHIP" "$GPIO_OFFSET" >/dev/null 2>&1 \
     || gpiomon --mode falling --num-events=1 "/dev/$GPIO_CHIP" "$GPIO_OFFSET" >/dev/null 2>&1; then
    sleep "$DEBOUNCE_S"   # 去抖
    echo "$(date '+%F %T') 按钮按下 → 触发任务"
    systemctl start dsh-task-default.service || echo "触发失败：$(date '+%F %T')"
  else
    # 退避避免驱动异常时死循环吃 CPU
    sleep 0.2
  fi
done
