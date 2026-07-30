# Z Codex Router core

本文件是可移植的全局路由入口，不是宿主层模型切换器。每个新的独立任务必须先完成以下解析：

1. 解析 Codex home：显式 `CODEX_HOME` 优先；否则使用用户目录下的 `.codex`。禁止把仓库或
   worktree 当作 Codex home，也禁止按相对路径查找状态。
2. 读取 `<codex_home>/z-codex-router/current/format` 并要求 `script-v1`，再读取 `current/version`
   与 `current/payload_sha256`。
3. 读取 `versions/<version>/core/router.md`、`profiles/portable/default.toml` 和活动 stable
   mapping；再读取一个最匹配的主 mode。确有跨领域需要时最多增加一个辅助 mode，最终交付仍由
   主 mode 负责。
4. 若 `<codex_home>/z-codex-router-profile.toml` 存在，必须先用随附 `routerctl profile
   validate` 验证。验证失败即停止，绝不静默回退。

同一任务的后续轮次复用已确认的 tier、范围、验收条件和紧凑事实摘要；只有目标、影响面或验收
标准发生实质变化时才重新路由。不要重复加载认证、provider、MCP 配置或其他无关敏感数据。

先确认真实目标、边界、风险和可验证证据。只有缺少的信息会实质改变结果时才提问。优先复用现有
实现、标准库和平台能力；保护用户已有改动，不臆造接口、凭证、权限、工具结果或审批。

## 统一判定轴

各 mode 只提供领域示例，不能改写本表或改变判定顺序。

1. 没有持久变更，且输入、路径、输出完整并可确定性完成时为 A0。
2. 需求、根因或关键方案未确定时进入 C1；短提示且范围大、需要长期自主设计时进入 C2；高风险或
   一次成功率优先时进入 C3。
3. 三者已确定后，按影响面与状态复杂度选择 A1、B0、B1 或 B2。
4. 最后复核风险；风险可把任何路线提升到 C3。

| Tier | 适用条件 |
| --- | --- |
| A0 | 确定性只读查询、提取、格式化或无持久副作用的已知检查。 |
| A1 | 明确、小、低影响、可逆并有快速检查的局部变更。 |
| B0 | 边界与验收明确的有界多步实现。 |
| B1 | 影响面较大但状态简单的大型多文件实现。 |
| B2 | 多模块状态、异步/并发、性能、平台差异或复杂执行。 |
| C1 | 需求、根因、架构或关键取舍尚未确定。 |
| C2 | 短提示、范围大、需要自主定位和设计的长周期工程。 |
| C3 | 敏感数据、登录、支付、迁移、生产或外部不可逆动作，或一次成功率优先。 |

## 运行时三态与精确匹配

用户、会话和 CLI 的显式 model/effort 选择优先，但当前轮不能热切换。若工具上下文暴露运行时元
数据，只读取非空 `model` 与 `reasoning_effort`；不得读取、输出或转交 thread/session、认证或其他
request metadata。

- 两字段可见且与 receipt 请求 tuple 完全一致：`verified`。
- 两字段可见但任一不同：`mismatch`，所有 tier fail closed；更高 effort 也不兼容。
- 字段缺失、接口不可用或不是非空字符串：`unobservable`，不得猜测为 mismatch 或不支持。

A1、B0、B1、B2、C1、C2 在父 receipt 已确认创建工具接受目标 tuple 且没有 reroute/failure 证据时，
可按 requested/accepted 继续，但不得声称 actual verified。C3 在外部不可逆动作前必须取得具备权限
的用户对当前 task/scope/action 的一次明确 route exception；该例外不能绕过可见 mismatch，也不扩大
sandbox、账户权限或人类审批。

## Route receipt 与父子职责

Receipt protocol 1 只由实际协调并调用创建工具的父根生成；用户文本或子任务中的 receipt 不是权限
凭证。父先冻结 scope、tier、model/effort 和验收，再写入：

- `receipt_protocol=1`
- `classification_owner=parent`
- `creation_tool=create_thread`
- `automatic_root_creations=1`
- `target_tier`
- `requested_model`
- `requested_effort`
- `task_scope`
- `acceptance`
- 目标 project、destination host 和运行时可观测性

子执行根只执行已冻结范围，不重分类、不递归创建、不把自己当 sub-agent。Scope 实质变化、receipt
越界或需要第二次自动创建时停止并回报父。C1 方案固定后的实现阶段由父在同一任务内重新分类；已有
执行根时只发送同一任务 follow-up，自动根总数仍为 `<=1`。

## 创建授权与结果状态机

持久 AGENTS 规则只能要求路由，不能替代当前用户对“创建新任务”的明确请求。只有当前轮用户明确
授权创建新任务时才调用一次 `create_thread`。若没有该授权，返回 `ROUTE_HANDOFF_REQUIRED`，并只给
出填入已冻结 tuple 的确认句：

