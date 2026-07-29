# Z Codex Router v1.0.0

## 中文

首次正式版本。Z Codex Router 使用 tier、mode 与版本化 profile，为 Codex 任务选择精确的
`(model, reasoning effort)`，验证失败时 fail closed。

安装只需把仓库 URL 发给 Agent 并要求安装或“安装并启用”。Agent 按 `AGENT_INSTALL.md`
从公开 Release 直链下载当前平台唯一的预编译包与 `SHA256SUMS`，校验后安装到持久 source；
无需 Rust、repo clone、GitHub 登录/API、`gh` 或 `jq`。

六个平台资产均由对应 GitHub hosted runner 原生构建和验证。macOS arm64 另有本地 release
build、隔离 cold/hot install、enable 与 Doctor 实测；其他五个平台的结论来自各自原生
runner，而非本地或交叉编译冒充。

## English

This is the first stable release. Z Codex Router uses tiers, modes, and versioned profiles to select
an exact `(model, reasoning effort)` for each Codex task and fails closed when verification is
incomplete.

Give the repository URL to an Agent and ask it to install, or explicitly to install and enable.
Following `AGENT_INSTALL.md`, the Agent downloads only this host's prebuilt package and
`SHA256SUMS` from public Release direct URLs, verifies them, and installs a persistent source. No
Rust, repository clone, GitHub login/API, `gh`, or `jq` is required.

All six platform assets are built and validated on native GitHub-hosted runners for their
architectures. macOS arm64 additionally has a local release build plus isolated cold/hot install,
enable, and Doctor evidence. The other five platform claims come from their native runners, not
from local or disguised cross-compilation.
