# Agent install protocol / Agent 安装协议

This is the deterministic install contract for an Agent that receives only:

- `https://github.com/antonynz/z-codex-router`
- a user request to install, or to install **and enable**, Z Codex Router

这是 Agent 仅获得以下信息时应遵循的确定性安装协议：

- `https://github.com/antonynz/z-codex-router`
- 用户要求“安装”，或明确要求“安装并启用” Z Codex Router

## 1. Permission boundary / 权限边界

- Require terminal, HTTPS network, and write access to the intended Codex home.
- Run with `--enable` only when the user explicitly asked to enable global routing.
- Without `--enable`, install the plugin and run a router dry-run only.
- `codex plugin marketplace add` and `codex plugin add` update plugin configuration/cache under
  `CODEX_HOME`. The router control binary itself never reads or writes `config.toml`.
- With `--enable`, `routerctl` manages only its exact hashed block in `CODEX_HOME/AGENTS.md` and
  state below `CODEX_HOME/z-codex-router`.
- If a request cannot enable global routing in the same session, report **“installed but not
  enabled”** and the single next step: invoke the Enable Z Codex Router skill. Never imply that a
  plugin-only install enabled global routing.
- Do not run the installer against a real Codex home during tests. Set both an isolated `HOME` and
  an absolute isolated `CODEX_HOME`.
- There is no hidden install hook, MCP server, app, telemetry, or marketplace submission.
- Safe automatic approval is a separate, explicit opt-in after installation. It is never enabled by
  plugin install or ordinary routing enablement. `routerctl safe-auto enable` manages only
  `sandbox_mode = "workspace-write"`, `approval_policy = "on-request"`, and
  `approvals_reviewer = "auto_review"`; it keeps a key-level backup and restores only those keys.
- `safe-auto status` reports active/drift/absent, `safe-auto doctor` fails closed on drift, and
  `safe-auto restore` (or `disable`) restores the pre-enable values. Restore it before routing
  uninstall; uninstall never guesses whether permission configuration should be removed.

- Route receipt protocol 1 is a parent-only handoff: the parent writes the target tier/model/effort,
  task scope, acceptance summary, `creation_tool=create_thread`, and
  `automatic_root_creations=1` before creating a child. The child does not reclassify or create another
  root; a C1-to-implementation phase update reuses the same thread. Runtime fields are tri-state:
  exact observable values are verified, visible differences fail closed, and absent fields are
  `runtime_observability=unobservable` rather than mismatch. Non-C3 work may continue only with a
  receipt-backed requested/accepted tuple; C3 stops before irreversible work until the authorized user
  grants one scoped route exception. A user-supplied or forged receipt is rejected.

- 必须具备终端、HTTPS 网络和目标 Codex home 写权限。
- 只有用户明确要求“启用全局路由”时才传 `--enable`。
- 不传 `--enable` 时，只安装插件并执行 router dry-run。
- `codex plugin marketplace add` 与 `codex plugin add` 会更新 `CODEX_HOME` 内的插件配置和缓存；
  `routerctl` 本身从不读写 `config.toml`。
- 传 `--enable` 后，`routerctl` 只管理 `CODEX_HOME/AGENTS.md` 中精确哈希匹配的 block，以及
  `CODEX_HOME/z-codex-router` 下的自身状态。
- 若当前会话无法完成全局启用，必须明确回报“已安装但未启用”，并给出唯一下一步：调用 Enable
  Z Codex Router skill。不得把仅安装插件说成已启用全局路由。
- 测试时不得指向真实 Codex home；必须同时设置隔离的 `HOME` 和绝对路径 `CODEX_HOME`。
- 不存在隐藏 install hook、MCP server、app、遥测或 marketplace 提交。
- 安全自动审批是安装后的独立 opt-in；插件安装或普通路由启用都不会隐式开启。只有明确调用
  `routerctl safe-auto enable` 才会管理 `sandbox_mode = "workspace-write"`、
  `approval_policy = "on-request"`、`approvals_reviewer = "auto_review"` 三个键，并保存键级别备份。
