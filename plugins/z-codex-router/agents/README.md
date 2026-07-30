# 参数化角色模板

这些模板只是数据，不是自动委派策略。只有 resolved profile 与真实 runtime capability 均通过校验后，
host 才可渲染 `{{model}}`、`{{reasoning_effort}}`、`{{task_scope}}`、`{{owned_paths}}` 和
`{{acceptance}}`。若 host 无法替换或强制执行某字段，就不得启用对应模板。

任何模板都不授予审批、签署、支付、发布、管理账户或作出法律/财务决策的权限。
