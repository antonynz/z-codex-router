# 变更日志

## 1.0.0 - 2026-07-30

- 发布重新定义后的首个公开基线；此前没有实际用户，因此不保留未采用版本的迁移历史。
- 新设备首次启用时，hash-managed `AGENTS.md` block 写入完整十条 `## 全局路由` 合同。明确
  install/enable 或 upgrade 会形成持久请求；tool policy 接受时，commentary 披露后直接进行一次同
  scope、精确 tuple 的 `create_thread` 调用，无需用户发送第二条消息。
- 路由继续 fail closed：持久请求只覆盖同一 task scope 的一个精确独立根，不授权 sub-agent、第二个
  任务、sandbox 扩权、外部不可逆动作或替代人类审批。host policy 明确拒绝、工具不可用、参数不支持
  或调用失败时，以对应 route exception 停止。
- 将合同中的历史名称 `$CODEX_HOME/routing/router.md` 映射到不可变活动版本
  `z-codex-router/versions/<current.version>/core/router.md`；新设备无需额外的未版本化路由文件。
- Doctor、upgrade、rollback、recover、bootstrap、profile、Safe Auto 与 route receipt 使用统一的
  v1.0.0 合同和回归测试；移除未发布版本专用的迁移分支与 fixture。
- 除 README 外，面向用户的项目文档与 plugin skill 以中文为主，必要的特殊名词和机器 token 保留英文。
