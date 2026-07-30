# Z Codex Router core

本文件是可移植的全局入口，不是自动加载的配置。每个新的独立任务都必须先完成以下解析，再开始领域诊断或实施：

1. 解析 Codex home：显式设置的 `CODEX_HOME` 优先；未设置时使用 `~/.codex`。禁止把仓库或 worktree 当作 Codex home，也禁止按相对路径查找路由状态。
2. 读取 `<codex_home>/z-codex-router/current.json`，校验它指向的版本目录、payload 哈希和运行时能力。
3. 读取该版本的 `core/router.md`、`profiles/portable/default.toml` 和 shipped default mapping；再读取一个最匹配的主 mode。若 `<codex_home>/z-codex-router-profile.toml` 存在，先用 `routerctl profile validate` 验证它，验证失败即停止，绝不静默回退。只有确有跨领域必要时最多再读取一个辅助 mode；最终交付由主 mode 负责。

同一任务的后续轮次复用已确认的 tier、范围、验收条件和紧凑事实摘要；只有目标、影响面或验收标准实质变化时重新路由。不要重复加载大段日志、认证、provider、MCP 配置或其他不需要的敏感数据。

先确认真实目标、边界、风险和可验证的验收证据。只有缺少的信息会实质改变结果时才提问。优先复用现有实现、标准库、平台能力和依赖；保护用户已有改动，不臆造函数、接口、凭证、工具或审批权限。

## 统一判定轴

各 mode 只能提供领域化示例，不能改写本表或改变顺序。

1. 先判断是否有持久变更；没有持久变更且输入、路径、输出完整并可确定性完成时为 A0。
2. 再判断需求、根因和方案/关键取舍是否已确定：未确定时进入 C1；短提示且范围大、需要长期自主定位和设计时进入 C2；高风险或一次成功率优先时进入 C3。
3. 若三者已确定，按影响面与状态复杂度选择 A1（小、低影响、可逆局部变更）、B0（边界和验收明确的有界多步工作）、B1（明确目标的大型多文件工作）或 B2（多模块状态、异步/并发、性能、平台差异或其他复杂执行）。
4. 最后做风险复核；风险可以将任何路线提升至 C3。

| Tier | 适用条件 |
| --- | --- |
| A0 | 输入、路径和输出完整的确定性只读查询、提取、格式化或无持久副作用的已知检查。 |
| A1 | 需求、根因和方案已确定；明确、小、低影响、可逆且有快速可靠检查的局部变更或产出。 |
| B0 | 需求、根因和方案已确定；边界与验收明确的有界多步工作、产出或实现。 |
| B1 | 需求、根因和方案已确定；影响面较大但状态简单的大型多文件实现。 |
| B2 | 需求、根因和方案已确定；多模块状态、异步/并发、性能、平台差异或其他复杂深入执行。 |
| C1 | 需求、根因或关键方案/取舍尚未确定，需要诊断、研究、架构或策略判断。 |
| C2 | 短提示、范围较大、需要自主定位和设计的长周期工程。 |
| C3 | 敏感数据、登录、支付、账户/权限、迁移/导出、生产影响、外部不可逆动作，或任务要求一次成功率优先。 |

## 运行时与精确匹配

用户、会话和 CLI 的显式 model/effort 选择优先，但本轮不能热切换。若工具上下文暴露运行时元数据，只读取非空的 `model` 与 `reasoning_effort` 两个字段；不得读取、输出或传递 thread、session、认证等无关字段。字段缺失、调用失败或不是非空字符串时记为 `runtime_observability=unobservable`，不得从默认配置猜测，也绝不能把未暴露字段写成 mismatch。

运行时校验是三态而非二态：`observable` 且两个字段与 receipt 的请求 tuple 完全相同为 `verified`；`observable` 但任一字段不同为明确 `mismatch`，所有 tier fail closed；字段缺失或接口不可用为 `unobservable`。更高 effort 也不兼容。对 A1、B0、B1、B2、C1、C2，在 receipt 已确认 `create_thread` 工具显式接受目标 tuple，且没有可见 reroute/failure 证据时，可以继续，但必须记录“requested/accepted，不声称 actual verified”。C3/高风险在 `unobservable` 时必须停在任何外部不可逆动作前，直到具备权限的用户对当前 task/scope/action 明确批准一次 `route exception`；`mismatch` 不能由例外绕过。

