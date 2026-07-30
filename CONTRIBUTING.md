# 贡献指南

变更应保持小、可移植并 fail closed。不要向 `core/` 添加个人路径、凭证、真实配置或 model mapping。

提交变更前运行 format、unit test、Clippy、plugin validation、全部 skill validation 与仓库
secret/path scan。Installer 测试必须使用临时 `CODEX_HOME`，绝不使用开发者真实 Codex 目录。

修改 install 语义时，需要覆盖首次安装、重复安装、drift/conflict、rollback 与 uninstall 的 fixture。
修改 profile 时，需要明确的 compatibility 与 migration 方案。Candidate model profile 在经过评估的
release 明确提升前保持 disabled。
