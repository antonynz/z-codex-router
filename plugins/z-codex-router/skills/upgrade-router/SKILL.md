---
name: upgrade-router
description: 安全发现、dry-run 并升级已有 Z Codex Router 安装。只在用户明确要求升级 Z Codex Router 或 rollback 失败升级时使用；普通任务路由不得使用。
---

# 升级 Z Codex Router

先说明目标 home、正在发现的 source release、当前版本、计划 backup 与 rollback 边界。整个交互留在 Codex 内完成，不要让用户操作命令行。

1. 运行**最新已安装 launcher** 的 `upgrade --dry-run`；不要先 uninstall，也不要调用旧版本 launcher。
2. 用当前安装自己的精确 payload evidence 校验 profile、managed block 与 state，再以事务方式替换为新版本 managed block/current pointer。升级必须逐字保留用户 `AGENTS.md`、`config.toml`、Safe Auto state 与 `z-codex-router-profile.toml`。
3. discovery 确认更新 stable release 兼容后，运行 `upgrade`。真正改变的 managed block 返回 `E_MANAGED_BLOCK_DRIFT`；损坏的 profile 返回对应稳定错误码；两者都不授权覆盖或 uninstall-first。
4. 若事务开始后 upgrade 失败，control plane 在返回错误前恢复刚创建的 backup。若报告 `E_TRANSACTION_PENDING`，使用 Recover Router skill；它只恢复精确的中断事务。只有用户明确要求恢复最近已完成状态时才用 `rollback`。不得以 candidate profile 替换 stable profile；candidate 按设计为 disabled 且 unevaluated。
5. 升级成功后运行 Doctor 并要求 `OK_ENABLED`；确认精确受管 block 包含完整 `## 全局路由` 合同与持久独立根授权。
6. 遇到冲突、profile/runtime 不兼容、权限或路径错误时停止并报告稳定错误码，不得手工改文件。已有任务保留已加载的 plugin context；需要新 task 才能载入更新后的 skills/tools。
