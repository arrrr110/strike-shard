# StrikeShard

实验性质的 Godot 回合制战棋：把棋子当台球打出去，靠碰撞与控制域（ZOC）造成伤害。

## 项目规矩在 `AGENTS.md`

**先读 [AGENTS.md](AGENTS.md)** —— 它是唯一事实来源：技术栈、关键约束、分工、
文档地图、怎么验证（`bash tools/verify.sh`）、熵账本规则、工作流。

本文件不再重复内容：换 Agent 或换工具时只改这里的一行指针，项目知识一个字都不动。

## 动手前必读

- `design/README.md` —— 模块索引，**先看「代码」列**才知道哪些模块真的有代码
- `design/00-overview/constraints.md` —— 全局约束与**实测出来的引擎事实**
- 改了 `scripts/` 或 `sences/` → `bash tools/verify.sh`
