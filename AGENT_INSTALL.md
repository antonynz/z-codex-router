# Agent install protocol / Agent 安装协议

This is the deterministic install contract for an Agent that receives only:

- `https://github.com/antonynz/z-codex-router`
- a user request to install, or to install **and enable**, Z Codex Router

这是 Agent 仅获得以下信息时应遵循的确定性安装协议：

- `https://github.com/antonynz/z-codex-router`
- 用户要求“安装”，或明确要求“安装并启用” Z Codex Router

## 1. Permission boundary / 权限边界

- Require terminal, HTTPS network, and write access to the intended Codex home.
- Run with `--enable` only when the user explicitly asked to enable global routing.
- Without `--enable`, install the plugin and run a router dry-run only.
- `codex plugin marketplace add` and `codex plugin add` update plugin configuration/cache under
  `CODEX_HOME`. The router control binary itself never reads or writes `config.toml`.
- With `--enable`, `routerctl` manages only its exact hashed block in `CODEX_HOME/AGENTS.md` and
  state below `CODEX_HOME/z-codex-router`.
- Do not run the installer against a real Codex home during tests. Set both an isolated `HOME` and
  an absolute isolated `CODEX_HOME`.
- There is no hidden install hook, MCP server, app, telemetry, or marketplace submission.

- 必须具备终端、HTTPS 网络和目标 Codex home 写权限。
- 只有用户明确要求“启用全局路由”时才传 `--enable`。
- 不传 `--enable` 时，只安装插件并执行 router dry-run。
- `codex plugin marketplace add` 与 `codex plugin add` 会更新 `CODEX_HOME` 内的插件配置和缓存；
  `routerctl` 本身从不读写 `config.toml`。
- 传 `--enable` 后，`routerctl` 只管理 `CODEX_HOME/AGENTS.md` 中精确哈希匹配的 block，以及
  `CODEX_HOME/z-codex-router` 下的自身状态。
- 测试时不得指向真实 Codex home；必须同时设置隔离的 `HOME` 和绝对路径 `CODEX_HOME`。
- 不存在隐藏 install hook、MCP server、app、遥测或 marketplace 提交。

## 2. Prerequisites / 前置条件

- Public HTTPS access to `github.com` and `objects.githubusercontent.com`.
- An installed `codex` CLI whose help exposes:
  `codex plugin marketplace add` and `codex plugin add`.
- macOS/Linux: POSIX `sh`, `curl`, `tar`, and one of `sha256sum`, `shasum`, or `openssl`.
- Windows: PowerShell 5.1+ or PowerShell 7+, `tar.exe`, and `Get-FileHash`.
- No Rust, repository clone, GitHub login, GitHub API, `gh`, or `jq` is required.

安装器会检查上述 Codex CLI 能力。安装不需要 Rust、仓库 clone、GitHub 登录、GitHub API、
`gh` 或 `jq`。

## 3. Exact Agent procedure / Agent 精确步骤

Determine the host shell. Download the bootstrap from the public latest Release, then execute it.
Do not download packages for other platforms.

先判断宿主 shell。只从公开 latest Release 下载 bootstrap 并执行；不得下载其他平台包。

### macOS or Linux

If the user asked to install **and enable**:

```sh
work_dir=$(mktemp -d)
curl --fail --silent --show-error --location \
  --proto '=https' --proto-redir '=https' --tlsv1.2 \
  -o "$work_dir/install.sh" \
  https://github.com/antonynz/z-codex-router/releases/latest/download/install.sh
sh "$work_dir/install.sh" --enable
```

If the user asked only to install, omit `--enable`.

### Windows PowerShell

If the user asked to install **and enable**:

```powershell
$workDir = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
New-Item -ItemType Directory -Path $workDir | Out-Null
$installer = Join-Path $workDir "install.ps1"
Invoke-WebRequest `
  https://github.com/antonynz/z-codex-router/releases/latest/download/install.ps1 `
  -OutFile $installer