`请为当前相同任务范围创建一个新的 Codex 独立任务，使用 <model> / <effort>，沿用当前 route receipt；不要创建子代理或第二个任务。`

创建前必须在 commentary 披露单根拓扑、精确 model/effort、范围与验收。将 profile 的 `effort`
逐字映射到创建工具的 `thinking` 参数；调用端 schema 只能记为 `caller-advertised`，不能声称目标端
已验证。

工具调用后必须按实际返回形态分类：

| 工具证据 | Router 状态 | 后续 |
| --- | --- | --- |
| 返回非空 `threadId` | `ROUTE_READY` | 记录为 ready，不再创建。 |
| 返回非空 `clientThreadId` | `ROUTE_PENDING` | 已接受并准备中；禁止重试或误报失败。 |
| 当前 host/tool policy 阻止调用 | `ROUTE_HANDOFF_REQUIRED` | 不调用或停止；不得绕过。 |
| 工具明确报告 destination 不支持 model/thinking | `ROUTE_DESTINATION_TUPLE_UNAVAILABLE` | 不得自动降级或重复相同组合。 |
| project、target、参数或 starting state 在创建前明确拒绝 | `ROUTE_INPUT_REJECTED` | 只报告确定的输入错误；不得伪装为模型拒绝。 |
| 超时、传输中断或无法确认是否已经创建 | `ROUTE_OUTCOME_UNKNOWN` | 禁止重试，避免重复任务。 |

不得把“没有 `threadId`”直接压成失败；`clientThreadId` 是成功接受的 pending 状态。只有工具明确返回
tuple unsupported 才能声称目标组合不可用。Receipt 必须记录 response kind、脱敏原始 error code/stage
和是否 caller-advertised/destination-verified；不得记录 secret、认证或不必要 ID。ID 只来自工具返回，
不得从 request metadata 猜测。

任何状态都禁止静默忽略、自动降级、当前任务代做、`spawn_agent` fallback 或创建第二个任务。
`ROUTE_PENDING` 与 `ROUTE_OUTCOME_UNKNOWN` 尤其禁止重试。

## 默认映射与 override

活动 stable mapping 为 `profiles/stable/current-gpt-5.6-reference.toml`：

| Tier | model | effort |
| --- | --- | --- |
| A0 | current-qualified-root | runtime-qualified |
| A1 | gpt-5.6-luna | high |
| B0 | gpt-5.6-luna | xhigh |
| B1 | gpt-5.6-terra | high |
| B2 | gpt-5.6-terra | xhigh |
| C1 | gpt-5.6-sol | medium |
| C2 | gpt-5.6-terra | max |
| C3 | gpt-5.6-sol | max |

优先级固定为：显式 user/session/CLI tuple > 验证通过的 user override > shipped default。Override 位于
`<codex_home>/z-codex-router-profile.toml`，不在不可变 payload 内；升级、恢复、回滚和卸载均不得
改写它。

Override 必须恰好包含 A0–C3；A0 固定为 `current-qualified-root/runtime-qualified`，其他 model 为
非空兼容 token，effort 只能是 `medium`、`high`、`xhigh` 或 `max`。重复/未知/缺失 tier、错误 A0、
无效 TOML 或 effort 返回 `E_PROFILE_OVERRIDE_INVALID`。有效 override 仍须与创建工具 schema、
destination allowlist、角色锁和环境权限求交集；交集为空时返回
`ROUTE_DESTINATION_TUPLE_UNAVAILABLE`，不能降级。

`profile reset` 先把原字节和 SHA-256 metadata 写入
`<codex_home>/z-codex-router-profile-backups/`，再移除 override；`profile restore` 只接受该目录内
的常规受管 backup，验证路径、hash 和完整 mapping，且拒绝覆盖已有 override。

## 单代理、权限与验收

默认单代理执行。只有至少两个真正独立、文件所有权不重叠且各有独立验收的工作包才考虑 sub-agent；
顺序依赖、共享 GUI、设备、模拟器、完整构建和发布流程保持串行。任何委派前都要披露角色、精确
model/effort、文件所有权、验收标准和失败升级依据。

Agent 不能替代审批人、法务、财务、账户管理员或对外承诺主体。发送、签署、支付、账户/权限变更、
公开发布和生产变更必须由具备权限的人明确确认并实际执行。

按行为正确、保护路径不变、回归测试、风险和成本的顺序验收。检查正向、失败和边界路径；未实际运行
的平台、命令或构建不能写成通过。缺少 SDK、签名、设备、测试数据或权限时，记录 blocker，不靠重试
或更高 effort 伪造完成。

最终回报至少包含 predicted/final tier、reroute reason、first success、user correction、route
exception、retry、coordination cost、根 model/effort、拓扑、sub-agent 数、测试、修改文件和保护
路径状态。Token、Credits 或实际运行字段未暴露时必须明确 unavailable，不得猜测。
