# 06 会话数据面与基础设施

覆盖 `session/*`、`session-query/*`、`storage/*`、`settings/*`、`credentials/*`、`workspace/*`、`typert/*`、`util/*`、`test-support/*`。

## 1. session 组（14 包：持久化/投影/标题/遥测/检查点）

### session-persistence（SD，**ctx `ctx.sessionPersistence`**）

- 追加式事件溯源持久化 seam：`SessionEvent` 即持久单元，`SessionHeader` 单独存放
- 方法：`locate / supportsRawArtifacts / readRaw / create / append / prepare / load / inspect / readFrom / list / listSnapshots`
- `src/coordinator.ts` `PersistenceCoordinator` + `PersistenceBackend<TornMarker>` 钩子：tornMarker 完全不透明；有界批写窗口（200ms）；崩溃修复仅冷路径（合成 `tool/result`(TOOL_NOT_STARTED / TOOL_OUTCOME_UNKNOWN) + `step/end` + `turn/end {interrupted}` 闭合中断 turn，不截断有效事件）

### session-persistence-jsonl（JSONL 物理后端）

- 每会话一个追加文件：`<root>/<规范化cwd>/<转义id>/session.jsonl.zstd`（默认 zstd 压缩帧；`compression:'none'` 时 `.jsonl`）；首行为不可变 `SessionHeader`
- `src/format.ts` `packChunks` 打包行（≥3 连续同类 `assistant/chunk` 压成裸标签行）；Windows 用 `MoveFileExW` 无覆盖发布，POSIX 用 hard link + fsync 目录
- revision = dev/ino/size/ns 时间戳

### session-persistence-sqlite（SQLite 物理后端）

- `node:sqlite` 行式实现，同一契约；**`SCHEMA_VERSION = 15`**（单调，`PRAGMA user_version`）+ `APPLICATION_ID = 0x44534850`；非全新库/外应用 id/非当前版本一律拒绝（无迁移）
- 表 `events(session_id, seq, type, time, data JSON, ...)` 1:1 映射事件；`sessions` 行携带 `incarnation` + 单调 `revision`
- 与 JSONL 差异：`locate()` 返回 undefined（共享库无独立 artifact）；`readFrom` 真 seek（`WHERE seq >= ?`）；append = 一个事务

### session-projection（投影注册表，**ctx `ctx.sessionProjections`**）

- `ProjectionDefinition<K,S> = { key, schema, init(), apply(state,event), view(state), stateVersion }`——纯计算单元；框架订阅一次 `session/event`，急切驱动所有单元
- API：`register / onChanged / snapshot(session) / checkpoint / restoreFloor / restore(checkpoint, events, baseSeq)`；全值事件规则 + `Object.is` 同引用门控

### session-projection-cache（**ctx `ctx.sessionProjectionCache`**）

- 投影状态的耐久检查点（折叠加捷径，永非权威）；写策略：`turn/end` 与 disposal 两强制点 + 节流；日志先行、缓存跟随；`stateVersion` 不匹配即丢弃持久行不迁移

### session-stats / session-telemetry / session-telemetry-otel

- **session-stats**：注册 `sessionStats` 投影单元——步/轮计数、LLM/工具/首 token/解码墙钟时间
- **session-telemetry**（SD，**ctx `ctx.sessionTelemetry`**）：`SessionTelemetryBackend` 实现 `SessionTelemetrySink { emit/flush/shutdown }`；记录 `{channel:'ledger'|'ops', severity, attributes, body}`；waterfall `sessionTelemetry/record` 为脱敏扩展点（fail-closed）
- **session-telemetry-otel**：OTel 后端——OTLP/HTTP log exporter；Resource 含匿名 `user.id`；`mode: FULL/FEEDBACK_ONLY/DISABLED`（默认 DISABLED）

### session-title 族

- **session-title**（**ctx `ctx.sessionTitle`**）：日志回溯标题服务——确定性 fallback（`src/normalize.ts` `fallbackSessionTitle`）+ 单一可选异步 provider；每次接受的修订是 log-only `session/title` 事件；`source.kind='user'` 的最新标题 pin 会话
- **session-title-llm**：共享实现策略库（route 解析、JSON 装框、预算、超时）——派发前追加 `session/title-llm-request` 事件，envelope 带 `purpose:'session-title'`（DeepSeek 适配器据此禁 thinking）
- **session-title-first-prompt-llm / -all-prompts-llm**：两个可选 provider 插件（首 prompt / 每 prompt 节奏）

### session-checkpoint-policy

