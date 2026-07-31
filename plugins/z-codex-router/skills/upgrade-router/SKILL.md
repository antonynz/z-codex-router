---
name: upgrade-router
description: 安全 dry-run 并升级已有 script-v1 Z Codex Router。只在用户明确要求升级或 rollback 已完成升级时使用；旧 Rust 安装必须先显式清理再全新安装。
---

# 升级 Z Codex Router

1. 使用最新已安装的纯脚本 launcher 运行 `upgrade --dry-run`；不要先 uninstall。
2. Preflight 验证活动 payload、managed prefix、profile、global override 和 pending transaction。
3. 成功后运行 `upgrade`。新版本可保持公开 `1.0.1`，本地 Codex cache 副本允许
   `1.0.1+codex.<timestamp>`；相同 bytes 返回 no-change。
4. 升级原子替换版本化 payload、managed prefix 和 current state，逐字节保留用户
   `AGENTS.md` remainder、BOM、换行风格、`config.toml` 和 profile override。
5. 运行 `doctor` 并要求 `OK_ENABLED`。若 Doctor 失败，立即运行一次 `rollback`；rollback 失败则
   停止并转 Recover。成功后明确提示新开任务加载更新。

`E_LEGACY_INSTALL_DETECTED` 不走 upgrade：必须显式 legacy cleanup 后 fresh install。Drift、override、
profile、权限、路径或 transaction 错误均 fail closed，禁止手工绕过。
