---
name: recover-router
description: 在不覆盖用户改动的前提下恢复中断的 Z Codex Router script-v1 install、upgrade、rollback 或 uninstall 事务。用户要求恢复、修复、失败后重试或报告 E_TRANSACTION_PENDING 时使用；只有明确要求撤销已完成操作时才 rollback。
---

# 恢复 Z Codex Router

1. macOS/Linux 用 `../../scripts/routerctl.sh doctor`，Windows 用
   `../../scripts/routerctl.ps1 doctor`。
2. 只有返回 `E_TRANSACTION_PENDING` 才运行一次 `recover`。Recover 先校验 backup hash 与 journal
   before hash；当前 `AGENTS.md` 必须等于 before/after，current state 必须等于
   before/intermediate/after。任何其他值视为外部/用户 drift 并停止。
3. Recover 只恢复事务 backup 和必要的 staged version，不触碰 `config.toml` 或 profile override。
4. 再次运行 Doctor，并按原样报告 `OK_ENABLED` 或 `OK_NOT_ENABLED`。
5. 只有用户明确要求撤销最近已完成的 install/upgrade，且 `AGENTS.md` 在完成后未被用户继续修改，
   才运行 `rollback`。若返回 `E_ROLLBACK_DRIFT`，停止，绝不用整文件 backup 覆盖新用户内容。

旧 Rust state 不由 Recover 迁移；使用 `legacy-cleanup --dry-run` 和显式 cleanup。
