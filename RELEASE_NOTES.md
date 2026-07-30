# Z Codex Router v1.0.3

## 中文

这是一个迁移和策略边界补丁；公开的 v1.0.2 未被重写。

- 最新 bootstrap 能直接升级健康的 1.0.1 和 1.0.2，不要求先卸载。它使用被升级版本自身的
  legacy/current 契约和 payload evidence 验证，再事务性替换唯一精确的 managed block/current pointer。
  真正的 managed drift、损坏 legacy profile、hash 不匹配或中断事务仍保持 fail-closed，并保留旧版本和
  Recover 路径。
- 新增 `<codex_home>/z-codex-router-profile.toml` 持久 mapping override，以及
  `routerctl profile show|init|validate|set|reset`。默认 mapping 仍随安装提供；显式 user/session/CLI
  选择优先于有效 override，override 优先于 shipped default。Doctor 输出 active source、path 与 mapping hash；
  无效 TOML/mapping 不会静默回退。
- `profile reset` 现在输出带 SHA-256 metadata 的受管 backup；只能通过
  `routerctl profile restore <backup>` 恢复。restore 限制在受管目录、验证 hash 与完整 mapping、拒绝 drift，
  并原子恢复，绝不要求用户手工覆盖文件。
- Desktop/tool policy 优先于路由：无法创建独立根时返回 `ROUTE_HANDOFF_REQUIRED` 并给出唯一明确的用户动作；
  已允许调用失败或工具不可用分别返回 `ROUTE_CREATE_FAILED`/`ROUTE_CREATE_UNAVAILABLE`。绝不以
  `spawn_agent` 或当前根替代 `create_thread`。父先冻结 tuple/receipt 再检查 policy；follow-up 现在是可直接
  发送的“创建新独立任务”命令，不是可能无法被 desktop 识别的元请求。
- 安装或升级后无需重启；新的 plugin skills/tools 在新开 task 时加载。Safe Auto 三键、用户 AGENTS 内容和
  profile override 不会被 upgrade/recover/uninstall 改写或删除（profile reset 除外，且先备份）。
- 本次本机发布准备只构建并验证了 darwin-arm64；darwin-amd64、linux-arm64、linux-amd64、windows-arm64
  和 windows-amd64 均未在本机构建、归档或发布。发布前必须由现有原生 GitHub-hosted CI 从源码构建并验证。

## English

This is a migration and policy-boundary patch; public v1.0.2 remains unchanged.

- The latest bootstrap upgrades healthy 1.0.1 and 1.0.2 installations without uninstall-first. It
  validates the installed version using its own legacy/current contract and payload evidence, then
  transactionally replaces only the exact managed block/current pointer. Real drift, malformed legacy
  profiles, hash mismatches, and interrupted transactions remain fail-closed with the old version and
  Recover path intact.
- Added `<codex_home>/z-codex-router-profile.toml` plus
  `routerctl profile show|init|validate|set|reset`. Shipped defaults remain available; explicit
  user/session/CLI selection wins over a valid override, which wins over the shipped default. Doctor
  reports the active source, path, and mapping hash, and invalid TOML/mappings never silently fall back.
- `profile reset` now returns a managed SHA-256-attested backup, and only
  `routerctl profile restore <backup>` can restore it. Restore is confined to the managed directory,
  validates hash and the complete mapping, rejects drift, and writes atomically without asking users to
  overwrite files manually.
- Desktop/tool policy wins over routing: a blocked independent root returns `ROUTE_HANDOFF_REQUIRED`
  with one exact user action; allowed-call failure and unavailable tools return
  `ROUTE_CREATE_FAILED`/`ROUTE_CREATE_UNAVAILABLE`. `spawn_agent` and the current root are never a
  substitute for `create_thread`. The parent freezes the tuple/receipt before policy inspection, and the
  follow-up is now a direct independent-task command rather than a desktop-unrecognized meta-request.
- No restart is needed after install or upgrade; open a new task to pick up updated plugin skills/tools.
  Safe Auto's three keys, user AGENTS content, and the profile override are not rewritten or deleted by
  upgrade/recover/uninstall (except explicit, backed-up `profile reset`).
- This local release preparation built and verified only darwin-arm64. darwin-amd64, linux-arm64,
  linux-amd64, windows-arm64, and windows-amd64 were not built, archived, or published locally; the
  existing native GitHub-hosted CI must build and verify them from source before release.

# Z Codex Router v1.0.2

## 中文

本次修复版本补齐可移植路由入口的 Codex home 解析和精确执行协议。

