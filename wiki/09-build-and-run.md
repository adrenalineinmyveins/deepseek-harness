# 09 构建与运行

## 1. 环境要求

- Node.js `^22.19.0 || >=24.0.0`（CI 覆盖 22.19 / 24 / 26）
- Corepack 启用的 pnpm（仓库 pin `pnpm@11.7.0`；`pnpm --version` 不对时 `corepack enable`）
- Git ≥ 2.26（worktree 特定配置扩展）
- 可选：DeepSeek API key（Web/headless/ACP 演示与真实 API e2e）

## 2. 安装与首次校验

```sh
pnpm install        # 同时安装 worktree 本地 Lefthook 钩子与翻译配对 merge driver
pnpm run typecheck  # 完成 Host lib 阶段（含生成的 Typert 契约）后再跑 Client tsc
```

- 若缓存恢复导致 `postinstall` 被跳过，手动 `node scripts/install-lefthook.mjs`。
- setup 完成的标志：`pnpm run typecheck` 成功退出。

## 3. 常用命令

| 命令 | 作用 |
|---|---|
| `pnpm run build` | 完整构建：Host tsc → Host tsdown（Typert 生成）→ Client tsc → Client tsdown → Web |
| `pnpm run typecheck` | 类型检查（含 Host 契约生成） |
| `pnpm run lint` / `lint:fix` | oxlint 静态检查 |
| `pnpm run test` | Vitest 单元测试 |
| `pnpm run test:coverage` | CI 覆盖率门禁（`packages/*/*/src` 每文件 100%） |
| `pnpm run test:e2e` | 真实 API 测试（无 `DEEPSEEK_API_KEY` 自动跳过） |
| `pnpm run test:snapshot` | 无 key 的 ACP/headless 回放快照（`-t <name>` 过滤） |
| `pnpm run test:snapshot:record` | 重录期望输出（需 key） |
| `pnpm run duplication` | jscpd 跨文件克隆检测 |
| `pnpm run hygiene` | knip + publint + workspace constraints + 许可证/包不变位 + cordis 配置校验等 |
| `pnpm run doc-sync` | 全部文档门禁 |
| `pnpm run website:build` | VitePress 文档站构建（兼作死链检查） |
| `pnpm run check:all` | 综合本地 gate 集（可选，独立于 Git 钩子） |

构建顺序细节（Host/Client 双聚合、Typert 时序、api-remotes 例外）见 [07-组装与运行时](07-assembly-runtime.md) §7。

## 4. 环境变量与密钥

```sh
DEEPSEEK_API_KEY=sk-...                 # 真实适配器、演示与 e2e
DEEPSEEK_BASE_URL=https://...           # 可选，默认公共 API
```

也可放在仓库根 gitignored 的 `.env`。分层加载：inherited env > 项目 `.env` > `$DSH_HOME/.env`（`app-boot` 的 `loadLayeredEnv()`）。凭据另有四层解析（env > `$DSH_HOME/.credentials.yaml` > project `.env` > user `.env`），见 [06](06-session-data-plane.md) §4。绝不提交真实凭据。

## 5. 运行方式

### 5.1 dsh CLI（源码检出形态）

```sh
# 一次性 Headless 编码智能体（需要 DEEPSEEK_API_KEY）
pnpm dsh --profile headless "summarize this workspace"

# 查看某 profile 实际启动的插件树（boot-free）
pnpm dsh --profile web --dump-config
```

`dsh` = `node --import tsx/esm apps/cli/src/bin.ts`；launcher flag（`--profile/--patch/--dump-config`）在前，第一个不认识的 token 起归被启动 app（如 `dsh --profile tui --resume abc` 中 `--resume abc` 属于 app）。

### 5.2 Web 应用

```sh
pnpm run build            # 先构建（Web 演示需要 built 产物）
pnpm run dev:web          # 开发模式（tsx scripts/dev-web.ts --poll，含 HMR）
pnpm run demo:cordis      # 自指 cordis 演示（web 默认，agent 检查/修改自身插件运行时）
```

运行形态：Node Host（webserver + `/api` 网关 + 静态前端）+ 浏览器 Client（槽位系统 UI）。架构见 [07](07-assembly-runtime.md) §2。

