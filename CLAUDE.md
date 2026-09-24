# StrikeShard

实验性质的 Godot 游戏项目。

## 技术栈

- Godot 4.7（GDScript）
- Forward Plus 渲染 + Jolt Physics
- 规范驱动开发（SDD）：Raven + ravenspec

## 关键约束（必须遵守）

- **离线自包含**：整个开发过程禁止与任何内部代码仓库、内部知识库交互。
  - 禁止使用 Sourcegraph 内部代码搜索、内部平台/知识库工具。
  - 代码探索仅限本地项目目录（Grep/Glob/Read 本地文件）。

## 协作方式

Godot 项目 = 文本文件 + 图形化编辑器，分工如下：

- **Agent 负责**：GDScript 逻辑、数据文件、shader、简单 `.tscn`/`.tres`、SDD 全部文本产物（PRD / spec / DESIGN / TASK）。
- **用户在编辑器负责**：复杂场景可视化搭建、美术资源导入、运行与手感验证。
- 运行与手感以用户在 Godot 编辑器中的实际行为为准。

## 工作流

用户提需求 → `/sdd-new-change` 起 spec → Agent 写逻辑代码 → 用户编辑器验收 → 反馈迭代。
