# Z Codex Router

[中文](#中文) · [English](#english)

**Choose the right model for every Codex task—exactly, audibly, and fail-closed.**

**为每个 Codex 任务精确选择正确模型：可审计、可升级、验证失败即停止。**

Version / 版本：`1.0.3`

## 中文

Z Codex Router 是一个 skills-only Codex 插件。把
`https://github.com/antonynz/z-codex-router` 发给具备终端、网络和写权限的 Agent，即可从
公开 GitHub Release 快速安装；无需 clone 仓库或下载其他平台包。

### 模型选择是核心

1. **先判 tier：** A0–C3 表达副作用、任务明确度、影响面、状态复杂度与风险。
2. **再选 mode：** Engineering、Product、Business Operations、Design、Testing 等 mode
   定义领域边界与验收证据。
3. **父协调与 receipt：** 只有父协调根分类并在实际 `create_thread` 前写入 protocol 1
   receipt；子线程不重分类、不递归创建，自动根创建最多一次，thread ID 只来自工具返回。
4. **三态校验：** 可见且 exact 为 `verified`，可见不一致为 `mismatch` 并 fail closed；字段
   缺失/接口不可用明确记为 `runtime_observability=unobservable`。非 C3 可在工具已接受目标
   tuple 且无 reroute/failure 证据时按 requested/accepted 继续，但不声称 actual verified；C3
   需当前 task/scope/action 的一次明确 route exception，mismatch 不能绕过。
5. **可控升级：** stable profile 与 disabled candidate 分离；新模型只有在兼容性数据、显式
   mapping 和评估状态都通过后才会被有意启用。

![Z Codex Router 中文架构](docs/images/z-codex-router-architecture-zh.png)

### 把这些提示词发给 Agent

#### 安装并启用

> 请从 https://github.com/antonynz/z-codex-router 的公开 GitHub Release 安装并启用 Z Codex
> Router。不要要求我安装 CLI 或手工执行命令；不要 clone 仓库、不要使用 GitHub API；严格按 AGENT_INSTALL.md
> 自动识别当前平台，只下载一个匹配的预编译包和 SHA256SUMS，校验后安装到持久 source，
> 执行 dry-run、启用和 Doctor，并回报耗时、下载字节与结果。测试不得写真实 Codex home；如果
> 此会话只能安装插件或需要新会话，明确回报“已安装但未启用”及唯一下一步“调用 Enable Z Codex
> Router”。

#### 安全自动审批（仅明确请求时）

> 仅在我明确要求时，为已安装的 Z Codex Router 开启安全自动审批；先检查当前
> `safe-auto status`/`safe-auto doctor`，再执行 `safe-auto enable`，并回报只管理
> `sandbox_mode`、`approval_policy`、`approvals_reviewer` 三个键。若我要求停用或恢复，执行
> `safe-auto restore`（drift 或事务冲突时停止）；不要因普通安装或路由启用而隐式开启，也不要
> 扩大 sandbox 或替代高风险/不可逆动作的人类授权。不要要求我安装 CLI 或手工执行命令，由
> Agent 在隔离检查后完成并回报结果。

#### 升级（不要先卸载）

> 请从 Z Codex Router 的 latest public GitHub Release 升级并启用现有安装。不要先卸载、不要手工编辑
> `AGENTS.md`、不要删除旧版本或 Safe Auto；使用 latest bootstrap 安装新插件后，让**新 launcher**执行
> `upgrade --dry-run`、`upgrade` 和 Doctor。它必须识别健康的 1.0.1/1.0.2 受管 payload 与旧 managed block，
> 原子替换为新版本，同时逐字保留我的 user `AGENTS.md` 内容、`config.toml`、Safe Auto 三键状态和
> `z-codex-router-profile.toml` user override。若发现真正的受管内容 drift、损坏 profile 或中断事务，停止并
> 报告稳定错误码和 Recover 路径；无效 override 也必须以 `E_PROFILE_OVERRIDE_INVALID` 停止，先修复或显式
> `profile reset` 后再试。不得以 uninstall-first、`spawn_agent` 或手工覆盖绕过。

升级写入完成后无需重启应用或 CLI；已运行的 `routerctl`/Doctor 可立即验证新状态。已有任务仍保留其已加载的
指令和工具集；要让 Codex 载入更新后的插件 skills/tools，请新开一个任务。

#### 映射与 desktop handoff 排障

> 显示并验证我的有效 Z Codex Router tier mapping；除非我明确要求，不要写 override。若我要求修改，使用
> `profile init`、`profile set`、可恢复的 `profile reset` 或 `profile restore <backup>`，并报告 source、path 和
> mapping hash。`profile reset` 返回的 backup 只能用 `profile restore` 恢复，不能手工覆盖文件。若 desktop policy
> 阻止创建独立根任务，停止并返回 `ROUTE_HANDOFF_REQUIRED`；不要 fallback 到 `spawn_agent`。我随后会直接请求：
> `请为当前相同任务范围创建一个新的 Codex 独立任务，使用 <model> / <effort>，沿用当前 route receipt；不要创建子代理或第二个任务。`

#### 恢复或回滚

> 恢复 Z Codex Router。先运行 Doctor；若为 `E_TRANSACTION_PENDING` 或
> `E_SAFE_AUTO_TRANSACTION_PENDING`，运行 `recover` 恢复原事务。若是普通路由事务，再运行 Doctor
> 并报告 `OK_ENABLED`/`OK_NOT_ENABLED`；若是 safe-auto 事务，运行 `safe-auto doctor` 并要求
> `OK_ACTIVE`/`OK_ABSENT`，再单独运行 Doctor 报告路由结果。路由未启用但 safe-auto active 时
> Doctor 返回 `E_SAFE_AUTO_ACTIVE` 是独立 opt-in 的真实边界，不是 safe-auto 恢复失败。只操作受管块、
> payload、状态和 safe-auto 三键，绝不覆盖我的其他 `AGENTS.md` 或
> `config.toml` 内容；哈希或用户修改冲突时停止。只有我明确要求回滚已完成的启用或升级时，才运行
> `rollback`。

#### 停用并卸载

> 停用并卸载 Z Codex Router。先运行 `safe-auto status`/`safe-auto doctor`；若为 active，在本次
> 用户明确的“停用并卸载”范围内运行 `safe-auto restore`，若为 drift 则停止并保留配置。然后按
> Doctor → `uninstall` → Doctor，要求最终为 `OK_NOT_ENABLED`；`uninstall` 必须先撤销精确受管块和
> 状态、验证我的非受管内容不变、清理受管 payload/备份/状态。任一冲突或失败都保留插件和可恢复控制面，绝不先删插件；仅在最终验收后执行
> `codex plugin remove z-codex-router@z-codex-router --json`。重复执行应安全，且不要删除整个
> `AGENTS.md` 或 `config.toml`。

普通“安装”只安装插件并执行 dry-run，不等于启用全局路由；只有明确“安装并启用”才会改变全局路由。

### 安全自动审批（明确 opt-in）

插件安装和路由启用不会修改 `config.toml`。用户明确选择后，使用已安装插件的
`routerctl safe-auto enable`（或对应 launcher）才会原子、幂等地写入以下三个顶层键：

```toml
sandbox_mode = "workspace-write"
approval_policy = "on-request"
approvals_reviewer = "auto_review"
```

`auto_review` 只替换符合条件的 reviewer，不扩大 sandbox，也不替代 Computer Use、凭证、支付、
签署、发布、生产变更或其他高风险/不可逆外部动作的人类授权。`safe-auto status` 是只读状态检查，
`safe-auto doctor` 对 drift fail closed，`safe-auto restore`（`disable` 同义）只恢复这三个键的
启用前原值/缺失状态并保留其他用户配置。路由 `uninstall` 不会自动恢复权限配置；先显式 restore，
再执行卸载。重复键、用户改动或事务漂移都会停止且不覆盖配置。

### 支持平台

| macOS | Linux | Windows |
| --- | --- | --- |
| arm64、Intel amd64 | arm64、x86_64 amd64 | arm64、x86_64 amd64 |

每个 tag 由对应架构的 GitHub hosted runner 原生构建并验证。macOS arm64 另有本地 release 与
隔离 lifecycle 实测。源码 checkout 故意不含二进制；可运行包位于 GitHub Releases。

### 详细文档

- [Agent 安装、权限、安全、缓存、恢复、升级、回滚与卸载协议](AGENT_INSTALL.md)
- [Router 架构](plugins/z-codex-router/core/router.md)
- [安全策略](SECURITY.md)
- [隐私](docs/privacy.md) · [条款](docs/terms.md) · [支持](docs/support.md)
- [变更记录](CHANGELOG.md)

本项目不是 OpenAI 官方产品，尚未提交或上架 OpenAI marketplace。Apache-2.0 licensed.

## English

Z Codex Router is a skills-only Codex plugin. Give
`https://github.com/antonynz/z-codex-router` to an Agent with terminal, network, and write access
to install quickly from a public GitHub Release—without cloning the repository or downloading
packages for other platforms.

### Model selection is the product

1. **Classify the tier:** A0–C3 captures side effects, task clarity, impact, state complexity, and
   risk.
2. **Choose the mode:** Engineering, Product, Business Operations, Design, Testing, and other modes
   define domain boundaries and acceptance evidence.
3. **Parent-owned receipts:** only the coordinating parent classifies and writes a protocol-1 receipt
   before the real `create_thread` call. Children never reclassify or recurse, automatic root creation
   is capped at one, and thread IDs come only from the tool return.
4. **Three-state verification:** observable exact fields are `verified`; visible differences are
   `mismatch` and fail closed; missing/unavailable fields are explicitly
   `runtime_observability=unobservable`. Non-C3 work may continue as requested/accepted (without
   claiming actual verification) only when the tool accepted the requested tuple and no reroute/failure
   evidence is visible. C3 requires one explicit route exception scoped to the current task/scope/action;
   mismatch can never be bypassed.
5. **Upgrade deliberately:** stable and disabled candidate profiles stay separate. A new model is
   enabled only after compatibility evidence, an explicit mapping, and evaluation state agree.

![Z Codex Router architecture](docs/images/z-codex-router-architecture-en.png)

### Paste these prompts to an Agent

#### Install and enable

> Install and enable Z Codex Router from the public GitHub Release at
> https://github.com/antonynz/z-codex-router. Do not ask me to install a CLI or run commands;
> do not clone the repository or use the GitHub API. Follow AGENT_INSTALL.md exactly: detect this
> host, download only its one prebuilt
> package plus SHA256SUMS, verify it, install a persistent source, run dry-run, enable, and Doctor,
> then report elapsed time, downloaded bytes, and results. Never target my real Codex home in tests.
> If this session can only install the plugin or needs a new session, explicitly report “installed
> but not enabled” and the single next step: invoke Enable Z Codex Router.

#### Safe automatic approval (only on explicit request)

> Only when I explicitly ask, enable safe automatic approval for the installed Z Codex Router. First
> check `safe-auto status`/`safe-auto doctor`, then run `safe-auto enable`, and report that it manages
> only `sandbox_mode`, `approval_policy`, and `approvals_reviewer`. If I ask to disable or restore it,
> run `safe-auto restore` and stop on drift or a pending transaction. Never infer this opt-in from
> ordinary installation/routing enablement, expand the sandbox, or replace human authorization for
> high-risk or irreversible actions. Do not ask me to install a CLI or run commands manually; perform
> the isolated checks and report the result.

#### Upgrade (do not uninstall first)

> Upgrade and enable my existing Z Codex Router from the latest public GitHub Release. Do not uninstall
> first, hand-edit `AGENTS.md`, delete the old version, or change Safe Auto. After the latest bootstrap
> installs the new plugin, use the **new launcher** for `upgrade --dry-run`, `upgrade`, and Doctor. It
> must recognize healthy 1.0.1/1.0.2 managed payloads and legacy blocks, atomically replace them with the
> new version, and preserve my user `AGENTS.md` content, `config.toml`, Safe Auto three-key state, and
> `z-codex-router-profile.toml` override byte-for-byte. On genuine managed drift, malformed legacy profile,
> an invalid override, or an interrupted transaction, stop with the stable error and Recover path (repair or
> explicitly `profile reset` an invalid override before retry); never use uninstall-first,
> `spawn_agent`, or a manual overwrite to bypass it.

No application or CLI restart is needed after the upgrade writes complete; `routerctl` and Doctor can
verify the new state immediately. Existing tasks retain instructions/tools already loaded into their
context. Start a new task to pick up updated plugin skills and tools.

#### Mapping and desktop-handoff troubleshooting

> Show and validate my effective Z Codex Router tier mapping; do not write an override unless I explicitly
> ask. If I request a change, use `profile init`, `profile set`, recoverable `profile reset`, or
> `profile restore <backup>`, and report source, path, and mapping hash. A reset backup must be restored with
> `profile restore`, never by manually overwriting the file. If desktop policy blocks the independent-root
> creation, stop with `ROUTE_HANDOFF_REQUIRED`; never fall back to `spawn_agent`. I will then directly request:
> `Create a new independent Codex task for the same current scope using <model> / <effort>, carrying forward the current route receipt; do not create a sub-agent or a second task.`

#### Recover or roll back

> Recover Z Codex Router. Run Doctor first; if it returns `E_TRANSACTION_PENDING` or
> `E_SAFE_AUTO_TRANSACTION_PENDING`, run `recover` to restore the original transaction. For a routing
> transaction, run Doctor and report `OK_ENABLED`/`OK_NOT_ENABLED`; for a safe-auto transaction, run
> `safe-auto doctor` and require `OK_ACTIVE`/`OK_ABSENT`, then run general Doctor separately. A route-
> absent installation with safe-auto active may honestly return `E_SAFE_AUTO_ACTIVE` from general Doctor;
> that is not a failed safe-auto recovery. Touch only managed blocks, payload, state, and the safe-auto three keys; never overwrite
> my other `AGENTS.md` or `config.toml` content, and stop on a hash or
> user-change conflict. Run `rollback` only when I explicitly ask to undo a completed enablement
> or upgrade.

#### Disable and uninstall

> Disable and uninstall Z Codex Router. First run `safe-auto status`/`safe-auto doctor`; if it is active,
> explicitly run `safe-auto restore` as part of this user-requested disable-and-uninstall operation; if
> it reports drift, stop and preserve the configuration. Then use the exact order Doctor → `uninstall` →
> Doctor and require final `OK_NOT_ENABLED`; `uninstall` must first revoke only the exact managed block and
> state, verify my unmanaged content is unchanged, and clean managed payload/backups/state. On any
> conflict or failure, retain the plugin and recoverable control plane—never remove the plugin
> first. Only after final acceptance run `codex plugin remove z-codex-router@z-codex-router --json`.
> It must be safe to repeat and must not delete my whole `AGENTS.md` or `config.toml`.

An ordinary “install” installs the plugin and performs a dry-run; it does not enable global routing.
Only explicit “install and enable” may change global routing.

### Safe automatic approval (explicit opt-in)

Plugin installation and routing enablement never modify `config.toml`. Only an explicit
`routerctl safe-auto enable` invocation writes these three top-level keys atomically and idempotently:

```toml
sandbox_mode = "workspace-write"
approval_policy = "on-request"
approvals_reviewer = "auto_review"
```

Auto-review only substitutes the eligible approval reviewer. It does not expand the sandbox or grant
human authorization for Computer Use, credentials, payment, signing, publishing, production changes,
or other high-risk/irreversible external actions. Use `safe-auto status` for a read-only state check,
`safe-auto doctor` to fail closed on drift, and `safe-auto restore` (`disable` is an alias) to restore
only the three pre-enable values while preserving unrelated user configuration. Routing uninstall
does not implicitly restore permission configuration; restore it explicitly first. Duplicate keys,
user edits, and transaction hash drift stop without overwriting config.

### Supported platforms

| macOS | Linux | Windows |
| --- | --- | --- |
| arm64, Intel amd64 | arm64, x86_64 amd64 | arm64, x86_64 amd64 |

Each tag is built and validated on a native GitHub-hosted runner for its architecture. macOS arm64
also has a local release-build and isolated-lifecycle test. Source checkouts intentionally contain
no binary; runnable packages are published in GitHub Releases.

### Detailed documentation

- [Agent install, permissions, security, cache, recovery, upgrade, rollback, and uninstall protocol](AGENT_INSTALL.md)
- [Router architecture](plugins/z-codex-router/core/router.md)
- [Security policy](SECURITY.md)
- [Privacy](docs/privacy.md) · [Terms](docs/terms.md) · [Support](docs/support.md)
- [Changelog](CHANGELOG.md)

This is not an official OpenAI product and has not been submitted to or listed in the OpenAI
marketplace. Licensed under Apache-2.0.
