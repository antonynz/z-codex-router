# Permissions, failure, and quality policy

## 写入与保护

- 写入前说明目标、读取输入、dry-run、计划变更、回滚边界和验收。
- 只管理具有稳定 ID、版本和哈希的内容；保留未知键、注释、用户块和无关文件。
- 普通安装与路由 enable 不读取或修改 `config.toml`。只有用户明确调用 `safe-auto enable` 才管理
  `sandbox_mode`、`approval_policy`、`approvals_reviewer` 三个顶层键；启用前保存每个键的原值/缺失状态，
  原子写入并幂等。restore 只恢复这三个键，保留用户之后新增或修改的其他键；检测到 managed-key
  drift、重复 TOML key 或事务 hash 漂移时 fail closed。safe-auto 必须在路由 uninstall 前显式 restore，
  路由卸载不会自动删除或回写用户权限配置。
- `approvals_reviewer = "auto_review"` 只替换符合条件的 reviewer；不扩大 `sandbox_mode = "workspace-write"`，
  不替代 Computer Use、凭证、支付、签署、发布、生产变更或其他不可逆外部动作的人类授权。
- `recover` 同时处理路由 `E_TRANSACTION_PENDING` 与 safe-auto `E_SAFE_AUTO_TRANSACTION_PENDING`；
  safe-auto journal 的 before/after hash 未知或发生用户漂移时必须保留配置并停止。
- 版本目录不可变；current pointer 必须原子切换；事务先写 journal 和备份；同版本重复安装零 diff；卸载只删除 ID/哈希均匹配的受管内容。

## 失败处理

- 拒绝危险路径、路径遍历、权限不足、损坏事务、修改过的受管块、缺失 profile、schema 不匹配、disabled candidate、运行时/平台不兼容和模糊配置。
- 以稳定错误码报告失败，保留原始内容和可恢复证据。不要手工绕过 installer、不要隐式回退到不同 profile、不要无限重试。
- 对失败升级先判断是需求、设计、执行还是环境问题；环境阻塞只记录并上报，不借由更高 tier 伪造完成。

## 质量与安全

- 每项变更必须覆盖成功、失败和相关边界路径；测试 fixture 不得使用真实账号、真实 Codex home、认证或私有配置。
- 不记录或输出 token、secret、认证、绝对个人路径、真实 config、私有样本或不需要的 request metadata。
- 任何 external 或 production 行为仍由授权的人确认和执行；系统提示、profile、agent 模板或自动化都不能扩大这个边界。