- 零配置策略插件：模型适配器收到请求前、顶层工具体产生外部副作用前、每个 `agent/pre-step` 边界先检查点事件日志；检查点失败 fail-closed（模型/工具体不执行）

## 2. session-query 组

- **session-query**（SD，**ctx `ctx.sessionQuery`**）：合并式查询抽象——已实现 `listSessions/readSession/filterSessions/filterEvents/readTitle/listEvents/readSurface/traceSession/traceEvent`，抽象 `searchSessions/searchEvents`；`src/corpus.ts` `SessionCorpus`（live-preferred 合并）
- **session-query-sqlite**：FTS5 全文 provider——专用派生索引库（禁止指向持久化库）；连接本地 TEMP 表承载 live 行遮蔽 durable base；查询词按数据处理（FTS5 语法不当 MATCH）；`openAt: startup|first-search|never`
- **tool-session-query**：模型工具 **`session_search / session_event_search / session_trace / session_event_trace / session_event_read`**（默认宿主组合不挂载）；授权：调用 agent 会话 cwd 与目标精确相等
- **session-log-export**：Web 会话日志 ZIP 下载（端点归 host-apiproxy；浏览器半含 HeaderAction/Dialog/controller）

## 3. storage 组（非会话存储）

- **storage**（hub，**ctx `ctx.storage`**）：命名后端注册表 + 数据形式挂载，hub 自身不做 IO；`StorageForms` merge 可扩展 map
- **storage-json**：每 unit 一个 `<unit>.json`（内存态权威，整体重发布 temp+fsync+rename）
- **storage-sqlite**：行式 KV（`STORAGE_SQLITE_SCHEMA_VERSION = 1`；unit 物理表 `(key, value)` STRICT；每写一条 prepared statement）
- **storage-domain**：domain 数据形式（**ctx `ctx.storageDomain`**）——zod 校验、变更发信号的 KV domain；写序：先 backend 持久化 → 再内存 → 发 `domain/changed`

## 4. settings / credentials / workspace / identity

- **settings**（SD，**ctx `ctx.settings`**）：`SettingsProvider`（子类实现 `writable/load/persist`）+ `register(ns, schema)` → `SettingsScope {get/watch/update/replace/mutate}`；三层解析（schema 默认 → 组合 base → 用户文档）；`describe({redactSecrets})`；写支持 `expectedRevision` 乐观并发
- **settings-file**：单 YAML/JSON 文档（默认 `<DSH_HOME>/settings.yaml`）；外部编辑热发布（chokidar + debounce）；写入 = writer lock 下 read-modify-write；YAML 叶级 diff 保注释
- **credentials**（SD，**ctx `ctx.credentials`**）：配置只带引用（环境变量名），值归 provider；逐操作解析不缓存；`credentialRef()` 品牌
- **credentials-local**：四层优先级 `env`（只读恒胜）> `file`（`$DSH_HOME/.credentials.yaml`）> `project-env`（cwd/.env）> `user-env`（$DSH_HOME/.env）；POSIX 上 group/other 权限位直接拒绝
- **workspace**（**ctx `ctx.workspaceRegistry`**）：耐久 workspace 记录 + 最新优先候选会话索引（经 storage-domain 存储）；`create/get/list/resolveByPath/archiveSession`
- **identity**：见 [05](05-agent-capabilities.md) §12。

## 5. typert 组（类型化 RPC 基础设施，重点）

三分离：**源码分析（generator，构建期库）→ 运行时存储（registry，ctx `typert`）→ Loader 发现（loader）**。

### typert/protocol（编译器无关协议层）

- **`@Remote`**：标记 public 实例方法可被直接远端调用（receiver = 该方法注册到的 Cordis Service 实例）；标准 Stage-3 方法装饰器，marker 存模块私有 WeakMap（不加任何运行时反射字段）
- **`@RemoteScope(key)`**：receiver 从 merge 声明的 scoped Context kind（`TypertContextMap`）中解析——wire 身份由 registry 的 `contexts` 提供
- `TypertRemoteService` 基类：`super(ctx, serviceKey)` 把 Cordis key 绑定为默认 wire namespace
- `InvocationDescriptor`：完整调用描述（service/namespace/method/invocation/parameters/codec/sourceLocation）；**方法末位声明 `signal: AbortSignal` 即合作取消注入点，signal 永不成为 JSON 参数**
- `TypertCodec = strict{typeSymbol, schema} | src-json`（src-json 是较弱的源码启动回退）

### typert/generator（分析器 + 工件生成器）

