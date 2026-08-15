# 03 核心主干与 LLM

覆盖 `packages/core/*`、`packages/llm/*`、`packages/runtime-diagnostics/invariants`——产品 API 的脊柱。

## 0. 主干协作全景

`agent-loop` 的 `ReactLoopAgent` 每个 step 经 `systemPrompt.assemble` + `agent/pre-step`/`agent/request` waterfall 组装请求，`llm.prepareCall` 冻结调用事实后由 `DeepSeekAdapter`/`PiAiAdapter` 产出 `StreamChunk`；chunk 与最终消息以 `assistant/chunk`/`assistant/message` 事件落 `Session`（`SessionStore` 管理），工具结果经 `ToolRuntime` 管线落 `tool/call`/`tool/result`；失败沿 `agent/request-error` 被 `llm-retry` 消化（durable 重试事件也进日志）；`token-meter` 重放同一日志给出压力计量；`scope` 的标签链支撑全部 `Scoped<X>` 事件过滤；`invariants` 为各包提供不变量安装点。

## 1. core/scope — 带标签的上下文原语

- 职责：为任意对象创建带标签（`kScope` Symbol）的子上下文，维护 parent 链，使"注册视图沿链向下继承、事件准入沿链向上扩展"。
- 纯函数包，不挂 Service。关键导出（`packages/core/scope/src/index.ts`）：
  - `createScope(ctx, key, options?)` → `Scope { ctx, rawDispose, dispose() }`
  - `bindScopeParent` / `scopeParentOf` / `scopeChainOf` / `scopeOf(ctx)` / `scopeTarget(base, key)` / `isScopeCarrier`
- `store.ts` 提供 `ScopedLayers` 分层注册视图；parent 链存于 WeakMap。是全库 `this: Scoped<X>` 事件过滤的底层支撑。

## 2. core/session — 事件溯源会话日志

- **ctx key `ctx.sessions`**；Service：`SessionStore extends Service`（`packages/core/session/src/index.ts`）
  - `create(id?, options?)` / `prepare(id?, options?)` — 新建/预备
  - `enter(session)` / `announce(session)` — 两阶段进入（enter 建 ctx+scope，announce 发事件）
  - `flush(session)` / `get(id)` / `list()`
  - `fork(source, boundary?, childSessionId?)` — 从 boundary 派生子会话；错误码 `SESSION_NOT_FOUND / SESSION_NOT_LIVE / SESSION_ALREADY_EXISTS / INVALID_BOUNDARY / OPEN_TURN`
- **`Session`**（普通类）：
  - `static create / fromRestore`
  - `append(type, data, ...opts)` — 核心写路径
  - `deriveMessages()` / `deriveEventMessage(event)` — 从日志派生模型消息历史
  - `requestHeader()` / `requestContext()` — 折叠最近的 `request/header`/`request/context`
  - 属性：`surface`（有序投影，只含 `user/message`/`assistant/message`/`tool/result`）、`events`、`seq`、`id`、`header`、`firstLiveSeq`
- 事件（均 `this: Scoped<Session>`）：`session/created`、`session/disposed`、`session/event`、`session/flush`
- 关键类型（`src/types.ts`）：`SessionId`（branded）、`SESSION_FORMAT_VERSION = 0`、`SessionEventMap`（merge 可扩展）、`TurnEndReasonMap`（completed/aborted/blocked/error/max-tokens/interrupted）、`SessionEvent.ignorable?: true`（未知事件可跳过）
- 经 Typert 注册 `session` lookup（SessionId ↔ Session）。

## 3. core/system-prompt — 提示词组装注册表

- **ctx key `ctx.systemPrompt`**；Service：`SystemPrompt extends Service`
- 方法：`section(PromptSection)`、`context(PromptContext)`、`suppressRuntimeContext()`、`tools(provider)`、`variable(name, provider)`、`assemble(context?)`
- 事件：`system-prompt/assemble`（waterfall）、`system-prompt/change`
- 类型：`PromptSection { name, order, text }`、`PromptAssembly { sections, contexts, tools, variables }`
- 常量：`PERSONA_SECTION = 'deployment:persona'`、`PERSONA_ORDER = 0`；渲染函数 `renderPrompt` / `renderContextSections` / `joinContextSections`

## 4. core/tools — 工具注册与执行管线

