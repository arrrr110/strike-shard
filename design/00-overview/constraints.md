# 全局约束与性能红线

> 状态：编写中 ｜ 最近修订：2026-10-10
> 适用范围：所有模块。新模块立项时先读这一页，避免方案与运行环境冲突。

## 运行环境

| 项 | 实际值 | 说明 |
| --- | --- | --- |
| 引擎 | Godot **4.7.2** stable | 本机 CLI：`/Users/admin/Downloads/godot/Godot.app/Contents/MacOS/Godot`（**不在 `/Applications`**，也不在 PATH 上），可 `--headless` 跑规则验证 |
| 语言 | GDScript | 无 C# / 无 GDExtension |
| 渲染后端 | `gl_compatibility` | `project.godot` 的 `config/features` 写的是 `Forward Plus`，但 `renderer/rendering_method` 实际是 `gl_compatibility`。本机 MoltenVK 无法创建 Forward+/Mobile 的计算管线，**以 gl_compatibility 为准**，特效方案要在这个后端的能力范围内选 |
| 物理（2D） | Godot 内置 2D 物理服务器 | 棋盘全部是 `RigidBody2D`。注意 `project.godot` 里的 `3d/physics_engine="Jolt Physics"` **只作用于 3D**，与棋盘无关 |
| 物理（3D） | Jolt Physics | 当前未使用 |
| 物理刻度 | 60 Hz | 每物理帧处理一次阶段推进与碰撞 |
| 重力 | 无 | 棋子 `gravity_scale = 0`，俯视棋盘 |
| 引擎线性阻尼 | **关闭** | 棋子与 Mob 都设了 `linear_damp_mode = 1`（REPLACE）且 `linear_damp = 0`，所以引擎阻尼不参与。减速**只**来自 `_integrate_forces` 里脚本施加的恒定减速 `decel`（默认 300 px/s²） |
| 引擎角阻尼 | **1.0 /s（默认值，没被关掉）** | 棋子 `angular_damp = 0` 但 `angular_damp_mode = 0`（COMBINE），所以取 ProjectSettings 的默认 `1.0`。实测自转按 `e^(-t)` 衰减：设 5.00 rad/s 后 1 秒剩 1.82、2 秒剩 0.67。**这是不倒翁倾斜只是短暂表现的原因**——自转本身约 1 秒就衰掉大半，倾斜跟着回正。想让棋子转得久一点就调 `angular_damp_mode` |
| 棋盘四壁摩擦 | **0** | `main.tscn` 的 `PhysicsMaterial_6strp` 设了 `friction = 0.0`。理由见下面「已知运行环境坑」 |
| 棋盘四壁弹性 | `bounce = 0.8` | 与棋子的 `0.8` 相加后夹到 1.0 → **完全弹性**。见下面「已知运行环境坑」 |
| 窗口 / 视口 | 720 × 480，`canvas_items` 拉伸 | 棋盘矩形世界坐标：左 161 / 右 621 / 上 61 / 下 401 |
| 输入 | 只用 `left_click` 映射名做记录 | 实际代码直接判 `InputEventMouseButton` + `MOUSE_BUTTON_LEFT/RIGHT`，没有走 InputMap。旧的 `ui_up` / `ui_left` / `ui_right` 推力**已删除** |

## 硬性约束

1. **离线自包含**：全部设计、实现、验证只依赖本地项目目录。禁止访问内部代码仓库、内部知识库、内部平台工具；代码探索只用本地 Grep / Glob / Read。
2. **分工**：Agent 负责 GDScript 逻辑、数据文件、shader、简单 `.tscn` / `.tres` 与全部设计文本；用户在 Godot 编辑器负责复杂场景搭建、美术导入、运行与手感验证。
3. **手感以编辑器实测为准**：本文档里的数值都是可调导出参数的占位值，最终由用户在编辑器里试出来。文档中记录"实测"的结论只用于锁定**机制语义**（例如冻结是否保速度），不用于锁定数值。

## 性能红线

| 红线 | 具体要求 | 原因 |
| --- | --- | --- |
| 单场物理实体数 | ≤ 14（每方 7 = 3 角色 + 最多 4 召唤物） | 2026-10-10 修订。原红线是"单场角色数 ≤ 10"；加入召唤物后改为按**每方「召唤物 + 角色」合计 ≤ 7** 算 |
| 静止判定 | 每物理帧遍历全部棋子，**遍历过程中不得分配新容器** | 避免每帧 GC 抖动。棋子名单由 `GameFlow` 在 `_ready` 从 `pieces` 组播一次种，之后靠 `register_piece()` / `unregister_piece()` 增删；**不能每帧调 `get_nodes_in_group`**（每次都会新建数组） |
| 热路径查询 | 每帧调用的查询（如静止判定）不得返回新建数组；冷路径查询（结算时才调的 ZOC 覆盖）允许返回数组 | 把"无分配"约束限定在真正每帧执行的地方，避免过度设计 |
| 去抖窗口 | 全场停稳到进入下一阶段 ≤ 0.1 秒 | 手感：停稳后立刻推进，但不能被碰撞瞬间的速度过零欺骗。当前默认 6 个物理帧 @ 60Hz |
| 表现耗时 | 不得阻塞阶段机推进——表现是**完成条件的一个加法项**，不是同步等待 | 见 [表现时间线与标记](../50-presentation/timeline-and-markers.md)【该机制未实现】 |

