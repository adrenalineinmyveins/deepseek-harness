# 07 组装与运行时

覆盖 `bundle / boot / api / host / client / sdk / acp / examples / apps` 与仓库外围（vendor、python、native、website、scripts、CI）。

## 1. 启动调用链：dsh CLI → Cordis 插件树

```text
apps/cli/src/bin.ts            parseDshArgs()：--profile/--patch/--dump-config、子命令 web/plugin
apps/cli/src/args.ts           Commander 适配器：launcher flag 在前，第一个不认识的 token 起归 app
apps/cli/src/profile-boot.ts   runProfile()
  ├─ composeProfile()：prepareProfile()（修复 profiles/node_modules 回退 + loadProfile）
  │   + home 级 cordis.patch.yml + --patch overlays + shipped preset 根 patch + 遥测开关
  ├─ provide(DSH_LAUNCH_ENVIRONMENT_KEY) / provideCmdline()
  ├─ boot()
  └─ watchUserPatches()：两个用户 patch 层热更新（bundle 层在下、overlay 在上）
packages/boot/app-boot/src/index.ts   boot()：new Context() -> ctx.plugin(Loader)
  -> mountRootInclude()（cordis:include/cordis:group 内建）-> loader.await()
  -> assertEntriesActivated()（FAILED/PENDING 均 fail-loud）
packages/boot/app-boot/src/profile.ts PROFILE_TEMPLATES：web -> [dsh-base, dsh-web-app]
                                                              headless -> [dsh-base, dsh-headless]
packages/boot/cmdline/src/index.ts    provideCmdline()：ctx.cmdlineArgs 冻结快照 + ctx.appExit
```

其他 CLI 模式：`apps/cli/src/dump-config.ts`（boot-free 打印组合树）、`apps/cli/src/plugin.ts`（pnpm 转发器 + 按 `dsh.bundle` 对账 profile bundles）。

### 三个 bundle 层（`packages/bundle/<name>/cordis.patch.yml`）

- **base**：所有 profile 的共享核心——一个约 70 行的巨型 insert（timer/hmr/llm/session/typert 三件套/agent/agent-loop/tools/system-prompt/sandbox 三平台门控/permission/subagent+fork+control/workflow/token-meter/compaction/web 搜索等）。patch 替换整行 config 而非合并。
- **headless**：one-shot 任务模式——覆盖 persona、禁用 hmr、插入 code-runtime、`headless-startup`（解析任务位置参数）、`headless-runner`。无 Host/HTTP/Web。
- **web-app**：浏览器表面——host 行（storage/message-feedback/workspace/session-projection-cache/directory-picker-auto/plugin-inventory/api-gateway/cordis-host-runner/web-startup）→ 传输层（webserver/web-runtime/client-hmr）→ **浏览器 roster（`dsh.client` 行，约 30 个 ui-*）**；同时按 id **禁用**（不删除）一批 per-agent 行（tool-bash、tool-fs、tool-subagent 等），让每个 session 经 agent-presets 组装；registry 类服务保留 host 面；末尾插入 `agent-presets` 行。

## 2. Web 架构：Host（Node）↔ Client（浏览器）

### Host 侧（`packages/host/`）

- **webserver**：`WebServer`（node:http）→ **ctx `ctx.webServer`**——`register()`（exact/prefix 路由）、`registerUpgrade()`（WebSocket）、`registerFallback()`（唯一 fallback 座位归 frontend-static）；匹配顺序 exact → 最长 prefix → fallback
- **frontend-static**：占 fallback 座位服务 SPA dist（403 穿越 / miss 回落 index.html）
- **apiproxy**：共享 API 网关——`src/api/` 零 Node 依赖 wire 契约（四象限判别联合 + Zod 双层校验）、`src/fetch/` host/client 双端、`ApiProxyService` → **ctx `ctx.apiProxy`**；域覆盖 session/workspace/settings/credentials/command/skill/搜索/导出等
- **connection 的 node 半**：注册唯一 `/api` 路由与 Fetch 桥；`src/api-request-trust.ts` 浏览器信任栅栏（Host 头 loopback/trustedHosts + Origin 一致 + 拒 cross-site，DNS-rebinding 防御）；`/api/events.mux` 与 `/api/events.host` 两条**只下行 WebSocket**
- **plugin-inventory**：Remote `pluginInventory/list`（ctx.loader.entries() 只读投影）
- **directory-picker{,-native,-browse,-auto}**：能力缝——`ctx.directoryPicker.capability()` 返回 `{kind:'native',pick}` 或 `{kind:'browse',list,createDirectory}`；`-auto` 开机检测并挂对应后端

### Typert RPC 网关（`packages/api/`）