- **ctx key `ctx.tools`**；Service：`ToolRuntime extends Service`（`inject = ['systemPrompt']`）
- 方法：`register(definition)`、`presentAs(mode)`、`restrict(filter)`、`guard(guard)`、`get(name, scope?)`、`schemas(scope?)`、`execute(exec)`、`executionMode(exec)`
- 内部调度器 `[TOOL_RUNTIME_SCHEDULER]: ToolRuntimeScheduler { prepare, dispatch, finalize, finish }` — agent-loop 用此 symbol 视图重叠 dispatch 而保持 pre/post 有序。
- 事件（除 `tools/change` 外均 scope 过滤）：
  - `tools/pre-execute`（waterfall → `PreToolDecision` allow/deny/ask）
  - `tools/execute`（around-dispatch waterfall）
  - `tools/post-execute`（waterfall → `PostToolDecision`）
  - `tools/code-dispatch-log`（waterfall）、`tools/result`（emit）、`tools/change`（emit）
- 类型：`ToolDefinition extends ToolSchema`（`execute` / `finalizeContent?` / `timeoutMs?` / `isConcurrencySafe?` / `presentCall?` / `presentResult?`）、`ToolRunContext`（含 `deferContext` / `concludeTurn`）、`ToolPresentationMode`
- Code Mode 支持：`RUN_CODE_NAME` 保留传输、`SDK_RENDERERS`（typescript/python）
- 错误：`ToolNotFoundError`（UNKNOWN_TOOL）、`ToolOutputError`（INVALID_TOOL_OUTPUT）

## 5. core/agent — Agent 接口、注册表与 initiator 归因

- **ctx key `ctx.agents`**（另挂 `ctx.agent?` DX 访问器）；Service：`AgentRegistry extends Service`
- 注册表：`register / enter / announce / get / isOwnedBy / list / roots`；工厂：`setFactory / create / resume`；initiator 归因：`currentInitiator / requireInitiator / withInitiator / withoutInitiator`（AsyncLocalStorage 因果链）
- **`Agent` 接口**（`src/runtime-types.ts`）：`id`、`options`、`session`、`inbox`、`status`、`ctx`、`cancel(cause, options?)`、`whenIdle()`、`runMaintenance(job)`、`send(message, target, wakeup)`、`followup`、`steer`、`inject`
- **`AgentEventMap`**：
  - 生命周期（emit）：`agent/created`、`agent/disposed`、`agent/status`、`agent/inbox/inserted|claimed|discarded`、`agent/session-start`
  - 扩展点：`agent/pre-step`（waterfall → `PreStepDecision = { kind:'reject' } | { kind:'enter'; messages }`）、`agent/request`（waterfall → `LlmCallConfig`）、`agent/request-error`（waterfall → `RequestErrorAction`）、`agent/turn-stopping`（serial）
  - `agent/error`（emit）
- `InboxTarget = 'next-turn' | 'next-step'`；declaration merging 扩展 `SessionEventMap` 增加 `agent/inbox/spliced`。

## 6. core/agent-loop — 具体驱动循环（重点）

- **ctx key `ctx.agentLoop`**；Service：`AgentLoop extends Service implements AgentFactory`（`inject = ['agents','sessions','llm','tools','systemPrompt']`）
- Config：`maxParallelToolCalls`（默认 10）+ `agents[]`（id/sessionId/provider/model/maxTokens/cwd/resumeSessionId）
- `packages/core/agent-loop/src/index.ts`：
  - `FactoryOwnership`（工厂级 teardown / liveAgents / startupTasks）
  - `prepare(ownerCtx, id, options, session, callerSignal?) → PreparedAgent`（逆向 teardown 备忘录）
  - `publish()` 按 `sessions.enter → agents.enter → sessions.announce → agents.announce → agent/session-start` 顺序发布
  - 注册 prompt variables `provider/model/cwd`；settings namespace `agent-loop`
- **`ReactLoopAgent`**（`packages/core/agent-loop/src/agent.ts`）状态机与调用链：

  ```text
  Phase: { idle; lastTurn }
       | { maintenance; abort; lastTurn; wakeRequested }
       | { running; abort; turn; step; wakeRequested }

  wakeDriver()  -- idle 时启动 kick()；maintenance/已中止时 latch wakeRequested
  kick()        -- while (await this.turn()) {}
  turn()        -- 追加 turn/start
        preStep(target) 循环：
          inbox.claim() -> systemPrompt.assemble() -> runtimeContext.project()
          -> agent/pre-step waterfall（默认 enter，runtime context 追加进 messages）
          reject => turnEnds = { kind: 'blocked' }
          每步：step/start -> user/message -> step(assembly) -> step/end
        停止条件满足 -> agent/turn-stopping (serial) -> turn/end
  step(assembly)
        buildRequest() -> BlockAssembler 逐 chunk 追加 assistant/chunk
        finish error/aborted -> agent/request-error waterfall（retry 则重试本 step）
        createAssistantMessage -> assistant/message（sourceEventSeqs 指向 chunk seqs）
        含 tool-call -> executeToolCalls()
  buildRequest()
        session.requestHeader() 折叠 -> agent/request waterfall
        -> llm.prepareCall(config, signal) -> 追加 request/header 与 request/context
  ```

  `cancel(cause)` 默认 `inbox.clear()` + `abort.abort(cause)`；构造时 `createScope(loopCtx, this)`，`this.ctx = scope.ctx.extend({ agent: this })`。
