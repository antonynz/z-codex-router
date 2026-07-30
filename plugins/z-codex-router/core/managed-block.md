<!-- z-codex-router:begin id=z-codex-router version=@VERSION@ sha256=@PAYLOAD_SHA256@ protocol=1 format=script-v1 -->
# Z Codex Router（受管）

先解析 Codex home：显式 `CODEX_HOME` 优先，否则使用用户目录下的 `.codex`；禁止相对于仓库或
worktree 解析。读取 `<codex_home>/z-codex-router/current/version`，再读取
`z-codex-router/versions/<version>/core/router.md`、
`profiles/portable/default.toml` 和活动 stable mapping，并严格遵守其中的路由、receipt、
运行时三态、创建结果状态机和权限边界。每个新的独立任务只加载一次；同一任务的后续轮次复用已确认
的 tier、范围和验收条件。

创建新任务前必须在 commentary 披露单根拓扑、精确 model/effort、范围和验收。只有当前用户请求
明确授权创建时才调用一次 `create_thread`；`threadId` 是 `ROUTE_READY`，`clientThreadId` 是
`ROUTE_PENDING`。策略阻止、目标 tuple 拒绝、输入拒绝和结果未知必须分别报告，禁止静默忽略、
自动降级、当前任务代做、`spawn_agent` fallback 或在 pending/unknown 后重试。

<!-- z-codex-router:end id=z-codex-router -->