## 已知运行环境坑

以下四条都是**实测**出来的，不要凭直觉推翻。探针记录见
[物理冻结与暂停策略](../40-physics/freeze-and-pause.md)。

- **2D 弹性是两边 `bounce` 相加再夹到 1，不是取最大值。** 实测：
  `0.8 + 0.8 → 1.0`（完全弹性）、`0.8 + 0.0 → 0.8`、`0.0 + 0.0 → 0.16`。
  所以"球和墙都设 0.8"实际上得到了**完全弹性**，不是 0.8 的衰减。
  蓄力条的轨迹预测按同一条规则读两侧材质（`player.gd._effective_bounce()`）。
  **踩过的坑**：探针里自建的棋盘如果没挂材质，弹性会退化成 `0.8`，
  与真实 `main.tscn` 的行为不同——曾因此得出过"墙有能量损失"的错误结论。
- **有摩擦时，斜射撞墙会把平动转成自转**，导致入射角 ≠ 反射角。
  实测摩擦 1.0 时斜射偏差 −7% ~ −22%，且角速度明显上升；**改成 0 之后收敛到 ±3%**。
  这就是四壁设 `friction = 0` 的原因：让"入射角 = 反射角"成立，蓄力条才能如实预测轨迹。
  角色之间**保留**摩擦，所以球与球碰撞照样传递自转（不倒翁倾斜的来源）。
- **运行期改 `PhysicsMaterial.bounce` 未必传到求解器。** 要整体赋值一个新的
  `PhysicsMaterial` 才可靠。所以轨迹预测是**读**材质、不是写材质。
- **`PhysicsServer2D` 没有任何手动步进接口**（`space_step` / `step` 都不存在）。
  想"在后台把其他棋子屏蔽掉、模拟一次碰撞然后立刻画出轨迹"是**做不到的**——
  物理空间只能随主循环按真实时间推进。预测只能靠解析计算 + 读引擎参数对齐。
- **在碰撞回调里冻结物理是安全的**（实测无报错、零漂移），但**不能**把规则判定写进棋子脚本。
  棋子只负责"问一句、拿到结果、决定要不要冻结"，判定逻辑属于规则层。【冻结机制未实现】
- **碰撞回调拿到的是已反弹后的状态**。引擎先算完弹性响应再通知；要改变碰撞结果，
  只能在回调里覆写速度。详见 [物理冻结与暂停策略](../40-physics/freeze-and-pause.md)。【未实现】

### 视觉表现与物理的边界（做特效前必读）

物理状态住在 `PhysicsServer2D`，每个物理帧由服务器**单向推**到节点 transform；
节点上的 transform 改动**不回写**物理。因此"看得见的抖动"和"物理真的动了"是两件事。
实测（`--headless --fixed-fps 60`，同一发球的逐帧轨迹对比）：

| 抖动对象 | 轨迹最大偏差 |
| --- | --- |
| `Camera2D`（offset ±12px） | **0.000000000** |
| 子节点 `AnimatedSprite2D`（位移 ±6px + 旋转 ±0.4rad + 缩放 ±20%） | **0.000000000** |
| 对照组：`RigidBody2D` 自身位置 | 110.44 px（证明确实能测出扰动） |
| 对照组：`CollisionShape2D` 自己的 `scale` | 114.87 px |
| （反直觉）`RigidBody2D` 自己的 `scale` | **0.00 px** |

两条结论：

- **相机抖动、子节点抖动都完全不影响物理**，可以放心用来做打击感。
  项目里的 `_update_sprite_tilt()` 每帧写 `sprite.rotation` / `sprite.position` 抵消刚体自转，
  用的就是这个性质。
- **`RigidBody2D.scale` 不改物理**（设成 0.5 / 1.5 / 2.0 轨迹都不变），
  真正改碰撞体积的是 `CollisionShape2D` 自己的 transform 或 shape 的半径。
  也就是说**刚体的视觉缩放和物理大小会悄悄不一致**——改碰撞体积时别改错地方。

两个要留意的交互：

- **相机抖动会带着瞄准一起抖**。瞄准走 `get_global_mouse_position()`，它**包含 canvas transform**，
  所以相机一抖，鼠标对应的世界坐标跟着抖，蓄力条方向会抖。
  碰撞瞬间抖动是安全的（那时在 `MOTION`、不接受输入）；但若以后在 `PLAYER_TURN` 也加相机效果，
  瞄准会受影响。
- **打击抖动要与 `_update_sprite_tilt()` 叠加，不能各写各的**。那个函数每帧都在写
  `sprite.rotation` 和 `sprite.position`；抖动若也直接赋值就会互相覆盖。
  正确做法是作为偏移量叠加：`sprite.position = base.rotated(-rotation) + shake_offset`。

## 曾经的坑（已解决，留作前车之鉴）

- ~~`LifeCycle` 是空 `Control` 且覆盖棋盘，会按 `mouse_filter` 吃掉点击。~~
  **已解决**：该节点现在是 `Label`（默认 `mouse_filter = IGNORE`），
  只用来显示当前阶段名，不吃点击。
- ~~棋子脚本里遗留 `ui_up` / `ui_left` / `ui_right` 旧推力。~~ **已删除**。
