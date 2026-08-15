# 01 项目概览

## 1. 项目定位

DeepSeek Harness（npm 包名 `@deepseek-ai/dsh`，版本线 `0.1.0-rc.*`，MIT 协议）是一个**插件式智能体运行时**：

- 以 vendored **Cordis** 框架为底座，"一切皆插件"——包括模型适配器、工具注册表、会话日志、甚至智能体驱动循环本身；
- 以**事件溯源会话日志**为唯一事实来源：凡到达模型请求的内容都必须能从日志重建（"model-visible ⟺ logged"）；
- 以**能力 Seam（Service Definition / Provider / Consumer 三角色）**组织一切可替换能力，换一个 Provider 即可把整个执行世界从本机搬到远端沙箱；
- 预发布阶段（foundation over blast radius）：无外部消费者，宁可重命名重构也不留兼容垫片。

产品形态：`web`（浏览器 GUI + Node Host）、`headless`（一次性 CLI 任务）、ACP 自动化服务器、JSON-RPC SDK（TypeScript / Python）。

## 2. 技术栈

| 层 | 技术 |
|---|---|
| 语言 | TypeScript（`strict: true`，ESM only，`"type": "module"`） |
| 运行时 | Node.js `^22.19 || >=24`（CI 覆盖 22.19 / 24 / 26） |
| 包管理 | pnpm 11.7.0 workspaces（Corepack 启用） |
| 插件框架 | vendored Cordis 4.0.0-rc.7（`vendor/`，重定域为 `@deepseek-ai/*`） |
| 构建 | tsc Project References（Host/Client 双聚合）+ tsdown 打包 + Vite（Web 前端） |
| 测试 | Vitest（单元 / 覆盖率门禁 / e2e / snapshot / web） |
| Lint/静态 | oxlint + oxlint-tsgolint、jscpd（重复代码）、knip、publint |
| 数据 | node:sqlite（内置 SQLite）、JSONL+zstd（会话日志）、Zod（Typert schema） |
| 其他语言面 | Python SDK（`python/`）、原生 addon（`native/landlock-run`，Landlock 沙箱启动器） |

## 3. 仓库布局

```text
vendor/      Vendored Cordis 源码（9 个包，manifest + 同步程序见 vendor/README.md）
packages/    @deepseek-ai/dsh-* 工作区，按 packages/<group>/<pkg>/ 组织（约 50 组、170+ 包）
  core/        产品 API 主干：session、system-prompt、tools、agent、agent-loop、scope
  llm/         LLM 能力族：抽象服务 + deepseek/pi-ai 适配器 + retry + token-meter
  api/         远程 BFF 组装与 Typert RPC 网关（gateway、remotes）
  typert/      类型图生成器/加载器/协议/运行时注册表（@Remote RPC 基础设施）
  session/     会话数据面：持久化(JSONL/SQLite)、投影、标题、遥测、检查点策略（14 包）
  session-query/ 会话检索族：查询引擎、FTS5、模型工具、日志导出
  storage/     非会话存储 hub：json / sqlite 后端 + domain 数据形式
  settings/    用户设置 seam + 文件 provider
  credentials/ 凭据引用 seam + env/.env provider
  workspace/   工作区实体注册表
  identity/    匿名身份
  shell/       bash/pwsh 能力族（executor seam、本地/沙箱 provider、模型工具）
  subprocess/  子进程能力 seam + 本地进程树 provider
  terminal/    持久 PTY 能力族
  fs/          文件系统能力族（seam、local/sandbox provider、read/write/edit/glob/grep 工具）
  sandbox/     进程围禁 seam：bwrap / Landlock / Seatbelt / Windows ACL 后端
  lsp/         LSP 能力族：seam、stdio provider、lsp 工具
  code-runtime/ 代码执行能力：worker-thread provider（Code Mode）
  skill/       skill 注册表 + 文件系统 provider + 模型工具
  compaction/  上下文压缩族
  context/     模型可见请求上下文（AGENTS.md 指令、时间、tmux、会话引用）
  subagent/    子代理能力：注册表 + 7 种 provider + 模型工具
  jobs/        后台任务运行时 + job_* 工具
  workflow/    工作流引擎（worker-thread）+ workflow/ralph 工具
  web/         web 能力：seam、search/fetch provider、web 工具
  attachment/  附件身份与内容寻址存储
  spill/       超限输出外溢存储
  todo/ plan/ goal/ schedule/ feedback/   待办/计划模式/目标/定时/反馈
  preset/      预设 per-session 智能体组合（agent-presets、persona）
  guard/       循环防护（重复提醒、工具超时）
  extensions/  自修改能力（agent 检查/挂载自身插件：cordis runner + 工具 + UI）
  hooks/       Claude Code / Codex hook 桥 + 线协议库
  mcp/         MCP 客户端桥
  interaction/ 人机协作面：commands、approval、user-questions、ask-user、permission-presets
  bundle/      可安装的 dsh --profile 补丁层（base、headless、web-app）
  boot/        共享启动胶水（app-boot、cmdline）
  host/        Web GUI 的 Node 宿主半（webserver、apiproxy、前端静态、插件清单、目录选择器）
  client/      Web GUI 的浏览器半（runtime、connection、modules、hmr、约 30 个 ui-* 插件）
  sdk/         进程外运行时 SDK：JSON-RPC 协议、TS 客户端、服务器插件
  acp/         automation-only Agent Client Protocol 服务器
  e2b/         E2B 远端沙箱 POC（e2b owner + fs/subprocess provider）
  examples/    演示 bundle（agent-spine-demo、acp-demo、jsonrpc-demo）
  test-support/ 测试基础设施（testkit、回放、mock LLM、快照、Loader 冒烟）
  runtime-diagnostics/ 运行时不变量注册表（invariants，几乎被所有包 peer 依赖）
  util/        零依赖工具（atomic-write、brand、home-paths、timeout 等 7 包）
apps/        应用入口：apps/cli（dsh CLI）、apps/web（浏览器前端薄入口）
python/      Python SDK 与捆绑运行时（sdk + sdk-runtime 双包）
native/      @deepseek-ai/node-addon-landlock-run 源码记录处
examples/    顶层可运行 cordis.yml 叶子（headless-agent、acp-agent、web-cordis 等）
docs/        架构、生成目录、postmortem、cookbook（双语 zh/en 配对）
website/     VitePress 文档站投影
scripts/     仓库门禁与生成器（约 90 个脚本，run-gates.ts 为调度核心）
.agents/     Agent 工作流与 Agent Notes（设计决策记录）
```

