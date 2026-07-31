# Z Codex Router v1.0.1

Profile routing 优化：

- **B1**: Terra high → Luna max — 利用 Luna 降价 80% 后的极致性价比，适合范围明确、
  工作量大的多文件工程任务，允许低成本长链执行和反复测试修复。
- **B2**: Terra xhigh → Terra max — 应对异步状态、并发、性能、跨平台差异等复杂状态问题，
  Terra max 在 CursorBench (64.9%) 和 DeepSWE (70%±3%) 中提供比 Luna max 更紧凑的
  执行轨迹。
- **C1**: Sol medium → Sol high — 为未知需求、架构取舍和高风险判断提供更高质量的方向性
  决策。
- 新增 `current-gpt-5.6-no-luna-compatibility-candidate` candidate profile，面向不支持 Luna 的
  destination 提供不同 routing 的兼容评估；balanced stable mapping 保持不变。
- 更新 reference profile 元数据，标注交叉基准评估依据（CursorBench 3.2、DeepSWE、
  GPT-5.6 官方定位）。

默认宿主/会话根模型建议：**Sol medium**（理解 → 分类 → 下发 → 监督 → 验收的协调角色），
不由 profile 本身管控；该建议不覆盖 A0 的 current-qualified-root/runtime-qualified 或三态
fail-closed 语义。父协调与执行根的自然语言通信尽量跟随原用户主要语言，机器字段保持原样。

---

# Z Codex Router v1.0.0

本次 v1.0.0 重新定义为纯脚本公开基线：

- 运行时改为 macOS/Linux POSIX `sh` 与 Windows PowerShell 5.1+；删除 Rust、Cargo、Python
  实现/测试、平台 launcher、预编译可执行文件和审批配置命令。
- Release 只发布内容相同的 `z-codex-router-1.0.0.tar.gz`、
  `z-codex-router-1.0.0.zip` 与 `SHA256SUMS`。
- 新 `script-v1` 状态使用目录化小文件、不可变 payload、锁、逐字节 backup 和
  before/intermediate/after hash transaction；Recover 会先验证 backup hash。
- Managed block 前置到全局 `AGENTS.md`，保留 UTF-8 BOM、CRLF/LF 与用户 bytes。Doctor 新增
  `--cwd`、global override、block byte range、有效 `project_doc_max_bytes` 与 project instruction
  chain 诊断。
- Managed block 启动协议显式校验 `format`、`version` 与 `payload_sha256`，加载主 mode 并验证
  profile override。Enable 构成持续到卸载的 route-only 根创建授权：A0 当前执行，A1–C3 必须
  创建一次，有效 receipt 执行根不递归创建。
- Bootstrap 无需 PATH 中另装 CLI：会发现并验证 macOS ChatGPT/Codex bundle、Windows
  user-local/AppX 与 Linux user-bin/AppImage 中支持 plugin marketplace 的 Codex executable。
- 同版本重装会原子刷新已注册的受管 marketplace root，并在 plugin 注册失败时恢复旧 source 与旧
  plugin，不再因新的 cache 路径触发同名 marketplace 冲突。
- 旧 Rust/prebuilt 安装不迁移：必须执行显式 legacy cleanup dry-run、确认 cleanup，再 fresh
  install。Cleanup 先备份用户指令、配置和旧 state。
- 任务创建结果区分 `ROUTE_READY`、`ROUTE_PENDING`、`ROUTE_HANDOFF_REQUIRED`、
  `ROUTE_DESTINATION_TUPLE_UNAVAILABLE`、`ROUTE_INPUT_REJECTED` 与
  `ROUTE_OUTCOME_UNKNOWN`；pending/unknown 禁止重试。
- Ready 与 pending 都进入父协调 monitor。Pending 用父生成 token、host、project/cwd 与 createdAt
  时间窗唯一解析，取得 threadId 后以 `wait_threads` cursor 增量等待；只回传新进展，偏差、阻塞或
  验收证据不足时纠偏同一任务，用户输入请求交还用户。
- 公开 manifest/tag/Release 保持 `1.0.0`；本地 Codex marketplace cache 允许
  `1.0.0+codex.<timestamp>`。
- Git 历史已重写以清除所有编译可执行 blob。现有 clone 应重新 clone，或显式重新获取并重置到新
  `main`；旧提交 ID 不再有效。

本项目不会修改 `config.toml`，不会扩大 sandbox，也不替代用户对新任务、发布、生产或其他外部
不可逆动作的明确授权。
