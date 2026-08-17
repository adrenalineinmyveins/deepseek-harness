# DeepSeek Harness Code Wiki

本目录是对 **deepseek-harness** 仓库的完整代码 Wiki，面向需要快速理解并上手该项目的工程师。全部内容基于仓库当前源码整理，文件内的代码路径均为仓库相对路径。

## 项目一句话介绍

DeepSeek Harness（`dsh`）是一个基于 vendored Cordis 插件框架构建的**智能体运行时（Agent Harness）**：模型适配器、工具注册表、会话日志、智能体循环本身全部是插件，一切皆可通过配置组合与替换。它提供 Web UI、Headless CLI、ACP、JSON-RPC SDK 等多种宿主形态，以及 Bash、文件系统、LSP、子代理、工作流等一整套模型可见能力。

## 文档导航

| 文档 | 内容 |
|---|---|
| [01-项目概览](01-overview.md) | 项目定位、技术栈、仓库布局、规模与关键概念速查 |
| [02-整体架构](02-architecture.md) | Cordis 框架、Profile/Bundle 装配、事件体系、Turn/Step 生命周期、能力 Seam、会话日志不变量 |
| [03-核心主干与 LLM](03-core-llm.md) | `core/*`（session、system-prompt、tools、agent、agent-loop 等）与 `llm/*` 详解 |
| [04-执行能力族](04-execution-capabilities.md) | subprocess、shell、terminal、fs、sandbox、lsp、code-runtime、e2b、mcp |
| [05-智能体能力族](05-agent-capabilities.md) | skill、compaction、context、subagent、jobs、workflow、web、plan、goal、interaction 等 |
| [06-会话数据面与基础设施](06-session-data-plane.md) | session 持久化/投影/遥测、session-query、storage、settings、credentials、typert、util |
| [07-组装与运行时](07-assembly-runtime.md) | bundle、boot、api 网关、host、client、sdk、acp、apps、vendor、python、native、website |
| [08-依赖关系](08-dependencies.md) | 包间依赖分层、依赖规则、关键依赖链 |
| [09-构建与运行](09-build-and-run.md) | 环境要求、安装、构建、测试门禁、各形态运行方式 |
| [10-Linux 容器化部署](10-linux-container-deploy.md) | Dockerfile + docker-compose、webserver host 覆盖、环境变量、持久化、安全注意 |

## 阅读建议

- **想跑起来**：直接看 [09-构建与运行](09-build-and-run.md)。
- **想理解整体设计**：按 [02-整体架构](02-architecture.md) → [03-核心主干与 LLM](03-core-llm.md) 顺序阅读。
- **想找某个功能的实现**：先查 [04](04-execution-capabilities.md) / [05](05-agent-capabilities.md) / [06](06-session-data-plane.md) 的能力族表格，再跳转对应包。
- **想加新功能**：[02-整体架构](02-architecture.md) 末尾的"新行为的落点"表给出每种扩展目标对应的机制。

## 权威文档索引（仓库内）

本 Wiki 是对仓库自带文档的再组织，深入细节时可回源：

- 架构总览：`docs/architecture.md`（含中文版 `.zh.md`）
- Cordis 入门：`docs/cordis-primer.md`、教程 `docs/cordis-tutorial/index.md`
- 开发指南：`docs/development.md`、测试策略 `docs/testing.md`
- 生成目录：`docs/module-graph.md`（包依赖图）、`docs/tool-catalog.md`（工具目录）、`docs/config-catalog.md`（配置目录）、`docs/event-producer-consumer.md`（事件生产/消费表）
- 扩展手册：`docs/cookbook/extension-cookbook.md`（加包/加工具/加 LLM 适配器/加 Chat 节点）
- 子系统参考：`docs/subsystems/*.md`
- 设计决策：`.agents/notes/implemented/**/*.md`（Agent Notes）
