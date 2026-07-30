# Agent 安装与生命周期协议

本协议面向代表用户执行安装的 Codex Agent。公开版本固定为 `1.0.0`，实现为 POSIX `sh` 与 Windows
PowerShell 5.1+；不得寻找、构建或下载平台可执行文件。

## 不可越过的边界

- 解析 Codex home 时显式 `CODEX_HOME` 优先；否则使用用户目录下的 `.codex`。禁止相对于仓库、
  worktree 或当前目录推断。
- 测试只能写临时 Codex home，绝不把真实 Codex home 当 fixture。
- 普通 plugin install 只注册 source 并执行 Router preflight；只有用户明确要求 enable 才能写
  `AGENTS.md` 与 Router state。
- 写入型生命周期不解析或修改 `config.toml`。Doctor 只读取
  `project_doc_max_bytes`；legacy cleanup 只做逐字节 backup。脚本版没有审批或 sandbox 管理命令。
- 非空全局 `AGENTS.override.md` 会遮蔽 `AGENTS.md`；安装必须返回
  `E_GLOBAL_OVERRIDE_ACTIVE`，不得修改 override。
- 旧 Rust/prebuilt state 不迁移、不覆盖。只允许显式 legacy cleanup 后 fresh install。
- 创建新任务仍需当前用户明确请求；安装/启用本身不是 `create_thread` 授权。

## Release 资产与校验

只下载当前版本对应的一个源码归档和 `SHA256SUMS`：

| 主机 | 归档 |
| --- | --- |
| macOS / Linux | `z-codex-router-1.0.0.tar.gz` |
| Windows PowerShell | `z-codex-router-1.0.0.zip` |

两份归档内容相同。校验要求：

1. URL 必须是 HTTPS。
2. `SHA256SUMS` 中目标文件名恰好出现一次。
3. 下载归档 SHA-256 与清单完全相同。
4. 归档拒绝绝对路径、`..`、重复 entry、链接和特殊文件。
5. 解包树拒绝 Mach-O、ELF、PE/EXE 魔数。
6. Plugin 与 release manifest 都必须是公开 `1.0.0`。
7. `.agents/plugins/marketplace.json`、plugin manifest、两种 controller 和 Router core 必须存在。

Bootstrap 会把 marketplace source 复制到
`<codex_home>/z-codex-router-marketplaces/1.0.0+codex.<timestamp>/`，只在该本地副本中更新 plugin
manifest 的 build metadata。Release manifest、Git tag 与公开源码始终为 `1.0.0`。

## Fresh install

POSIX：

```sh
sh install.sh --source . --enable
```

PowerShell：

```powershell
.\install.ps1 -Source . -Enable
```

执行顺序：

1. 下载、校验并安全解包源码，或使用显式 `--source` / `-Source`。
2. 用源码 controller 执行只读 `dry-run`。
3. Preflight 验证 source、profile、global override、legacy state、路径和当前 transaction。
4. 生成唯一的本地 cache build source。
5. 使用 Codex CLI 注册 marketplace 并安装 plugin。
6. 只有 enable 请求才从新 cache launcher 执行 `install`。
7. 执行 `doctor` 并要求 `OK_ENABLED`。
8. 回报公开版本、本地 cache version、source、下载字节、Router action 和 `start-a-new-task`。

任何 Codex registration 失败都发生在 Router 写入之前；`AGENTS.md`、`config.toml` 与 Router state
必须保持不变。若 Router 写入后的 Doctor 失败，bootstrap 必须立即 rollback；rollback 失败时保留
transaction/backup 并转 Recover，不得把失败安装报告为启用。

## 受管块与指令预算

首次安装把 managed block 写在全局 `AGENTS.md` 的字节前缀：

- 无 BOM：从 byte 0 开始。
- UTF-8 BOM：保留 BOM，block 从 byte 3 开始。
- Block 使用用户文件既有的 CRLF 或 LF；用户 remainder 不转码、不重排。
- 若原文件有内容，在 block 后写一个相同风格的 separator，再附上原始 bytes。

State 记录 block/prefix byte length 与 SHA-256。Doctor 必须同时检查：

- 实际全局 instruction source；
- managed block 唯一性、start/end bytes 与 hash；
- 有效 `project_doc_max_bytes`；
- `doctor --cwd` 指定目录的 project/nested instruction count；
- global override；
- payload 与 profile hash。

`managed_block_end > project_doc_max_bytes` 返回
`E_MANAGED_BLOCK_OUTSIDE_INSTRUCTION_BUDGET`。不得靠静默提高用户配置绕过。

## 状态、事务与恢复

新格式为 `script-v1`：

```text
<codex_home>/z-codex-router/
├── current/
├── versions/<version>/
├── backups/backup-*/
└── transaction/
```