- managed `AGENTS.md` block 先解析显式 `CODEX_HOME`，否则使用 `~/.codex`，禁止按仓库或 worktree 相对路径读取 `current.json`。
- portable core 明确 A1/B0/B1/B2/C1/C2/C3 的 model+effort 精确匹配、更高 effort 不兼容、C1 不匹配时的独立根转交、C1 后重新分类和顺序任务不委派规则。
- 增加内容契约回归测试，并将活动发布版本同步为 1.0.2。
- 增加明确 opt-in 的 `safe-auto` 三键策略：原子、幂等、键级恢复、drift 检测和中断恢复；路由
  卸载前必须先显式恢复权限配置。
- 增加无第三方依赖的活动策略链 verifier，并让 source/release asset preflight 实际调用；兼容性
  元数据明确普通 install/enable 不改 `config.toml`，只有 safe-auto opt-in 管理三个键。
- 增加 protocol-1 父协调 route receipt：父是唯一分类 owner，`create_thread` 前写入目标 tuple、scope
  和 acceptance，自动根创建最多一次，thread ID 只来自工具返回，子线程不重分类/递归。运行时改为
  `verified`/`mismatch`/`unobservable` 三态；非 C3 的不可观测字段记录 requested/accepted 而非 verified，
  C3 在不可逆动作前要求一次当前 scope/action 的 route exception，mismatch 不能绕过。
- 增加显式同版本 `upgrade` 刷新：以 journal 记录版本目录备份并原子替换本地 1.0.2 payload，更新
  managed block，同时不触碰 `config.toml` 或 safe-auto 三键状态。

## English

This patch fixes Codex home resolution and the exact execution protocol in the portable routing entry point.

- The managed `AGENTS.md` block resolves explicit `CODEX_HOME` first, then `~/.codex`, and never reads `current.json` relative to a repository or worktree.
- The portable core now requires exact model-and-effort matches for A1/B0/B1/B2/C1/C2/C3, rejects higher effort, defines the independent-root handoff for a C1 mismatch, reclassifies after C1, and keeps sequential work out of sub-agent delegation.
- Added content-contract regression tests and synchronized active release metadata to 1.0.2.
- Added an explicit opt-in `safe-auto` three-key policy with atomic/idempotent writes, key-level restore,
  drift detection, and crash recovery; routing uninstall requires an explicit permission restore first.
- Added a dependency-free active policy-chain verifier and wired it into source/release-asset preflight;
  compatibility metadata now distinguishes untouched ordinary install/enable from safe-auto opt-in.
- Added protocol-1 parent-owned route receipts: the parent alone classifies and writes the requested tuple,
  scope, and acceptance before `create_thread`; automatic root creation is capped at one, IDs come only from
  the tool return, and children cannot reclassify or recurse. Runtime checks are now
  `verified`/`mismatch`/`unobservable`; non-C3 unknown fields remain requested/accepted without a verified claim,
  while C3 blocks before irreversible work until one scoped route exception, and mismatch can never bypass it.
- Added an explicit same-version `upgrade` refresh with a journaled version-directory backup, allowing
  local 1.0.2 payload iterations to update the managed block without touching `config.toml` or safe-auto state.

# Z Codex Router v1.0.1

## 中文

本次补丁版本新增 `recover-router` 与 `uninstall-router`，补齐安全恢复与卸载闭环。

- `recover` 安全恢复中断事务，并只清理能按事务身份和哈希验证的新版本。
- `uninstall` 只撤销受管块、状态与 payload，保护用户的非托管 `AGENTS.md` 和
  `config.toml` 内容；重复执行保持安全。
- Doctor 明确区分 `OK_ENABLED` 与 `OK_NOT_ENABLED`。
- README 提供安装并启用、恢复或回滚、停用并卸载三类中英文提示词。

六个平台包由对应 GitHub-hosted runner 构建，并执行仓库既有的平台打包与 bootstrap
检查；本地额外完成 macOS arm64 release 构建和隔离生命周期验证。

## English

This patch adds `recover-router` and `uninstall-router` to complete the safe recovery and removal
flows.

- `recover` safely restores interrupted transactions and removes a newly created version only when
  its transaction identity and hash are verified.
- `uninstall` revokes only managed blocks, state, and payload while preserving user-owned
  `AGENTS.md` and `config.toml` content; repeated runs remain safe.
- Doctor explicitly distinguishes `OK_ENABLED` from `OK_NOT_ENABLED`.
- The README now includes bilingual prompts for install and enable, recovery or rollback, and
  disable and uninstall.

All six platform packages are built on their corresponding GitHub-hosted runners and run the
repository's existing package and bootstrap checks. macOS arm64 additionally has a local release
build and isolated lifecycle verification.
