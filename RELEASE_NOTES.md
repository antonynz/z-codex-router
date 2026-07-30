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

## English

This patch fixes Codex home resolution and the exact execution protocol in the portable routing entry point.

- The managed `AGENTS.md` block resolves explicit `CODEX_HOME` first, then `~/.codex`, and never reads `current.json` relative to a repository or worktree.
- The portable core now requires exact model-and-effort matches for A1/B0/B1/B2/C1/C2/C3, rejects higher effort, defines the independent-root handoff for a C1 mismatch, reclassifies after C1, and keeps sequential work out of sub-agent delegation.
- Added content-contract regression tests and synchronized active release metadata to 1.0.2.
- Added an explicit opt-in `safe-auto` three-key policy with atomic/idempotent writes, key-level restore,
  drift detection, and crash recovery; routing uninstall requires an explicit permission restore first.
- Added a dependency-free active policy-chain verifier and wired it into source/release-asset preflight;
  compatibility metadata now distinguishes untouched ordinary install/enable from safe-auto opt-in.

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
