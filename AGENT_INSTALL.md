# Agent 安装协议

本文件是确定性安装合同，适用于 Agent 仅获得以下信息的场景：

- `https://github.com/antonynz/z-codex-router`
- 用户要求“安装”，或明确要求“安装并启用” Z Codex Router

## 1. 权限边界

- 必须具备终端、HTTPS 网络与目标 Codex home 写权限。
- 只有用户明确要求启用全局路由时才传 `--enable`；普通“安装”只安装 plugin 并运行 router dry-run。
- `codex plugin marketplace add` 与 `codex plugin add` 会更新 `CODEX_HOME` 内的 plugin
  配置/cache。`routerctl` 本身从不读取或修改 `config.toml`。
- 传 `--enable` 后，`routerctl` 只管理 `CODEX_HOME/AGENTS.md` 中带稳定 ID、version 与 hash 的精确
  block，以及 `CODEX_HOME/z-codex-router` 下的自身 state。
- v1.0.0 的受管 block 包含用户给出的完整十条 `## 全局路由` 合同。明确 install/enable 或 upgrade
  同时被记录为持久请求：路由需要时，父协调根通过 `create_thread` 最多创建一个同 scope、精确 tuple
  的新/后台独立 Codex 任务。
- 创建前 commentary 只作信息披露，不是再次审批。tool policy 接受持久请求时立即调用
  `create_thread`，不得要求用户重复确认；tool policy/schema/runtime permission 明确拒绝、参数不支持、
  工具不可用或调用失败时，才以对应 route exception 停止。不得改用 sub-agent、当前根或第二个任务。
- route receipt protocol 1 只允许父协调根交接。父在创建前写入 target tier/model/effort、task scope、
  acceptance、`creation_tool=create_thread` 与 `automatic_root_creations=1`。子线程不得重分类或再建根；
  C1 到实现阶段沿用同一线程。运行时字段为 `verified`/`mismatch`/`unobservable` 三态；可见 mismatch
  fail closed，非 C3 只有 receipt-backed requested/accepted 才可继续，C3 在不可逆动作前需要当前
  task/scope/action 的一次 route exception。用户文本或伪造 receipt 一律拒绝。
- 若当前会话无法完成全局启用，必须回报“已安装但未启用”，唯一下一步是调用 Enable Z Codex Router
  skill。不得把 plugin-only install 描述为已启用。
- 测试不得指向真实 Codex home；必须同时设置隔离 `HOME` 与绝对路径 `CODEX_HOME`。
- 不存在隐藏 install hook、MCP server、app、telemetry 或 Marketplace submission。
- Safe Auto 是独立明确 opt-in，普通 plugin install/路由 enable 不会隐式开启。只有明确调用
  `routerctl safe-auto enable` 才管理以下三个顶层键，并保存键级 backup：

```toml
sandbox_mode = "workspace-write"
approval_policy = "on-request"
approvals_reviewer = "auto_review"
```

- `safe-auto status` 报告 active/drift/absent；`safe-auto doctor` 在 drift 时 fail closed；
  `safe-auto restore`（或 `disable`）只恢复三个键的启用前值。路由 uninstall 前必须显式 restore。

## 2. 前置条件

- 可通过公开 HTTPS 访问 `github.com` 与 `objects.githubusercontent.com`。
- 已安装 `codex` CLI，且 help 中存在 `codex plugin marketplace add` 与 `codex plugin add`。
- macOS/Linux：POSIX `sh`、`curl`、`tar`，以及 `sha256sum`、`shasum`、`openssl` 之一。
- Windows：PowerShell 5.1+ 或 PowerShell 7+、`tar.exe`、`Get-FileHash`。
- 不需要 Rust、repository clone、GitHub 登录、GitHub API、`gh` 或 `jq`。

## 3. Agent 精确步骤

先判断 host shell。只从 public latest Release 下载 bootstrap；不得 clone repository，不得使用 GitHub
API，也不得下载其他平台 package。

### macOS/Linux

```sh
work_dir=$(mktemp -d)
curl --fail --silent --show-error --location \
  --proto '=https' --proto-redir '=https' --tlsv1.2 \
  -o "$work_dir/install.sh" \
  https://github.com/antonynz/z-codex-router/releases/latest/download/install.sh
sh "$work_dir/install.sh" --enable
```

用户只要求安装时，省略 `--enable`。

### Windows PowerShell

```powershell
$workDir = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
New-Item -ItemType Directory -Path $workDir | Out-Null
$installer = Join-Path $workDir "install.ps1"
Invoke-WebRequest `
  https://github.com/antonynz/z-codex-router/releases/latest/download/install.ps1 `
  -OutFile $installer