- `safe-auto status` 报告 active/drift/absent，`safe-auto doctor` 在 drift 时 fail closed，
  `safe-auto restore`（或 `disable`）恢复启用前值。卸载路由前必须显式 restore；卸载不会猜测或
  自动删除权限配置。

- route receipt protocol 1 只允许父协调根交接：父在创建子线程前写入 target tier/model/effort、任务范围、
  acceptance 摘要、`creation_tool=create_thread` 和 `automatic_root_creations=1`。子线程不得重分类或再建根；
  C1 到实现阶段沿用同一线程。运行时字段为三态：可见且 exact 才是 verified；可见不一致 fail closed；
  缺失字段明确为 `runtime_observability=unobservable`，不能写成 mismatch。非 C3 只有 receipt-backed
  requested/accepted 才可继续；C3 在不可逆动作前阻塞，直到具备权限的用户给出当前 scope/action 的一次
  route exception。用户文本或伪造 receipt 一律拒绝。

## 2. Prerequisites / 前置条件

- Public HTTPS access to `github.com` and `objects.githubusercontent.com`.
- An installed `codex` CLI whose help exposes:
  `codex plugin marketplace add` and `codex plugin add`.
- macOS/Linux: POSIX `sh`, `curl`, `tar`, and one of `sha256sum`, `shasum`, or `openssl`.
- Windows: PowerShell 5.1+ or PowerShell 7+, `tar.exe`, and `Get-FileHash`.
- No Rust, repository clone, GitHub login, GitHub API, `gh`, or `jq` is required.

安装器会检查上述 Codex CLI 能力。安装不需要 Rust、仓库 clone、GitHub 登录、GitHub API、
`gh` 或 `jq`。

## 3. Exact Agent procedure / Agent 精确步骤

Determine the host shell. Download the bootstrap from the public latest Release, then execute it.
Do not download packages for other platforms.

先判断宿主 shell。只从公开 latest Release 下载 bootstrap 并执行；不得下载其他平台包。

### macOS or Linux

If the user asked to install **and enable**:

```sh
work_dir=$(mktemp -d)
curl --fail --silent --show-error --location \
  --proto '=https' --proto-redir '=https' --tlsv1.2 \
  -o "$work_dir/install.sh" \
  https://github.com/antonynz/z-codex-router/releases/latest/download/install.sh
sh "$work_dir/install.sh" --enable
```

If the user asked only to install, omit `--enable`.

### Windows PowerShell

If the user asked to install **and enable**:

```powershell
$workDir = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
New-Item -ItemType Directory -Path $workDir | Out-Null
$installer = Join-Path $workDir "install.ps1"
Invoke-WebRequest `
  https://github.com/antonynz/z-codex-router/releases/latest/download/install.ps1 `
  -OutFile $installer
& $installer -Enable
```

If the user asked only to install, omit `-Enable`.

### Copy-paste upgrade / 一键升级（不要先卸载）

For a healthy existing router installation, rerun the **latest** bootstrap with enablement authority.
Do not invoke an old packaged launcher, uninstall first, or hand-edit the managed block. The latest
bootstrap first installs the latest plugin at its path-stable source, then invokes that **new launcher**
for `upgrade --dry-run`, `upgrade`, and Doctor:

```sh
work_dir=$(mktemp -d)
curl --fail --silent --show-error --location \
  --proto '=https' --proto-redir '=https' --tlsv1.2 \
  -o "$work_dir/install.sh" \
  https://github.com/antonynz/z-codex-router/releases/latest/download/install.sh
sh "$work_dir/install.sh" --enable
```

```powershell
$workDir = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
New-Item -ItemType Directory -Path $workDir | Out-Null
$installer = Join-Path $workDir "install.ps1"
Invoke-WebRequest `
  https://github.com/antonynz/z-codex-router/releases/latest/download/install.ps1 `
  -OutFile $installer
