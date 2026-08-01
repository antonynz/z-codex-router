# Marketplace 审核材料模板

这是供未来 reviewer 使用的草稿，刻意不包含 authentication 声明；不得把它描述为已提交或已获批的 listing。

## 上架文案

**Name:** Z Codex Router

**Short description:** 为 Codex 启用可移植、fail-closed 的全局路由策略。

**Long description:** Z Codex Router 通过一键 Codex skill 安装版本化全局任务路由策略。它先执行
dry-run，保留用户配置，校验 profile、指令预算与 hash，保持 candidate disabled，并通过 POSIX sh
与 Windows PowerShell 5.1+ 提供 Doctor、upgrade、recover、rollback 与 uninstall 控制。

## 起始提示词

1. 全局启用 Z Codex Router。
2. 检查我的 Z Codex Router 安装。
3. 安全升级 Z Codex Router。

## 正向测试

1. 新临时 Codex home：enable 成功，创建版本化 payload 与一个 managed block。
2. 已有 `AGENTS.md`：enable 保留全部用户 bytes，并在文件前部写入带身份标识的 managed block。
3. 已有复杂 `config.toml`（含 `[agents]` table）：记录 bytes，再依次 enable、Doctor、同版本
   re-enable 与 uninstall；每次操作后 bytes 均保持一致。
4. 同版本 re-enable：返回 no-change，文件内容无 diff。
5. 更新 stable fixture：upgrade 创建 backup 并切换 current pointer，rollback 恢复先前 state。

## 负向测试

1. 修改 managed block：Doctor 与 upgrade 以 `E_MANAGED_BLOCK_DRIFT` 停止。
2. portable profile 缺失、candidate 被启用，或必需 mode/role/skill 缺失：preflight 以
   `E_SOURCE_INVALID` fail closed；无效 user override 以 `E_PROFILE_OVERRIDE_INVALID` 停止。
3. 非空全局 `AGENTS.override.md`：preflight 以 `E_GLOBAL_OVERRIDE_ACTIVE` fail closed。
4. managed block 超出 `project_doc_max_bytes`：Doctor 以
   `E_MANAGED_BLOCK_OUTSIDE_INSTRUCTION_BUDGET` fail closed。
5. 旧 Rust/prebuilt state：fresh install 以 `E_LEGACY_INSTALL_DETECTED` fail closed，必须显式
   legacy cleanup 后再安装。

## 发布说明草稿

Z Codex Router 1.1.0 提供 skills-only 本地 router plugin、POSIX sh 与 Windows PowerShell 5.1+
纯脚本 control plane、可移植 policy core、reference 与 disabled-candidate profile、七个参数化
role template、普通 install/enable 不触碰 `config.toml` 的边界、不可变版本目录、事务
backup/rollback、AGENTS 指令预算诊断，以及 `create_thread` ready/pending/failure 分类。Router 不
仅分类创建结果，还用唯一 correlation token 解析 pending，并以 cursor 增量等待、同任务纠偏和
最终验收门禁持续协调 routed task。本草稿不表示 Marketplace listing 或 OpenAI review 已发生。

## 提交前检查

- [ ] Release 只包含两个 universal source archives 与 `SHA256SUMS`。
- [ ] clean checkout 中 shell/PowerShell、plugin、skill、fixture、secret/path 与历史编译魔数扫描
      全部通过。
- [ ] privacy、terms、support、version、license 与 publisher 信息准确。
- [ ] 不包含凭证、authentication 声明、个人路径或真实配置。
- [ ] 由具备资格的人类 publisher（不是 Agent）提交并接受 Marketplace terms。
- [ ] 实际发生前，任何 listing 文案都不声称 OpenAI 已审核、批准、背书或发布。
