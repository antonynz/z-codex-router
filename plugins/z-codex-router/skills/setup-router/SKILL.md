---
name: setup-router
description: 启用 Z Codex Router 的全局任务路由策略，或处理用户明确要求的 Safe Auto 审批 opt-in。只在用户明确要求全局安装并启用、启用、安装或开启 Z Codex Router，或要求 Safe Auto enable、restore、status、doctor、开启、关闭或检查安全自动审批时使用；普通路由启用绝不隐含 Safe Auto。
---

# 启用 Z Codex Router

写入前说明选定的 Codex home；本操作会读取 plugin payload、`AGENTS.md` 与 router state，并且只增加 hash 标识的受管内容。说明路由 install/enable 不读取或修改 `config.toml`，也不修改已有 `z-codex-router-profile.toml` override；安全自动审批是独立明确 opt-in，绝不隐含启用。还要说明：v1.0.0 精确受管 block 会写入完整十条 `## 全局路由` 合同，并将这次明确 install/enable 记录为持久且范围受限的请求；路由需要时，父协调根可通过 `create_thread` 最多创建一个精确独立 Codex 任务。它不授权 sub-agent、第二个任务、外部不可逆动作、更大权限或替代人类审批。不要要求用户使用 CLI。

1. macOS/Linux 调用 `../../scripts/routerctl.sh dry-run`，Windows 调用 `../../scripts/routerctl.ps1 dry-run`。只有设置了 `CODEX_HOME` 时才传 `--codex-home`；否则让内部 launcher 解析标准 Codex home。
2. 展示 dry-run 的目标与计划写入。若报告冲突、权限错误、profile/runtime 不兼容或危险路径，立即停止并报告稳定错误码；不得绕过重试或手工改文件。
3. dry-run 成功后，用同一 launcher 调用 `install`。只有全部 preflight 通过才自动完成；事务失败会在返回前恢复原状态。
4. 调用 `doctor` 并要求 `OK_ENABLED`。只有活动版本使用当前 contract，且精确受管 block 同时包含 `## 全局路由` 与持久独立根授权时，才可声称它已生效。若必须新开 session 才能载入 plugin，回报“已安装但未启用”，唯一下一步是调用本 Enable skill。
5. 回报安装版本、backup 位置、Doctor 结果、持久独立根请求状态和 no-change 结果。host policy 接受持久明确请求时，后续路由任务不得要求用户重复确认；若 host policy 要求当前轮请求或明确拒绝持久请求，保留 `ROUTE_HANDOFF_REQUIRED` 及其精确、延续 receipt 的 follow-up。不要仅因普通任务需要路由就运行本 skill；启用后由受管全局入口生效。

## Safe Auto 审批相互独立

只有用户明确 opt-in 时，才用打包 launcher 调用 `safe-auto enable`。它只原子管理
`sandbox_mode = "workspace-write"`、`approval_policy = "on-request"` 与
`approvals_reviewer = "auto_review"`。随后运行 `safe-auto doctor` 或 `safe-auto status`。
Auto-review 不扩大 sandbox，也不替代 Computer Use、凭证或外部高风险/不可逆动作的人类授权。
停用时先运行 `safe-auto restore`（或 `safe-auto disable`），再卸载 router；它只恢复已备份的三个键，
遇到 drift 必须停止。