每个 state 字段是一个小文件。版本 payload 不可变；Shell 与 PowerShell 使用相同的 tree hash
算法。写操作使用 Codex-home 内锁目录、逐字节 backup、before/intermediate/after SHA-256 和
transaction 目录。

Doctor 发现 transaction 时返回 `E_TRANSACTION_PENDING`。Recover 先校验 backup 自身 hash 及其与
journal before hash 的对应关系；AGENTS 只接受 before/after，current state 只接受
before/intermediate/after。未知值返回 `E_TRANSACTION_DRIFT` 并保留用户修改。成功恢复后再次运行
Doctor。

Rollback 只撤销最近完成的生命周期操作。若 `AGENTS.md` 在该操作完成后被用户继续编辑，返回
`E_ROLLBACK_DRIFT`；不得用旧整文件 backup 覆盖新内容。

## Upgrade

公开版本可以保持 `1.0.0`，本地 source identity 使用新的 `+codex.<timestamp>`。升级顺序：

1. 新 controller 执行 `upgrade --dry-run`。
2. 验证当前 managed prefix、payload、profile、override 与 transaction。
3. 新 cache source 注册成功后执行 `upgrade`。
4. 原子替换 payload/current/managed prefix，保留用户 remainder、BOM、换行、`config.toml` 与 profile
   override。
5. Doctor 要求 `OK_ENABLED`；失败时立即 rollback，rollback 失败则转 Recover。成功后再提示新开
   任务。

相同 version 与 payload bytes 返回 `OK_NO_CHANGE`。不同 source 使用 `install` 返回
`E_UPGRADE_REQUIRED`。

## Profile override

用户 override 位于 `<codex_home>/z-codex-router-profile.toml`，必须恰好包含 A0–C3：

- A0 固定为 `current-qualified-root/runtime-qualified`。
- 其他 model 是非空兼容 token。
- Effort 只能是 `medium`、`high`、`xhigh`、`max`。

命令：

```text
profile show
profile init
profile validate
profile set <tier> <model> <effort>
profile reset
profile restore <backup>
```

Reset 先写受管 TOML backup 与 `.sha256` metadata，再删除 override。Restore 只接受
`z-codex-router-profile-backups/` 内的常规 backup，验证路径、hash 和完整 mapping，并拒绝覆盖已有
override。生命周期与 uninstall 始终保留 override。

## Legacy cleanup

检测到旧 `current.json`、旧 transaction、旧 managed block 或旧权限管理 state 时，fresh install
返回 `E_LEGACY_INSTALL_DETECTED`。不得手工删除或隐式迁移。

严格顺序：

1. `legacy-cleanup --dry-run`
2. 用户确认后 `legacy-cleanup`
3. fresh `install`

Bootstrap 入口：

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

Cleanup 要求旧 `current.json` 的 version/payload hash 与 managed block identity 完全相同，先备份
`AGENTS.md`、存在时的 `config.toml` 和整个旧 Router state。块漂移、旧 transaction 或旧权限管理
state 必须停止并给出旧控制面的恢复路径；不得删除或猜测用户权限键。

## Uninstall

顺序：

1. Doctor。
2. `uninstall`。
3. Doctor 要求 `OK_NOT_ENABLED`。
4. 最后才运行 `codex plugin remove z-codex-router@z-codex-router --json`。

Uninstall 验证 managed prefix 后只移除 prefix 与 state；安装后的用户编辑仍位于 remainder 中并被
保留。若 Router 创建了原本不存在且最终为空的 `AGENTS.md`，才删除该空文件。Profile override 保留。

## 路由创建结果

父任务只有在当前用户明确授权新任务时才调用一次 `create_thread`，并把 profile effort 映射到工具
`thinking` 参数。结果必须分类为：

- `threadId` → `ROUTE_READY`
- `clientThreadId` → `ROUTE_PENDING`
- policy 阻止 → `ROUTE_HANDOFF_REQUIRED`
- destination tuple 拒绝 → `ROUTE_DESTINATION_TUPLE_UNAVAILABLE`
- input/project/target 拒绝 → `ROUTE_INPUT_REJECTED`
- 无法确认 outcome → `ROUTE_OUTCOME_UNKNOWN`

Pending 与 unknown 禁止重试。任何分支都禁止自动降级、当前任务代做、第二个根或 `spawn_agent`
fallback。只有工具明确报告 tuple unsupported 才能作该结论。

## 验收

仓库提供：

```sh
sh scripts/test_all.sh
```

```powershell
.\scripts\test_all.ps1
```

CI 覆盖 macOS、Linux、Windows PowerShell 5.1 和 PowerShell 7。Release 前从最终提交生成 tar.gz 与
zip，比较解包后的逐文件 hash，分别 smoke controller，并扫描当前树及全部可达 Git blobs 的编译魔数。
PNG 文档图片明确保留。
