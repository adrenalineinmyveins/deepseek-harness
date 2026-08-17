#!/usr/bin/env bash
# dsh-run.sh — 触发一次 dsh headless 单次任务（systemd transient unit）
#
# 用法：dsh-run "<任务描述>"
#   dsh-run "查看 /mnt/sdcard/dsh 下日志并总结"
#
# 任务作为 node 的位置参数传入 headless profile（见
# packages/bundle/headless/cordis.patch.yml：headlessStartup 解析 cmdlineArgs 的 task 位置参数）。
# 每次任务独立 transient unit，跑完即退出，互不干扰。

set -euo pipefail

TASK="${1:?用法: dsh-run \"<任务描述>\"}"
DSH_BIN="${DSH_BIN:-/opt/dsh/apps/cli/lib/bin.js}"
ENV_CONF="/etc/environment.d/10-dsh-env.conf"

[ -x "$DSH_BIN" ] || DSH_BIN="$(command -v node 2>/dev/null && echo /opt/dsh/apps/cli/lib/bin.js)"
[ -f "$DSH_BIN" ] || { echo "dsh 入口不存在: $DSH_BIN"; exit 1; }

# transient unit 名仅允许 ASCII，用时间戳保证唯一
UNIT="dsh-task-$(date +%s)"

echo "触发 dsh 任务 → unit=$UNIT"
echo "任务: $TASK"

# --wait：等任务结束并转发退出码
# EnvironmentFile：复用 /etc/environment.d 的 DSH_HOME / 权限 / API KEY
# Wants/After network-online：确保 4G 已就绪
exec systemd-run --unit="$UNIT" --uid=dsh \
  --property=WorkingDirectory=/home/dsh \
  --property=Wants=network-online.target \
  --property=After=network-online.target \
  --property=EnvironmentFile="$ENV_CONF" \
  --wait \
  node "$DSH_BIN" --profile headless "$TASK"