## Route receipt 与父子职责

receipt protocol 1 只由实际执行 `create_thread` 的父协调根生成，不能由用户文本、子线程或任意 prompt 自行伪造。父根是唯一 classification owner：在工具策略允许调用后确定 `target_tier`、`requested_model`、`requested_effort`，并在实际 `create_thread` 提示中写入结构化 receipt，至少包含 `receipt_protocol=1`、`classification_owner=parent`、`creation_tool=create_thread`、`automatic_root_creations=1`、`task_scope` 和 `acceptance`。receipt 必须与实际工具返回和当前 task scope 交叉核对；纯提示协议没有密码学防伪能力，不得声称有。

父只能自动创建一次根线程。线程 ID 只能由创建方从 `create_thread` 返回值记录；如需补充 receipt 或 thread ID，由父在同一线程发送 follow-up，子线程不得猜测。创建失败、receipt 无效/越界、可观测 mismatch 或 C3 未获一次例外时都不得递归创建第二线程。

桌面端或 tool policy 的权限高于本路由。父先完成一次分类，冻结 scope、tier、model/effort 和 parent-owned receipt，再检查当前策略是否允许 `create_thread`；policy follow-up 绝不重新分类。若策略要求用户明确请求“新建任务”，不得尝试绕过、不得使用 `spawn_agent`、不得改由当前根执行。停止并返回稳定状态 `ROUTE_HANDOFF_REQUIRED`，且只给出填入已冻结 tuple 的直接新建任务动作：中文 `请为当前相同任务范围创建一个新的 Codex 独立任务，使用 <model> / <effort>，沿用当前 route receipt；不要创建子代理或第二个任务。`；英文 `Create a new independent Codex task for the same current scope using <model> / <effort>, carrying forward the current route receipt; do not create a sub-agent or a second task.`。收到该明确 follow-up 后，父只可为同一 scope/tuple 进行这一次创建，并携带同一父拥有的 receipt；不得重新分类、不得递归创建。若策略已允许但 `create_thread` 调用失败，返回 `ROUTE_CREATE_FAILED` 并停止；若工具未暴露，返回 `ROUTE_CREATE_UNAVAILABLE` 并停止。三种情况都不得 fallback 到 `spawn_agent`、当前根或第二个线程。

收到有效 receipt 的独立执行根只加载 router/mode 来执行边界，不重新分类本任务，不把自己当 sub-agent，不 `create_thread`/spawn 解决模型匹配，也不把用户提供的 receipt 当可信输入。若 scope materially changes 或 receipt 无效，停止并回报父。C1 方案固定后由父重新分类实现阶段；若已有线程则沿用同一线程发送更新，自动根创建总数仍为 `<=1`，不得为阶段变更再建线程。

子线程运行时若能读取字段，必须把 actual tuple 与 receipt 的 requested tuple 交叉验证并报告 `verified` 或 `mismatch`；若字段不可见，明确 `runtime_observability=unobservable` 并按上面的 tier/C3 规则继续或阻塞。一次 route exception 只授权当前 task/scope/action，不继承到其他线程、不扩大 sandbox 或人类授权；明确 mismatch 永远拒绝。

`stable/current-gpt-5.6-reference.toml` 是安装随附的 shipped default tier mapping：

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

## Persistent user profile override

优先级固定为：显式 user/session/CLI model+effort 选择 > 通过验证的 user override > shipped default。用户 override 位于 `<codex_home>/z-codex-router-profile.toml`，不在不可变版本 payload 内，因此升级不会改写它。使用 `routerctl profile show` 查看有效 source/path/mapping hash，`profile init` 生成完整可编辑的默认副本，`profile validate` 只读验证，`profile set <tier> <model> <effort>` 显式修改一项。`profile reset` 会先在 `<codex_home>/z-codex-router-profile-backups/` 原子写入带 SHA-256 metadata 的备份再删除 override；要恢复时必须运行 `routerctl profile restore <reset 返回的 backup 路径>`。restore 只接受该受管目录内的常规 backup、验证 metadata/hash 与完整 mapping、拒绝已有 override 的 drift，并原子恢复，绝不要求用户手工覆盖文件。