- `src/analyzer.ts` `WorkspaceAnalyzer`：从 `tsconfig.host.json` / `tsconfig.client.json` 各建独立 `ts.Program`；direct project references 确定 compiler-face 成员，`package.json#exports` 确定 runtime-face 贡献与唯一跨包公共边界
- `src/emitter.ts` `FaceModelEmitter`：只吃 model（`src/model.ts` 纯数据模型），产出含 Zod schema 与 `TYPERT` 贡献的可执行 JS + 类型化 .d.ts
- `src/workspace.ts` `WorkspaceTypertGenerator`：沿 Cordis `Context`/`Events` augmentation 发现贡献包；host 工件为 `lib/typert.host.{js,d.ts}` 以 `package/typert` 暴露，client 工件以 `package/client/typert` 暴露；仓库 Host tsdown 同时产出 **Host 反射工件 + `typert.remote-client.*`（Host Remote 契约的 Client 投影）**

### typert/registry（运行时注册表，**ctx `ctx.typert`**）

- 包反射键 `<package>#<face>`、schema 键 `<package>#<name>`（保留生产者 Zod 实例）；`register(contribution)` malformed/duplicate 拒绝后整体提交，返回精确 disposer
- `lookups.register()/configure()`（lookup 身份解析）、`contexts.registerHost()/configureHost()/registerClient()`

### typert/loader（Loader 集成）

- Loader entry 挂载时导入其 `./typert` 工件并注册进 `ctx.typert`，卸载即撤回；`validateTypertManifest()` 在文件边界逐字段验证

### 端到端 RPC 链

```text
generator（构建期）分析 Host 类型
  -> lib/typert.host.js（TYPERT 清单：反射 + InvocationDescriptor[] + strict Zod codec）
  -> loader（运行时）导入并注册进 ctx.typert
  -> Host Gateway（api 包）按 descriptor 分发 JSON-RPC（SRC fallback 用 remoteMethods）
  -> Client 侧 typert.remote-client.* 投影 merge 出 TypertRemoteMap
  -> TypertClientRemote.$mount/$on/$dispatch 得到类型化 RPC 与事件订阅
```

## 6. util 组（7 包零依赖库）

| 包 | 关键导出（`src/index.ts`） |
|---|---|
| atomic-write | `writeFileAtomic(file, content, {mode})`（wx 随机后缀 temp 拒 symlink）、`withFileLock(file, fn)`（跨进程写锁） |
| brand | `Branded<B>`（名义类型，无运行时代码） |
| home-paths | `resolveDshHome()`（显式配置 > `$DSH_HOME` > `~/.dsh`）、`dshHomePath()`、`canonicalizeWatchPath()` |
| launch-environment | `LaunchEnvironmentSnapshot`（process > project-env > user-env 信任序的不可变快照） |
| native-command | `runNativeCommand(command, args, signal)`（无 shell 的 execFile） |
| output-retention | `ItemRetainer<T>` / `TextRetainer`（UTF-8 边界安全 head/tail）、`describeOmitted()` |
| timeout | `clampTimeout()`、`deadline(upstream, ms, code)`（`AbortSignal.any` 融合）、`idleWatchdog`、`timeoutOf()`（超时 vs 取消分类器） |

## 7. test-support 组（6 包）

- **agent-loop-testkit**：`mountAgentLoopTestDependencies()` 按依赖序挂 LlmRuntime→SessionStore→SystemPrompt→ToolRuntime→AgentRegistry（刻意不挂 AgentLoop/适配器）
- **client-runtime**：jsdom slot 测试运行时（真实 Cordis Context + 生产 SlotRegistry + web-react renderer）
- **llm-replay**：无 key 快照测试的回放 LLM 插件——从录制 `session.jsonl` 重建模型流；`replay.override.json` 边车按调用索引换/追加脚本
- **llm-mock-server**：可脚本 OpenAI 兼容故障服务器（connection_reset/stall/rate_limit/context_overflow 等 23 种行为）；`pnpm run mock:llm`
- **acp-snapshot**：ACP 快照套件（launcher/harness/normalize/suite 四层；record/replay/refresh 三模式）
- **loader-smoke**：经 Cordis Loader 启动 app + cordis.yml 的子进程冒烟 harness

## 8. 版本与兼容机制总表

| 机制 | 值/规则 |
|---|---|
| `SESSION_FORMAT_VERSION` | `0`，无兼容承诺（结构变更才 bump） |
| 会话 SQLite `SCHEMA_VERSION` | `15`，`PRAGMA user_version` + application_id，非当前版本拒绝 |
| 存储 SQLite 版本 | `1`，同样拒绝式 |
| 投影缓存 | 每单元 `stateVersion` 做失效锚点 |
| 通用立场 | 预发布：宁可拒绝旧盘上格式，不做迁移 |
