---
name: router-doctor
description: 在不做修改的前提下检查 Z Codex Router 安装。用户要求校验 router 安装、managed block 完整性、payload hash、profile 或 runtime 兼容性时使用。
---

# Z Codex Router Doctor

macOS/Linux 调用 `../../scripts/routerctl.sh doctor`，Windows 调用
`../../scripts/routerctl.ps1 doctor`。该操作只读，检查所选安装的 state pointer、payload hash、
受管 `AGENTS.md` block、版本化 profile contract、disabled candidate 状态、
受支持 runtime platform，以及存在时的 Safe Auto 三键状态。当前 contract 还必须确认精确受管
block 包含完整十条 `## 全局路由` 合同与持久独立根授权。

按原样回报结构化结果。`OK_ENABLED` 包含有效 mapping source（`default` 或 `user override`）、path 与
mapping hash；无效 override 返回 `E_PROFILE_OVERRIDE_INVALID`，必须修复或显式 reset，绝不静默忽略。
reset backup 只能从受管 backup 目录通过 `profile restore <backup>` 恢复；不要建议手工覆盖。
`OK_NOT_ENABLED` 只证明没有 router 受管全局状态，不声称检查 plugin registration。Safe Auto 状态报告
active/absent，drift 属于校验失败。非零结果不授权手工修文件；将 `E_TRANSACTION_PENDING` 或
`E_SAFE_AUTO_TRANSACTION_PENDING` 路由到 Recover Router，其他情况只有在 Enable 或 Upgrade 的
preflight 能安全处理稳定错误码时才建议对应操作。
