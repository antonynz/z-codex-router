---
name: recover-router
description: 在不覆盖用户改动的前提下，安全恢复中断的 Z Codex Router install、enable、upgrade、uninstall 或 Safe Auto 权限事务。用户要求恢复、修复、失败后重试，或报告 E_TRANSACTION_PENDING、E_SAFE_AUTO_TRANSACTION_PENDING 时使用。只有用户明确要求撤销已完成的 upgrade 或 enablement 时才使用 rollback。
---

# 恢复 Z Codex Router

1. macOS/Linux 用 `../../scripts/routerctl.sh` 运行 `doctor`，Windows 用
   `../../scripts/routerctl.ps1`。
2. 若返回 `E_TRANSACTION_PENDING` 或 `E_SAFE_AUTO_TRANSACTION_PENDING`，只运行一次 `recover`。
   只有当前 files/config、journal 与预期 before/after hash 匹配时，才恢复精确原事务。Safe Auto
   recovery 也覆盖 config 已恢复但 state/journal 尚未清理的中断点；绝不改写无关 `config.toml`
   内容。它是失败恢复而非用户 rollback，因此不需要第二次授权。
3. 按恢复的事务类型完成校验：
   - `E_TRANSACTION_PENDING` 后再次运行 `doctor`，按原样报告 `OK_ENABLED` 或 `OK_NOT_ENABLED`；
   - `E_SAFE_AUTO_TRANSACTION_PENDING` 后运行 `safe-auto doctor` 并要求 `OK_ACTIVE` 或
     `OK_ABSENT`，再单独运行通用 `doctor`，如实报告路由结果。路由未安装但 Safe Auto 独立 active
     时，通用 `doctor` 应返回 `E_SAFE_AUTO_ACTIVE`；这是明确 opt-in 边界，不是 Safe Auto recovery 失败。
4. 只有用户明确要求撤销已完成的 enablement 或 upgrade，且 Doctor 健康后，才运行 `rollback`。
   它只替换受管 block 与 current pointer，并保留周围用户 `AGENTS.md` 内容、Safe Auto state 和持久
   profile override。

遇到其他错误、hash drift 或用户内容冲突时停止。不得手工修文件或静默调用 rollback。
