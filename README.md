# Z Codex Router

[中文](#中文) · [English](#english)

**Choose the right model for every Codex task—exactly, audibly, and fail-closed.**

**为每个 Codex 任务精确选择正确模型：可审计、可升级、验证失败即停止。**

Version / 版本：`1.0.0`

## 中文

Z Codex Router 是一个 skills-only Codex 插件。把
`https://github.com/antonynz/z-codex-router` 发给具备终端、网络和写权限的 Agent，即可从
公开 GitHub Release 快速安装；无需 clone 仓库、安装 Rust 或下载其他平台包。

### 模型选择是核心

1. **先判 tier：** A0–C3 表达副作用、任务明确度、影响面、状态复杂度与风险。
2. **再选 mode：** Engineering、Product、Business Operations、Design、Testing 等 mode
   定义领域边界与验收证据。
3. **精确匹配：** profile 把 tier 映射到明确的 `(model, reasoning effort)`；运行时元数据、
   平台能力或精确组合无法验证时，报告 route exception，不猜默认值、不静默降级。
4. **可控升级：** stable profile 与 disabled candidate 分离；新模型只有在兼容性数据、显式
   mapping 和评估状态都通过后才会被有意启用。

![Z Codex Router 中文架构](docs/images/z-codex-router-architecture-zh.png)

### 把这一段发给 Agent

> 请从 https://github.com/antonynz/z-codex-router 的公开 GitHub Release 安装并启用 Z Codex
> Router。不要 clone 仓库、不要构建 Rust、不要使用 GitHub API；严格按 AGENT_INSTALL.md
> 自动识别当前平台，只下载一个匹配的预编译包和 SHA256SUMS，校验后安装到持久 source，
> 执行 dry-run、启用和 Doctor，并回报耗时、下载字节与结果。测试不得写真实 Codex home。

只有明确说“启用”时，Agent 才应改变全局路由。只安装插件时省略 enable 步骤。

### 支持平台

| macOS | Linux | Windows |
| --- | --- | --- |
| arm64、Intel amd64 | arm64、x86_64 amd64 | arm64、x86_64 amd64 |

每个 tag 由对应架构的 GitHub hosted runner 原生构建并验证。macOS arm64 另有本地 release 与
隔离 lifecycle 实测。源码 checkout 故意不含二进制；可运行包位于 GitHub Releases。

### 详细文档

- [Agent 安装、权限、安全、缓存、升级与回滚协议](AGENT_INSTALL.md)
- [Router 架构](plugins/z-codex-router/core/router.md)
- [安全策略](SECURITY.md)
- [隐私](docs/privacy.md) · [条款](docs/terms.md) · [支持](docs/support.md)
- [变更记录](CHANGELOG.md)

本项目不是 OpenAI 官方产品，尚未提交或上架 OpenAI marketplace。Apache-2.0 licensed.

## English

Z Codex Router is a skills-only Codex plugin. Give
`https://github.com/antonynz/z-codex-router` to an Agent with terminal, network, and write access
to install quickly from a public GitHub Release—without cloning the repository, installing Rust,
or downloading packages for other platforms.

### Model selection is the product

1. **Classify the tier:** A0–C3 captures side effects, task clarity, impact, state complexity, and
   risk.
2. **Choose the mode:** Engineering, Product, Business Operations, Design, Testing, and other modes
   define domain boundaries and acceptance evidence.
3. **Match exactly:** a profile maps each tier to an explicit `(model, reasoning effort)`. Missing
   runtime metadata, platform capability, or an exact match produces a route exception—never a
   guessed default or silent downgrade.
4. **Upgrade deliberately:** stable and disabled candidate profiles stay separate. A new model is
   enabled only after compatibility evidence, an explicit mapping, and evaluation state agree.

![Z Codex Router architecture](docs/images/z-codex-router-architecture-en.png)

### Paste this to an Agent

> Install and enable Z Codex Router from the public GitHub Release at
> https://github.com/antonynz/z-codex-router. Do not clone the repository, build Rust, or use the
> GitHub API. Follow AGENT_INSTALL.md exactly: detect this host, download only its one prebuilt
> package plus SHA256SUMS, verify it, install a persistent source, run dry-run, enable, and Doctor,
> then report elapsed time, downloaded bytes, and results. Never target my real Codex home in tests.

The Agent may change global routing only when enablement is explicit. Omit enablement for a
plugin-only install.

### Supported platforms

| macOS | Linux | Windows |
| --- | --- | --- |
| arm64, Intel amd64 | arm64, x86_64 amd64 | arm64, x86_64 amd64 |

Each tag is built and validated on a native GitHub-hosted runner for its architecture. macOS arm64
also has a local release-build and isolated-lifecycle test. Source checkouts intentionally contain
no binary; runnable packages are published in GitHub Releases.

### Detailed documentation

- [Agent install, permissions, security, cache, upgrade, and rollback protocol](AGENT_INSTALL.md)
- [Router architecture](plugins/z-codex-router/core/router.md)
- [Security policy](SECURITY.md)
- [Privacy](docs/privacy.md) · [Terms](docs/terms.md) · [Support](docs/support.md)
- [Changelog](CHANGELOG.md)

This is not an official OpenAI product and has not been submitted to or listed in the OpenAI
marketplace. Licensed under Apache-2.0.
