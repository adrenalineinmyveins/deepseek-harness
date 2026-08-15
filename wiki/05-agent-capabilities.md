# 05 智能体能力族

覆盖让智能体"更聪明/更可控/更持久"的周边能力：skill、compaction、context、subagent、jobs、workflow、web、attachment、spill、todo、plan、preset、guard、extensions（自修改）、hooks、goal、schedule、feedback、interaction、identity。

## 0. 模型工具与人类命令总览

**模型工具**：`skill`、`subagent`（可改名/多实例）、`send_message`/`interrupt_agent`/`list_agents`、`report`（子作用域）、`job_output`/`job_list`/`job_kill`、`workflow`、`ralph`、`web_search`/`web_fetch`、`todo_write`、`exit_plan_mode`、`cordis_inspect`/`cordis_define`/`cordis_run`/`cordis_stop`/`cordis_undefine`、`get_goal`/`create_goal`/`update_goal`、`schedule_create`/`schedule_list`/`schedule_delete`、`ask_user_question`。

**人类命令**：`/compact`、`/plan`、`/goal`、`/feedback`、`/permissionPresets`。

**durable 化纪律**：所有跨 turn 状态（plan/mode、todo/write、goal/change、schedule/change、subagent/descriptor、compaction/*、command/run|done、hook/*、approval/asked|decided、permissionPresets/preset、feedback/record）都以 log-only `SessionEventMap` 事件存在，恢复/fork/压缩一律从日志 fold；进程本地 activation 明确不持久化。

## 1. skill 组

| 包 | 角色 | 说明 |
|---|---|---|
| skill/skill | SD，**ctx `ctx.skills`** | 纯 provider 注册表（`registerProvider/snapshot/list/get`），不关心技能来源；host+per-scope 分层（`SkillLayer` over dsh-scope）；`renderSkillContent` 渲染技能正文 |
| skill/skill-badge | Provider | 内置固定 `dsh-badge` 技能，默认 disabled |
| skill/skill-filesystem | Provider | 扫描 project/custom/user 五类根（rank 100–500），解析 `SKILL.md`/扁平 Markdown；`SkillWatchManager`（Chokidar）热更新；frontmatter 支持 `disable-model-invocation`/`user-invocable` |
| skill/tool-skill | Consumer | 工具 **`skill`**（参数 name）；`agent/pre-step` 快照 → durable `<available_skills>` 目录（digest 变化才重发）；用户消息中 `/name` 手势注入技能内容 |

## 2. compaction 组

- **compaction/compaction**（SD，**ctx `ctx.compaction`**）：`CompactionEngine`——`compactIfNeeded`（何时压缩）/`compactNow`/`compactRegion`（把旧区间总结为单节点）；`compaction/start|summary|end` log-only 事件 + durable 锁
- **compaction/compaction-basic**（基础后端）：`BasicCompactionEngine extends CompactionEngine`——tokenMeter 压力 + token 预算保留 + 一次性 `llm.stream()` 摘要（回放原前缀复用 KV）；config `thresholdRatio 0.8 / retainRatio 0.16`
- **compaction/compaction-tool-result-pruner**：无模型剪枝——超长 `tool/result` surface 改写为 head+marker+tail（原事件保留在 log）；**ctx `ctx.toolResultPruner`**
- **compaction/command-compact**：人类 `/compact` 命令

## 3. context 组（模型可见请求上下文，全为插件）

- **agent-instructions**：每会话加载 AGENTS.md 兼容链（`$DSH_HOME/AGENTS.md` → 项目根到 cwd 各目录 + `AGENTS.local.md` overlay）；首个 `agent/pre-step` 折入 baseline；read/write/edit 成功 touch 驱动嵌套发现与增/改/删通知
- **session-reference**：**ctx `ctx.sessionReferenceResolver`**——跨会话 `@[label](dsh-session:<base64url>)` 引用 → 有界只读快照
- **time-context**（opt-in）：`agent/pre-step` 注入带时区时间戳 + elapsed
- **tmux-context**（opt-in）：每 turn 第一步经 `ctx.shell` 跑 tmux `display-message`，注入 session/window/pane/layout 三行

## 4. subagent 组（Provider 注册表模式）

- **subagent/subagent**（SD，**ctx `ctx.subagents`**）：`SubagentRuntime`——`registerProvider(provider)`（重名 fail-loud，增删发 `subagent/provider-added|removed` 事件）；`start(name, request)`（one-shot）/`startContinuable(spec)`/`followup`/`interrupt`；每个 Provider 声明 `capabilities`（outputSchema/depthLimit/toolFilter/persona）与 `inheritsParentContext`，service 在建子前拒绝不支持的能力请求
- **7 个 Provider**：

| Provider 包 | 注册名 | 机制 |
|---|---|---|
| subagent-spawn-in-process | `spawn`（默认） | 本进程新 Agent、空白会话 |
| subagent-fork-in-process | `fork` | 以父"已完成 turn 前缀"为种子 |
| subagent-in-process-driver | （共享驱动库，非插件） | `startInProcessRun` + `attachStructuredRuntime`（结构化输出工具）；spawn/fork 共用 |
| subagent-acp | `acp` | 每次运行 spawn 新子进程作 ACP 客户端 |
| subagent-claude-code | `claude-code` | 官方 Claude Agent SDK `query()` |
| subagent-codex | `codex` | spawn `codex app-server --stdio` |
| subagent-dsh-sdk | `dsh-sdk` | 子进程跑完整 harness runtime（stdio JSON-RPC） |

- **3 个 Consumer**：
  - tool-subagent：每实例绑一个 provider + `toolName`（默认 **`subagent`**）；`backgroundMode: one-shot|continuable`；config `maxDepth 3`
  - tool-subagent-control：全局共享 **`send_message` / `interrupt_agent`** + **`list_agents`**（父→子方向）
  - tool-subagent-report：仅 continuable 子代理作用域的 **`report`** 工具（子→父方向）

## 5. jobs 组

- **jobs/jobs**（SD，**ctx `ctx.jobs`**）：`JobRegistry`——`start(spec)/get/list/read/kill/wait/onJobDone/attachController`；owner 相对（SessionId fence）；Producer 插件扩展 `JobKindMap`
- **jobs/jobs-local**（Provider）：`LocalJobRegistry`，进程内 `<kind>-N` id，`maxConcurrentJobsPerOwner 10`
- **jobs/tool-jobs**（Consumer）：**`job_output` / `job_list` / `job_kill`**；完成通知（busy→inject、idle→wake，`maxConsecutiveWakes 3` 限流）

## 6. workflow 组

- **workflow/workflow**（SD，**ctx `ctx.workflowEngine`**）：`WorkflowEngine`——`start(request): WorkflowRun`；observe-only 事件 `workflow/start|end|phase|log|agent-start|agent-end`
- **workflow/workflow-worker-thread**（Provider）：每 run 一个 Node worker；脚本钩子 `agent()/parallel()/pipeline()/phase()/log()`；`src/protocol.ts` host/worker typed 协议、`src/realm.ts` plain-JSON 值边界
- **workflow/tool-workflow**（Consumer）：工具 **`workflow`**（meta/script/args）；同步收集结果
- **workflow/tool-ralph**：工具 **`ralph`**（objective/maxRounds?）——固定前台 workflow 脚本，每轮一个全新子代理 + 结构化 handoff（status continue|complete|blocked），workspace 为长期记忆

## 7. web 组

- **web/web**（SD，**ctx `ctx.web`**）：`WebRuntime`——`registerSearchProvider/registerFetchProvider/search/fetch`；执行时选择策略（显式配置/env 或唯一可用自动选；歧义抛 `WEB_PROVIDER_AMBIGUOUS`）
- Provider：**web-fetch-http**（匿名 HTTP(S)，同源重定向、字节/字符/超时上限；SSRF 防护为 deferred）、**web-search-deepseek**（DeepSeek `/messages` + `web_search_20250305` 服务端工具）、**web-search-exa**、**web-search-perplexity**
- **web/tool-web**（Consumer）：工具 **`web_search(query)` / `web_fetch(url)`**；turndown HTML→markdown；`ToolDefinition.timeoutMs` 声明超时（由 timeout-policy 执行）

## 8. attachment / spill 组（大内容基础设施）

- **attachment**（SD，**ctx `ctx.attachments`**）：`AttachmentStore`——`validateImage/saveImage/readImage`，原子提交不可变图像字节 → `ImageAttachmentRef`（v1: PNG/JPEG/WebP/GIF）；`attachment-local` Provider 落 `<DSH_HOME>/attachments/v1/objects/<sha256前缀>/<sha256>`（硬链接发布）
- **spill**（SD，**ctx `ctx.spillStore`**）：`SpillStore.saveText(input): SpillRef`；`spill-local` Provider 落 `<root>/session-<hash>/<random>-<safeName>`；**spill-policy** Consumer 在 `tools/post-execute` 把超限纯文本结果外溢 + head/tail 预览 + locator 提示

## 9. todo / plan / goal / schedule / feedback（任务状态面）

- **todo/tool-todo**：工具 **`todo_write(todos)`**——整表替换；每调用 append `todo/write` 事件（last-write-wins 重放）；单 agent 作用域
- **plan/plan-mode**：**ctx `ctx.planMode`**；`PlanModeController`——durable `plan/mode {active}` 事件 + `foldPlanMode()`；工具 **`exit_plan_mode`**（经 `ctx.userQuestions` 的 plan-review intent 审批）；命令 **`/plan [message]` / `/plan off`**
- **goal/goal**：**ctx `ctx.goals`**；`GoalService extends TypertRemoteService`——事件溯源同会话目标（create/edit/pause/resume/complete/block/clear + `disarm()` 进程本地 activation）；CAS `GoalRef {id, revision}`；每次变更 append `goal/change` 完整快照
  - goal-round-driver：续跑驱动（idle 检查点 flush + 排队 `<goal_round>` prompt）
  - command-goal：**`/goal`** 命令族；tool-goal：**`get_goal` / `create_goal` / `update_goal`** 工具
- **schedule/schedule**：仅安装到 runtime root Agent；工具 **`schedule_create / schedule_list / schedule_delete`**（`after_seconds` / `at` RFC3339 / `every_seconds` ≥300s）；durable `schedule/change`；投递 = idle 时 `followup()` 排队 `[SCHEDULE REMINDER]` framing
- **feedback**：command-feedback（**`/feedback <text>`** 命令 + log-only `feedback/record`）；message-feedback（**ctx `ctx.messageFeedback`**，Host Remote 逐消息 rating/note sidecar）

## 10. preset / guard / extensions / hooks

- **preset/agent-presets**：**ctx `ctx.agentPresets`**——每 preset = 目录 + `agent.cordis.yml`；standing scope 单次挂载，agent scope key 父链 join（视图解析 `agent→preset→global`）；`agent-preset/selected` 会话事件；copy-only 授权。**preset/persona**：preset 内组合行——shadow 部署 `deployment:persona` section（只能挂 agent scope）
- **guard/repeat-tool-reminder**：`tools/post-execute` 上按 `(tool名, 规范化参数)` 计数连续重复，达阈值 [3,5,8] 注入升级提醒（咨询性，无否决）
- **guard/timeout-policy**：唯一 `tools/execute` around-dispatch wrapper，读 `ToolDefinition.timeoutMs` 融合信号，超时替换为结构化 `TOOL_TIMEOUT` 错误结果
- **extensions（自修改能力）**：agent 检查并改写自身运行时
  - cordis-host-runner：**ctx `ctx.dynamicCordisRunner`**；`DynamicCordisRunnerService extends TypertRemoteService`——两阶段：`define` 只记录（双半语法编译预检）；`run` 生效（host half 在 **`node:vm` sandbox** 求值，可注册 tools/prompt/listeners——即 agent 修改自身运行时）；带 browser half 时 `run` 变为人审 round-trip；卸载经 `stop`/`undefine`
  - cordis-client-runner：browser half 加载器（async 函数体求值 + whitelisting proxy + `loader.create` 挂载/卸载）
  - tool-cordis：工具 **`cordis_inspect / cordis_define / cordis_run / cordis_stop / cordis_undefine`**
  - ui-cordis：浏览器 UI（overlay 面板 + 定义列表 + run/stop/approve）
- **hooks**：hook-protocol（共享库：matcher/runner/codec/merge/events/detached）；hooks-claude-code（7 个 CC hook 点映射到 harness 扩展点，如 `PreToolUse→tools/pre-execute`、`Stop→agent/turn-stopping`）；hooks-codex（5 点，regex-only matcher）

## 11. interaction 组（人机协作面）

- **commands**：**ctx `ctx.commands`**；`CommandRuntime extends TypertRemoteService`——`register/list/find/execute/parseCommand`；durable `command/run|done` 对；agent-scoped 子注入可 shadow 全局同名
- **permission-presets**：**ctx `ctx.permissionPresets`**——`set(session, name)` 打包 `sandbox/mode + approval/policy`（默认 `workspace-write`/`danger-full-access`）；log-only 事件；`/permissionPresets` 命令
- **user-approval**：**ctx `ctx.approval`**；`ApprovalService`——`request(req)` → `allowed-once|rejected|cancelled|unavailable`（缺/坏 answerer fail-closed）；`approval/request` waterfall；`ApprovalPolicy 'ask'|'never'`
- **user-questions**：**ctx `ctx.userQuestions`**；`UserQuestionService`——`registerProvider`（单 provider）/`ask(request)`；`AskUserQuestionIntent {kind:'plan-review', approve}` 展示意
- **tool-ask-user**：工具 **`ask_user_question`**（questions[{question, options[], multi_select?}]）；runtime-owned 子代理被 `DELEGATED_CALLER` 拒绝

## 12. identity/anonymous-user-id

纯库：`getOrCreateAnonymousUserId()`——per-harness-home 随机 UUID v4，持久化 `$DSH_HOME/.anonymous-user-id`；消费方：OTel Resource `user.id`、`/feedback` 确认、`dsh-llm-deepseek` 归因头。