- **api/gateway**：双面端点。Host 面 `TypertGatewayService`（**ctx `typertGateway`**）：`invoke()` 解析 `InvocationDescriptor`（strict 模式读 `ctx.typert.local`）→ 校验参数 → 解析 lookup（agent/session 标识）→ 调用业务方法 → 校验结果；Host 面还在 `/api` FetchHandler 上注册 trusted-host 拦截器（认领 Remote 端点进 Gateway，未认领回落 API Proxy）。Client 面 `ClientRemote`（**ctx `ctx.remote`**）：`$mount()/$on()/$dispatch()`
- **api/remotes**：BFF——Host 面拥有 Agent/Session 身份策略（`createApiRemoteAgentResolver()`：活 Agent 复用、冷 session resume、并发去重、subagent 所有权栅栏）；Client 面以运行时值导入各业务包生成的 `/remote` 产物并挂载。**构建边界特殊**：全仓唯一 Host/Client 双 tsconfig 面的包（Host 面参与 Host Typert 图，Client 面依赖 Host tsdown 先生成 `/remote` 产物）

### Client 侧（`packages/client/`，约 38 包）

- **启动**：`apps/web/src/main.ts` → `new AppWebEntry(el).run()`（`packages/client/web`）。两阶段 boot：① 构建 `ClientModuleLoader` 覆盖宿主推入的 `window.__DSH_BOOT__` 入口图并 prefetch；② 挂 vendored cordis Loader（经其 internal 契约注入模块系统），settle 后点亮 UI。`apps/web/vite.config.ts` 把 workspace 包 alias 到源码、把 `process.versions.node` define 成 `"0.0.0"` 使 vendored Loader 的 internal 槽为空
- **modules**：浏览器模块系统 = vendored Loader `EntryTree.import` 的替换实现。lazy CJS 模型：bundle 执行只注册工厂 `window.__ModuleLoader__.load({id, factory})`，副作用在物化时运行；node 半扫描 `dsh.client` 行、经 `/plugins/<id>/client.js` 提供构建产物
- **connection**：**ctx `ctx.connection`**（共享 api client + loopback 状态 + 代际化 hostDescription + 单消费者流循环）；unary/respond 走 HTTP POST，事件走两条下行 WebSocket
- **runtime**：React-free 对象层——`ConnectionController` → `SessionManager` → `Session`（事件窗口、流式累积、重连机）；`SlotRegistry`/`SlotCore` 供渲染器数据源；`ConversationNodeAssembler` 按 Definition 折事件为会话节点；`defineStore` 快照-store 引擎；`ctx.slots.inject(name, cb)` 槽位声明注入
- **web-react**：壳层 React 胶水——`createSlotRenderer`、`SessionProvider`、`bindSnapshotSelector`（唯一 hook 构造点）；业务插件不依赖它
- **ui-slots**：槽位系统纯核——一个 API `ctx.slots.register({name, children?, store?, inject?}, Component)`；声明 = 渲染授权 = 运行时规格
- **hmr**：`GET /plugins/events` SSE 订阅，`rebuilt` 帧重载单个插件
- **其余 ui-\***：每包一个浏览器特性插件，全部经 `slots.register` 组合（conversation/tool/workspace/sidebar/settings×4/plan/goal/jobs/skill/subagent/model-selection/permission-presets/agent-preset/trajectory/workflow-run/deliverables/user-questions/message-feedback/commands/theme/layout/primitives/attachment/locale/schema-form/cordis）

### 端到端请求路径

```text
浏览器 ctx.remote.$mount() 贡献
  -> ctx.connection.rpc.call('/api', endpoint)  HTTP POST
  -> webserver /api 路由 -> Connection FetchHandler（trusted-host 拦截器）
  -> TypertGatewayService.invoke() -> Cordis Service 方法
  -> 校验后的响应原路返回；事件走 events.mux/events.host WebSocket 下行
```

## 3. SDK 与 ACP：两种进程外协议

均为 **stdio JSON-RPC**，定位不同：

### SDK JSON-RPC（`packages/sdk/`）

- **protocol**：`JsonRpcLineTransport`（每 `\n` 一帧紧凑 JSON）；方法 `initialize`、`session/prompt`（返回入队回执 messageId）、`shutdown`；通知 `session.event`（全量日志信封）、`session.status`、`subagent.started/finished`
- **server**：`HarnessSdkJsonRpcServer`（`inject:['agents']`，每 sessionId 一个 agent；shutdown → 刷响应 → dispose 根 → exit 0）
- **client**：TS 客户端——高层 `DeepSeekHarness`（`run()` = 入队 → 等回执 → 收集到 idle → `RunResult`；`await using` 管理）、低层 `HarnessClient`（显式 start/initialize/prompt/subscribe；close 走 shutdown→stdin-EOF→SIGTERM→SIGKILL 阶梯）

### ACP（`packages/acp/acp`）

对外标准 Agent Client Protocol 的 automation-only 适配器：`AgentSideConnection`（stdin/stdout）驱动 `ctx.agents`；`session/new` 造新 agent、`session/prompt` 等整 agent idle、`session/update` 只发已提交 assistant 文本、`session/request_permission` 一次性允许/拒绝。仓内主客户是 `dsh-subagent-acp`。

