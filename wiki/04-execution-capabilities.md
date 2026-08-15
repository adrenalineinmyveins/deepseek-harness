# 04 执行能力族

覆盖 `subprocess / shell / terminal / fs / sandbox / lsp / code-runtime / e2b / mcp` 九组——一切"模型能借以触碰世界"的执行能力。

## 0. 同 seam 双 Provider 对仗

| Seam | 本地 Provider | 沙箱/远端 Provider |
|---|---|---|
| `ctx.subprocess` | `subprocess-local`（detached 进程树 + node-pty） | `subprocess-e2b`（远端沙箱） |
| `ctx.fs` | `fs-local` | `fs-sandbox`（本地策略围栏）、`fs-e2b`（远端） |
| `ctx.shell` | `bash-local` / `pwsh-local` | `bash-sandbox` / `pwsh-sandbox`（argv 交给 `ctx.sandbox.confine`） |
| `ctx.terminals` | `terminal-bash` | —（受限模式经 sandbox confine） |
| `ctx.sandbox` | `sandbox-local`（bwrap/Landlock/Seatbelt 三平台） | `sandbox-windows-acl`（win32 档） |

所有差异封在 Provider 内；Consumer（`tool-*`）与 Service Definition 不动。**换一个 Provider = 换整个执行世界**：fs 与 subprocess 共享执行世界，指向 E2B 后 Bash、PTY、LSP 一起远端化。

## 1. subprocess 组

### subprocess/subprocess（Service Definition，模板所有者）

- **ctx `ctx.subprocess`**；抽象类 `SubprocessRuntime`：`resolveExecutable(command, env?, signal?)`、`spawn(spec)`、`spawnTerminal(spec)`
- 关键导出（`src/index.ts`/`types.ts`）：`scrubbedParentEnv()` + `SENSITIVE_ENV_PATTERN`（全仓唯一环境清洗定义）、`DSH_ENV_PREFIX`
- `SubprocessSpawnSpec` 全显式（argv/cwd/stdio/graceMs/signal/env），seam 零默认——**request/spec 分离模板的所有者**：argv 从不被 shell 解释，要 shell 自己传 `['bash','-c',command]`
- `SubprocessHandle`：pid/stdin/stdout/stderr/collected/done/`terminate()`/`waitForExit()`；终止只有 `terminate()` 一个动词：树级 SIGTERM → graceMs → SIGKILL
- `SubprocessTerminalHandle`：write / inspectForeground / signalForeground / terminate（PTY 唯一原语）

### subprocess/subprocess-local（Provider）

- `LocalSubprocessRuntime`（无 config；处置与限额由调用 seam 传入）
- POSIX `detached`（独立进程组）、信号发负 pgid；Windows `taskkill /PID <pid> /T /F`
- collect 模式：内存尾部 tail + 可选全量 spill 文件（0600）；`spawnTerminal` 用 `nodePty.spawn()`；host-exit 时对存活树同步 SIGKILL（不建 promise/timer）
- 核心在 `src/spawn.ts`

## 2. shell 组

### shell/shell（Service Definition）

- **ctx `ctx.shell`**；抽象类 `ShellExecutor`：`resolve(request): ShellExecSpec`、`run(spec)`、`start(spec)`；虚 getter `sandboxMode`
- **request/spec 分离的具名范例**：`ShellExecRequest`（command/workdir?/timeoutMs?/stdoutMaxBytes?/signal?/stdin?/env?/dshEnv?/sandboxPolicy?）→ `resolve()` 填充为全显式 spec；`run()` 仅基础设施失败 reject，非零退出/超时杀/中止杀都以 `ShellRunResult` resolve
- 导出 `parseExitStatus`（`[exit code: N]` 标记的反函数）、`SHELL_SETTINGS_NAMESPACE`

### bash-local / pwsh-local（本地 Provider）

- `LocalBashExecutor extends ShellExecutor`（`inject=['subprocess']`）：每调用 spawn `bash -c` 托管进程组；Config：timeoutMs=120s/maxTimeoutMs=600s/maxOutputBytes=64k/graceMs=3s；`ENV_OVERRIDES`（NO_COLOR/TERM=dumb/PAGER=cat）；protected 钩子 `runArgv()/startArgv()/onProcessDone()` 供沙箱子类复用（argv 级 seam）
- `PwshLocalExecutor`：`pwsh -NoLogo -NoProfile -NonInteractive -Command <command>`；`ENCODING_PREAMBLE` 前置 UTF-8 编码设置；可执行解析 `resolvePwshPath`（`src/resolve.ts` 纯函数）