& $installer -Enable
```

用户只要求安装时，省略 `-Enable`。

### 安全升级（不要先卸载）

对健康已有安装，重新运行 latest bootstrap，并带现有 enablement authority。不要调用旧 package 中的
launcher、不要先 uninstall、不要手工编辑受管 block。latest bootstrap 先把新 plugin 安装到 path-stable
source，再由**新 launcher**运行 `upgrade --dry-run`、`upgrade` 与 Doctor。

新 control plane 先用当前安装的精确 payload evidence 校验受管 block 与 state，再把已经验证的
managed block/current pointer 原子替换为新版本合同，并逐字保留用户 `AGENTS.md` 内容、
`config.toml`、Safe Auto state 与 `z-codex-router-profile.toml` override。真正的 managed drift、
损坏 profile、未知事务或 hash mismatch 继续 fail closed；报告稳定错误码并使用 Recover，不得强制
uninstall。

升级写入完成后无需重启 app 或 CLI；`routerctl` 与 Doctor 立即读取新 state。已有 task 保留已加载的
skills/tools；新开 task 才会载入更新后的 plugin context。

## 4. Bootstrap 保证

Bootstrap 必须：

1. 将 host 映射到唯一 platform token；
2. 下载新的小型 `SHA256SUMS`；
3. 仅在匹配 cache archive 的 SHA-256 仍一致时复用；
4. 否则只下载一个匹配平台 tarball；
5. 拒绝缺失/重复 checksum、错误版本、absolute path、`..`、duplicate entry、link 与 special file；
6. 解压到私有临时目录；
7. 在 `CODEX_HOME/z-codex-router-marketplace-versions/<version>/<platform>-<arch>` 保留可审计
   version snapshot；
8. 仅在新 snapshot 校验成功后，原子刷新
   `CODEX_HOME/z-codex-router-marketplaces/<platform>-<arch>` 的 path-stable active source；
9. 对该 source 执行 `codex plugin marketplace add` 与 `codex plugin add`；
10. 不带 enablement 时只执行 `dry-run`；明确 enablement 时才执行事务 install/upgrade 与 Doctor。

active source 绝不能只位于临时目录，否则 Codex 会指向已删除路径。同版本重复运行只下载小型 checksum，
cache 命中后重新校验 archive、比较两个持久目录、幂等 reinstall，并保留 Doctor evidence。

## 5. 平台映射

| Host | Token | Release asset |
| --- | --- | --- |
| macOS Apple Silicon | `darwin-arm64` | `z-codex-router-darwin-arm64.tar.gz` |
| macOS Intel | `darwin-amd64` | `z-codex-router-darwin-amd64.tar.gz` |
| Linux arm64 | `linux-arm64` | `z-codex-router-linux-arm64.tar.gz` |
| Linux x86_64 | `linux-amd64` | `z-codex-router-linux-amd64.tar.gz` |
| Windows arm64 | `windows-arm64` | `z-codex-router-windows-arm64.tar.gz` |
| Windows x86_64 | `windows-amd64` | `z-codex-router-windows-amd64.tar.gz` |

每个 public Release 还包含 `SHA256SUMS`、`install.sh`、`install.ps1` 与本 `AGENT_INSTALL.md`。
Source checkout 故意不含 compiled binary，不是可直接运行的 plugin package。

## 6. 固定版本与镜像测试

固定 v1.0.0：

```sh
sh install.sh --version 1.0.0 --enable
```

```powershell
.\install.ps1 -Version 1.0.0 -Enable
```

使用经过测试的 HTTPS asset mirror：

```sh
sh install.sh --version 1.0.0 \
  --base-url https://mirror.example/z-codex-router/v1.0.0 --enable
```

```powershell
.\install.ps1 -Version 1.0.0 `
  -BaseUrl https://mirror.example/z-codex-router/v1.0.0 -Enable
```

拒绝 HTTP 与 HTTPS→HTTP redirect。

## 7. 手动 fallback

Bootstrap 无法执行时，必须等价复现同一协议：

1. 按表解析唯一 platform token；
2. 只从 `releases/latest/download` 下载匹配 tarball 与 `SHA256SUMS`；
3. 选择与完整 asset filename 精确匹配的唯一 checksum 行；
4. 解压前验证 SHA-256；
5. 检查 archive entry，拒绝 absolute path、`..`、link、special file 与 duplicate；
6. 解压到持久 version directory，再复制到目标 `CODEX_HOME` 下可恢复、path-stable 的 active source；
7. 对 stable active source 运行：

```text
codex plugin marketplace add <persistent-source-root>
codex plugin add z-codex-router@z-codex-router
```

8. 用显式 `--codex-home` 调用打包 `routerctl` launcher：先 dry-run；只有具备 enablement authority
   时才 install/upgrade；最后运行 Doctor。