& $installer -Enable
```

The new control plane recognizes the healthy 1.0.1 legacy profile/managed-block contract and 1.0.2
contract using the installed version's own evidence. It atomically replaces only the verified managed
block/current pointer and preserves user `AGENTS.md`, `config.toml`, Safe Auto state, and
`z-codex-router-profile.toml` override byte-for-byte. A truly changed managed block, malformed legacy
profile, unknown transaction state, or hash mismatch remains fail-closed; report the stable error and use
Recover rather than forcing uninstall.

升级后无需重启应用或 CLI；`routerctl` 和 Doctor 立即读取新状态。已有 task 已加载的 skills/tools 不会被
回写，请新开 task 才加载更新后的 plugin skills/tools。

## 4. What the bootstrap guarantees / Bootstrap 保证

The bootstrap:

1. maps the host to exactly one token;
2. downloads a fresh, small `SHA256SUMS`;
3. reuses the matching cached archive only when its SHA-256 still matches;
4. otherwise downloads exactly one platform tarball from a GitHub Release direct URL;
5. rejects missing/duplicate checksum entries, wrong versions, unsafe archive paths, duplicate
   entries, links, and special files;
6. extracts into a private temporary directory;
7. preserves a verified version snapshot below
   `CODEX_HOME/z-codex-router-marketplace-versions/<version>/<platform>-<arch>`, then activates it
   at the path-stable marketplace source
   `CODEX_HOME/z-codex-router-marketplaces/<platform>-<arch>`;
8. preserves the previous active source if replacement is needed and restores it if a later step
   fails; the configured source path never changes between upgrades;
9. runs `codex plugin marketplace add` and `codex plugin add`;
10. detects an existing active state and always runs the new launcher's router `upgrade --dry-run`; with
    explicit enablement it then runs the transactional install/upgrade and Doctor.

The extracted marketplace is never placed only in a temporary directory, so Codex is not left
pointing at a deleted local source. The version snapshot provides audit evidence while the
path-stable active source avoids marketplace-name/source conflicts during upgrades. Same-version
runs download only the small checksum file when the archive cache matches, reverify the archive,
compare both persistent trees, reinstall idempotently, and preserve Doctor evidence.

Bootstrap 会自动识别平台、只下载当前平台包、精确校验 SHA-256、拒绝危险 archive、保留持久
版本快照，并激活路径稳定的 marketplace source。它不会删除 Codex 正在引用的临时解压目录，
升级也不会更换已配置的 source 路径。同版本热路径只重新下载小型 checksum 文件，复验缓存
archive、比较两棵持久目录、幂等重装，并保留 Doctor 证据。

## 5. Platform mapping and assets / 平台映射与资产

| Host | Token | Release asset |
| --- | --- | --- |
| macOS Apple Silicon | `darwin-arm64` | `z-codex-router-darwin-arm64.tar.gz` |
| macOS Intel | `darwin-amd64` | `z-codex-router-darwin-amd64.tar.gz` |
| Linux arm64 | `linux-arm64` | `z-codex-router-linux-arm64.tar.gz` |
| Linux x86_64 | `linux-amd64` | `z-codex-router-linux-amd64.tar.gz` |
| Windows arm64 | `windows-arm64` | `z-codex-router-windows-arm64.tar.gz` |
| Windows x86_64 | `windows-amd64` | `z-codex-router-windows-amd64.tar.gz` |

Every public Release also contains `SHA256SUMS`, `install.sh`, `install.ps1`, and this
`AGENT_INSTALL.md`. Source checkouts intentionally contain no compiled binary and are not a
directly runnable plugin package.

## 6. Version pin and mirror testing / 版本固定与镜像测试

Pin an exact version:

```sh
sh install.sh --version 1.0.3 --enable
```

```powershell
.\install.ps1 -Version 1.0.3 -Enable
```

For a tested HTTPS asset mirror, override the fully resolved asset directory:

```sh
sh install.sh --version 1.0.3 \
  --base-url https://mirror.example/z-codex-router/v1.0.3 --enable
```

```powershell
.\install.ps1 -Version 1.0.3 `
  -BaseUrl https://mirror.example/z-codex-router/v1.0.3 -Enable
```

HTTP and HTTPS-to-HTTP redirects are rejected.

## 7. Manual fallback / 手动回退路径