## 4. 规模速览

- pnpm workspace 内约 **170+ 个 `@deepseek-ai/dsh-*` 包**，外加 9 个 vendored 包、2 个应用入口、Python 双包、1 个原生 addon 家族。
- 完整包间依赖图由脚本生成并门禁保鲜：`docs/module-graph.md`（`pnpm run gen-module-graph`）。
- 每个包的 `package.json` 通过 `dsh` 字段声明产品集成元数据：`dsh.profile`（profile 列出 bundle）、`dsh.bundle`（bundle 指向补丁文件）、`dsh.client`（浏览器 roster 行）。

## 5. 关键概念速查

| 概念 | 含义 | 详见 |
|---|---|---|
| Cordis | vendored 插件框架：插件实现 Service、经 `inject` 声明依赖、以 `ctx.<key>` 发现服务、事件四种派发模式（emit/waterfall/parallel/serial） | [02-整体架构](02-architecture.md) |
| Session Event Log | append-only 事件日志，模型历史由 `deriveMessages()` 投影而来 | [03](03-core-llm.md)、[06](06-session-data-plane.md) |
| Turn / Step | 一次 turn = 零或多步；一步 = 一次模型请求 + 其工具调用 | [02-整体架构](02-architecture.md) |
| 能力 Seam | Service Definition / Provider / Consumer 三角色组成一个可替换能力 | [02-整体架构](02-architecture.md) |
| Profile / Bundle | 启动时按层组合出的 Cordis 插件树；bundle 是可分发的补丁层 | [02](02-architecture.md)、[07](07-assembly-runtime.md) |
| Typert | 构建期类型图分析器 + 运行时反射注册表，支撑 Host→Client 的类型化 RPC（`@Remote`/`@RemoteScope`） | [06](06-session-data-plane.md)、[07](07-assembly-runtime.md) |
| Scope | 带标签的子上下文原语，支撑"注册沿链继承、事件沿链向上"的 per-agent 视图 | [03](03-core-llm.md) |
| Harness Home | `$DSH_HOME`（默认 `~/.dsh`）：settings、credentials、profiles、attachments 等用户数据根 | [06](06-session-data-plane.md) |

## 6. 仓库约定摘录（影响读码）

- 包命名一律 `@deepseek-ai/dsh-<name>`；跨包用包名导入，包内相对导入用 `.ts`。
- **注册即效果**：一切贡献经 `ctx.effect()` / `ctx.on()`，注册返回 disposer。
- 闭集 union 的 switch 必须以 `assertNever` 收尾；merge 可扩展 union 走带注释的 default。
- Waterfall 监听器必须调用 `next()` 委托，否则短路整个链。
- 部署可变的调优项必须是可在 cordis.yml 配置的 `Config` 字段；协议常量与安全不变量除外。
- 不透明跨边界 id 用 `Branded<B>`（`dsh-brand`），不用裸 string。
- 误导配置必须尽早响亮失败，绝不静默跳过。
- 非平凡变更必须同 PR 附 Agent Note（`.agents/notes/`）。
