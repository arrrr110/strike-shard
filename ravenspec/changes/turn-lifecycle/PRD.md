# 回合生命周期 产品需求文档（已迁移）

> ⚠️ **本文件已迁移，请勿在此编辑。**
>
> - 模块 PRD：`design/10-turn/PRD.md`
> - 技术方案：`design/10-turn/DESIGN.md`
> - 迁移日期：2026-10-04

## 为什么迁移

原 PRD 按"单次变更"组织，但回合机制会**持续迭代**（0 费卡、卡片挂载技能、
结算与表现的关系都会反复触碰它）。按 `design/README.md` 的分工：

- `design/<module>/`：长期活文档，按业务模块迭代
- `ravenspec/changes/<change>/`：单次变更的工作区，放 spec delta 与 TASK
- `ravenspec/specs/<capability>/`：变更落地后归档的能力规范

## 旧版本在哪

2026-09-30 的初版内容完整保留在 git 历史里，随时可取：

- `00c033b` 开始构建回合生命周期（初版 195 行）
- `da1ac5a` 生命周期（修订 + 4 个能力 spec）

## 本次变更的工作区

- spec delta：`ravenspec/changes/turn-lifecycle/specs/`
- 任务拆分：`ravenspec/changes/turn-lifecycle/TASK.md`（待生成）