If bootstrap execution is unavailable, reproduce the same protocol manually:

1. resolve the exact platform token from the table;
2. download only its tarball and `SHA256SUMS` from `releases/latest/download`;
3. select exactly one checksum line matching the complete asset filename;
4. verify SHA-256 before extraction;
5. inspect archive entries and reject absolute paths, `..`, links, special files, and duplicates;
6. extract to a persistent version directory, then copy it into a recoverable, path-stable active
   source under the intended `CODEX_HOME`;
7. run against that stable active source:

```text
codex plugin marketplace add <persistent-source-root>
codex plugin add z-codex-router@z-codex-router
```

8. run the packaged `routerctl` launcher with explicit `--codex-home`: dry-run first, then
   install/upgrade only with enablement authority, then Doctor.

## 8. Upgrade and rollback / 升级与回滚

- Upgrade: rerun the latest installer with enablement authority; do **not** uninstall first. If router
  state exists, the bootstrap uses the new source launcher's `upgrade --dry-run` and then `upgrade`.
  It recognizes healthy 1.0.1 legacy contracts and 1.0.2 contracts from their exact installed payload
  evidence, then transactionally replaces one verified managed block/current pointer. An explicit
  same-version `upgrade` may refresh a changed local policy payload by journaling an atomic
  version-directory backup, but only when the current block is byte-for-byte intact; it never changes
  `config.toml`, Safe Auto three-key state, or `z-codex-router-profile.toml` user override. Before any
  managed write, it validates an existing override; an invalid override returns
  `E_PROFILE_OVERRIDE_INVALID` and must be repaired or explicitly reset before retry.
- A failed enablement or upgrade restores its own just-created backup before returning. If an
  interrupted process leaves `E_TRANSACTION_PENDING`, run `recover`: it restores only when the
  journal and current files match its recorded before/after values, and it does not need a second
  authorization.
- An interrupted safe-auto transaction reports `E_SAFE_AUTO_TRANSACTION_PENDING`; run `recover` and
  require exact before/after config hashes before continuing. Then run `safe-auto doctor` and require
  `OK_ACTIVE` or `OK_ABSENT`; run general `doctor` separately for routing. If routing was never
  enabled, general `doctor` may return `E_SAFE_AUTO_ACTIVE`, which is the honest independent opt-in
  boundary, not a failed safe-auto recovery. Unknown hashes or user edits stay untouched and fail
  closed.
- Rollback of a completed action is never automatic. Only after the user explicitly asks, invoke
  `rollback` from the persistent active source printed as `ZCR_SOURCE` (POSIX) or `source`
  (PowerShell). It replaces only the exact managed block and current pointer; the audited version
  snapshot is printed as `ZCR_VERSION_SOURCE` or `versionSource`.

升级时重新运行 latest installer，**不要先卸载**；已有 state 会由新 launcher 自动走安全 upgrade。健康的
1.0.1 legacy contract 与 1.0.2 contract 会根据精确 installed payload evidence 验证，再替换一段
受管 block/current pointer；真正 drift 仍停止。只有显式 `upgrade` 才允许对发生变化的同版本本地 policy
payload 做带 journal 的原子目录刷新，而且必须先确认 managed block 完整；不改 `config.toml`、safe-auto
三键状态或 `z-codex-router-profile.toml` user override。启用或升级失败会在返回前恢复
本次刚创建的备份；如进程中断留下 `E_TRANSACTION_PENDING` 或 `E_SAFE_AUTO_TRANSACTION_PENDING`，
运行 `recover`，仅在 journal 与当前文件/config 匹配记录的前后值时恢复原事务，无需二次授权；safe-auto
事务随后运行 `safe-auto doctor` 验收，再单独运行通用 Doctor 检查路由；若路由未启用而 safe-auto active，
`E_SAFE_AUTO_ACTIVE` 是独立 opt-in 边界而非恢复失败。未知 hash 或用户编辑保持不动并 fail closed。
现有 override 会在任何受管写入前被验证；无效 override 返回 `E_PROFILE_OVERRIDE_INVALID`，必须先修复或
显式 `profile reset` 后再重试，绝不会静默回退到默认 mapping。
已完成动作的回滚永不自动发生，必须由用户明确要求，
并使用安装器输出的持久 active source 中 launcher 执行 `rollback`；它只替换精确受管 block 和
current pointer。