& $installer -Enable
```

If the user asked only to install, omit `-Enable`.

## 4. What the bootstrap guarantees / Bootstrap 保证

The bootstrap:

1. maps the host to exactly one token;
2. downloads a fresh, small `SHA256SUMS`;
3. reuses the matching cached archive only when its SHA-256 still matches;
4. otherwise downloads exactly one platform tarball from a GitHub Release direct URL;
5. rejects missing/duplicate checksum entries, wrong versions, unsafe archive paths, duplicate
   entries, links, and special files;
6. extracts into a private temporary directory;
7. preserves a verified version snapshot below
   `CODEX_HOME/z-codex-router-marketplace-versions/<version>/<platform>-<arch>`, then activates it
   at the path-stable marketplace source
   `CODEX_HOME/z-codex-router-marketplaces/<platform>-<arch>`;
8. preserves the previous active source if replacement is needed and restores it if a later step
   fails; the configured source path never changes between upgrades;
9. runs `codex plugin marketplace add` and `codex plugin add`;
10. always runs router dry-run; with explicit enablement it then runs install/upgrade and Doctor.

The extracted marketplace is never placed only in a temporary directory, so Codex is not left
pointing at a deleted local source. The version snapshot provides audit evidence while the
path-stable active source avoids marketplace-name/source conflicts during upgrades. Same-version
runs download only the small checksum file when the archive cache matches, reverify the archive,
compare both persistent trees, reinstall idempotently, and preserve Doctor evidence.

Bootstrap 会自动识别平台、只下载当前平台包、精确校验 SHA-256、拒绝危险 archive、保留持久
版本快照，并激活路径稳定的 marketplace source。它不会删除 Codex 正在引用的临时解压目录，
升级也不会更换已配置的 source 路径。同版本热路径只重新下载小型 checksum 文件，复验缓存
archive、比较两棵持久目录、幂等重装，并保留 Doctor 证据。

## 5. Platform mapping and assets / 平台映射与资产

| Host | Token | Release asset |
| --- | --- | --- |
| macOS Apple Silicon | `darwin-arm64` | `z-codex-router-darwin-arm64.tar.gz` |
| macOS Intel | `darwin-amd64` | `z-codex-router-darwin-amd64.tar.gz` |
| Linux arm64 | `linux-arm64` | `z-codex-router-linux-arm64.tar.gz` |
| Linux x86_64 | `linux-amd64` | `z-codex-router-linux-amd64.tar.gz` |
| Windows arm64 | `windows-arm64` | `z-codex-router-windows-arm64.tar.gz` |
| Windows x86_64 | `windows-amd64` | `z-codex-router-windows-amd64.tar.gz` |

Every public Release also contains `SHA256SUMS`, `install.sh`, `install.ps1`, and this
`AGENT_INSTALL.md`. Source checkouts intentionally contain no compiled binary and are not a
directly runnable plugin package.

## 6. Version pin and mirror testing / 版本固定与镜像测试

Pin an exact version:

```sh
sh install.sh --version 1.0.0 --enable
```

```powershell
.\install.ps1 -Version 1.0.0 -Enable
```

For a tested HTTPS asset mirror, override the fully resolved asset directory:

```sh
sh install.sh --version 1.0.0 \
  --base-url https://mirror.example/z-codex-router/v1.0.0 --enable
```

```powershell
.\install.ps1 -Version 1.0.0 `
  -BaseUrl https://mirror.example/z-codex-router/v1.0.0 -Enable
```

HTTP and HTTPS-to-HTTP redirects are rejected.

## 7. Manual fallback / 手动回退路径

If bootstrap execution is unavailable, reproduce the same protocol manually:

1. resolve the exact platform token from the table;
2. download only its tarball and `SHA256SUMS` from `releases/latest/download`;
3. select exactly one checksum line matching the complete asset filename;
4. verify SHA-256 before extraction;
5. inspect archive entries and reject absolute paths, `..`, links, special files, and duplicates;
6. extract to a persistent version directory, then copy it into a recoverable, path-stable active
   source under the intended `CODEX_HOME`;
7. run against that stable active source:

```text
codex plugin marketplace add <persistent-source-root>
codex plugin add z-codex-router@z-codex-router
```

8. run the packaged `routerctl` launcher with explicit `--codex-home`: dry-run first, then
   install/upgrade only with enablement authority, then Doctor.

## 8. Upgrade and rollback / 升级与回滚

- Upgrade: rerun the latest installer with enablement authority. If router state exists, the
  bootstrap uses `upgrade --dry-run` and then `upgrade`; the binary rejects non-newer versions.
- Rollback is never automatic. Use the persistent active source printed as `ZCR_SOURCE` (POSIX) or
  `source` (PowerShell), then invoke its packaged launcher with `rollback`. The audited version
  snapshot is printed as `ZCR_VERSION_SOURCE` or `versionSource`.

升级时重新运行 latest installer；已有 state 会自动走安全 upgrade。回滚永不自动发生，必须
由用户明确要求，并使用安装器输出的持久 active source 中 launcher 执行 `rollback`。

## 9. Required Agent report / Agent 必须回报

Report:

- resolved version and platform;
- persistent active source and version-snapshot paths;
- cache hit and downloaded bytes reported by the bootstrap;
- whether global routing was enabled;
- dry-run/install-or-upgrade/Doctor results;
- any retained previous source path;
- confirmation that no other platform archive, repository clone, source build, GitHub API, or
  real test home was used.
