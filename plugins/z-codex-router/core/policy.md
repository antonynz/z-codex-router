# 权限、失败与质量策略

## 写入与保护

- 写入前说明目标、读取输入、dry-run、计划变更、恢复边界和验收。
- 只管理具有稳定 ID、版本、格式和 SHA-256 的内容；保留未知文件、用户指令、BOM、换行风格及
  `config.toml`。
- 新安装把受管块放在全局 `AGENTS.md` 开头；非空全局 `AGENTS.override.md` 返回
  `E_GLOBAL_OVERRIDE_ACTIVE`，绝不修改 override。
- 状态使用 `z-codex-router/current/` 下的目录化小文件、不可变 `versions/<version>/`、锁目录、
  transaction 目录和逐字节 backup；不依赖通用 JSON/TOML runtime。
- `doctor --cwd <path>` 报告实际全局 instruction source、受管块字节范围、有效
  `project_doc_max_bytes`、项目/嵌套指令数量和 profile source/hash。受管块超出预算时返回
  `E_MANAGED_BLOCK_OUTSIDE_INSTRUCTION_BUDGET`。
- 写入型生命周期不解析或修改 `config.toml`；Doctor 只读取 `project_doc_max_bytes`，legacy cleanup
  只做逐字节 backup。旧 safe-auto 命令已删除。检测到 legacy safe-auto state 时，
  `legacy-cleanup` 要求先使用旧控制面 restore，绝不猜测或删除权限键。
- Profile override 位于不可变 payload 外。只有显式 profile 子命令管理它；reset/restore 使用受管
  backup 与 SHA-256 metadata。

## 失败处理

- 拒绝危险路径、链接、路径遍历、重复或漂移受管块、未完成事务、损坏 profile、无效 payload、
  global override 遮蔽、预算不可读和 legacy 状态。
- 失败返回稳定错误码，并保留用户文件和可恢复证据。不得手工绕过、uninstall-first、静默 fallback、
  无限重试或删除整个 `AGENTS.md`。
- `recover` 先校验 backup hash 与 transaction before hash；当前 AGENTS 只接受 before/after，
  current state 只接受 before/intermediate/after。其他值是用户/外部 drift，必须停止。
- `rollback` 若安装完成后用户继续修改过 `AGENTS.md`，则 fail closed；不得用旧整文件 backup 覆盖
  新用户内容。
- 旧 Rust 安装不迁移。新安装返回 `E_LEGACY_INSTALL_DETECTED`，必须按
  `legacy-cleanup --dry-run` → `legacy-cleanup` → fresh install 的顺序处理。

## Route create 结果

- 当前用户未明确授权创建新任务：`ROUTE_HANDOFF_REQUIRED`。
- `threadId`：`ROUTE_READY`。
- `clientThreadId`：`ROUTE_PENDING`，不是失败，禁止重试。
- 明确 destination tuple 拒绝：`ROUTE_DESTINATION_TUPLE_UNAVAILABLE`。
- 明确输入/项目拒绝：`ROUTE_INPUT_REJECTED`。
- 调用结果无法确认：`ROUTE_OUTCOME_UNKNOWN`，禁止重试。
- 不得把所有错误压成 `ROUTE_CREATE_FAILED`，不得自动降级、当前任务代做或 fallback 到
  `spawn_agent`。

## 质量与安全

- 测试 fixture 只能使用临时 Codex home，不得读写真实账号、认证或私有配置。
- 不记录 token、secret、认证、私有样本或不必要的 request metadata。
- 外部不可逆动作仍由具备权限的人明确确认；路由指令、profile、技能和自动化不能扩大该边界。
