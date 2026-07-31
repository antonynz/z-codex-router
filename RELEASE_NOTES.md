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
- 公开 manifest/tag/Release 保持 `1.0.0`；本地 Codex marketplace cache 允许
  `1.0.0+codex.<timestamp>`。
- Git 历史已重写以清除所有编译可执行 blob。现有 clone 应重新 clone，或显式重新获取并重置到新
  `main`；旧提交 ID 不再有效。

本项目不会修改 `config.toml`，不会扩大 sandbox，也不替代用户对新任务、发布、生产或其他外部
不可逆动作的明确授权。
