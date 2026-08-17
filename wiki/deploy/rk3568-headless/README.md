# RK3568 无屏 Headless 盒子：镜像烧录与初始化脚本

面向上一节 [RK3568 无屏 headless 盒子硬件清单](../11-rk3568-headless-box.md) 的一套可执行部署脚本。覆盖从镜像烧录到 dsh 任务服务的全流程。

## 重要前提：headless 是单次任务模式

dsh 的 `headless` profile 是 **one-shot task mode**——一次任务跑完即退出，**不是常驻进程**（见 [packages/bundle/headless/cordis.patch.yml](../../../../packages/bundle/headless/cordis.patch.yml#L1-L5)）。因此便携盒的正确形态是 **事件触发的单次任务**：

- GPIO 按钮 / cron / 远程 SSH 触发一次 `dsh --profile headless "<task>"`
- dsh 跑完打印结果后退出
- 每次任务由 `dsh-run` 创建独立 systemd transient 单元隔离执行
- GPIO 按钮可绑定到固定默认任务（`dsh-task-default.service`）

若需要本地 Web 交互界面长驻，应改用 `web` profile（带 Host），不在本套脚本范围。

## 文件清单

| 文件 | 运行位置 | 职责 |
|---|---|---|
| [00-flash-image.sh](00-flash-image.sh) | 宿主机（x86 Linux/Mac） | 下载并烧录 Armbian 镜像到 eMMC/SD |
| [01-first-boot-setup.sh](01-first-boot-setup.sh) | 设备首启后 | 系统基础配置、用户、SSH、串口调试 |
| [02-configure-4g-modem.sh](02-configure-4g-modem.sh) | 设备 | EC20/EG912N 4G 模块拨号联网 |
| [03-install-dsh.sh](03-install-dsh.sh) | 设备 | 安装 Node 24 + dsh，注册 dsh-run 与服务 |
| [04-hardening.sh](04-hardening.sh) | 设备 | 硬件看门狗、日志轮转、防火墙 |
| [files/dsh-run.sh](files/dsh-run.sh) | 设备 | 触发器：创建 transient 单元跑任意任务 |
| [files/dsh-task-default.service](files/dsh-task-default.service) | 设备 | 固定默认任务单元（GPIO 触发） |
| [files/10-dsh-env.conf](files/10-dsh-env.conf) | 设备 | /etc/environment.d 环境变量 |
| [files/dsh-gpio-trigger.service](files/dsh-gpio-trigger.service) | 设备 | GPIO 按钮监听服务（可选） |
| [files/dsh-gpio-watch.sh](files/dsh-gpio-watch.sh) | 设备 | GPIO 监听脚本（gpiomon 下降沿） |

## 执行流程

```
[宿主机] 00-flash-image.sh /dev/sdX            # 烧录镜像
   ↓ 插卡/eMMC 启动设备，串口或 HDMI 临时登录
[设备]   01-first-boot-setup.sh                  # 系统初始化
   ↓
[设备]   02-configure-4g-modem.sh                 # 4G 联网
   ↓
[设备]   03-install-dsh.sh                       # 装 dsh + 服务
   ↓
[设备]   04-hardening.sh                         # 加固
   ↓
[设备]   dsh-run "我的任务"                        # 触发一次任务
[设备]   systemctl start dsh-task-default.service  # 或跑默认任务（GPIO 按钮也触发它）
```

## 环境变量约定

便携盒通过 `/etc/environment.d/10-dsh-env.conf`（见 [files/10-dsh-env.conf](files/10-dsh-env.conf)）集中注入。关键变量来源对照：

| 变量 | 来源 | 作用 |
|---|---|---|
| `DSH_HOME` | [profile-boot.ts#L44](../../../../apps/cli/src/profile-boot.ts#L44) | home 层 patch 位置；便携盒指向外置 SD 卡降低 eMMC 磨损 |
| `DSH_PERMISSION_MODE` | [base/cordis.patch.yml#L191](../../../../packages/bundle/base/cordis.patch.yml#L191) | 沙箱权限档：`read-only` / `workspace-write` / `danger-full-access` |
| `DSH_TELEMETRY_DISABLED` | [profile-boot.ts#L56](../../../../apps/cli/src/profile-boot.ts#L56) | 关遥测省蜂窝流量 |
| `DEEPSEEK_API_KEY` | 真实运行必需 | DeepSeek API 凭据 |
| `DEEPSEEK_BASE_URL` | 可选 | API 代理地址 |

## 使用注意

- 脚本以 `set -euo pipefail` 严格模式执行，任何失败即停
- `DEEPSEEK_API_KEY` 不要写入仓库或 dotfile，仅放 `/etc/environment.d/`（root 只读）
- `danger-full-access` 档仅在设备物理隔离可信场景使用
- 镜像 URL 与 SHA256 需按你购买的核心板厂商替换（脚本给出的是占位）
