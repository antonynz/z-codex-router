<!-- z-codex-router:begin id=z-codex-router version=@VERSION@ sha256=@PAYLOAD_SHA256@ protocol=1 format=script-v1 -->
# Z Codex Router（受管）

先解析 Codex home：显式 `CODEX_HOME` 优先，否则使用用户目录下的 `.codex`；禁止相对于仓库或
worktree 解析。依次读取 `<codex_home>/z-codex-router/current/format`、`version` 和
`payload_sha256`，要求 `format=script-v1`；再读取版本 payload 内的 `core/router.md`、
`profiles/portable/default.toml`，按其 `selection.stable_profile` 解析 stable profile，再读取最匹配的主 mode，并严格遵守其中的路由、
receipt、运行时三态、创建结果状态机和权限边界。存在用户 profile override 时必须先验证，失败即
停止。每个新的独立任务只加载一次；同一任务的后续轮次复用已确认的 tier、范围和验收条件。

用户启用本受管块即持续明确授权 Router 为路由而创建新/后台独立模型根会话，并仅用
`list_threads`/`wait_threads`/`send_message_to_thread` 解析和协调该同一任务，直到卸载 Router；
不授权对外发送、发布、生产变更或其他外部副作用。无有效父 receipt 的协调根：
A0 在当前根执行；A1–C3 必须先在 commentary 披露单根拓扑、精确 model/effort、范围和验收，再恰好
调用一次 `create_thread`，禁止留在当前任务代做。携带有效 receipt 的执行根直接执行冻结范围，禁止
递归创建。创建前生成唯一 correlation token 并写入 title/prompt。`threadId` 是 `ROUTE_READY`，
`clientThreadId` 是 `ROUTE_PENDING`；两者都进入 monitor，pending 禁止重建，优先显式 resolve，否则
仅接受 token+host+project/cwd+createdAt 时间窗全部匹配且唯一的 `list_threads` 结果；0 个继续有界
等待，多匹配/超期为 outcome-unknown needs-attention。取得 threadId 后用 cursor 增量、有界 timeout
的 `wait_threads` 持续到明确终态；只转述新进展，偏差/阻塞/缺证据时向同一任务纠偏且保留
model/thinking，用户输入请求必须转交用户。receipt、进展、纠偏、用户输入转交和最终回报应尽量跟随
原用户主要语言；原用户使用中文时，线程间自然语言通信也尽量使用中文。该规则不改写机器字段、tier、
model/effort、opaque token、路径、命令、错误码或协议键。策略阻止、目标 tuple 拒绝、输入拒绝和结果
未知必须分别报告，禁止静默忽略、自动降级、`spawn_agent` fallback 或在 pending/unknown 后重试。

<!-- z-codex-router:end id=z-codex-router -->
