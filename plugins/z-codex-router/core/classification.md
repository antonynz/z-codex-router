# 分类参考

在 `router.md` 的顺序之外不增加捷径。先把用户原始问题转成目标、边界、持久副作用、依赖、风险与可验证输出；不假设用户已经想清实现路径。

## 决策记录

记录分类依据而不是臆造精度：是否写入、输入/输出是否完整、需求/根因/关键取舍是否已知、影响面、状态复杂度、平台差异、敏感性和外部不可逆性。若必要事实缺失，标记 C1 或 blocker；不得把不确定性伪装成 B-tier 执行。

## Profile 隔离

本文件和 `router.md` 不包含模型名称。classification 输出的是 tier、mode、理由、风险和验收证据。profile resolver 在兼容性通过后才选择执行面；优先级是显式 user/session/CLI 选择 > 已验证的 `<codex_home>/z-codex-router-profile.toml` user override > shipped default。override 无效、未知或 disabled candidate 都停止，而不是隐式 fallback。

## 例外

当用户明确限定模型、effort、执行面或审批边界时，先验证该要求与 resolved profile、运行时 `create_thread` allowlist、角色权限和环境能力的交集。交集为空即报告 `ROUTE_PROFILE_RUNTIME_UNAVAILABLE` 或 route exception。用户请求不授予发送、签署、支付、发布、账户/权限变更或生产变更的权限。