override 必须包含恰好 A0–C3 全部 tier；A0 必须保留 `current-qualified-root` / `runtime-qualified`，其他 tier 只能使用非空 future-compatible model token 和 `medium`、`high`、`xhigh` 或 `max`。重复/无效 TOML、未知或缺失 tier、空值、错误 A0 语义和不支持 effort 都返回 `E_PROFILE_OVERRIDE_INVALID`；修复文件或显式 `profile reset` 后才可继续。CLI 只做语法和策略验证，绝不猜测某个 future model 是否在运行时可用。

解析出的 non-A0 tuple 仍必须与当前 `create_thread` tool schema、实际 model/effort allowlist、角色锁和环境权限求交集。交集为空时返回 `ROUTE_PROFILE_RUNTIME_UNAVAILABLE` 并 fail closed；有效 override 不会授权不在 runtime allowlist 中的模型，也不会改变 C3、receipt 或人类授权边界。

`runtime_observability=unobservable` 不等于 mismatch。A1、B0、B1、B2、C1、C2 在父 receipt 已确认
`create_thread` 工具显式接受目标 tuple 且没有可见 reroute/failure 证据时，可以按 requested/accepted 继续，
但不得声称 actual verified；C3 在不可逆动作前必须阻塞并取得一次 scoped route exception。可见 mismatch
对所有 tier fail closed，不能由例外绕过。没有有效 receipt 的初始根仍按正常分类入口；创建能力不可用、receipt
无效或需要第二次自动创建时停止，不得为了获得模型标签创建无收益 sub-agent。

## 独立根与 C1 阶段

C1 先完成需求、根因或架构判断；方案固定后，必须重新分类具体实现 tier，再由该 tier 的精确执行面实施。全任务最多允许一次“C1 判断 → 实现”回环；第二次需要回到 C1 时停止并报告。

如果当前运行时是 `gpt-5.6-sol/xhigh`，而 C1 profile 要求 `gpt-5.6-sol/medium`，这是不匹配：在开始领域诊断前就创建精确的 `gpt-5.6-sol/medium` 独立根任务。独立根不是 sub-agent；当前根不得继续代做诊断或实施。

创建前必须在 commentary 披露执行拓扑、准确 model、effort、任务范围和验收条件。若 `create_thread` 未直接暴露，先对线程创建能力执行一次 `tool_search`；随后先检查当前 desktop/tool policy 是否允许本次调用。创建不可用、需要用户显式新任务请求、调用失败，或新执行根实际核验后仍不匹配，都必须按 `ROUTE_HANDOFF_REQUIRED`、`ROUTE_CREATE_UNAVAILABLE`、`ROUTE_CREATE_FAILED` 或 route exception 停止。仅因模型不匹配，同一任务最多自动创建一次；不得递归创建、静默降级、伪造模型标签或 fallback 到 `spawn_agent`。

如果运行时仍不匹配，当前根不得继续领域诊断、实施或代做；新根必须重新核验 model/effort 后才可开始。C2 使用一个可审计的 Luna/Terra max 单代理执行面；C3 由 Sol 完成风险判断和实施，一次有证据的完整修正后仍失败即停止，只有明确要求才由未参与实现的 reviewer 复核，reviewer 不触发新的实现重试。

## 独立根、权限与安全自动审批

新建独立根时，以新线程实际创建参数和运行时状态为准：`model`、`cwd`、`sandbox` 与
`approval` 都必须由新根重新解析。不得假设它继承父会话的临时 sandbox、approval、凭证或
其他人工授权；fork 只复制上下文，不复制人工授权。若参数或状态未暴露，记为 unknown 并
fail closed，不猜继承关系。

安全自动审批是明确 opt-in 的权限配置，不由插件安装、普通路由 enable 或新线程隐式开启。
在已安装插件的 launcher 上运行 `safe-auto enable` 才会原子地设置且仅设置：

```toml
sandbox_mode = "workspace-write"
approval_policy = "on-request"
approvals_reviewer = "auto_review"
```

