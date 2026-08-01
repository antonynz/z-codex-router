# Z Codex Router

面向 Codex 的纯脚本、可审计、fail-closed 全局任务路由策略。v1.1.0 提供稳定的 `zcr`
入口、清晰的生命周期命令、可恢复的 profile 自定义，以及 macOS/Linux 与 Windows
PowerShell 5.1/7 的同一套行为。

[English README](README.en.md) · [命令参考](docs/commands.md) · [手动安装](docs/manual-install.md) · [故障排除](docs/troubleshooting.md) · [架构](docs/architecture.md) · [安全](SECURITY.md) · [路由策略](plugins/z-codex-router/core/router.md)

## 常用操作（先看这里）

从仓库克隆目录或解压后的 v1.1.0 归档根目录执行。安装器会注册 plugin，并把稳定入口放在
`$CODEX_HOME/bin`；只有 `--enable` / `-Enable` 会写入受管 AGENTS 路由块。

### macOS / Linux

```sh
# zcr-test:posix-install
: "${CODEX_HOME:=$HOME/.codex}"
export CODEX_HOME
sh install.sh --source . --enable
export PATH="$CODEX_HOME/bin:$PATH"
zcr status
```

```sh
PATH="$CODEX_HOME/bin:$PATH"
zcr enable
zcr disable
zcr upgrade
zcr uninstall                 # 保留 profile
zcr uninstall --purge-profile # 先备份，再移除 profile
```

### Windows PowerShell 5.1 / 7

```powershell
# zcr-test:powershell-install
if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME = Join-Path $env:USERPROFILE ".codex" }
.\install.ps1 -Source . -Enable
& (Join-Path $env:CODEX_HOME "bin\zcr.ps1") status
```

```powershell
$zcr = Join-Path $env:CODEX_HOME "bin\zcr.ps1"
& $zcr enable
& $zcr disable
& $zcr upgrade
& $zcr uninstall
& $zcr uninstall --purge-profile
```

`zcr.cmd` 也会随 Windows 安装创建，供 `cmd.exe` 使用。PowerShell 示例使用绝对的稳定
入口，因此从任意当前目录都可运行；POSIX 示例把 `$CODEX_HOME/bin` 放入当前 shell 的
`PATH` 后同样如此。

## 安装 release 归档

GitHub Release 为同一源码内容提供两份归档和一份 `SHA256SUMS`：

- `z-codex-router-1.1.0.tar.gz`：macOS / Linux。
- `z-codex-router-1.1.0.zip`：Windows PowerShell。

POSIX 示例：

```sh
version=1.1.0
base="https://github.com/antonynz/z-codex-router/releases/download/v$version"
curl --fail --location --remote-name "$base/z-codex-router-$version.tar.gz"
curl --fail --location --remote-name "$base/SHA256SUMS"
expected=$(awk '$2 == "z-codex-router-1.1.0.tar.gz" { print $1 }' SHA256SUMS)
test -n "$expected"
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "z-codex-router-$version.tar.gz" | awk '{print $1}')
else
  actual=$(shasum -a 256 "z-codex-router-$version.tar.gz" | awk '{print $1}')
fi
test "$actual" = "$expected"
tar -xzf "z-codex-router-$version.tar.gz"
cd "z-codex-router-$version"
sh install.sh --enable
```

PowerShell 示例：

```powershell
$Version = "1.1.0"
$Base = "https://github.com/antonynz/z-codex-router/releases/download/v$Version"
Invoke-WebRequest -UseBasicParsing "$Base/z-codex-router-$Version.zip" -OutFile "z-codex-router-$Version.zip"
Invoke-WebRequest -UseBasicParsing "$Base/SHA256SUMS" -OutFile "SHA256SUMS"
$Expected = ((Get-Content SHA256SUMS) | Where-Object { $_ -match "z-codex-router-$Version.zip$" } | Select-Object -First 1).Split()[0]
if ((Get-FileHash "z-codex-router-$Version.zip" -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected.ToLowerInvariant()) { throw "SHA256 mismatch" }
Expand-Archive "z-codex-router-$Version.zip" -DestinationPath .
Set-Location "z-codex-router-$Version"
.\install.ps1 -Enable
```

离线或镜像场景可以让安装器验证已下载的同名归档和 `SHA256SUMS`：

```sh
sh install.sh --release-dir /absolute/path/to/release --enable
```

```powershell
.\install.ps1 -ReleaseDirectory C:\path\to\release -Enable
```

## 生命周期与 profile

Bootstrap 安装器注册 plugin 来源；`zcr install` / `zcr enable` 写入受管路由块；`zcr disable`
只移除受管路由块；`zcr uninstall` 移除受管 payload。`disable` 保留 plugin 与 profile；
`uninstall` 默认也保留 profile。
`uninstall --purge-profile` 会先在 `$CODEX_HOME/z-codex-router-profile-backups/` 创建带 SHA-256
metadata 的备份。

无需编辑 TOML 即可调整一个 tier：

```sh
zcr profile set B2 gpt-5.6-terra high
zcr profile show
zcr profile backups
```

常用 lifecycle 与 profile 命令输出稳定的 `code=...`、`state=...`、`impact=...`、
`retry_safe=...` 和一个 `next_command=...`；受控失败路径也提供同一组诊断字段。`status` 对
disabled、shadowed、legacy-cleanup-required 和 recovery-required 状态给出无副作用的下一步建议。

## 支持边界

- 不修改 `config.toml`、用户 profile 或全局 override，除非相应的显式命令要求这样做。
- 不接受不安全的 archive path、链接或编译产物；release 包必须通过 SHA-256 校验。
- 现有 routing 分类、stable mapping、schema、动态降级、telemetry、多根 handoff、no-Luna
  默认值和授权边界不属于本次 lifecycle 表面，保持不变。

有关兼容、恢复、隐私和贡献，请参阅 [docs/index.md](docs/index.md)、[AGENT_INSTALL.md](AGENT_INSTALL.md) 和 [CONTRIBUTING.md](CONTRIBUTING.md)。
