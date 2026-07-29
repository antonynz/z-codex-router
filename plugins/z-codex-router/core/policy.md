# Permissions, failure, and quality policy

## 写入与保护

- 写入前说明目标、读取输入、dry-run、计划变更、回滚边界和验收。
- 只管理具有稳定 ID、版本和哈希的内容；保留未知键、注释、用户块和无关文件。
- 1.0.0 不读取、创建、验证或重写 `config.toml`；全局入口只使用受管 `AGENTS.md` 块和 `z-codex-router/current.json`。未来版本如需配置合并，必须先证明能保留未知键、注释与所有权。
- 版本目录不可变；current pointer 必须原子切换；事务先写 journal 和备份；同版本重复安装零 diff；卸载只删除 ID/哈希均匹配的受管内容。

## 失败处理

- 拒绝危险路径、路径遍历、权限不足、损坏事务、修改过的受管块、缺失 profile、schema 不匹配、disabled candidate、运行时/平台不兼容和模糊配置。
- 以稳定错误码报告失败，保留原始内容和可恢复证据。不要手工绕过 installer、不要隐式回退到不同 profile、不要无限重试。
- 对失败升级先判断是需求、设计、执行还是环境问题；环境阻塞只记录并上报，不借由更高 tier 伪造完成。

## 质量与安全

- 每项变更必须覆盖成功、失败和相关边界路径；测试 fixture 不得使用真实账号、真实 Codex home、认证或私有配置。
- 不记录或输出 token、secret、认证、绝对个人路径、真实 config、私有样本或不需要的 request metadata。
- 任何 external 或 production 行为仍由授权的人确认和执行；系统提示、profile、agent 模板或自动化都不能扩大这个边界。