### bash-sandbox / pwsh-sandbox（沙箱 Provider）

- `SandboxBashExecutor extends LocalBashExecutor`（`inject=['subprocess','sandbox','sandboxPolicy']`）：把将要 spawn 的 `['bash','-c',command]` 原样交给 `ctx.sandbox.confine(argv, policy)`，直接 spawn 返回的 argv；`danger-full-access` 绕过 provider；拒绝是结果事实（`result.sandbox.denied`，按后端 `denialSignatures` 从 stderr 推断）；runner 启动失败抛 `SandboxUnavailableError`
- `SandboxPwshExecutor` 为 pwsh 孪生

### shell-env

- **ctx `ctx.shellEnv`**；`ShellEnvRegistry`：受信 `DSH_*` 环境注册表（内置 `DSH_HOME`/`DSH_SHELL`/`DSH_SESSION_ID`）；快照经 `ShellExecRequest.dshEnv` 传递；本地执行器先清除继承的 `DSH_*` 再合并

### 模型工具 Consumer

| 包 | 工具名 | 要点 |
|---|---|---|
| shell/tool-bash | `bash` | workdir 默认取 agent session `header.cwd`；后台进程经 `ctx.jobs.start()` 注册（job_output/job_list/job_kill 控制）；沙箱执行器在场才广告 `sandbox_permissions` 升级字段；`tool:bash` prompt section（order 105） |
| shell/tool-pwsh | `pwsh` | 与 tool-bash 逐调用镜像，PowerShell 方言契约 |
| shell/tool-bash-persistent | `bash`（同名不同插件） | 一个 owner 级 `ctx.terminals` 会话之上的持久 shell；`wrapCommand()` 用随机 nonce 标记切出命令输出与 `$?`；超时/exit/取消重置 shell |

## 3. terminal 组

- **terminal/terminal**（SD）：**ctx `ctx.terminals`**；`TerminalSessionService`——会话 id 铸造、后端路由、按 Agent 围栏、awaited 清理；`TerminalSessionId`（branded）；错误如 `FOREIGN_SESSION`/`SEND_ACTIVE`/`OWNER_NOT_LIVE`
- **terminal/terminal-bash**（Provider）：`ctx.subprocess.spawnTerminal` 之上的持久 bash PTY；`LocalPtySession`（`src/session.ts`）；受限模式把 shell argv 经 `ctx.sandbox.confine()` 包装；readiness = 私有 PS1 标记 + stdin-wait 事实 + 静默回退 + 绝对超时；send 取消对前台组发真 SIGINT
- **terminal/tool-terminal**（Consumer）：六个工具 **`terminal_open / terminal_send / terminal_read / terminal_signal / terminal_close / terminal_list`**；每个操作校验发起 Agent 身份；`terminal_send(run_in_background:true)` 复用 `ctx.jobs`（JobKind `'pty-send'`）

## 4. fs 组（四层栈）

```text
Consumer 层   tool-fs / tool-fs-search / tool-str-replace-editor   （模型工具）
Policy 层     fs-observation-policy（观察态 + 版本守卫，纯事件）
Provider 层   fs-local / fs-sandbox / fs-e2b
Contract 层   fs（Service Definition + fs/* 事件词汇）
```

### fs/fs（Service Definition）

- **ctx `ctx.fs`**；抽象类 `FileSystem`，12 个原语：`resolve / processPath / fileUrl / contains / stat / lstat / readText / streamText / readBytes / listDir / writeText / editText`
- `FsTargetKey`/`FsVersion` 为 branded；`FsWriteIntent`（`createIfAbsent`/`replaceIfVersion`，可选版本守卫）；`FsError` + 12 个稳定错误码（FS_NOT_FOUND/FS_STALE_VERSION/FS_NOT_OBSERVED/FS_AMBIGUOUS_EDIT…）
- 三个事件：`fs/write-intent`、`fs/edit-intent`（单槽决策 waterfall，不调 `next()` 即决策）、`fs/observed`（fire-and-forget，`FsObservation` = present@version | absent）