- **工具调度**（`packages/core/agent-loop/src/tool-calls.ts`）：`executeToolCalls()` 按 `ctx.tools.executionMode()` 分组，parallel 组用有界滚动池，exclusive 为屏障；经 `[TOOL_RUNTIME_SCHEDULER]` 调 prepare/dispatch/finalize/finish；结果按模型顺序 commit；abort 时为未派发调用补合成 `tool/call` + `ABORTED_BEFORE_DISPATCH` 结果。

## 7. core/agent-default-model 与 core/agent-tool-presentation

- **agent-default-model**：跨会话持久化"当前默认模型"。`ctx.agentDefaultModel`；`AgentDefaultModelConfig`：`currentSelection()` / `saveSelection(next)`；settings namespace `agent-default-model`。
- **agent-tool-presentation**：按部署模式（native/code/both）设置工具 UI 渲染意图；普通插件无 ctx key；`apply()` 中 code/both 模式经 `ctx.inject(['codeRuntime'], ...)` 等待 Code 运行时。

## 8. llm/llm — Provider 中立的 LLM 服务（重点）

- **ctx key `ctx.llm`**；Service：`LlmRuntime extends Service`（`packages/llm/llm/src/index.ts`）
- **适配器 seam**：
  - `registerAdapter(providers, adapter)` → handle 含 `replace(providers)`（原子换路由，无空窗）
  - `registerConfigurableProviders(entries)` / `listConfigurableProviders()` — 可配置 provider 目录
  - `registerModelDiscovery(settingsNs, discover)` / `discoverModels(...)` — 端点模型探测
  - `listModels` / `resolveModelInfo` / `resolveCallConfig`
  - **`prepareCall(config, signal?): Promise<PreparedLlmCall>`** — 每 step 一次的调用冻结点：`{ config, retryPolicy, context?, adapterDefaults, stream(options) }`，一次性（二次使用抛 `INVALID_PREPARED_CALL`）
- 事件：`llm/stream`（waterfall）、`llm/adapters-updated`（emit）
- `LlmAdapter` 抽象基类：可覆写 `providerInfo / providerRetryPolicy / listModels / resolveModel`，抽象 `stream(options)`
- 错误：`LlmError extends HarnessError`；内部把适配器选择/分发/迭代失败规范化为单个 terminal `finish` chunk
- **消息词汇表**（`src/types.ts` + `src/message.ts`）：
  - `Message { id, role: system|user|assistant, content: ContentBlock[], source }`；特化 `UserMessage` / `AssistantMessage` / `ToolResultMessage`
  - `MessageSourceMap`（merge 可扩展）：`user` / `plugin` / `model` / `tool`
  - `ContextForm`（producer 语义声明）：instructions / catalog / snapshot / notice / relay / recall
  - `ContentBlockMap`：text / reasoning / image（attachment 引用）/ tool-call / tool-result
  - `FinishReasonMap`：stop / tool-calls / max-tokens / aborted / error
  - `StreamChunk`（适配器原始流）：block-start / text-delta / reasoning-delta / tool-call-delta / block-end / usage / finish
  - `GenerateOptions`（完整单次请求，含 `purpose: 'compaction'|'session-title'`）
  - `TokenUsage`（DISJOINT 桶：input/cacheRead/cacheWrite/output/reasoning）
  - 构造器：`createMessage` / `createUserMessage` / `createAssistantMessage` / `createToolResultMessage` / `freezeMessage` / `isTokenDelta`

## 9. llm/llm-deepseek — DeepSeek 官方适配器

