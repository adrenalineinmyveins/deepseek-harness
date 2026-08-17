# Linux 容器化部署指南

面向生产/预生产环境的 dsh Web Host 容器化部署。所有配置项均来自仓库源码事实，关键事实出处以行内链接标注。

## 1. 设计约束（容器化前必读）

| 约束 | 事实 | 出处 |
|---|---|---|
| Node 引擎 | `^22.19.0 \|\| >=24.0.0` | [package.json](../package.json#L8-L10) |
| pnpm | `11.7.0`（仅构建期） | [package.json](../package.json#L7) |
| 构建产物 | `build:lib`（host/client 双 tsconfig + tsdown）+ `build:web`（vite） | [package.json](../package.json#L20-L24) |
| CLI 入口 | 发布为 `dsh` → `apps/cli/lib/bin.js`；源码模式 `node --import tsx/esm apps/cli/src/bin.ts` | [apps/cli/package.json](../apps/cli/package.json#L14-L16)、[package.json#L136](../package.json#L136) |
| Harness Home | 默认 `~/.dsh`，由 `DSH_HOME` 覆盖；承载 profiles/sessions/settings/credentials | [home-paths/src/index.ts](../packages/util/home-paths/src/index.ts#L12-L91) |
| 环境加载顺序 | 进程环境 > 调用目录 `.env` > `$DSH_HOME/.env`；`DEEPSEEK_*` 等只允许来自进程环境 | [app-boot/src/index.ts](../packages/boot/app-boot/src/index.ts#L167-L206) |
| Web 默认监听 | host `127.0.0.1`、port `3080` | [web-app/cordis.patch.yml](../packages/bundle/web-app/cordis.patch.yml#L115-L120) |
| `--host 0.0.0.0` | **命令行层被故意拒绝**（RCE 风险） | [web-app/src/startup.ts#L69-L71](../packages/bundle/web-app/src/startup.ts#L69-L71) |
| WebServer schema | 允许 `0.0.0.0`（配置层不校验命令行语义） | [host/webserver/src/index.ts#L45-L50](../packages/host/webserver/src/index.ts#L45-L50) |
| 信号 | SIGTERM→exit 0；SIGINT→exit 130；均触发 root fiber 优雅卸载 | [profile-boot.ts#L221-L222](../apps/cli/src/profile-boot.ts#L221-L222) |
| 持久存储 | 会话日志（JSONL + zstd）+ SQLite（`SCHEMA_VERSION=15`）；须可写 | [base/cordis.patch.yml#L98-L121](../packages/bundle/base/cordis.patch.yml#L98-L121) |

**关键推论**：容器内要让外部访问，不能靠 `dsh web --host 0.0.0.0`。正确做法是用 profile 的 `cordis.patch.yml` 覆盖 `webserver` 行的 `config.host` 为 `0.0.0.0`（schema 允许，patch 层替换整段 config，绕过命令行校验）。容器网络边界已承担隔离责任，0.0.0.0 的 RCE 风险由容器网络策略承接。

## 2. 目录与持久化规划

```
DSH_HOME=/data/dsh            # 卷挂载点（只此一个卷即可）
├── profiles/web/             # web profile（自动初始化）
│   ├── package.json          # dsh.profile.bundles 清单
│   ├── cordis.yml            # 空 root（启动时重写）
│   └── cordis.patch.yml      # ★ 我们注入：webserver host=0.0.0.0
├── cordis.patch.yml          # home 级 patch（所有 profile 共享）
├── sessions/                 # 会话 JSONL 日志（事件溯源事实来源）
├── storages/                 # 存储后端数据
├── settings.yaml             # 用户设置（模型、适配器）
└── .credentials.yaml         # 凭据引用
```

## 3. Dockerfile（多阶段）

```dockerfile
# syntax=docker/dockerfile:1.7

# ── stage 1: builder ─────────────────────────────────────────────
FROM node:24-bookworm-slim AS builder

# native addon（landlock-run）与部分依赖需要的构建工具链
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 make g++ ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

# pnpm 11.7（与 packageManager 锁定一致）
RUN corepack enable && corepack prepare pnpm@11.7.0 --activate

WORKDIR /workspace

# 先装依赖（利用 pnpm 缓存层）
COPY pnpm-lock.yaml pnpm-workspace.yaml package.json tsconfig.base.json ./
COPY vendor/ ./vendor/
COPY packages/ ./packages/
COPY apps/ ./apps/
COPY native/ ./native/
COPY scripts/ ./scripts/
COPY tsconfig.host.json tsconfig.client.json ./
COPY .oxlintrc.json ./
# website 与 examples 按需；若不构建文档可省略

RUN pnpm install --frozen-lockfile

# 构建：lib（host+client）与 web 前端
RUN pnpm run build

# ── stage 2: runner ──────────────────────────────────────────────
FROM node:24-bookworm-slim AS runner

# 运行时：git 供工具调用，ca-certificates 供 HTTPS 出网；curl 供健康检查
# bwrap 可选（workspace-write 沙箱后端需要）；landlock native addon 已构建进 lib
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git bubblewrap \
    && rm -rf /var/lib/apt/lists/*

# 非 root 运行
RUN groupadd -r dsh && useradd -r -g dsh -d /data -s /usr/sbin/nologin dsh
WORKDIR /app

# 拷贝构建产物（apps/cli 的 lib + 依赖树 + vendor + web 前端 dist）
# 从 builder 复制整个 workspace 的 node_modules 与 lib（pnpm 隔离布局需要全树）
COPY --from=builder --chown=dsh:dsh /workspace/ ./

# Harness Home：卷挂载点
ENV DSH_HOME=/data/dsh
RUN mkdir -p /data/dsh && chown -R dsh:dsh /data
VOLUME ["/data"]

USER dsh

# web profile 默认 3080；patch 层会覆盖 host 为 0.0.0.0
EXPOSE 3080

# 信号语义已由 profile-boot 处理（SIGTERM=exit0, SIGINT=exit130）
# tini 确保 PID 1 正确转发信号给 node
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "apps/cli/lib/bin.js", "web"]
```

> **关于 native addon**：`native/landlock-run` 是 root workspace 的一员（[package.json#L14-L15](../package.json#L14-L15)），构建期会编译。运行时 Landlock 是 Linux 沙箱后端之一；容器内通常以容器隔离为边界，可设 `DSH_PERMISSION_MODE=danger-full-access`（仅当容器已隔离）或保留 `workspace-write` 并依赖 bwrap（需挂载权限）。若不需要 Landlock，runner 阶段可不复制 native artifacts 以减小镜像。

## 4. docker-compose.yml

```yaml
services:
  dsh-web:
    build:
      context: ..
      dockerfile: deploy/Dockerfile
    image: dsh-web:local
    container_name: dsh-web
    restart: unless-stopped
    environment:
      # ★ 必需：真实运行依赖外部 LLM
      DEEPSEEK_API_KEY: ${DEEPSEEK_API_KEY:?DEEPSEEK_API_KEY is required}
      # 可选：指向代理或自建 endpoint
      DEEPSEEK_BASE_URL: ${DEEPSEEK_BASE_URL:-}
      # 可选：遥测开关（非空值禁用）
      DSH_TELEMETRY_DISABLED: "1"
      # 可选：权限模式（容器隔离后可放宽；生产建议 workspace-write）
      DSH_PERMISSION_MODE: ${DSH_PERMISSION_MODE:-workspace-write}
    volumes:
      # 持久化 Harness Home（会话日志、设置、凭据、profile patch）
      - dsh-home:/data/dsh
    ports:
      # 容器内绑 0.0.0.0:3080（由 patch 层覆盖），映射到宿主机
      - "3080:3080"
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:3080/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    # 如需容器内 bwrap 沙箱（workspace-write 模式），取消注释：
    # security_opt:
    #   - "apparmor:unconfined"
    # cap_add:
    #   - SYS_ADMIN

volumes:
  dsh-home:
```

## 5. 关键一步：注入 webserver host 覆盖

容器启动前，在挂载的卷里准备好 web profile 的 patch 层。一次性初始化：

```sh
# 在宿主机侧，用临时容器初始化 profile 目录结构
docker run --rm -v dsh-home:/data/dsh --entrypoint /bin/sh dsh-web:local -c '
  mkdir -p /data/dsh/profiles/web
  cat > /data/dsh/profiles/web/cordis.patch.yml <<'"'"'EOF'"'"'
# 容器化覆盖：让 webserver 监听全网卡（schema 允许，绕过命令行安全校验）
# patch 替换整段 config，所以此处需重述 webStartup 不提供的回退值
- id: webserver
  config:
    host: 0.0.0.0
    port: 3080
EOF
'
```

该 patch 在 [profile-boot.ts 的 composeProfile](../apps/cli/src/profile-boot.ts#L142-L171) 中位于"profile 自身层"，会在 `dsh web` 启动时被 [composeEntries](../packages/boot/app-boot/src/profile.ts#L413-L419) 合入，覆盖 [web-app bundle 的 webserver 行默认值](../packages/bundle/web-app/cordis.patch.yml#L115-L120)。web profile 目录本身由 [loadProfile 自动初始化](../packages/boot/app-boot/src/profile.ts#L375-L384)（首次运行时按 `PROFILE_TEMPLATES.web` 建模板）。

## 6. 环境变量速查

| 变量 | 必需 | 默认 | 说明 |
|---|---|---|---|
| `DEEPSEEK_API_KEY` | 是 | — | 真实运行的唯一凭据来源；`DEEPSEEK_*` 类变量只能来自进程环境，不可写入 `.env`（[index.ts#L120-L160](../packages/boot/app-boot/src/index.ts#L120-L160)） |
| `DEEPSEEK_BASE_URL` | 否 | 官方 | 指向代理/自建 endpoint |
| `DSH_HOME` | 否 | `~/.dsh` | 本指南固定为 `/data/dsh` |
| `DSH_PERMISSION_MODE` | 否 | `workspace-write` | `read-only` / `workspace-write` / `danger-full-access`（[base/cordis.patch.yml#L175-L191](../packages/bundle/base/cordis.patch.yml#L175-L191)） |
| `DSH_TELEMETRY_DISABLED` | 否 | 未设 | 非空值（含 `'0'`/`'false'`）即禁用遥测（[profile-boot.ts#L80-L83](../apps/cli/src/profile-boot.ts#L80-L83)） |
| `DSH_TELEMETRY_MODE` | 否 | `DISABLED` | `FULL` / `FEEDBACK_ONLY`（[base/cordis.patch.yml#L151](../packages/bundle/base/cordis.patch.yml#L151)） |
| `DSH_TOOLS_MODE` | 否 | `native` | `native` / `code` / `both`（[web-app/cordis.patch.yml#L36-L41](../packages/bundle/web-app/cordis.patch.yml#L36-L41)） |

凭据与模型设置通过 `$DSH_HOME/settings.yaml` 与 `$DSH_HOME/.credentials.yaml` 管理（[base/cordis.patch.yml#L75-L96](../packages/bundle/base/cordis.patch.yml#L75-L96)），热重载无需重启。

## 7. 构建与运行

```sh
# 假设本文件位于 deploy/ 目录
docker compose build

# 首次：初始化 web profile 的 host 覆盖（见第 5 节）
docker compose run --rm --no-deps --entrypoint /bin/sh dsh-web -c '...'

# 启动
DEEPSEEK_API_KEY=sk-xxx docker compose up -d

# 查看日志（profile-boot 会打印 web-runtime 的 URL 行）
docker compose logs -f dsh-web

# 健康检查
curl -fsS http://localhost:3080/

# 优雅停止（SIGTERM → root fiber dispose → exit 0）
docker compose stop dsh-web
```

## 8. 安全注意

1. **`--host 0.0.0.0` 被命令行层拒绝是设计意图**（[startup.ts#L69-L71](../packages/bundle/web-app/src/startup.ts#L69-L71)）：浏览器 UI 可驱动任意工具，全网卡暴露等同 RCE。容器化之所以可接受，是因为容器网络（bridge/host with firewall）替代了 loopback 隔离职责。**切勿**在非容器化、直接暴露公网的环境中用 patch 覆盖 `0.0.0.0`。
2. **`DSH_PERMISSION_MODE=danger-full-access`** 仅在容器已隔离且可信用户操作时使用；默认 `workspace-write` + `approval: ask` 是安全姿态（[base/cordis.patch.yml#L188-L205](../packages/bundle/base/cordis.patch.yml#L188-L205)）。
3. **凭据不入 `.env`**：`DEEPSEEK_API_KEY` 等网络凭据只能来自进程环境（[index.ts#L120-L160](../packages/boot/app-boot/src/index.ts#L120-L160)），用 compose 的 `environment` 或 secrets 注入，不要写进卷里的 `.env`。
4. **卷权限**：`/data` 由非 root 用户 `dsh` 拥有；首次挂载空卷时 compose 的 `chown` 在 Dockerfile 完成，后续宿主机挂载需确保 uid 一致。
5. **信号转发**：`tini` 作为 PID 1 确保信号正确转发；dsh 自身已处理 SIGTERM/SIGINT 的优雅卸载（[profile-boot.ts#L221-L222](../apps/cli/src/profile-boot.ts#L221-L222)）。

## 9. 可选：Headless CLI 单次任务

同一镜像可跑 headless 一次性任务（不改默认 CMD）：

```sh
docker run --rm \
  -e DEEPSEEK_API_KEY=sk-xxx \
  -v dsh-home:/data/dsh \
  dsh-web:local \
  node apps/cli/lib/bin.js --profile headless "完成某任务"
```

headless profile 的 bundle 组合见 [PROFILE_TEMPLATES](../packages/boot/app-boot/src/profile.ts#L113-L117)，CLI 一次性执行后退出。