### fs-local（Provider）

- `LocalFileSystem extends FileSystem`；`targetKey` = realpath 身份（symlink 别名共享守卫）；`version` = `dev:ino:size:mtimeNs:ctimeNs` 派生 token；原子写 = 独占 `wx 0600` 临时文件 + fsync + rename；`createIfAbsent` 用 hardlink 原子 no-replace；per-targetKey 变异锁（FIFO）；原始 I/O 在 `src/fsio.ts`（Cordis-free 独立测试）

### fs-sandbox（Provider，策略围栏）

- `SandboxedFileSystem extends LocalFileSystem`（`inject=['sandboxPolicy']`）：仅在 `writeText`/`editText` 加 per-call 模式围栏——`read-only` 全拒、`workspace-write` 用共享 `writableRoots()` + `isPathUnder`（`src/containment.ts`，词法快路径 + 身份回退）、`danger-full-access` 直通。定位是"可信代码里的策略围栏，非内核边界"

### fs-observation-policy（Policy 层）

- `ObservedStateGate`：WeakMap 按 session 记录观察态；监听三个 `fs/*` 事件实现 read-before-edit + 版本 CAS。可拔插：卸载后工具回落裸 provider 无条件写

### 模型工具 Consumer

| 包 | 工具 | 要点 |
|---|---|---|
| fs/tool-fs | `read`（offset/limit 窗口）、`read_image`、`write`、`edit`（old_string/new_string） | 写/编辑经 `fs/write-intent`/`fs/edit-intent` waterfall 取守卫再调 seam，最后 emit `fs/observed` |
| fs/tool-fs-search | `glob`、`grep` | 打包 `@vscode/ripgrep` 二进制（不走 ctx.fs、不走系统 rg）；固定 argv 防 `RIPGREG_CONFIG_PATH` 注入；超 cap 经 `ctx.spillStore` 外溢 |
| fs/tool-str-replace-editor | `str_replace_editor`（view/create/str_replace/insert） | SWE-agent 风格；每次 mutation 解析当前 session 沙箱策略并走 intent 事件；view 用 `cat -n` 式行号且保留 tab |

## 5. sandbox 组

### sandbox/sandbox（Service Definition）

- **ctx `ctx.sandbox`**；抽象类 `SandboxProvider`，唯一方法 **`confine(argv, policy): ConfinedArgv`**——返回"替代你自己的 argv 去 spawn"+ enforcement 完整度 + 该后端拒绝方言 + runner 失败规则；无后端可用时 throw（fail-closed）
- 词汇：`SandboxMode`（read-only / workspace-write / danger-full-access）、`SandboxExecutionPolicy`（mode+workspaceRoot+sessionId，**逐调用**）
- 同世界限定：容器/微 VM/远端不是本 seam 的 backend，而是整体替换 `ctx.shell`/`ctx.fs` 的 Provider（E2B 走的就是这条路）

### sandbox/sandbox-local（Provider：平台 runner 链）

`LocalSandboxProvider` + `src/profiles.ts` 的四个后端，统一包装契约 `[runner, ...profileArgs, '--', ...callerArgv]`：

| 平台 | 后端 | profile 机制 | 拒绝方言 |
|---|---|---|---|
| Linux（首选） | bwrap | `--ro-bind / / --dev /dev --proc /proc --die-with-parent` + workspace-write 追加 bind | EROFS 文本 |
| Linux（次选） | Landlock（`native/landlock-run` 原生 addon） | `landlockGrantArgs({readOnly:['/'], readWrite:[...]})` | EACCES |
| macOS | Seatbelt（`sandbox-exec -p`） | SBPL profile `(deny file-write*)` + subpath 允许列表 | EPERM |
| Windows | ACL runner（`sandbox-windows-acl`） | `node runner.js --workspace ... --mode ... -- <argv>`（受限令牌） | runner 失败规则 |

功能探测（`spawnSync` 跑真实 profile + `true`）仲裁多候选；旧内核 Landlock ABI → `enforcement: 'partial'`。

### sandbox/sandbox-policy

- **ctx `ctx.sandboxPolicy`**；`SandboxPolicyService`：`resolve({session?, mode?})`（优先级：显式批准 > session `sandbox/mode` 事件 fold > defaultMode）；`setSandboxMode(session, mode)` 写路径 = 恰追加一个 `sandbox/mode` 日志事件。fs/bash/terminal 三个强制家族读同一 resolve 结果

