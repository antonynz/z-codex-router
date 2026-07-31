---
name: setup-router
description: 启用 Z Codex Router 的全局任务路由策略。只在用户明确要求安装并启用、启用、安装或开启 Z Codex Router 时使用；不会管理审批、sandbox 或 config.toml。
---

# 启用 Z Codex Router

写入前说明选定 Codex home。本操作读取 plugin payload、`AGENTS.md`、全局
`AGENTS.override.md`、Router state 与存在时的 profile override；写入型步骤不解析或修改
`config.toml`，最终 Doctor 只读取其中的 `project_doc_max_bytes`。

1. macOS/Linux 调用 `../../scripts/routerctl.sh dry-run`；Windows 调用
   `../../scripts/routerctl.ps1 dry-run`。只有显式设置 Codex home 时才传 `--codex-home`。
2. 若返回 `E_LEGACY_INSTALL_DETECTED`，停止并要求严格执行
   `legacy-cleanup --dry-run` → 用户确认后的 `legacy-cleanup` → fresh install。不得迁移旧 Rust
   state、手工删块或 uninstall-first。
3. 若返回 `E_GLOBAL_OVERRIDE_ACTIVE`、profile、路径、budget、payload 或 drift 错误，保持用户文件
   不变并报告稳定错误码。
4. Dry-run 成功后调用 `install`，再调用 `doctor` 并要求 `OK_ENABLED`。若写入后的 Doctor 失败，
   立即运行一次 `rollback`；rollback 失败则停止并转 Recover，不得继续注册成功。受管块必须位于
   全局 `AGENTS.md` 的字节前缀（可在 UTF-8 BOM 后），且处于有效
   `project_doc_max_bytes` 内。
5. 报告版本、payload hash、backup、profile source/hash、持续路由根创建/解析/同任务协调授权状态和
   `start-a-new-task`。已有任务不会重新加载新指令或技能。

用户明确要求启用 Router，即持续授权它为路由创建独立模型根会话，并仅用
`list_threads`/`wait_threads`/`send_message_to_thread` 解析和协调同一任务，直至卸载。A0 在当前根
执行；A1–C3 的协调根必须调用一次 `create_thread`，有效 receipt 执行根不得递归创建。该授权不涵盖
对外发送、发布、生产或其他外部副作用。创建前生成唯一 correlation token 并写入 title/prompt。
`threadId` 为 `ROUTE_READY`，`clientThreadId` 为 `ROUTE_PENDING`；两者都进入 monitor，pending
禁止重建。Pending 优先显式 resolve，否则只接受 token+host+project/cwd+createdAt 时间窗全匹配且
唯一的 `list_threads` 结果；0 个继续有界等待，多匹配/超期进入 outcome-unknown needs-attention。
取得真实 threadId 后使用 cursor 增量、有界 timeout 等待，只转述新进展；偏差、阻塞或缺少验收
证据时向同一任务纠偏并省略 model/thinking，用户输入请求交还用户。其他拒绝或未知结果按 Router
合同分类，禁止降级、当前任务代做、重试 pending/unknown 或 fallback 到 `spawn_agent`。