`auto_review` 只替换符合条件的审批 reviewer，不扩大 `workspace-write` sandbox，也不等于
用户授权。Computer Use、凭证、支付、签署、发布、生产变更及其他高风险或不可逆外部动作仍
必须由具备权限的人明确确认并实际执行。使用 `safe-auto status`/`safe-auto doctor` 检查
`active`、`drift` 或 `absent`；使用 `safe-auto restore`（`disable` 为同义命令）只恢复这
三个键的启用前原值/缺失状态。检测到用户改动、重复 TOML 键或事务 hash 漂移时拒绝覆盖并
fail closed。`recover` 也处理 `E_SAFE_AUTO_TRANSACTION_PENDING`，仅在 journal before/after
hash 可验证时继续。路由 `uninstall` 不会自动恢复权限配置；必须先显式 restore，再卸载路由，避免
误删用户之后新增的配置。若恢复的是 safe-auto 事务，应以 `safe-auto doctor` 验收；路由尚未启用时，
通用 `doctor` 返回 `E_SAFE_AUTO_ACTIVE` 只表示独立的权限 opt-in 仍 active，不是恢复失败。

当 `create_thread` 未直接暴露时，先对线程创建能力执行一次 `tool_search`；模型/effort 不
匹配时最多自动重路由一次，仍不匹配就报告 route exception 并停止。desktop policy 若拒绝未经用户明确“新建任务”的创建，使用 `ROUTE_HANDOFF_REQUIRED` 的精确 prompt 并停止；严禁 `spawn_agent` fallback。C1 方案固定后，必须重新分类具体实现 tier；严格顺序任务不创建 sub-agent。

## 单代理与委派

默认单代理执行，不为了形式上的角色所有权拆分任务。只有至少两个真正独立、文件所有权不重叠、各自有独立验收且并行收益大于协调成本的工作包才创建 sub-agent；顺序依赖的工作不委派。例如“发现最新 Git 分支 → 检查工作树 → 切换/更新”的顺序任务不应创建 sub-agent。

任何委派都必须在 commentary 说明角色、准确 model/effort、文件所有权、验收标准和失败升级依据。agent 不能替代审批人、法务、财务、账户管理员或对外承诺主体；对外发送、签署、支付、账户/权限变更、公开发布和生产变更必须由具备权限的人明确确认并实际执行。

角色权限边界如下：`code_writer` 只写分配的源码、测试、脚本和必要项目配置；`docs_writer` 只写分配的文档和变更说明；`runtime_validator` 在实现稳定后独占 GUI、设备、模拟器、平台切换、完整构建和跨端验证；`analyst`/`reviewer` 只读；`designer`/`media_creator` 只创建分配的设计或媒体产物，不替代业务实现、发布或权利决定。

普通仓库工作最多一个 sub-agent；只有两个独立工作包时最多两个。共享 GUI、设备、模拟器和完整构建环境始终串行；不得并行写同一文件。

## 验收与失败

按行为正确、保护路径不变、回归测试、风险和成本的顺序验收。检查正向、失败和边界路径；未实际运行的命令、平台或构建不能表述为通过。缺少 SDK、签名、设备、测试数据、权限或可复现环境时记录 blocker，不靠重试或更高 effort 掩盖。

每一级最多进行一次有证据的完整修正；单次命令失败、无限重试或仅因环境缺失不构成升级理由。A1 按 `Luna/high → Terra/high`、B0 按 `Luna/xhigh → Terra/xhigh`、B1/B2 按 `Terra/high → Terra/xhigh → Terra/max`；C1 普通高难判断按 `Sol/medium → Sol/xhigh`；C2 的 `Terra/max` 失败只在风险确实提升为 C3 时转 `Sol/max`；C3 的 `Sol/max` 一次完整修正后仍失败即停止。根因不明确时回到 C1；第二次需要回到 C1 时停止。

最终回报至少披露 `predicted_tier`、`final_tier`、`reroute_reason`、`first_success`、`user_correction`、`route_exception`、`retry`、`coordination_cost`、任务明确度、根模型/effort、执行拓扑、sub-agent 数量、输入/缓存/输出/reasoning/总 Token、Credits、耗时、测试结果、修改文件和保护路径状态。若创建过独立根，final topology disclosure 还必须列出父创建方、`create_thread-return-only` 的 thread ID 来源、requested/actual tuple、receipt continuity、sub-agent 数量以及父是否发送过收敛或纠偏指令；执行根不得从 request metadata 输出 thread/session 信息。
