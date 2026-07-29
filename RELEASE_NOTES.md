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
