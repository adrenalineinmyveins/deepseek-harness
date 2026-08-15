# 02 整体架构

## 1. 分层鸟瞰

整个系统从上到下可分为五层：

```text
┌─────────────────────────────────────────────────────────────┐
│ 宿主形态层  apps/cli (dsh) · apps/web · ACP server · SDK     │
│             (python/ TS) · examples/*                        │
├─────────────────────────────────────────────────────────────┤
│ 组装层      bundle/{base,headless,web-app} + boot/{app-boot, │
│             cmdline}：profile → 补丁栈 → Cordis 插件树       │
├─────────────────────────────────────────────────────────────┤
│ 能力层      shell/fs/sandbox/lsp/web/skill/subagent/jobs/   │
│             workflow/compaction/... （Seam 三角色组织）      │
├─────────────────────────────────────────────────────────────┤
│ 主干层      core/{session,system-prompt,tools,agent,         │
│             agent-loop,scope} + llm/llm                      │
├─────────────────────────────────────────────────────────────┤
│ 基础层      typert · storage · settings · credentials ·     │
│             util/* · invariants · vendored Cordis           │
└─────────────────────────────────────────────────────────────┘
```

Web 形态额外有 host/client 两半与 api 网关，见 [07-组装与运行时](07-assembly-runtime.md)。

## 2. Cordis：底座框架

源码在 `vendor/`（9 个包，重定域为 `@deepseek-ai/*`；同步程序与 18 条本地修改记录见 `vendor/README.md`）。五个核心思想：

1. **插件是 Service**：带 `inject`/`apply(ctx)` 的函数插件，或 `Service` 子类。
2. **上下文是服务仓库**：服务认领稳定的 `ctx.<key>`（如 `ctx.tools`），其他插件按键发现而非导入具体实现。
3. **`inject` 声明依赖**：声明了必需服务的插件会等待服务出现——加载顺序由服务需求表达，而非手工编排。
4. **类型化事件通信**：事件名经 TypeScript declaration merging 声明，按语义选择派发模式：

   | 模式 | 是否等待 | 顺序 | 返回值 |
   |---|---|---|---|
   | `emit` | 否 | 注册序观察 | 无 |
   | `waterfall` | 否 | 注册序环绕中间件 | 有（经 `next()` 传递） |
   | `parallel` | 是 | 并行 | 无 |
   | `serial` | 是 | 注册序 | 有 |

5. **注册即可逆效果**：prompt 段、工具 schema、适配器、监听器都经 `ctx.effect()` / `ctx.on()` 安装，重载与卸载可预测回滚。

Waterfall 语义：监听器收到 `(...args, next)`；调用 `next()` 把（可能改写的）结果委托给下一个监听器，不调用即短路。单决策事件（如 `tools/pre-execute`）短路即设计意图。

## 3. Profile 与 Bundle：启动装配

一次运行中的 `dsh` 是启动时由有序层组合出的插件树：

- **profile**：Harness home 中命名的组合（`$DSH_HOME/profiles/<name>/`），声明堆叠的 bundle 列表、out-of-tree 插件、用户自己的 `cordis.patch.yml`。仓库自带 `web` 与 `headless` 模板。
- **bundle**：Cordis 配置行 + 所挂代码的可分发格式；在自身 `package.json` 的 `dsh.bundle` 字段指向补丁文件。
  - `dsh-base`（`packages/bundle/base/cordis.patch.yml`）：所有 profile 的第一层——模型适配器、工具、持久化、沙箱与审批策略、settings、credentials、遥测等约 70 行核心 insert。
  - `dsh-web-app`：叠加浏览器应用（host 行 + 传输层 + 约 30 个浏览器 `dsh.client` roster 行）。
  - `dsh-headless`：叠加一次性 runner，无服务器。

补丁栈应用顺序（对空 entry 列表依次叠加）：**bundle 层（按 profile 声明序）→ profile `cordis.patch.yml` → home 级 `cordis.patch.yml` → `--patch` overlay → 遥测开关 patch**。补丁按行 id 定位，替换整行 config 或插入新行。

查看实际启动树：

```sh
dsh --profile web --dump-config
```

装配调用链与启动细节见 [07-组装与运行时](07-assembly-runtime.md)。

## 4. 事件体系：三类域

事件是主要扩展点，选对域是大多数改动的第一个决策：

- **会话事件（Session Events）**：追加进日志的耐久事实，经 `session/event` 广播。事实需要跨重载存活时用它。`SessionEventMap`（`packages/core/session/src/types.ts`）merge 可扩展：`turn/start|end`、`step/start|end`、`user/message`、`assistant/chunk|message`、`tool/call|result`、`todo/write`、`request/header|context` 等。
- **智能体事件（`agent/*`）**：携带活 `Agent` 的实时事件——inbox、step、status、request、校验、continuation。观察或拦截进行中的工作用它。
- **能力事件**：把策略与适配器挂到 seam（`fs/*`、`tools/*`、`llm/*`、`telemetry/*`）而不导入循环。

每个事件的生产者/消费者全景见生成的 `docs/event-producer-consumer.md`。

## 5. Turn / Step 生命周期

**step** = 一次模型请求 + 它调用的工具；**turn** = 零或多个 step：在第一个输入被认领前开启，不再欠任何东西时关闭。

