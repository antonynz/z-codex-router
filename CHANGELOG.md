# 变更日志

## 1.0.1 - 2026-07-31

- 优化 GPT-5.6 profile routing 映射：B1 从 Terra high 改为 Luna max（利用 Luna 降价 80% 后的
  极致性价比，适合范围明确、工作量大的执行任务）；B2 从 Terra xhigh 改为 Terra max（应对
  异步/并发/性能/跨平台等复杂状态问题）；C1 从 Sol medium 改为 Sol high（为未知架构取舍
  提供更高质量的判断）。
- 新增 balanced-luna-max candidate profile（同 routing 映射），作为下一轮默认 profile 候选。
- 基于 CursorBench 3.2、DeepSWE 及 GPT-5.6 官方定位交叉评估更新 reference profile 说明。

## 1.0.0 - 2026-07-30

- 将控制面、测试和打包重构为 POSIX sh 与 Windows PowerShell 5.1+。
- 删除 Rust、Cargo、Python、平台/架构 executable 和审批配置命令。
- 引入 `script-v1` 目录状态、原子 managed prefix、transaction recover、rollback drift protection
  和 hash-managed profile backup/restore。
- Managed block 前置，并新增 global override、指令预算和 `doctor --cwd` 检查。
- 新增显式 `legacy-cleanup`，旧安装必须清理后 fresh install。
- 修正 `clientThreadId` 被误判为创建失败的问题，并细分 policy、destination tuple、input 与 unknown
  outcome。
- 让 ready/pending 都进入父协调 monitor；pending 以父生成 token、host、project/cwd 与 createdAt
  时间窗唯一解析，随后用 `wait_threads` cursor 增量等待，并在偏差、阻塞或证据不足时纠偏同一任务。
- 强化全局 `AGENTS.md` 受管块：显式校验 format/version/payload、加载主 mode、验证 profile
  override，并将 enable 定义为持续的路由根创建授权；A0 当前执行，A1–C3 必须创建一次，有效
  receipt 执行根不递归创建。
- 安装器在 PATH 之外发现并能力探测 macOS ChatGPT/Codex bundle、Windows user-local/AppX 与
  Linux user-bin/AppImage 中的 Codex executable。
- 同版本重装原子刷新已注册的受管 marketplace root；注册失败时恢复旧 source 与旧 plugin，避免
  因唯一 cache 路径变化触发同名 marketplace 冲突。
- Release 收敛为相同内容的 tar.gz/zip 源码包和 SHA-256。
- 重写全部可达 Git 历史，清除编译可执行 blob，保留 PNG 文档图片。