- 插件 `name = 'llm-deepseek'`，唯一路由 `PROVIDER = 'deepseek-official'`
- `DeepSeekAdapter extends LlmAdapter`（`packages/llm/llm-deepseek/src/adapter.ts`）：
  - 构造注入三个 thunk：`options()`（每操作读一次连接事实）、`resolveApiKey(connection)`（同一快照解析，端点与密钥永不跨代配对）、`resolveUserId()`
  - `stream()`：冻结连接 → 闲置看门狗（`LLM_STREAM_IDLE_TIMEOUT`，默认 300s）→ `serializeRequest` → `fetch POST {baseURL}/chat/completions` → `translate(parseSse(...))`
  - HTTP 错误映射：401/403→AUTH、429→RATE_LIMIT、400→INVALID_REQUEST/CONTEXT_WINDOW_EXCEEDED、≥500→SERVER；另有 TRANSPORT/TIMEOUT/ABORTED/EMPTY_RESPONSE
- Config：`apiKeyEnv`（默认 `DEEPSEEK_API_KEY`，经 credential seam）、`baseURL`（回退 `$DEEPSEEK_BASE_URL` → `https://api.deepseek.com`）、thinking、reasoningEffort、maxTokens（默认 256k）、defaultContextWindow（默认 1M）、models、retryPolicy 等
- 热更新：settings 变化 per-request 重解析；retry policy 是注册时唯一事实，变化时 `registration.replace([PROVIDER])` 原地重注册
- 支撑文件：`serialize.ts`、`sse.ts`、`translate.ts`

## 10. llm/llm-pi-ai — 多 Provider 适配器

- 基于 `@earendil-works/pi-ai`；一个插件实例拥有 provider 路由字典（catalog 路由 + hand-declared 路由）
- `PiAiAdapter extends LlmAdapter`（`packages/llm/llm-pi-ai/src/adapter.ts`）：
  - **不可变快照机制** `current(): PiAiSnapshot { profiles, models }` — 每次操作捕获整快照，配置变化建新集合，保证 `prepareCall` 冻结贯穿到底
  - `stream()`：校验（不支持 `stop`）→ 快照 → `resolveReasoningLevel` → 图片输入校验 → `toPiContext` → `models.streamSimple(...)`（`maxRetries: 0`，重试归 agent 恢复层）→ `toStreamChunks`
- `resolveApiKey`：profile 命名了 `apiKeyEnv` 但解析不到 → 抛 `MISSING_CREDENTIAL`（绝不落到 pi-ai ambient key）；未命名才交给 pi-ai 自身发现
- 配置类型 `PiAiProviderProfile`（apiKeyEnv/baseURL/compat/models/transport/timeoutMs/headers 等）

## 11. llm/llm-retry — 请求重试执行器

- 在 `agent/request-error` waterfall 上实现 provider 路由的指数退避重试；每次重试在可取消等待前先落日志（durable）
- `recover()`：`mode === 'always'` 委托下游后仍强制 retry（无上限）；`normal` 按 `retryableCodes` 匹配
- **重试计数跨恢复存活**：`agent.session.events.findLast('llm/retry')` 按 `(turn, step, provider, policyKey)` 匹配恢复计数
- `backoff()`：`session.append('llm/retry')` → 可取消延迟（指数退避 × jitter）→ `session.append('llm/retry-started')` → 返回 `{ kind:'retry' }`

## 12. llm/token-meter — 重放感知 token 计量

- **ctx key `ctx.tokenMeter`**；`TokenMeter extends Service`
- `measure(session, requestHeader?)` → `{ logRevision, baseline, surfaceDeltaTokens, totalTokens, surfaceTokens, nodes }`；`estimateMessage(message)` 纯启发式
- 机制：per-session `ReplayState`（WeakMap）+ `_sync()` 增量消费事件流；锚点策略——`assistant/message` 带 usage 且与当前 canonical header 匹配时建 usage 基线（保守采纳），否则 estimated 基线
- 可选注册三个会话投影单元：`tokenUsageProjectionDefinition`、`contextPressureProjectionDefinition`、`contextBreakdownProjectionDefinition`

## 13. runtime-diagnostics/invariants — 运行时不变量注册表

- **ctx key `ctx.invariants`**；`InvariantRegistry extends Service`
- `register(packageName, installer)`：各包从自身 `./invariant` companion 安装运行时检查，普通入口不依赖诊断；包名即使被过滤禁用也保留（重复注册仍报错）；启用的 installer 跑在 child fiber，失败即销毁
- Config：`enabled`、`package_allowlist` / `package_blocklist`（正则）
- 被几乎所有包 peer 依赖（见 [08-依赖关系](08-dependencies.md)）——是依赖图的共同根。
