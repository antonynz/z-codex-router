# Z Codex Router

[中文](#中文) · [English](#english)

**为每个 Codex 任务选择合适的模型：可审计、可恢复、验证失败即停止。**

**Choose the right model for each Codex task: auditable, recoverable, and fail-closed.**

公开版本 / Public version: `1.0.0`

## 中文

Z Codex Router 是一个仅本地运行的 skills-only Codex 插件。运行时完全由 macOS/Linux 的 POSIX
`sh` 与 Windows PowerShell 5.1+ 实现；仓库、插件和 Release 不包含 Rust、Python、平台可执行文件或
其他编译产物。

![Z Codex Router 中文架构](docs/images/z-codex-router-architecture-zh.png)

### 它解决什么

- 按 A0–C3 的统一轴判断副作用、任务明确度、影响面、状态复杂度与风险。
- 按 Engineering、Product、Business Operations、Design、Testing 等 mode 选择领域验收标准。
- 用 parent-owned receipt、精确 model/effort 和运行时三态避免静默降级。
- 正确区分任务创建结果：

  | 创建工具证据 | Router 状态 |
  | --- | --- |
  | `threadId` | `ROUTE_READY` |
  | `clientThreadId` | `ROUTE_PENDING`，禁止重试 |
  | 当前策略阻止 | `ROUTE_HANDOFF_REQUIRED` |
  | destination 明确拒绝 tuple | `ROUTE_DESTINATION_TUPLE_UNAVAILABLE` |
  | project/target/参数明确拒绝 | `ROUTE_INPUT_REJECTED` |
  | 无法确认是否创建 | `ROUTE_OUTCOME_UNKNOWN`，禁止重试 |

- 把受管路由块放在全局 `AGENTS.md` 前部（可在 UTF-8 BOM 后），并由 Doctor 检查实际指令来源、
  字节范围、`project_doc_max_bytes`、全局 override 与项目/嵌套指令链。

Router 是“指令路由”，不是宿主层模型切换器。只有当前用户明确请求创建新任务时，父任务才可调用
一次 `create_thread`；持久指令本身不是创建授权。禁止自动降级、当前任务代做、pending/unknown 后
重试或 fallback 到 `spawn_agent`。

### 安装资产

GitHub v1.0.0 Release 只包含：

- `z-codex-router-1.0.0.tar.gz`：POSIX 安装与源码。
- `z-codex-router-1.0.0.zip`：PowerShell 安装与相同源码。
- `SHA256SUMS`：两份归档的 SHA-256。

两份归档解包后的文件内容相同。公开 manifest、标签和 Release 均保持 `1.0.0`；本地 Codex marketplace
cache 会使用 `1.0.0+codex.<timestamp>`，让同版本重装能够被新任务重新载入。

### 安装并启用

macOS/Linux：

```sh
version=1.0.0
curl --fail --location \
  --remote-name-all \
  "https://github.com/antonynz/z-codex-router/releases/download/v${version}/z-codex-router-${version}.tar.gz" \
  "https://github.com/antonynz/z-codex-router/releases/download/v${version}/SHA256SUMS"
count=$(awk '$2 == "z-codex-router-1.0.0.tar.gz" { count++ } END { print count + 0 }' SHA256SUMS)
expected=$(awk '$2 == "z-codex-router-1.0.0.tar.gz" { print $1 }' SHA256SUMS)
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "z-codex-router-${version}.tar.gz" | awk '{ print tolower($1) }')
else
  actual=$(shasum -a 256 "z-codex-router-${version}.tar.gz" | awk '{ print tolower($1) }')
fi
[ "$count" -eq 1 ] && [ "$actual" = "$expected" ] || exit 1
tar -xzf "z-codex-router-${version}.tar.gz"
cd "z-codex-router-${version}"
sh install.sh --source . --enable
```

Windows PowerShell 5.1+：

```powershell
$Version = "1.0.0"
Invoke-WebRequest `
  -Uri "https://github.com/antonynz/z-codex-router/releases/download/v$Version/z-codex-router-$Version.zip" `
  -OutFile "z-codex-router-$Version.zip"
Invoke-WebRequest `
  -Uri "https://github.com/antonynz/z-codex-router/releases/download/v$Version/SHA256SUMS" `
  -OutFile SHA256SUMS
$Lines = @(Select-String -Path SHA256SUMS -Pattern "^([0-9a-f]{64})  z-codex-router-1\.0\.0\.zip$")
if ($Lines.Count -ne 1) { throw "invalid SHA256SUMS" }
$Expected = $Lines[0].Matches[0].Groups[1].Value
$Actual = (Get-FileHash -LiteralPath "z-codex-router-$Version.zip" -Algorithm SHA256).Hash.ToLowerInvariant()
if ($Actual -ne $Expected) { throw "archive checksum mismatch" }
Expand-Archive -LiteralPath "z-codex-router-$Version.zip" -DestinationPath .
Set-Location "z-codex-router-$Version"
.\install.ps1 -Source . -Enable
```

从本地 checkout 测试：

```sh
sh install.sh --source . --enable
```

```powershell
.\install.ps1 -Source . -Enable
```

普通安装（不带 enable）只注册带 cache build metadata 的插件 source，并执行只读 preflight；只有
`--enable` / `-Enable` 才修改全局 Router state。安装、升级和卸载后必须新开任务，已有任务不会重新
加载指令或技能。

### 旧 Rust 安装边界

脚本版不迁移旧状态。检测到旧 `current.json`、旧 transaction、旧受管块或旧权限状态时，fresh
install 返回 `E_LEGACY_INSTALL_DETECTED`。严格顺序是：

```sh
sh install.sh --source . --legacy-cleanup-dry-run
sh install.sh --source . --legacy-cleanup
sh install.sh --source . --enable
```

```powershell
.\install.ps1 -Source . -LegacyCleanupDryRun
.\install.ps1 -Source . -LegacyCleanup
.\install.ps1 -Source . -Enable
```

Cleanup 会先备份 `AGENTS.md`、存在时的 `config.toml` 和旧 Router state，只移除由 marker、version
与 hash 共同识别的旧内容。块漂移、旧 transaction 或旧权限管理 state 会停止；不会猜测或删除用户
权限键。

### 控制面

macOS/Linux：

```sh
plugins/z-codex-router/scripts/routerctl.sh doctor --cwd /path/to/project
```

Windows：

```powershell
plugins\z-codex-router\scripts\routerctl.ps1 doctor --cwd C:\path\to\project
```

生命周期命令：

- `dry-run`
- `install`
- `doctor [--cwd PATH]`
- `upgrade [--dry-run]`
- `recover`
- `rollback`
- `uninstall`
- `legacy-cleanup [--dry-run]`
- `profile show|init|validate|set|reset|restore`

脚本版没有审批、sandbox 或 `config.toml` 管理命令。Profile override 位于
`<codex_home>/z-codex-router-profile.toml`，生命周期操作不会改写或删除它。

### 数据保护

- 状态使用 `z-codex-router/current/` 下的小文件、不可变 `versions/<version>/`、锁目录、transaction
  目录和逐字节 backup。
- 新安装保留 BOM、换行风格和原始用户 bytes；卸载只移除经 hash 验证的 managed prefix，并保留安装
  后的用户编辑。
- 非空全局 `AGENTS.override.md` 返回 `E_GLOBAL_OVERRIDE_ACTIVE`，不会被修改。
- Recover 先校验 backup hash；只接受 transaction 记录的 before/intermediate/after 状态，未知
  drift 停止。
- Rollback 在完成后用户又修改过 `AGENTS.md` 时停止，绝不以旧整文件 backup 覆盖新用户内容。
- Bootstrap 写入后的 Doctor 若失败，会先 rollback 到写入前状态；rollback 未完成时保留恢复证据并
  转 Recover。

### 开发与验证

```sh
sh scripts/test_all.sh
```

```powershell
.\scripts\test_all.ps1
```

CI 在 macOS、Linux、Windows PowerShell 5.1 和 PowerShell 7 上运行生命周期、profile、budget、
override、legacy、打包和保护路径测试。`verify_source` 扫描当前树与重写后的全部可达 Git blobs，
拒绝 Mach-O、ELF、PE/EXE；PNG 明确保留。

本项目不是 OpenAI 官方产品，也未声明已获 OpenAI Marketplace 审核或上架。Apache-2.0 licensed.

## English

Z Codex Router is a local-only, skills-only Codex plugin. Its runtime is implemented entirely in
POSIX `sh` for macOS/Linux and Windows PowerShell 5.1+ for Windows. The repository, plugin, and
Release contain no Rust, Python, platform executables, or other compiled artifacts.

![Z Codex Router architecture](docs/images/z-codex-router-architecture-en.png)

It classifies tasks on a shared A0–C3 axis, selects a domain mode, uses parent-owned receipts and
exact model/effort matching, and treats missing runtime metadata as `unobservable` rather than a
mismatch.

Task creation results are explicit: `threadId → ROUTE_READY`,
`clientThreadId → ROUTE_PENDING`, policy denial → `ROUTE_HANDOFF_REQUIRED`, destination tuple denial
→ `ROUTE_DESTINATION_TUPLE_UNAVAILABLE`, input denial → `ROUTE_INPUT_REJECTED`, and uncertain
outcome → `ROUTE_OUTCOME_UNKNOWN`. Pending and unknown outcomes must never be retried.

The managed routing block is written at the start of global `AGENTS.md` (after an optional UTF-8
BOM). Doctor reports its byte range, effective `project_doc_max_bytes`, the effective global
instruction source, global override shadowing, and the project/nested instruction chain for
`doctor --cwd`.

The v1.0.0 Release has exactly two universal source assets plus checksums:

- `z-codex-router-1.0.0.tar.gz`
- `z-codex-router-1.0.0.zip`
- `SHA256SUMS`

Public manifests and the tag remain `1.0.0`. Local Codex marketplace copies use
`1.0.0+codex.<timestamp>` as cache metadata.

An old Rust/prebuilt installation is never migrated implicitly. Run an explicit legacy cleanup
dry-run, confirm the cleanup, and then perform a fresh install. Cleanup backs up user instructions,
configuration, and old Router state before removing only marker/version/hash-identified Router
content. Drift or an unfinished legacy transaction stops without overwriting user files.

The script control plane supports install, Doctor, upgrade, recover, rollback, uninstall,
legacy cleanup, and profile management. It has no approval, sandbox, or `config.toml` management
commands.

If post-write Doctor validation fails, bootstrap rolls back to the pre-write Router state; an
incomplete rollback preserves recovery evidence and stops.

Run the full suites with:

```sh
sh scripts/test_all.sh
```

```powershell
.\scripts\test_all.ps1
```

This is not an official OpenAI product and does not claim OpenAI Marketplace review or listing.
Licensed under Apache-2.0.
