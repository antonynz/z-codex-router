# Z Codex Router

[中文](#中文) · [English](#english)

**Version / 版本：1.0.0**

## 中文

Z Codex Router 是一个 skills-only 的 Codex 插件，用可移植、可版本化、fail-closed 的策略为任务选择执行路径。它把“任务属于哪种风险与复杂度”同“使用哪个 model 与 reasoning effort”分开：先分类，再验证 profile、运行时能力和权限，最后只接受精确匹配。

![Z Codex Router 中文架构流程](docs/images/z-codex-router-architecture-zh.png)

### 核心优势

- **精确 model + reasoning effort 路由。** A0–C3 分类只描述任务的持久副作用、明确度、影响面、状态复杂度与风险；具体 `(model, reasoning effort)` 存在 profile 中。运行时元数据、profile schema、平台能力或精确组合无法验证时，路由会报告 route exception 并停止，不猜默认值、不静默换模，也不把更高 effort 当作兼容。
- **agent 表示能力和权限边界，不是职业目录。** `code_writer`、`docs_writer`、`runtime_validator`、`analyst`、`designer`、`media_creator`、`reviewer` 模板约束可读写范围与验收责任。默认单代理；只有独立工作包、文件所有权和验收都可分离，且并行收益真实存在时才委派。
- **产品与业务运营是独立问题域。** Product 覆盖 discovery、PRD、优先级、指标、实验、发布准备与复盘；Business Operations 覆盖运营、商务、预算、品牌、提案、报价、合同与外部沟通材料。两者都要求区分事实、建议、待确认项与最终决策。
- **专项验收不止“代码能跑”。** Engineering、Design、Testing、Automation、Content、Video 等 mode 分别定义工程 contract、设计源和视觉 QA、风险驱动测试与 release gate、幂等/重试/回滚、内容事实与发布边界、codec/HDR/time base/A/V sync 等验收证据。
- **覆盖 Web 前端与移动端工程检查。** Web 范围包括 CSR/SSR/SSG、hydration、状态与数据流、响应式、主题、可访问性、性能、安全、测试矩阵和发布链路。移动范围覆盖 Flutter、Android、iOS 与 HarmonyOS NEXT，并要求核对 SDK、生命周期、权限、签名、包格式、设备/模拟器和平台差异。
- **把设计还原拆成可验证细节。** 规则要求检查字体族与 fallback、字号、字重、行高、字距、换行与文字缩放；测量文本/图标基线、水平和垂直对齐、文本与容器居中、padding/content inset、安全区、网格和相邻间距。设计还原度必须基于设计源、运行界面和实际证据，不能用“看起来正确”或单张截图代替。
- **未来模型通过数据升级。** classification/core 不硬编码模型名；stable reference 与 disabled candidate profile 分离。未来模型只有在兼容性数据、显式 mapping、运行时能力和评估状态都满足时才能被有意启用，不会自动接管现有路线。
- **Rust 单二进制控制面，无 Go 运行依赖。** 每个平台包内只有对应的原生 `routerctl` 控制二进制；项目不需要 Go toolchain 或 Go runtime。CI 还显式拒绝遗留 Go 源模块。
- **安装状态可审计、可恢复。** 每次写入前先 dry-run；只管理带稳定 ID、版本和 SHA-256 的 `AGENTS.md` block；版本 payload 不可变，`current.json` 原子切换。重复安装同版本为零 diff，doctor 校验 managed block、payload hash、profile 与平台，升级先备份并写 transaction journal，失败或显式回滚可恢复最近状态。

### 安全边界

1.0.0 不读取、创建、验证或重写 `config.toml`。它只管理 `CODEX_HOME/AGENTS.md` 中 ID/哈希匹配的 block，以及 `CODEX_HOME/z-codex-router` 下自己的 state、版本、备份和 transaction 文件。未知内容、用户 block 和无关文件会被保留。

插件没有 MCP server、app、网络服务、遥测、analytics 或 install hook。危险路径、路径遍历、权限不足、损坏 transaction、managed block 漂移、缺失/禁用 profile、schema 或运行时不兼容都会 fail closed。

agent、profile、skill 或自动化都不能替代人工审批、法务、财务、业务签字人、账户管理员或对外承诺主体。发送、签署、支付、采购、账户/权限变更、公开发布和生产变更仍必须由有权限的人明确确认并执行。没有真实浏览器、设备、模拟器、SDK 或构建证据时，也不能声称对应平台已经验证。

### 支持平台、Rust target 与证据

| 操作系统 | 包标识 | 原生 Rust target | Actions artifact / 内层 tar 包 | 验证级别 |
| --- | --- | --- | --- | --- |
| macOS arm64 | `darwin-arm64` | `aarch64-apple-darwin` | `z-codex-router-darwin-arm64` / `z-codex-router-darwin-arm64.tar.gz` | 本地 release build + 隔离 lifecycle；同时进入 CI |
| macOS x86_64 | `darwin-amd64` | `x86_64-apple-darwin` | `z-codex-router-darwin-amd64` / `z-codex-router-darwin-amd64.tar.gz` | 未在本地实测；等待/以 CI 结果为准 |
| Linux arm64 | `linux-arm64` | `aarch64-unknown-linux-gnu` | `z-codex-router-linux-arm64` / `z-codex-router-linux-arm64.tar.gz` | 未在本地实测；等待/以 CI 结果为准 |
| Linux x86_64 | `linux-amd64` | `x86_64-unknown-linux-gnu` | `z-codex-router-linux-amd64` / `z-codex-router-linux-amd64.tar.gz` | 未在本地实测；等待/以 CI 结果为准 |
| Windows arm64 | `windows-arm64` | `aarch64-pc-windows-msvc` | `z-codex-router-windows-arm64` / `z-codex-router-windows-arm64.tar.gz` | 未在本地实测；等待/以 CI 结果为准 |
| Windows x86_64 | `windows-amd64` | `x86_64-pc-windows-msvc` | `z-codex-router-windows-amd64` / `z-codex-router-windows-amd64.tar.gz` | 未在本地实测；等待/以 CI 结果为准 |

包名和 checksum 使用 `amd64` 表示 Rust 的 `x86_64`。六个 job 都运行在 GitHub 对应架构的原生 hosted runner 上，并显式构建表中的 target triple；workflow 没有把交叉编译伪装成原生验证。

首次源码公开只把 **macOS arm64** 记为本地实测；其他五个平台必须以实际 GitHub Actions 结果为准。`main` push 同时触发常规 CI 和六平台构建/打包矩阵；维护者也可以手动 dispatch，未来版本 tag 也会触发打包，但本项目不会因此自动创建 GitHub Release。

### 安装

源码 checkout 故意不提交编译二进制，因此不能直接作为可运行插件安装。先构建本机二进制，再生成包含 `.agents/plugins/marketplace.json`、插件 payload、匹配二进制和 checksum 的自包含 marketplace。以下是 macOS arm64 示例：

```sh
RUSTFLAGS="--remap-path-prefix=$PWD=. --remap-path-prefix=$HOME/.cargo=." cargo build --release
python3 scripts/package_release.py \
  --binary target/release/routerctl \
  --platform darwin \
  --arch arm64 \
  --out dist/darwin-arm64
codex plugin marketplace add ./dist/darwin-arm64
codex plugin add z-codex-router@z-codex-router
```

这只安装插件包，不会自动启用全局路由。GitHub Actions artifact 内含同名 `.tar.gz`；先解开 Actions 下载的外层压缩包，再解开内层 tar 包，并对内层解压目录运行同样的 `codex plugin marketplace add` 与 `codex plugin add`。内层 tar 用于保留 macOS/Linux 的 launcher 与二进制可执行位。workflow 只生成 Actions artifact；本项目没有因此声称或自动创建 GitHub Release。

### 使用、doctor、升级与回滚

| 操作 | 在 Codex 中的用法 | 行为 |
| --- | --- | --- |
| 启用 | “启用 Z Codex Router 全局路由。” | Enable skill 先 dry-run，验证路径、payload、profile 和 managed block，再执行幂等安装。 |
| Doctor | “检查我的 Z Codex Router 安装。” | 只读检查 state、哈希、managed block、profile、candidate 状态和当前平台。 |
| 升级 | 安装更新后的插件包，再说“安全升级 Z Codex Router。” | Upgrade skill 先执行 `upgrade --dry-run`；只有新 stable 版本更高且预检通过才备份并原子切换。 |
| 回滚 | 明确说“将 Z Codex Router 回滚到最近备份。” | 仅在用户明确要求时恢复最近备份；不会手工绕过损坏 state 或漂移检查。 |

内部 `routerctl` 由 skill launcher 调用；日常使用者不需要直接操作它。安装后的全局入口从下一次独立任务起按 managed block、`current.json`、portable profile 和相关 mode 解析。

### 仓库结构

```text
plugins/z-codex-router/     Codex 插件 payload
  core/                     classification、policy 与各领域 mode
  profiles/                 portable、stable reference、disabled candidate
  agents/                   7 个参数化能力/权限模板
  skills/                   Enable、Doctor、Upgrade
  scripts/                  内部跨平台 launcher
  release/                  1.0.0 manifest 与 checksum schema
src/                        Rust routerctl 控制面
.agents/plugins/            仓库 marketplace 清单
.github/workflows/          常规 CI 与六平台打包矩阵
docs/                       隐私、条款、支持说明
submission/                 未来 marketplace review 草案
```

### 开发与验证

需要当前 stable Rust toolchain。插件和 skill 校验器还需要其自身声明的 Python 依赖。

```sh
cargo fmt --check
cargo test --all-targets
cargo clippy --all-targets -- -D warnings
RUSTFLAGS="--remap-path-prefix=$PWD=. --remap-path-prefix=$HOME/.cargo=." cargo build --release
python3 scripts/verify_source.py
python3 /path/to/plugin-creator/scripts/validate_plugin.py plugins/z-codex-router
python3 /path/to/skill-creator/scripts/quick_validate.py plugins/z-codex-router/skills/router-doctor
python3 /path/to/skill-creator/scripts/quick_validate.py plugins/z-codex-router/skills/setup-router
python3 /path/to/skill-creator/scripts/quick_validate.py plugins/z-codex-router/skills/upgrade-router
```

测试只使用临时 `CODEX_HOME` fixture；不得对真实本地 Codex home 运行安装 lifecycle。仓库公开前还应扫描 secrets、个人绝对路径、旧名称、Go 残留与不应提交的 `target/`、`dist/`、`bin/` 产物。

本仓库不是 OpenAI 官方产品、未获得 OpenAI marketplace 审核或上架。许可证为 [Apache-2.0](LICENSE)。

## English

Z Codex Router is a skills-only Codex plugin that installs a portable, versioned, fail-closed task-routing policy. It separates “what risk and complexity class does this task belong to?” from “which model and reasoning effort should execute it?” Classification happens first; profile, runtime capability, and permissions are then verified; only an exact match is accepted.

![Z Codex Router architecture flow](docs/images/z-codex-router-architecture-en.png)

### Core advantages

- **Exact model + reasoning-effort routing.** A0–C3 classification describes persistent side effects, task clarity, impact, state complexity, and risk. Concrete `(model, reasoning effort)` pairs live in profiles. If runtime metadata, the profile schema, platform capability, or the exact pair cannot be verified, routing reports a route exception and stops. It does not guess a default, silently switch models, or treat a higher effort as compatible.
- **Agents express capability and permission boundaries, not a job catalog.** The `code_writer`, `docs_writer`, `runtime_validator`, `analyst`, `designer`, `media_creator`, and `reviewer` templates constrain write scope and acceptance responsibility. Single-agent execution is the default; delegation is reserved for genuinely independent work packages with separable ownership and acceptance evidence.
- **Product and Business Operations are first-class domains.** Product covers discovery, PRDs, prioritization, metrics, experiments, launch readiness, and retrospectives. Business Operations covers operations, commercial work, budgets, brand, proposals, quotes, contracts, and external-communication materials. Both distinguish verified facts, recommendations, open decisions, and final owner decisions.
- **Acceptance goes beyond “the code runs.”** Engineering, Design, Testing, Automation, Content, and Video modes define evidence for engineering contracts, design-source and visual QA, risk-driven tests and release gates, idempotency/retry/rollback, content facts and publication boundaries, and codec/HDR/time-base/A/V-sync behavior.
- **Web frontend and mobile engineering are covered.** Web guidance includes CSR/SSR/SSG, hydration, state and data flow, responsive behavior, themes, accessibility, performance, security, test matrices, and release operations. Mobile guidance covers Flutter, Android, iOS, and HarmonyOS NEXT, including SDKs, lifecycle, permissions, signing, package formats, devices/simulators, and platform differences.
- **Design fidelity is decomposed into verifiable details.** The policy requires checks for font family and fallback, font size, weight, line height, letter spacing, wrapping, and text scaling; it also calls for measurements of text/icon baselines, horizontal and vertical alignment, text and container centering, padding/content insets, safe areas, grids, and adjacent spacing. Fidelity claims require a design source, a running UI, and actual evidence—not “looks right” or a single screenshot.
- **Future models are upgraded through data.** Classification and core policy do not hard-code model names. Stable references and disabled candidate profiles are separate. A future model can be intentionally enabled only after compatibility data, an explicit mapping, runtime capability, and evaluation status all agree.
- **One Rust control binary per platform, with no Go runtime dependency.** Each platform package contains its matching native `routerctl` binary. The project does not require a Go toolchain or Go runtime, and CI explicitly rejects legacy Go source modules.
- **Installed state is auditable and recoverable.** Every write is preceded by a dry-run. The installer manages only an `AGENTS.md` block with a stable ID, version, and SHA-256; version payloads are immutable and `current.json` changes atomically. Same-version installation is zero-diff, Doctor verifies the managed block, payload hash, profile, and platform, and upgrades write a backup plus transaction journal before switching. A failed change or explicit rollback can restore the latest state.

### Safety boundaries

Version 1.0.0 does not read, create, validate, or rewrite `config.toml`. It manages only its ID/hash-matched block in `CODEX_HOME/AGENTS.md` and its own state, versions, backups, and transaction files under `CODEX_HOME/z-codex-router`. Unknown content, user blocks, and unrelated files are preserved.

The plugin has no MCP server, app, network service, telemetry, analytics, or install hook. Dangerous paths, traversal, insufficient permissions, a damaged transaction, managed-block drift, missing or disabled profiles, and incompatible schemas or runtimes fail closed.

No agent, profile, skill, or automation replaces a human approver, lawyer, finance owner, business signatory, account administrator, or external commitment owner. Sending, signing, paying, purchasing, changing accounts or permissions, publishing publicly, and production changes still require explicit confirmation and execution by an authorized person. A platform is not considered validated without the required browser, device, simulator, SDK, or build evidence.

### Supported platforms, Rust targets, and evidence

| Operating system | Package token | Native Rust target | Actions artifact / inner tarball | Validation level |
| --- | --- | --- | --- | --- |
| macOS arm64 | `darwin-arm64` | `aarch64-apple-darwin` | `z-codex-router-darwin-arm64` / `z-codex-router-darwin-arm64.tar.gz` | Local release build + isolated lifecycle; also covered by CI |
| macOS x86_64 | `darwin-amd64` | `x86_64-apple-darwin` | `z-codex-router-darwin-amd64` / `z-codex-router-darwin-amd64.tar.gz` | Not locally tested; pending/judged by CI |
| Linux arm64 | `linux-arm64` | `aarch64-unknown-linux-gnu` | `z-codex-router-linux-arm64` / `z-codex-router-linux-arm64.tar.gz` | Not locally tested; pending/judged by CI |
| Linux x86_64 | `linux-amd64` | `x86_64-unknown-linux-gnu` | `z-codex-router-linux-amd64` / `z-codex-router-linux-amd64.tar.gz` | Not locally tested; pending/judged by CI |
| Windows arm64 | `windows-arm64` | `aarch64-pc-windows-msvc` | `z-codex-router-windows-arm64` / `z-codex-router-windows-arm64.tar.gz` | Not locally tested; pending/judged by CI |
| Windows x86_64 | `windows-amd64` | `x86_64-pc-windows-msvc` | `z-codex-router-windows-amd64` / `z-codex-router-windows-amd64.tar.gz` | Not locally tested; pending/judged by CI |

Package names and checksums use `amd64` for Rust's `x86_64`. Every job uses GitHub's native hosted runner for the corresponding architecture and explicitly builds the listed target triple; the workflow does not present cross-compilation as native validation.

For this initial source publication, **macOS arm64** is the only locally tested target. The other five targets must be judged by actual GitHub Actions results. A push to `main` triggers both regular CI and the six-platform build/package matrix. Maintainers may also dispatch it manually, and future version tags trigger packaging, but the project does not automatically create a GitHub Release.

### Installation

The source checkout intentionally excludes compiled binaries, so it is not directly runnable as an installed plugin. First build the host binary, then stage a self-contained marketplace containing `.agents/plugins/marketplace.json`, the plugin payload, the matching binary, and checksums. Example for macOS arm64:

```sh
RUSTFLAGS="--remap-path-prefix=$PWD=. --remap-path-prefix=$HOME/.cargo=." cargo build --release
python3 scripts/package_release.py \
  --binary target/release/routerctl \
  --platform darwin \
  --arch arm64 \
  --out dist/darwin-arm64
codex plugin marketplace add ./dist/darwin-arm64
codex plugin add z-codex-router@z-codex-router
```

This installs the plugin package but does not enable the global router. A GitHub Actions artifact contains a same-named `.tar.gz`: unpack the outer Actions download, then unpack the inner tarball and run the same `codex plugin marketplace add` and `codex plugin add` commands against that inner extracted directory. The tarball preserves executable permissions for macOS/Linux launchers and binaries. The workflow produces Actions artifacts only; this project does not claim or automatically create a GitHub Release.

### Enable, Doctor, upgrade, and rollback

| Operation | What to say in Codex | Behavior |
| --- | --- | --- |
| Enable | “Enable Z Codex Router globally.” | The Enable skill dry-runs first, verifies the path, payload, profiles, and managed block, then performs an idempotent installation. |
| Doctor | “Check my Z Codex Router installation.” | Read-only verification of state, hashes, the managed block, profiles, candidate status, and the current platform. |
| Upgrade | Install the updated plugin package, then say “Safely upgrade Z Codex Router.” | The Upgrade skill runs `upgrade --dry-run`; it backs up and atomically switches only when a newer stable version and every preflight check pass. |
| Rollback | Explicitly say “Roll back Z Codex Router to the latest backup.” | Restores the latest backup only on an explicit request; it does not manually bypass damaged state or drift checks. |

The internal `routerctl` is invoked by skill launchers; normal users do not operate it directly. From the next independent task after enablement, the global entry point resolves the managed block, `current.json`, the portable profile, and the relevant mode.

### Repository layout

```text
plugins/z-codex-router/     Codex plugin payload
  core/                     Classification, policy, and domain modes
  profiles/                 Portable, stable reference, disabled candidate
  agents/                   Seven parameterized capability/permission templates
  skills/                   Enable, Doctor, and Upgrade
  scripts/                  Internal cross-platform launchers
  release/                  1.0.0 manifest and checksum schema
src/                        Rust routerctl control plane
.agents/plugins/            Repository marketplace manifest
.github/workflows/          Regular CI and six-platform packaging matrix
docs/                       Privacy, terms, and support documents
submission/                 Draft future marketplace-review material
```

### Development and validation

A current stable Rust toolchain is required. The plugin and skill validators also need their declared Python dependencies.

```sh
cargo fmt --check
cargo test --all-targets
cargo clippy --all-targets -- -D warnings
RUSTFLAGS="--remap-path-prefix=$PWD=. --remap-path-prefix=$HOME/.cargo=." cargo build --release
python3 scripts/verify_source.py
python3 /path/to/plugin-creator/scripts/validate_plugin.py plugins/z-codex-router
python3 /path/to/skill-creator/scripts/quick_validate.py plugins/z-codex-router/skills/router-doctor
python3 /path/to/skill-creator/scripts/quick_validate.py plugins/z-codex-router/skills/setup-router
python3 /path/to/skill-creator/scripts/quick_validate.py plugins/z-codex-router/skills/upgrade-router
```

Tests use temporary `CODEX_HOME` fixtures only; the installation lifecycle must never target a real local Codex home. Before publishing, also scan for secrets, personal absolute paths, legacy names, Go remnants, and build outputs such as `target/`, `dist/`, or `bin/` that must not be committed.

This repository is not an official OpenAI product and has not been reviewed or listed in an OpenAI marketplace. Licensed under [Apache-2.0](LICENSE).