### sandbox/sandbox-windows-acl

- koffi FFI 实现的 Windows 写限制后端：复制调用方 token 为 `WRITE_RESTRICTED` 受限令牌；`workspaceWriteSid`（确定性 per-workspace SID）、`tempWriteSid`（每 session 随机私有 temp）；`enforcement: 'partial'`（Everyone 写权与 NTFS hard link 是边界）
- 关键导出：`AclSandbox`、`workspaceWriteSid`/`tempWriteSid`（`src/workspace-sid.ts`）、`Win32Error`；FFI 层 `src/ffi.ts`/`src/win32-abi.ts`（结构体尺寸对 `verify/abi-probe.cpp` 断言）

## 6. lsp 组

- **lsp/lsp**（SD）：**ctx `ctx.lsp`**；类 `Lsp`——`registerProvider(provider)`（branded `LspProviderId` + 归一化扩展名排他所有权）、`query(request, signal?)`（按文件最终扩展名选 provider）；四个操作：`goToDefinition` / `findReferences` / `goToImplementation` / `hover`；无 JSON-RPC 逃生口
- **lsp/lsp-stdio**（Provider）：通用 stdio 语言服务器宿主；每 `(server id, workspace)` 惰性 single-flight 一个服务器进程；每查询 transient-open（didOpen 全文 → 请求 → didClose）；协议帧 `src/framing.ts`；读源码经 `ctx.fs` 流式保证与执行世界同域
- **lsp/tool-lsp**（Consumer）：只读工具 **`lsp`**（operation/file_path/line/character）；Config maxLocations=100/maxResultChars=16000/timeoutMs=60000

## 7. code-runtime 组（Code Mode）

- **code-runtime/code-runtime**（SD）：**ctx `ctx.codeRuntime`**；抽象类 `CodeRuntime`——`run(request)` 对一组宿主异步绑定运行模型写的程序返回 `{value, logs, error?}`（一切程序结局都 resolve，仅契约误用 reject）；`language: 'typescript'|'python'`
- **code-runtime/code-runtime-worker-thread**（Provider）：`WorkerThreadCodeRuntime`——每次 run 一个全新 Node Worker（host 侧 `stripTypeScriptTypes` 类型剥离）；消息端口桥接绑定（端口假设敌对 peer，逐条校验）；双预算（ELU 忙时轮询 25ms + 墙钟兜底）汇入 `worker.terminate()`。**遏制而非安全边界**（信任姿态 = bash 等价）

## 8. e2b 组（POC：远端执行世界）

- **e2b/e2b**：**ctx `ctx.e2b`**；`E2BRuntime`——单个 E2B 沙箱的共享生命周期所有者（pin `e2b@2.29.1`）；Config：apiKey/env 回退 `E2B_API_KEY`、cwd=`/home/user/workspace`、timeoutMs=300000（到期删沙箱）
- **e2b/fs-e2b**：`E2BFileSystem extends FileSystem`——canonical 身份用 GNU `realpath -mz` + NUL 帧传输；版本 = E2B metadata + `dsh-version` xattr 的不透明 hash；写 = 远端 staging 目录 + 同文件系统原子 rename；不与宿主工作区同步
- **e2b/subprocess-e2b**：`E2BSubprocessRuntime extends SubprocessRuntime`——现有 Bash/PTY/LSP Consumer 无需改动即在共享远端沙箱执行；远端 `exec setsid --wait` 启动并发布真实 PGID；终止对负 PGID SIGTERM→SIGKILL→SDK kill 回退；stdio 以 NDJSON base64 帧跨 SDK 回调边界增量还原

## 9. mcp/mcp-client — MCP 客户端桥

- 纯 Consumer 插件（`inject=['tools']`）：连接外部 MCP 服务器（stdio 或 streamable-http）并把其工具注册到 `ctx.tools`
- 工具命名：`mcp__<serverName>__<rawName>`（归一化到 64 字符；改名/截断追加确定性 12 位 hex hash 防碰撞）
- 行为：连接后整代注册工具；`tools/list_changed` 通知触发整代替换；断连 supervisor 指数退避重启，预算耗尽注销停止；执行走 `client.callTool`（公开名从不上 wire）