### 5.3 ACP 自动化服务器

```sh
pnpm run build
pnpm run demo:acp         # ACP JSON-RPC over stdio（需要 DEEPSEEK_API_KEY）
```

### 5.4 JSON-RPC SDK（TS / Python）

```sh
# 仓内 demo bin
node --import tsx packages/examples/jsonrpc-demo/src/bin.ts --config examples/jsonrpc-agent/cordis.yml
```

Python 侧（`python/`，`deepseek-harness-sdk`）：SDK 默认启动匹配的捆绑运行时（`deepseek-harness-runtime-bin`）；参考 `examples/jsonrpc-agent/minimal.py`。

### 5.5 顶层示例（`examples/`）

每个是可直接运行的 cordis.yml 叶子，配 `cordis.snapshot.yml` 供无 key 回放：

```sh
pnpm dsh --profile headless --patch examples/headless-agent/cordis.yml "task"
pnpm dsh --profile web --patch examples/web-schedule/cordis.yml
```

示例：`headless-agent`、`jsonrpc-agent`、`acp-agent`、`web-cordis`、`web-schedule`、`mcp-memory`。

### 5.6 模型服务（测试用）

```sh
pnpm run mock:llm         # 可脚本 OpenAI 兼容故障服务器（--sequence/--seed 等）
```

## 6. 用户数据：Harness Home

`$DSH_HOME`（默认 `~/.dsh`，可显式配置）：

```text
$DSH_HOME/
  settings.yaml           # 用户设置（settings-file provider）
  .credentials.yaml       # 凭据文件层
  .env                    # 用户 env 层
  .anonymous-user-id      # 匿名身份
  profiles/<name>/        # profile：cordis.yml + cordis.patch.yml + node_modules
  agent-presets/          # 用户 preset 根（includeUserRoot）
  attachments/v1/objects/ # 内容寻址图像附件
  skills/                 # 用户 skill 根（skill-filesystem rank 500）
```

## 7. Profile / Bundle 定制

- profile 模板：`web` = `[dsh-base, dsh-web-app]`；`headless` = `[dsh-base, dsh-headless]`
- 补丁栈：bundle 层（按声明序）→ profile `cordis.patch.yml` → home 级 `cordis.patch.yml` → `--patch` overlay → 遥测开关
- 自建 profile/bundle：包 `package.json` 声明 `"dsh": {"profile": {...}}` 或 `"dsh": {"bundle": {"patch": "./cordis.patch.yml"}}`；`dsh plugin` 子命令按已安装 bundle 对账
- 任一 `--dump-config` 打印的行都可被你自己的 patch 按 id 替换

## 8. Git 钩子与 CI

- Lefthook（`lefthook.yml`）：pre-commit 校验翻译配对记录、staged 文件 oxlint 校验+一次有界修复、THIRD_PARTY_NOTICES 再生、空白检查、vendor manifest 守卫；pre-push 跑 `pnpm run typecheck`。钩子刻意不跑测试/构建。
- CI（`.github/workflows/ci.yml`）：PR 必需 lane `node-24`(static) / `node-24-coverage` / `node-24-consumers` / `node-compat`(22.19, 26) / `python-sdk` / `python-runtime` / `windows`(Wine)；另有真实 API 独立 workflow；`all-checks-passed` 是唯一分支保护必需检查
- 本地原则：**跑覆盖改动面的最小检查**——行为改动跑聚焦测试、模型/用户可见输出跑快照、文档跑 `doc-sync`、发布路径跑 build/hygiene、provider 行为跑真实 e2e；绝不默认全量套件（CI 负责穷尽覆盖与平台矩阵）

## 9. 测试策略要点（`docs/testing.md`）

- 覆盖率门禁是 `test:coverage`（每文件 100%），不是 `test`
- 每个非平凡的模型可见/产品用户可见行为变更，须同 PR 通过**真实可运行示例**添加或更新无 key 快照；包测试、e2e 断言、mock fixture 不能替代组装后应用 transcript
- fixture 必须在 macOS/Linux 可重放；修 fixture 而非规范化器
- 能力 seam 须规划单元/e2e/快照三层覆盖
