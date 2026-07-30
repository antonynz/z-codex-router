# 变更日志

## 1.0.0 - 2026-07-30

- 将控制面、测试和打包重构为 POSIX sh 与 Windows PowerShell 5.1+。
- 删除 Rust、Cargo、Python、平台/架构 executable 和审批配置命令。
- 引入 `script-v1` 目录状态、原子 managed prefix、transaction recover、rollback drift protection
  和 hash-managed profile backup/restore。
- Managed block 前置，并新增 global override、指令预算和 `doctor --cwd` 检查。
- 新增显式 `legacy-cleanup`，旧安装必须清理后 fresh install。
- 修正 `clientThreadId` 被误判为创建失败的问题，并细分 policy、destination tuple、input 与 unknown
  outcome。
- Release 收敛为相同内容的 tar.gz/zip 源码包和 SHA-256。
- 重写全部可达 Git 历史，清除编译可执行 blob，保留 PNG 文档图片。
