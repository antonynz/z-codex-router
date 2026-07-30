---
name: router-doctor
description: 在不做修改的前提下检查 Z Codex Router 安装、managed block、指令预算、global override、payload hash、profile 与指定工作目录的指令链。
---

# Z Codex Router Doctor

macOS/Linux 调用 `../../scripts/routerctl.sh doctor`，Windows 调用
`../../scripts/routerctl.ps1 doctor`。需要检查某个项目时传 `--cwd <path>`。

Doctor 只读验证：

- `script-v1` state 与不可变 payload SHA-256；
- 全局 `AGENTS.md` 中唯一、完整且位于前缀的受管块；
- 非空全局 `AGENTS.override.md` 是否遮蔽 Router；
- 受管块起止字节与有效 `project_doc_max_bytes`；
- 指定 cwd 的项目/嵌套 instruction document 数量；
- default 或 user override mapping 的 source、path 与 normalized hash；
- pending transaction、legacy Rust state、链接、路径及受管内容 drift。

按原样报告结果。`OK_NOT_ENABLED` 只表示没有活动全局 Router state，不声称 plugin registration
存在。`E_TRANSACTION_PENDING` 路由到 Recover Router；`E_LEGACY_INSTALL_DETECTED` 只能走显式
legacy cleanup；其他非零结果不授权手工覆盖文件。