## 8.1 Profile override and desktop handoff / 映射覆盖与桌面交接

`routerctl profile show` and Doctor report the active mapping source (`default` or `user override`),
path, and mapping hash. `profile init` creates a full editable override outside version payloads;
`profile validate` is read-only; `profile set <tier> <model> <effort>` is explicit; `profile reset`
atomically writes a managed TOML backup plus SHA-256 metadata and removes the override; and
`profile restore <backup>` restores only the returned managed backup after validating its path, hash, and
complete mapping. Never ask the user to overwrite the file manually. Invalid TOML, duplicate keys, missing/unknown tiers, empty fields,
unsupported effort, and invalid A0 semantics return `E_PROFILE_OVERRIDE_INVALID` without a silent
default fallback. Install and upgrade preflight an existing override before any managed write, so an
invalid one stops with `E_PROFILE_OVERRIDE_INVALID` and must be repaired or explicitly reset before retry.
Future model names are syntactically allowed, but a later `create_thread` must still
intersect its actual runtime allowlist and fail closed.

Parent first classifies and freezes the scope/model/effort/receipt, then checks desktop/tool policy;
the follow-up never reclassifies. Desktop/tool policy can forbid `create_thread` until the user directly
asks for a new task. Do not use `spawn_agent` or the current root as a substitute. Return
`ROUTE_HANDOFF_REQUIRED` with the localized direct command (fill the frozen tuple):

```text
请为当前相同任务范围创建一个新的 Codex 独立任务，使用 <model> / <effort>，沿用当前 route receipt；不要创建子代理或第二个任务。

Create a new independent Codex task for the same current scope using <model> / <effort>, carrying forward the current route receipt; do not create a sub-agent or a second task.
```

On that follow-up, the parent may make the same single receipt-backed `create_thread` call. A rejected or
failed call is `ROUTE_CREATE_UNAVAILABLE` or `ROUTE_CREATE_FAILED`, not permission to create a second root.

## 9. Disable and uninstall / 停用与卸载

If safe-auto is active, run `safe-auto status`/`safe-auto doctor` first and, as part of an explicit
disable-and-uninstall request, run `safe-auto restore`; stop on drift. Keep the plugin installed until
this exact sequence succeeds: Doctor → `uninstall` → Doctor with
`OK_NOT_ENABLED` → `codex plugin remove z-codex-router@z-codex-router --json`. `uninstall`
validates the active payload hash, revokes only its matching `AGENTS.md` block and state, confirms
the remaining user content, and then removes only router-managed payloads, backups, and state. On
any conflict or failure, stop and retain the plugin and recoverable control plane. Do not delete
an entire `AGENTS.md` or `config.toml`.

如果 safe-auto 为 active，必须先运行 `safe-auto status`/`safe-auto doctor`，并在用户明确要求停用并卸载时
运行 `safe-auto restore`；drift 时停止。随后必须完成以下固定顺序，才能删除插件：Doctor → `uninstall` → Doctor 返回
`OK_NOT_ENABLED` → `codex plugin remove z-codex-router@z-codex-router --json`。`uninstall`
会校验 active payload 哈希，只撤销匹配的 `AGENTS.md` block 和状态，确认剩余用户内容后才清理
受管 payload、备份和状态。任一冲突或失败都停止并保留插件与可恢复控制面；不得删除整个
`AGENTS.md` 或 `config.toml`。

## 10. Required Agent report / Agent 必须回报

Report:

- resolved version and platform;
- persistent active source and version-snapshot paths;
- cache hit and downloaded bytes reported by the bootstrap;
- whether global routing was enabled;
- dry-run/install-or-upgrade/Doctor results;
- any retained previous source path;
- confirmation that no other platform archive, repository clone, source build, GitHub API, or
  real test home was used.