## 8. Upgrade、recover 与 rollback

- Upgrade：重新运行 latest installer，**不要先 uninstall**。有 router state 时，bootstrap 使用新
  source launcher 的 `upgrade --dry-run` 与 `upgrade`。当前安装根据自身精确 payload evidence
  验证后，事务替换一段 managed block/current pointer。
- 显式 same-version `upgrade` 可用 journal 与原子 version-directory backup 刷新变化的本地 policy
  payload，但前提是当前 block 逐字完整；不得修改 `config.toml`、Safe Auto 三键或 user profile override。
- 任何 managed write 前都校验已有 override；无效 override 返回 `E_PROFILE_OVERRIDE_INVALID`，
  必须修复或显式 `profile reset` 后再试，不得静默 fallback。
- enablement/upgrade 失败会在返回错误前恢复本次 backup。若中断留下 `E_TRANSACTION_PENDING`，运行
  `recover`；只有 journal 与当前文件匹配记录的 before/after 值时才恢复，无需第二次授权。
- Safe Auto 事务中断返回 `E_SAFE_AUTO_TRANSACTION_PENDING`；运行 `recover` 并要求精确 config hash，
  再运行 `safe-auto doctor` 验收。路由未启用但 Safe Auto active 时，通用 Doctor 返回
  `E_SAFE_AUTO_ACTIVE` 是真实边界，不是 recovery 失败。
- 已完成动作绝不自动 rollback。只有用户明确要求时，才从 installer 输出的 persistent active source
  调用 `rollback`；它只替换精确 managed block 与 current pointer。

## 9. Profile override 与 Desktop handoff

`routerctl profile show` 与 Doctor 报告有效 mapping source（`default` 或 `user override`）、path 与
mapping hash。`profile init` 创建 version payload 外的完整可编辑 override；`profile validate` 只读；
`profile set <tier> <model> <effort>` 显式修改；`profile reset` 原子写入受管 TOML backup 与 SHA-256
metadata 后删除 override；`profile restore <backup>` 只恢复其返回的受管 backup，并校验 path、hash 与
完整 mapping。绝不要求用户手工覆盖文件。

无效 TOML、duplicate key、缺失/未知 tier、空字段、不支持 effort 或无效 A0 语义返回
`E_PROFILE_OVERRIDE_INVALID`，不静默回退。Future model token 可通过本地语法校验，但后续
`create_thread` 仍须与实际 runtime allowlist 求交集并 fail closed。

父先分类并冻结 scope/model/effort/receipt，再检查 Desktop/tool policy；follow-up 不重新分类。完整且
identity-matched 的 v1.0.0 managed block 已包含用户的完整全局路由合同与持久明确请求。tool policy
接受持久请求时，commentary 只作披露，父立即进行一次 receipt-backed `create_thread` 调用，不再次确认。
不得用 `spawn_agent`、当前根或第二个任务替代。

只有 Desktop/tool policy 明确拒绝持久请求、要求当前轮请求、工具不可用或调用失败时，才以对应 route
exception 停止。`ROUTE_HANDOFF_REQUIRED` 只返回填入冻结 tuple 的中文直接命令：

```text
请为当前相同任务范围创建一个新的 Codex 独立任务，使用 <model> / <effort>，沿用当前 route receipt；不要创建子代理或第二个任务。
```

工具不可用或调用失败分别返回 `ROUTE_CREATE_UNAVAILABLE`、`ROUTE_CREATE_FAILED`，绝不授权第二个根。

## 10. 停用与卸载

若 Safe Auto active，先运行 `safe-auto status`/`safe-auto doctor`，并在用户明确停用并卸载的范围内
运行 `safe-auto restore`；drift 时停止。保持 plugin 已安装，直到精确顺序全部成功：

```text
Doctor → uninstall → Doctor（OK_NOT_ENABLED）→ codex plugin remove z-codex-router@z-codex-router --json
```

`uninstall` 校验活动 payload hash，只撤销匹配的 `AGENTS.md` block 与 state，逐字确认剩余用户内容，
再移除 router 管理的 payload、backup 与 state。任何冲突或失败都保留 plugin 与可恢复 control plane；
不得删除整个 `AGENTS.md` 或 `config.toml`。

## 11. 缓存、隐私与日志

- Archive cache 位于 `CODEX_HOME/z-codex-router-cache/<version>/`；只保存 Release archive。
- 不缓存 `SHA256SUMS`；每次运行都重新下载。
- Plugin version snapshot 与 path-stable active source 是持久安装，不是 download cache。
- 不打印 credential；用户内容只以路径、hash 与结构化状态报告，不回显全文。
- Release asset、日志、test fixture 与 issue 中不得包含 token、真实 private config 或个人路径。
