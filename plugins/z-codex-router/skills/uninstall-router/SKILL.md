---
name: uninstall-router
description: 在保留用户 AGENTS.md、config.toml 和 profile override 的前提下安全停用并卸载 script-v1 Z Codex Router；旧 Rust 安装使用显式 legacy cleanup。
---

# 卸载 Z Codex Router

在 control plane 完成全部检查前保留 plugin 与 launcher。不得手工删除 `AGENTS.md`、`config.toml`、
marketplace source 或 profile override。

1. 运行 Doctor。Pending、drift、路径、payload 或 profile 错误立即停止。
2. 若为旧 Rust 安装，使用 `legacy-cleanup --dry-run`，取得用户确认后运行 `legacy-cleanup`；遇到旧
   safe-auto state 时先用旧控制面 restore，脚本版不会猜测或删除权限键。
3. 对 script-v1 安装运行 `uninstall`。它验证唯一 managed prefix，只移除该 prefix 和 state，并逐字
   保留 BOM 后的用户 remainder；profile override 位于 state 外并保留。
4. 再次运行 Doctor 并要求 `OK_NOT_ENABLED`。
5. 只有上述步骤成功后，才运行
   `codex plugin remove z-codex-router@z-codex-router --json`。

最终 plugin removal 失败时不要再删文件；Router 已停用，可通过正常 plugin 命令重试。
