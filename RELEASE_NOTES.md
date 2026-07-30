# Z Codex Router v1.0.0

v1.0.0 是重新定义后的首个公开基线。此前没有实际用户，本次发布不保留旧标签所表达的迁移历史。

- 修复新设备首次安装并启用后仍返回 `ROUTE_HANDOFF_REQUIRED`、必须再次发消息才能创建独立 Codex
  任务的问题。hash-managed `AGENTS.md` block 现在原样携带完整十条 `## 全局路由` 合同；用户明确
  install/enable 或 upgrade 即形成持久请求。tool policy 接受时，创建前 commentary 只作信息披露，
  父协调根立即进行同 scope、精确 tuple、最多一次的 `create_thread` 调用，不再要求第二次确认。
- 权限边界不扩大：该请求不授权 sub-agent、第二个任务、sandbox 扩权、外部不可逆动作，也不替代
  人类审批。host policy 明确拒绝持久请求、参数不支持、工具不可用或调用失败时仍 fail closed，并返回
  对应 route exception。
- 完整合同中的历史路径 `$CODEX_HOME/routing/router.md` 在受管入口中明确映射到不可变活动版本
  `z-codex-router/versions/<current.version>/core/router.md`；新设备不需要额外的未版本化文件。
- Doctor、upgrade、rollback 与 recover 统一校验当前 payload、profile、managed block 和 state，
  不再携带未发布基线的旧迁移分支。
- plugin skill、default prompt、Agent 安装协议与辅助文档以中文为主；`create_thread`、route receipt、
  model/effort、Doctor、Safe Auto、错误码与机器协议 token 保留英文。
- Release asset 覆盖 darwin/linux/windows 的 amd64/arm64 六个平台。tag workflow 会原生构建，
  生成 `SHA256SUMS`，验证完整 payload chain 后发布。
