# Z Codex Router

Z Codex Router 是开源、仅本地运行的 Codex 路由策略 plugin。它提供安全的 `zcr` lifecycle
操作、Doctor、受控 upgrade/recover 路径与可恢复 profile 管理。本项目不是 OpenAI 产品，也未经过
OpenAI 审核或上架。

本 plugin 将任务 classification 与 model profile 分离，保留用户管理的 `AGENTS.md` 内容；无法安全校验
state 时 fail closed。

开发与发布详情见 [中文 README](../README.md) 或 [English README](../README.en.md)。

- [手动安装](manual-install.md)：release、离线归档和稳定入口。
- [命令参考](commands.md)：install/enable/disable/status/uninstall 与 profile 操作。
- [故障排除](troubleshooting.md)：稳定错误码、影响、重试安全性和下一步。
- [架构与边界](architecture.md)：launcher、bootstrap、控制器与受保护的 routing policy。
- [隐私](privacy.md)、[条款](terms.md)、[安全](../SECURITY.md)。