```text
turn/start
  认领 next-step 输入 + 一条排队消息
  组装 prompt sections + tool schemas
  -> agent/pre-step                    reject | enter(messages)
     reject 或首次 enter 被改写为空 -> 不消耗 step 即关闭 turn
     step/start
     追加 entered messages 为 user/message
     deriveMessages() 从日志派生模型历史
     agent/request -> llm/stream -> assistant/chunk* -> assistant/message
     tool/call* -> tools/pre-execute -> tools/execute -> tools/post-execute -> tool/result*
     step/end
     tools 欠新请求，或 next-step 输入到达 -> 认领 -> 下一个 step
  -> agent/turn-stopping
turn/end
```

- `turn/*`、`step/*`、`user/message`、`assistant/*`、`tool/*` 是耐久会话事件；其余是跨三个域的实时扩展点。
- `agent/pre-step`、`agent/request`、`llm/stream`、三个 `tools/*` 是 waterfall（必须 `next()`）；`agent/turn-stopping` 是 serial（无 `next()`）。
- 输入经单一 inbox 到达驱动器：有的消息立即唤醒；注入的上下文在 inbox 中等待下一条消息。
- 时序图见 `docs/agent-lifecycle.md`，工具管线见 `docs/tool-execution-pipeline.md`。

## 6. 会话日志不变量

会话日志是模型所见上下文的唯一来源：`deriveMessages()` 从日志投影模型历史，原始 `assistant/chunk` 事件保住重放与 UI 保真。Fork、resume、transcript、遥测、持久化全部派生自这条流。

**Model-visible ⟺ logged**：凡到达模型请求的内容必须能从日志重建，且由运行时不变量断言。因此新的模型可见输入需要新的会话事件：扩展 `SessionEventMap` 并从日志渲染。

## 7. 能力 Seam（Capability Seam）

**Seam** = 一个可替换能力的三个角色：

| 角色 | 职责 | 例 |
|---|---|---|
| Service Definition | 声明接口（抽象 Service 类 + 事件词汇 + 类型） | `SubprocessRuntime`、`FileSystem`、`ShellExecutor`、`WebRuntime` |
| Service Provider | 实现接口（本地/沙箱/远端可互换） | `LocalSubprocessRuntime` / `E2BSubprocessRuntime` |
| Consumer | 使用接口（通常是模型可见工具） | `tool-bash`、`tool-fs`、`tool-web` |

一个包可合并多角色，但只有一个角色不成 seam；新增能力意味着三角色齐备（图谱见 `docs/capability-seams.md`）。

Seam 的威力：文件系统与子进程 provider 共享同一执行世界，把二者指向远端沙箱即可把 Bash、PTY、LSP 一起搬走，无 provider 分叉。子代理 provider 同样在一层接口后从"进程内新 agent"到"委托给另一个产品"广泛变化。

依赖规则配套：**扩展插件依赖 Service Definition，绝不依赖具体 Provider**。`dsh-agent-loop` 可替换；UI、hook、工具插件用 `dsh-agent`。

## 8. 新行为的落点

| 目标 | 机制 |
|---|---|
| 加模型 provider | 在 `ctx.llm` 注册适配器 |
| 加模型可见能力 | 注册到 `ctx.tools`；其 schema 自动进入 prompt 组装 |
| 给单个 session 不同能力集 | 组合 agent preset；preset 里的 service 行需 `isolate` realm |
| 加 shell 执行 | 注册 `ctx.shell` 后端；本地后端经 `ctx.subprocess` 派生 |
| 加持久终端 | 注册 `ctx.terminals` 后端 + `dsh-tool-terminal` |
| 加人类命令 | 注册 `ctx.commands`；不经模型 turn 直接派发 |
| 加后台工作 | 注册 `ctx.jobs`；`job_*` 工具收集/停止它 |
| 加文件系统访问或策略 | 注册 `ctx.fs` provider 或监听 `fs/*` 事件 |
| 围禁派生进程 | 用 `ctx.sandbox` 后端；消费者在 spawn 前包装 argv |
| 拦截请求/工具/turn | 用对应 `agent/*` 或 `tools/*` 事件；`agent/turn-stopping` 停止 turn |
| 加模型可见上下文 | 调 `agent.inject()`；落在下一个被准入的请求 |
| 加 UI/编辑器集成 | 驱动 `ctx.agents` 并从 `session/event` 渲染 |
| 加 Web Chat 节点 | 注册 `ConversationNodeDefinition` + keyed renderer |
| 加耐久 session 状态 | 扩展 `SessionEventMap`；从日志渲染与重放 |
| 生成会话标题 | 注册唯一的 `ctx.sessionTitle` provider |
| 管理同 session 目标 | 用 `ctx.goals`；经 `agent/*` 续跑 |
| fork 活会话 | `ctx.sessions.fork(source, boundary?, childSessionId?)` |
| 把注册限定到单个 agent | 用该 agent 的 `agent.ctx` |

## 9. 架构上的关键不变量（读码前必知）

1. **注册即效果**：任何贡献没有 disposer 就是 bug。
2. **运行时不变量断言"拥有的关系"**：检查权威事件流或可变数据，而非服务/方法存在性。
3. **闭集 union 用 `assertNever` 收尾**；merge 可扩展 union 走 documented default。
4. **request/spec 分离**：默认值填充是 owning 实现中显式的 `resolve(request): Spec` 步骤，绝不藏在 `run()` 里的 `?? default`（模板：`dsh-shell`、`dsh-subprocess`）。
5. **source plane 与 artifact plane 不混**：静态门禁经 tsconfig `paths` 解析到 `src`；消费 built `lib/` 的门禁显式声明依赖。
6. **Host/Client 双聚合**：两侧对 cordis `Context` 接口做同名 declaration merging 但服务不同，合成一个 program 会冲突，因此 tsconfig 分 `host`/`client` 两个聚合（详见 [07](07-assembly-runtime.md) 与 `docs/development.md`）。