## 4. examples（`packages/examples/`）

- **agent-spine-demo**：代码形态 bundle——一个 `apply()` 挂全套 agent 脊柱服务，LLM 适配器/bash 执行器/入口点留给叶子（capability seam 在组合层的应用）
- **acp-demo**：bin `dsh-acp-demo`（spine + jsonl 持久化 + checkpoint + sqlite query + acp）
- **jsonrpc-demo**：bin `dsh-jsonrpc-agent`（boot 外部 cordis.yml；`lib/packaged-bin.js` 供 Python 单文件可执行发行）

顶层 `examples/`（叶子 cordis.yml）：`headless-agent`、`jsonrpc-agent`（含 Python `minimal.py`）、`acp-agent`、`web-cordis`（自指 agent 改自身插件树）、`web-schedule`、`mcp-memory`。每个可直接 `dsh --profile ... --patch ...` 运行，配 `cordis.snapshot.yml` 供无 key 回放。

## 5. apps/

- **apps/cli**（`@deepseek-ai/dsh`）：dsh CLI（profile 启动/插件管理/dump）；`composition.md` 是生成的 base 组合图
- **apps/web**（`@deepseek-ai/dsh-web-frontend`）：浏览器薄入口 + Vite 构建（vendor 手工分块、workspace alias 到源码、拒 standalone serve）

## 6. 仓库外围

### vendor/

Cordis 框架及基础库的源码 vendoring，9 个包（cosmokit、schemastery、cordis 4.0.0-rc.7、loader/include/group/timer/hmr/logger-console），全部重定域到 `@deepseek-ai/*`。`vendor/README.md` 含精确到 commit 的 manifest、18 条本地修改日志（fiber 生命周期加固、事务性 Loader 调解、`applyEntryPatches` 导出、lazy config 解析、`disabled: !!js` 插值等）与 5 步同步程序。修改 vendored 代码必须同步 manifest（pre-commit 门禁）。

### python/

Python SDK 双包：`sdk`（`deepseek-harness-sdk`：高层 turns API + 低层 JSON-RPC 客户端）与 `sdk-runtime`（`deepseek-harness-runtime-bin`：打包运行时二进制与默认 agent 配置）。SDK 默认启动匹配的捆绑运行时；runtime 永远要求显式配置。

### native/

`@deepseek-ai/node-addon-landlock-run` 源码记录处（`native/landlock-run/`）：Landlock "先自我限制再 exec" 启动器，三包 npm 家族（入口包 + 按平台 optional 平台包）；独立 GitHub workflow 构建发布。

### website/

VitePress 双语文档站。`website/docs.ts` 是规范发布清单（把 docs/ 各 canonical Markdown 源映射到 root(zh)/en 两棵路由树）；`pnpm run website:build` 兼作死链检查。

### scripts/ 与 CI

- `scripts/run-gates.ts`：带界内进程调度的 gate 运行器——`Mode` 聚合（ci-static/ci-coverage/ci-snapshot/ci-artifacts/ci-consumers/ci-windows-*/node-compat/check-all/doc-sync 等），`Gate {id, 命令, needs, env, allowFailure}` 经 `runGates()` 有界并发执行
- scripts/ 另有约 90 个生成器与校验器（gen-cordis-catalog、verify-cordis-config、verify-doc-budgets、rescope-vendor、release/ 发布族等）
- CI（`.github/workflows/ci.yml`）：PR 必需 lane——`node-24`（static）、`node-24-coverage`、`node-24-consumers`（快照/产物/兼容 + Playwright）、`node-compat`（22.19 与 26）、`python-sdk`、`python-runtime`、`windows`（Linux 上 Wine）；master push 跑自托管串行演练；`all-checks-passed` 是唯一分支保护必需检查

## 7. Host/Client 双聚合构建（读 build 脚本前须知）

- 两侧对 cordis `Context` 接口做**同名 declaration merging 但服务不同**，合成一个 `ts.Program` 会碰撞——因此 `tsconfig.host.json`（Host 包 + examples + tests + scripts + website + api/remotes Host 面）与 `tsconfig.client.json`（client 包 + apps/web + api/remotes Client 面）是两个聚合 program
- 根构建顺序：`tsc -b tsconfig.host.json` → `tsdown --env.DSH_BUILD_FACE host`（Typert 只在 Host tsdown 期运行，同时产出 Host 反射工件与 Host-for-Client Remote 投影）→ `tsc -b tsconfig.client.json` → `tsdown --env.DSH_BUILD_FACE client` → `pnpm run build:web`
- `api/remotes` 是唯一 split 包：其 Host 面必须参与 Host Typert 图，Client 面依赖先生成的 `/remote` 声明；`constraints` 门禁自动发现 split 包并校验引用面
