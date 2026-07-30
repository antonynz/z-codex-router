---
name: uninstall-router
description: 在保留用户配置的前提下安全停用并卸载 Z Codex Router。用户要求停用并卸载、卸载、移除，或清理已安装的 Z Codex Router 时使用。
---

# 卸载 Z Codex Router

在 routerctl 完成全部 control-plane 检查前，必须保留 plugin 与 launcher。不得手工删除
`AGENTS.md`、`config.toml`、marketplace source、`z-codex-router-profile.toml` 或用户内容。

若 `safe-auto` 为 active，先运行 `safe-auto doctor`，再运行 `safe-auto restore`。路由 uninstall
不得猜测用户是否仍需要三个权限键，也绝不隐式删除。

1. macOS/Linux 用 `../../scripts/routerctl.sh` 运行 `doctor`，Windows 用
   `../../scripts/routerctl.ps1`。若报告 conflict、drift、pending transaction、permission、path
   或 compatibility 错误，立即停止并保持 plugin 与 control plane 完整。
2. 运行 `uninstall`。它校验活动 payload hash，只移除自身精确受管 `AGENTS.md` block 与 current state，
   逐字校验剩余用户内容，再只移除受管 payload、backup 与 state。持久 user profile override 位于
   payload 外，必须保留。重复执行应安全。
3. 再次运行 `doctor` 并要求 `OK_NOT_ENABLED`。这表示不再有全局 router state；routerctl 不声称检查
   plugin registration 状态。
4. 只有上述检查成功后，才运行
   `codex plugin remove z-codex-router@z-codex-router --json` 移除 plugin，并回报结果。

若最终 plugin removal 失败，回报结果且不要再删除任何文件。router 已安全停用，可通过正常 plugin 命令重试。
