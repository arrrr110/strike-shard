# 回合机制 技术方案

> 模块：`10-turn` ｜ 状态：编写中 ｜ 最近修订：2026-10-10
> 需求见 [PRD.md](PRD.md) ｜ 冻结语义依据见 [实测](../40-physics/freeze-and-pause.md)

## 阅读指南

本文件分两部分，**别把第二部分当现状读**：

| 部分 | 内容 | 与代码的关系 |
| --- | --- | --- |
| **第一部分：当前实现** | 代码里现在真实存在的东西 | 改代码时同步改这里 |
| **第二部分：设计储备（未实现）** | 为环节 1（卡牌装载）和环节 3（ZOC 围攻）预做的设计论证 | **一行代码都没有**。2026-10-10 经确认暂不落地，按当前规模重新规划 |

第二部分保留而不删除，是因为里面的论证多数有实测支撑（冻结是否零漂移、速度是否保留，
都是在 `$TMPDIR` 探针里逐帧测出来的，见 [冻结与暂停策略](../40-physics/freeze-and-pause.md)）。
等环节 3 真的开工时不必重想一遍。

---

# 第一部分：当前实现

## 骨架

```
main (Node2D)
├── ColorRect                          棋盘底色（半透明面板）
├── TileMapLayer                       （空，只挂调试 Label 脚本）
├── WorldPositionLabel / PlayerPositionLabel   调试用
├── StaticBody2D                       ← 棋盘容器：四壁 + 三枚棋子 + Mob + AimLine
│   ├── Player1 / Player2 / Player3    player.tscn 实例（我方）
│   ├── Mob / Mob2 / Mob3              mob.tscn 实例（敌方，也挂 player.gd，owner_id = 1）
│   ├── AimLine                        Line2D，全盘共享一条
│   └── top / end / bottom / start     四面 WorldBoundaryShape2D 墙，friction = 0
├── TurnController                     ← 选择协调（scripts/turn_controller.gd）
├── LifeCycle                          ← Label，显示当前阶段名
├── EndTurnButton                      ← Button，"结束回合"
├── GameFlow                           ← 阶段机（scripts/game_flow.gd）
└── HpOverlay                          ← 血量显示（scripts/hp_overlay.gd，调试级）
```

五个脚本、三个组：

| 脚本 | 职责 | 所在组 |
| --- | --- | --- |
| `game_flow.gd` | 阶段机：阶段推进、停留、棋盘级静止判定、发射边锁、输入许可、按钮与 Label、**归属方血量池**、**棋子名单增删** | `game_flow` |
| `turn_controller.gd` | 选择协调：全盘唯一 `selected_piece`、鼠标解释、发射信号 | `turn_controller` |
| `player.gd` | 棋子：蓄力、瞄准线、轨迹预测、贴图倾斜、恒定减速、**归属与血量** | `pieces`（含 Mob） |
| `hp_overlay.gd` | 在棋子头上画血量、左下角画归属方血量池。**调试级，不是最终 UI** | — |
| `tile_map_layer.gd` | 只维护两个调试 Label | — |

## 阶段机（`scripts/game_flow.gd`）

**五个阶段**，`enum Phase { TURN_START, PLAYER_TURN, MOTION, TURN_END, ENEMY_TURN }`：

```
TURN_START ─(停留 1s + 全场静止)→ PLAYER_TURN
PLAYER_TURN ─┬─(发射)→ MOTION ─(全场静止)→ PLAYER_TURN
             └─(结束回合 且 全场静止)→ TURN_END
TURN_END ─(停留 1s)→ ENEMY_TURN ─(停留 1s)→ TURN_START
```

推进循环就是决策 2 / 决策 3 的直接实现，只是把 `poll(ctx)` 内联成了 `_poll(delta) -> int`：

```gdscript
func _physics_process(delta: float) -> void:
	_dwell += delta
	var next := _poll(delta)
	if next == NO_TRANSITION:
		return
	var from := phase
	_leave(from)
	phase = next
	_enter(next)
	phase_changed.emit(from, next)   # 至多一条边，用 if 不用 while（红线 #3）
```

**`_leave(PLAYER_TURN)` 会清掉选中态**：离开我的回合就调 `turn_controller.clear_selection()`。
不加这一下会出现"棋子停在蓄力态、但阶段已经进了敌方回合"的悬挂状态——
玩家选中棋子后直接点结束回合时，棋盘上没有任何东西在动，静止闸门会立刻放行。

**没有 `TurnContext` 类**。本期的回合瞬时量只有两项，直接是 `game_flow.gd` 的成员：
`launch_available`（发射边锁）和 `_end_turn_requested`（结束回合意愿），
外加 `_launched_this_phase`（把发射事件从信号世界搬进轮询世界的信箱）。
回合结束即重置，不需要单独的对象。

### 发射边锁

`launch_available`：进 `TURN_START` 置 true，收到 `piece_launched` 置 false。
这是**边上的开关**，不是计数器（决策 9）。

信号从 `TurnController` 发而不是从每枚棋子发：`release_charge()` 的 bool 返回值
只有 `TurnController` 看得到，一处连线胜过连三枚棋子。

### 输入许可

`game_flow.gd` 暴露 `can_operate_pieces()`（= 在 `PLAYER_TURN` 且发射边开着）。
`TurnController.handle_left_press()` 开头问一句，不许就 return（决策 11）。

两个实现细节值得记：

- **门槛加在"按下"上，不加在"松开"上**。已经合法开始的蓄力必须能正常结束，
  否则棋子会卡在蓄力态。
- **`game_flow` 引用是延迟查找的**。`TurnController` 在 `main.tscn` 里排在 `GameFlow`
  **之前**，`_ready` 那会儿 GameFlow 还没进组——早期版本在这里缓存，拿到 null，
  而 null 兜底（本来是给 headless 探针留的）会悄悄把整个门槛关掉。
  现在改成第一次用到时才查，每次按下左键才问一次，不是热路径。

### 结束回合按钮

`pressed` → `request_end_turn()`，**只置 `_end_turn_requested = true`，不切阶段**。
真正的切换由 `PLAYER_TURN` 的完成条件在"全场静止"满足时执行。
所以"任何时候都能点、但静止后才真的走"是自然成立的，不需要额外的等待态。

`disabled` 随阶段变：`PLAYER_TURN` 和 `MOTION` 期间可点，其余阶段变灰。

### 阶段名显示

`GameFlow` 把 `"PLAYER_TURN 我的回合"` 这类字符串写进 `../LifeCycle` 那个 `Label`。
Label 是 `IGNORE` mouse_filter，不吃点击。

## 棋盘级静止判定

写在 `game_flow.gd` 的 `_board_at_rest(delta)` 里（文档原先规划独立
`scripts/core/utils/board_query.gd`，这一版先放在这里，等环节 3 一起拆出去）。

- **遍历 `pieces` 组**（含 Mob），线速度与角速度**各自独立阈值**
- **去抖**：连续 N 个物理帧都静止才算数（默认 6 帧 @60Hz = 0.1 秒）
- **超时兜底**：等太久强制放行，并 `push_warning` 报出还在动的是哪一枚、速度多少
- **零分配**：棋子数组由 `GameFlow` 在 `_ready` 里从 `pieces` 组播一次种，
  之后靠 `register_piece()` / `unregister_piece()` 增删——**不每帧重新扫组**
  （`get_nodes_in_group` 每次调用都新建数组）。
  **运行时新生成的棋子必须登记**（将来的召唤物走这条路），否则静止判定扫不到它、
  阶段会在它还在动的时候推进。棋子自己 `_exit_tree` 时自动摘除。

导出参数（占位值，按 `constraints.md` 的约定留给用户在编辑器里试）：
`rest_lin_speed = 10.0` / `rest_ang_speed = 0.5` / `rest_debounce_frames = 6` /
`rest_timeout_sec = 8.0` / `dwell_sec = 1.0`。

> **棋子里还留着另一套静止判定**（`locked` / `lock_armed` / `lock_time`），
> 它管的是"这枚球能不能被选中"，与棋盘级的"回合能不能推进"是两件事。
> PRD 原计划把它上移，目前**没有上移**——两套判定的职责边界见下面「棋子的锁定」。

## 选择协调（`scripts/turn_controller.gd`）

**全盘唯一的 `selected_piece` 持有者**，鼠标输入也由它统一解释。

为什么选择权不放在棋子自己身上：如果每枚棋子各自在 `_input` 里抢选中，裁决结果就取决于
Godot 派发 `_input` 的节点树序——那正是红线 #2 要防的东西。这里一次性挑出
"鼠标下最近的那枚"（`_pick`），结果只由几何决定。

交互是**两次按键 + 粘性**（决策 19）：

```gdscript
func handle_left_press(mouse: Vector2) -> void:
	if not _can_operate():
		return                       # 操作许可由阶段机发放
	var hit := _pick(mouse)
	if selected_piece == null:
		if hit != null:
			select(hit)              # 第一拍：只选中，不蓄力
		return
	selected_piece.begin_charge(mouse)   # 第二拍：点在哪都是给已选中的那枚蓄力
```

"点别的角色不改选、但照样蓄力"是刻意的：瞄准时鼠标经常会压到别的角色，
那时不让蓄力就没法瞄。想换角色必须先右键取消。

**右键**清选中；**`_input` 而不是 `_unhandled_input`**——`_input` 在 GUI 之前派发，
不会被 `Control` 吃掉。

**`piece_launched(piece)` 信号**：`handle_left_release()` 里 `release_charge()` 返回 true 时发出，
emit 在 `clear_selection()` **之后**，让阶段机看到的是最终状态。

## 棋子（`scripts/player.gd`）

一枚 `RigidBody2D`。`player.tscn` 与 `mob.tscn` **共用同一个脚本**：
Mob 通过 `owner_id = 1` 变成"敌方"——不可被选中、但仍被撞着走。

### 归属与血量（2026-10-10 加入）

| 字段 | 含义 |
| --- | --- |
| `owner_id` | `0` = 我方 / `1` = 敌方。决定伤害去向，也决定能不能被选中 |
| `kind` | `CHARACTER` / `SUMMON`。角色不可摧毁，召唤物血量归零即移除 |
| `max_hp` / `hp` | 角色血量，下限 0。到 0 即**薄弱点**：不退场、仍全功能可用，但受到的伤害全额转给归属方 |
| `is_selectable()` | 能不能被选中 = `owner_id == 0 and kind == CHARACTER` |

**`controllable` 已退役。** 它原先同时管"这枚是谁的"和"我能不能操作它"——
现在归属由 `owner_id` 回答，能不能操作由阶段机发放
（`TurnController._can_operate()` → `GameFlow.can_operate_pieces()`）。
不拆开的话，二期接入人类对手时"敌方是另一个玩家"就无处安放。

**归属方血量池不在棋子上，在 `GameFlow`。** 它是**对局级**状态（比回合长寿），
索引 = `owner_id`，归零即该方失败。`damage_owner(who, amount)` 是唯一的修改入口
（目前**没有调用方**——碰撞伤害是下一步；先放着是为了让血量池能被改，否则显示出来的 99 永远是个常量）。

### 血量显示是调试级的

`hp_overlay.gd` 挂在 `main` 下（**不在棋盘容器里**），用世界坐标在每个棋子头上画血量。
不挂在棋子下面的原因：棋子是刚体会自转，挂上去的 Label 会跟着转，还得再写一份抵消旋转的逻辑。
代价是设计期在编辑器里看不到，只有运行起来才画。**最终的血条 / 头像框是美术与布局工作，归用户**——
那时把这个节点删掉即可。

### 蓄力

- `charge_rate = 300`（蓄满 2 秒，决策 22）
- **鼠标移出 `table_rect` 时蓄力暂停**：不涨也不退，回到盘内接着涨（决策 22）
- **零蓄力松手**：不施加冲量、不上锁、保留选中，可以重新蓄力

### 蓄力条 = 理想轨迹预测（决策 20）

不是一根长度条，而是**把球按真实物理推一遍算出的折线**：

```gdscript
func _predict_path(start, dir, v0) -> PackedVector2Array:
	# 每段：先算现有速度够不够走到墙；不够就停在半路（那就是球真正停下的地方）
	#       够就撞墙 -> 速度减去这段路程的消耗 -> 乘有效弹性 -> 反射 -> 继续
```

- 边界是 `table_rect.grow(-body_radius)`——**球是圆心撞墙的**，不是贴图边缘撞墙
- 长度是**平方**关系：`路程 = v² / (2·decel)`，所以半蓄力只走满蓄力的 1/4
- 只预测四壁，**不预测与其他角色的碰撞**（那是打出去才知道的事）

两条辅助函数与真实运动共用同一组参数：`_stop_distance(v)` 和 `_speed_after(d, v)`，
`decel` 就是 `_integrate_forces` 每帧施加的同一个值。

### 有效弹性

`_effective_bounce()` 把球和墙两边的 `bounce` 都读出来，按 **Godot 自己的规则**合并
（**相加后夹到 1**，实测确认，不是取最大值）。所以调任何一个材质，真实运动和蓄力条
同时跟着变——这就是"两边共用一套参数"的落点。

## 碰撞结算（2026-10-10 加入）

**数值链路已经通了**：撞上就当场扣血。但这是**最简形态**，不是文档里那套完整设计。

```
棋子体碰体 → player.gd 上报 bumped(other) → GameFlow._resolve_collision → 双方各打一次
```

| 环节 | 现在怎么做的 |
| --- | --- |
| 检测 | `RigidBody2D.body_entered`（两个 .tscn 都开了 `contact_monitor`）。**撞墙被过滤掉**——只有对方也在 `pieces` 组里才算角色碰撞 |
| 资格 | **只有"行动角色 × 敌方"才结算**（2026-10-10）。行动角色 = 本回合 `piece_launched` 的那一枚，记在 `GameFlow._actor`，`TURN_START` 清空。撞自己人、被撞飞的角色再撞别人，都直接 return |
| 上报 | 棋子只发 `bumped` 信号，**不判断要不要结算、不自己扣血**（规则属于规则层） |
| 结算 | `GameFlow._resolve_collision(a, b)` → **双向**：`_exchange(a,b)` 与 `_exchange(b,a)` 各一次。双方各打出自己的 `atk`，互相扣血（2026-10-10 用户确认）。**只有 ZOC 结算是单向的** |
| 伤害 | `攻击方 atk`。**类型克制暂时屏蔽**（2026-10-10），所以现在没有倍率；启用后才有"克制方向 ×2"（护卫>斗士>施法者>护卫；任一方是 `NONE` 则恒 1 倍） |
| 去向 | 一行 `mini(dmg, defender.hp)` 自然涵盖三档：角色先吃、吃不完的转给归属方、`hp == 0`（薄弱点）则全额转移 |

**去重是必须的**：`body_entered` 对接触**双方各发一次**，不去重就会把同一次碰撞结算两遍。
`GameFlow._settled_pairs` 每物理帧清空，键是**与顺序无关**的两个 instance_id（红线 #2：
不依赖谁先被回调）。实测同类型对撞各掉 30 而不是 60。

**已知的粗糙处**（都不是 bug，是"还没做"）：

- **没有冻结物理、没有事件队列、没有表现**。文档里的完整设计是
  "冻结 → 生成事件 → 全序键排序 → 串行结算 → 表现 → 排空 → 解冻"。
  那套服务的核心需求是**表现**（伤害数字在撞击那一刻跳出来、运动暂停等待）。
  现在没有表现，先不引入闸门与队列——接表现时 `_resolve_collision` 就是"生成碰撞事件"的位置。
- **伤害不看速度**。这是"伤害 = atk"的直接后果：轻轻擦一下和全力一撞伤害相同。
  实测里 p1 只是"移到"m1 旁边就掉了 30 血。**如果手感不对，这是第一个要调的地方**
  （回退点是"atk 为基、速度调制"，见 [20-character PRD](../20-character/PRD.md) 的待定）。
- **接触抖动可能造成多次结算**。`body_entered` 是"接触开始"触发一次；
  如果两枚棋子反复分离又接触，会重复结算。目前没观察到，等实测。

## 棋子的锁定（`locked` 等）

这套判定管的是**"这枚球此刻能不能被选中"**，与棋盘级的"回合能不能推进"是两件事：

| 变量 | 含义 | 置位 | 清除 |
| --- | --- | --- | --- |
| `locked` | 球还在动，禁止选中/蓄力 | `release_charge()` 里真的发射之后 | `_process` 里速度降到 `rest_speed` 以下（且 `lock_armed`）或 `max_lock_time` 兜底 |
| `lock_armed` | 冲量要到下一个物理帧才生效，先等速度真的起来 | 速度超过 `rest_speed` 时 | 发射时清零 |
| `lock_time` | 锁定累计时长 | 每帧累加 | 发射时清零；解锁时不再累加 |

**为什么没上移到棋盘级**：棋子的 `locked` 回答的是"这一枚能不能点"（每枚各不相同），
棋盘静止回答的是"回合能不能翻页"（全盘一个）。两者阈值恰好接近但不是同一个问题，
合并会让"一枚球卡住不动但另一枚在飞"这种情形失去表达能力。PRD 决策 14 说的
"静止判定是棋盘级"指的是后者；前者是选择层的局部约束。

### 为什么不给棋子开 `lock_rotation`

`RigidBody2D.lock_rotation = true` 听起来很适合"只该平动的球"，但实测（2026-10-10）会**彻底关掉不倒翁**：

- 贴图倾斜的唯一输入就是 `angular_velocity`（`tilt = clampf(angular_velocity * tilt_per_spin, ...)`），
  锁旋转后它恒为 0。同一次偏心碰撞实测：倾斜 **15.0° → 0.0°**。
  所以"锁旋转不影响贴图表现"这个直觉在此项目里**不成立**。
- 它还会改变**球与球**碰撞的结果：被撞方轨迹最大偏差 29.6 px。因为摩擦在锁旋转时
  无法靠自转消化，只能全部作用在线性运动上。
- **墙面完全不受影响**（0.00 px）：四壁摩擦为 0，本就不产生自转。所以这个属性只影响球与球之间。

**结论：保持默认 `false`。** 代价是棋子带一份"看不见的自转状态"——贴图会把它抵消，
只有倾斜能读出它，而它会影响后续碰撞。如果将来更看重可预测性，正解是
**锁旋转 + 把倾斜改成由碰撞冲量驱动**，而不是单纯把开关翻过去。

## 已验证的引擎事实

这几条都是本轮实测出来的，**不要凭直觉推翻**。完整数据见
[冻结与暂停策略](../40-physics/freeze-and-pause.md) 与 [全局约束](../00-overview/constraints.md)。

| 事实 | 说明 |
| --- | --- |
| 2D 弹性是**两边 bounce 相加再夹到 1** | `0.8 + 0.8 → 1.0`（完全弹性），`0.8 + 0.0 → 0.8`。不是取最大值 |
| 有摩擦时斜射撞墙会**把平动转成自转** | 入射角 ≠ 反射角，蓄力条会高估 7%~22%。所以四壁设 `friction = 0` |
| **没有 `space_step`** | `PhysicsServer2D` 没有任何手动步进接口，做不到"后台模拟一次碰撞然后立刻画出轨迹" |
| 运行期改 `PhysicsMaterial.bounce` 未必传到求解器 | 要整体赋值一个新材质才可靠。所以预测是**读**材质而不是写材质 |

## 当前生效的结构性红线

九条红线（见第二部分）里，**已经真正被代码强制**的是这四条：

| # | 红线 | 落点 |
| --- | --- | --- |
| 2 | 不依赖引擎回调顺序、字典迭代顺序、节点树顺序 | `TurnController._pick` 一次挑出最近命中者，结果只由几何决定 |
| 3 | 每物理帧至多推进一条边 | `game_flow.gd._physics_process` 用 `if` 不用 `while` |
| 5 | 状态唯一归属 | `selected_piece` 只在 `TurnController`；阶段状态只在 `GameFlow` |
| 7 | 每个等待都必须有终止条件 | 静止判定的 `rest_timeout_sec` 超时兜底；`PLAYER_TURN` 按设计无限等待 |

其余五条（1 / 4 / 6 / 8 / 9）服务于事件链、覆盖查询、物理闸门，等第二部分落地时再生效。

## 关键决策（已生效）

沿用 PRD 的编号，此处只列与实现直接相关的：

| # | 决策 | 在代码里的落点 |
| --- | --- | --- |
| 9 | 发射边用锁，不用剩余次数 | `game_flow.gd` 的 `launch_available` |
| 11 | 输入闸门统一由阶段机发放 | `TurnController._can_operate()` → `GameFlow.can_operate_pieces()` |
| 14 | 静止判定是棋盘级 | `game_flow.gd._board_at_rest()` |
| 17 | 回合级 5 阶段；选中/蓄力/射击是动作 | `enum Phase`，`TurnController` + `player.gd` |
| 18 | 枢纽叫 `PLAYER_TURN` | 同上 |
| 19 | 两次按键 + 粘性选中 | `TurnController.handle_left_press` |
| 20 | 蓄力条 = 理想轨迹预测 | `player.gd._predict_path` |
| 21 | 四壁 `friction = 0` | `main.tscn` 的 `PhysicsMaterial_6strp` |

## 改动范围（当前实现）

| 文件 | 性质 |
| --- | --- |
| `scripts/game_flow.gd` | 新增 |
| `scripts/turn_controller.gd` | 新增 |
| `scripts/player.gd` | 重写：删除 `ui_*` 旧推力与 `_input`；新增轨迹预测、有效弹性、`hit_test` / `set_selected` / `begin_charge` / `release_charge` / `cancel_charge` 能力接口 |
| `sences/main.tscn` | 新增 `GameFlow` / `TurnController` / `EndTurnButton`；`Player` → `Player1`；四壁加 `friction = 0` |
| `sences/player.tscn` | 挂 aura 描边材质（`resource_local_to_scene = true`，保证三枚实例各自独立） |
| `sences/mob.tscn` | 挂 `player.gd` + `owner_id = 1`，并补齐与棋子一致的物理材质与阻尼模式 |
| `shaders/aura.gdshader` | 新增 |
| `scripts/tile_map_layer.gd` | 同步改名后的调试 Label 路径 |

> **原文档在这里规划过一整套 `scripts/core/`（契约 / 工具类 / 桥 / 事件队列）。**
> 2026-10-10 决定按当前规模重新规划：那套服务于事件链、物理闸门、表现时间线，
> 都还没实现，预先铺开只会得到一堆空文件。相关论证挪到第二部分保留。

## 测试策略（当前）

- **headless 探针**：在 `$TMPDIR` 建最小 Godot 项目，拷真实场景与脚本进去，
  `--headless --fixed-fps 60` 跑确定性物理帧。阶段循环、静止闸门、发射边锁、
  蓄力条几何都是这样验的。**注意几个已踩过的坑**：
  - headless 里 `get_global_mouse_position()` 是 `(0,0)`，落在棋盘外。
    要测蓄力就临时把 `table_rect` 放大，而不是去伪造鼠标。
  - 探针的棋盘**没有挂物理材质**时弹性会退化成 `0.0 + 0.8 = 0.8`，
    与真实 `main.tscn`（`0.8 + 0.8 = 1.0`）不同。曾经因此得出过错误结论。
  - 每次投掷前要**复位所有相关状态**，不只是位置：棋子的位置/速度/自转/**血量**、
    以及 `GameFlow.owner_hp`。漏掉任何一项，上一个子测试的残留都会污染下一个。
    这一条被反复踩到——一轮验证里连中三次，全部表现为"看起来是代码 bug 的假失败"。
    写断言时**尽量从当前状态现算期望值**（如"起始血量 / 每撞伤害 = 需要几撞"），
    比写死数字更抗污染。
  - `--fixed-fps 60` 会把循环压到真实时间，长测试要留足窗口。
- **手工验证（用户在编辑器里做）**：手感类结论——蓄力速率、去抖窗口、ZOC 半径、
  四壁摩擦——全部以编辑器实测为准，文档只锁机制不锁数值。

---

# 第二部分：设计储备（未实现）

> ⚠️ **以下全部未实现。** 保留是为了环节 1（卡牌装载）与环节 3（ZOC 围攻）开工时
> 不必重推一遍。读到时请记住：这些文件、类名、接口**都不存在**。

## 背景与问题（2026-10-04 版，说明这些设计为何存在）

要把它变成回合制战棋，技术上有四个根因问题，而不是"缺几个阶段"：

1. **没有权威的推进者**。谁来决定"这一步做完了、可以往下走"？（**已解决**，见第一部分）
2. **没有事件的载体**。碰撞发生了、伤害产生了、有人死了——这些"发生了什么"现在只是
   代码执行路径的副作用，没有可以被结算、被表现、被测试、被 AI 推演消费的数据形态。
   （**未解决**）
3. **没有时间的所有权**。一旦要在碰撞中途插一段表现，就需要有人能"把物理按住一会儿再放开"，
   而且要按得精确、放得无损。（**未解决**，设计见下）
4. **规则和内容混在一起**。角色池、技能池、卡片池一旦长起来，这种混法会让每次加内容都要改核心。
   （**未解决**）

## 核心思路（目标形态）

**一根脊梁 + 一个队列 + 三个桶。**

- **脊梁**：阶段图。（已实现，规模比这里设想的小）
- **队列**：事件队列。结算与表现都挂在事件上——`事件是唯一真相`。链式效果靠
  "处理完一个再把新事件入队"展开，不做递归。
- **三个桶**：契约（接口，零逻辑）、工具类（纯函数，无状态）、桥（把内容接进核心的单向适配层）。
  核心只依赖契约，永远不认识任何具体的角色、卡片或技能。

物理冻结不在这三者里，它是**表现时间线持有的一个闸门**：需要的时候就按住，表现播完就放开。

## 关键决策（未生效，论证保留）

### 决策 1：阶段序列 → 阶段图

**已生效**（规模调整为 5 阶段）。理由：`PLAYER_TURN` 有三条出边、`MOTION` 有一条回边，
用"固定序列"表达必须写特例分支，而特例分支正是结构性缺陷的温床。

### 决策 2：把"是否完成"和"去哪"合并成一个返回值

**已生效（简化版）**：`_poll(delta) -> int`，返回 `NO_TRANSITION` 表示未完成。
没有单独的 `TurnPhase` 类，但"非法状态在类型上不可表达"这条性质保留了。

### 决策 3：轮询驱动，不用信号链，也不用协程

**已生效**。本作最主要的"完成信号"是物理静止，它天生是轮询的。
用协程会让规则层的执行顺序依赖 GDScript 的调度细节，无法在 headless 下稳定回放。

### 决策 4：阶段完成条件 = 规则条件 AND 表现排空

**未生效**（没有表现时间线）。`MOTION` / `PLAYER_TURN` 的完成在规则条件之外
还要加上"事件队列与表现时间线都已排空"。理由：表现是时间性的，不把"表现排空"算进去，
回合会在动画还在播的时候翻页。折中是把表现排空作为**完成条件的一个加法项**：
阶段机不知道动画细节，只知道"还有东西没播完"。

### 决策 5：事件是唯一真相，结算与表现同源

**未生效**。一次碰撞/攻击产生 `GameEvent`（纯数据）。结算读事件改状态；表现读事件画东西。
表现**只读事件，不回查规则**。

理由：动效上必然会有结算表现（`-8` 白字、爆炸、从角色表面跳出），
所以"结算归规则还是归动效"是个假问题。真正的结构问题是**两者必须看到同一份真相**，
否则会出现"数字显示 -8、血量实际扣了 9"这类不可排查的错位。

### 决策 6：链式效果用队列串行，禁止递归

**未生效**。效果规则签名是"输入一个事件，输出一组新事件"；新事件回到队列，
由队列排序后继续处理，直到队列为空。规则之间**不互相调用**。

理由：本作有一条真实的四层链：碰撞 → 双向伤害 → 角色血量见底 → 溢出伤害 →
归属方血量扣减 → 可能对局结束。用递归写，深度和顺序都不可控；用队列写，
顺序是显式的、可断点的、可序列化回放的。

### 决策 7：全序键定序，核心不认识"卡片"

**未生效**。每个事件带一个 `order_key: PackedInt32Array`，队列按字典序比较，
末尾以入队序号 `seq` 兜底。`order_key` 的首字段由**内容层**提供（当前是角色对应卡片的序号）。

理由："卡片"是内容概念，核心一旦认识它，就再也没法把这个策略换成"按速度"或"按攻击力"了。
把策略值降级成"内容层填的一个整数序列"，核心只做排序——换策略时改内容层，核心零改动。

### 决策 8：契约 / 工具类 / 桥 三桶分离

**已暂缓**（2026-10-10）。见 PRD 决策 13。

| 桶 | 内容 | 硬约束 |
| --- | --- | --- |
| 契约 | 阶段、事件、效果规则、表现、角色数据 | 零逻辑；不得出现任何具体角色名/卡名 |
| 工具类 | 棋盘查询、全序键比较、蓄力换算 | 纯函数、无状态、不缓存 |
| 桥 | 规则注册表、内容注册表、表现桥、物理闸门 | 单向：核心不认识内容，只有桥认识 |

### 决策 10：物理闸门是引用计数，且只在 `MOTION` 内使用

**未生效**。`PhysicsGate` 用计数封装 `PhysicsServer2D.set_active(false/true)`，
计数归零才真正解冻。

理由：一次行动里可能出现嵌套（一段碰撞表现还没播完，围攻结算又要播一段），
如果谁先播完谁解冻，物理会在中途被意外放开。计数让"最后一个离开的人关门"。

**备选（均已实测否决）**：
- `RigidBody2D.freeze = true`：解冻后速度归零（默认 STATIC 模式），KINEMATIC 模式速度被改写成旧值
- `get_tree().paused`：停的是整棵树，动画、Tween、`_process`、`_input` 都要逐个设 `PROCESS_MODE_ALWAYS`
- `Engine.time_scale = 0`：delta 直接变 0，动画一起冻死

### 决策 12：表现时间线可加速，不可跳过

**未生效**。时间线永远运行，事件按序触发；可变的只是时间源（真实 delta / ×N / 立即完成）。
提供"跳过"会破坏"事件必达"的不变量；提供"加速"既不破坏它，又能让 AI 推演与
`--headless` 回归测试跑得动。

## 结构性红线（完整九条）

已生效的四条见第一部分。以下五条等对应子系统落地时才生效：

| # | 红线 | 防的是什么 | 状态 |
| --- | --- | --- | --- |
| 1 | 效果链走队列串行，规则之间禁止互相调用 | 递归深度不可控、顺序不可回放 | 待生效 |
| 4 | 覆盖关系一类查询一律纯函数现算，不存状态 | 忘记更新缓存 | 待生效（环节 3） |
| 6 | 核心不得出现具体角色名/卡名 | 内容倒灌 | 待生效 |
| 8 | 事件是纯数据、可序列化；时间线可加速跑完 | 规则无法脱离渲染验证 | 待生效 |
| 9 | 物理闸门引用计数，只在时间线内成对出现，且限 `MOTION` 使用 | 漏放（物理永久冻死）与早放（中途解冻） | 待生效 |

## 事件链（设计草案）

这是整套机制的心脏，用场景走一遍完整链路：

```
[物理] 角色 A 撞上角色 B，回调拿到的是"已反弹后"的状态
   │
   ├─ 棋子只上报事实：collision(A, B, normal, 相对速度)   ← 不解释、不判断
   │
[规则] 有效果碰撞？—— 纯查询，不缓存
   │  否 → 什么都不做，物理继续跑（普通弹跳不冻结、不入队）
   │  是 ↓
[闸门] gate.acquire()                       ← PhysicsServer2D.set_active(false)
   │                                          位置零漂移，速度原样保留（已实测）
[队列] push(CollisionEvent{order:[card_index_A, A.id, ...]})
        drain():
          排序（全序键 + seq 兜底）
          for 每个事件:
            present.on_event(e)             ← 表现先接住（只读）
            for 新事件 in registry.apply(e, ctx):
              push(新事件)                   ← 回队，不递归
   │
   │  链路展开：
   │    CollisionEvent
   │      → DamageEvent(A→B, 8) → B.hp: 7 → 0（不够扣的 1 点溢出）
   │          → OverflowEvent(B, 1) → B 归属方的血量池 -1 → (可能) MatchOverEvent
   │      → DamageEvent(B→A, 6) → A.hp: 12 → 6
   │
   │  注意：B 血量到 0 就停住，**不退场、不死亡**（决策 23）。
   │  之后打到 B 身上的每一击都会整份溢出到它归属方的血量池。
   │
[表现] 时间线消费事件，依次播出"-8 白字 + 爆炸"
   │
[闸门] 表现排空 → gate.release()             ← PhysicsServer2D.set_active(true)
   │                                          运动以冻结前的速度继续（已实测）
[物理] 运动继续，直到全场静止
```

**"结算挂在动效标记上"怎么落地**：规则在 `apply` 里有两个选择——
不关心时机就直接改状态（默认）；关心时机就改为在 `present` 上订阅具名标记（`hit` / `end`），
标记到达时再改状态。两条路走的是同一个队列、同一个时间线。

## 物理闸门协议（设计草案）

- **唯一实现**：`PhysicsServer2D.set_active(false/true)`。禁止在别处直接调用，
  也禁止用 `RigidBody2D.freeze` 或 `SceneTree.paused` 顶替。
- **唯一持有者**：表现时间线。`acquire` 与 `release` 成对出现在表现桥内部。
- **使用范围**：仅 `MOTION` 阶段。
- **安全网**：`MOTION` 的退出钩子里断言计数为 0；不为 0 说明有表现没播完就退出了阶段，
  强制释放并输出警告日志。这是"冻结泄漏"的唯一兜底。

```gdscript
class_name PhysicsGate extends RefCounted

var _holds: int = 0

func acquire() -> void:
	_holds += 1
	if _holds == 1:
		PhysicsServer2D.set_active(false)

func release() -> void:
	assert(_holds > 0, "PhysicsGate: release 次数多于 acquire")
	_holds -= 1
	if _holds == 0:
		PhysicsServer2D.set_active(true)

func is_frozen() -> bool:
	return _holds > 0
```

## 关键接口（设计草案）

> 再次提醒：**以下类都不存在**。它们是为环节 3 与卡牌预锁的名称形状。

```gdscript
# ---------- 目标契约 ----------

class_name TurnPhase extends RefCounted
const NO_TRANSITION := -1
func enter(_ctx) -> void: pass
func exit(_ctx) -> void: pass
func on_input(_event: InputEvent, _ctx) -> void: pass
## 未完成 → NO_TRANSITION；完成 → 下一个阶段 id
func poll(_ctx) -> int: return NO_TRANSITION


class_name GameEvent extends RefCounted
var type: StringName                       # &"collision" / &"damage" / &"overflow" / ...
var source_id: int = -1
var target_ids: PackedInt32Array = PackedInt32Array()
var payload: Dictionary = {}               # 结算与表现所需的一切；表现只读这里
var order_key: PackedInt32Array = PackedInt32Array()   # 内容层填写（如卡片序号）
var seq: int = 0                           # 入队序号，全序的最终兜底


class_name Combatant extends RefCounted
var id: int
var owner_id: int          # 0 = 玩家方，1 = 敌方
var card_index: int        # 定序用；由内容层给出
var atk: int
var hp: int
var max_hp: int
var zoc_radius: float
var mounted_skills: Array[StringName] = []


# ---------- 目标工具类 ----------

class_name BoardQuery extends RefCounted
## 热路径：每物理帧调用，零分配
static func all_resting(pieces: Array, lin_sq: float, ang_sq: float) -> bool
## 冷路径：结算时调用
static func cover_set(pieces: Array, target_id: int, radius: float) -> PackedInt32Array
## 围攻：必须包含行动者，且覆盖数 >= 2
static func siege_of(pieces: Array, target_id: int, actor_id: int, radius: float) -> PackedInt32Array
```

## 故意不做（YAGNI）

- **不做表现层的对象池**：单场 ≤ 14 枚物理实体（每方 7 = 3 角色 + 最多 4 召唤物），
  伤害表现峰值不超过几十个节点。等实测有压力再说。
- **不做事件的持久化 / 存档**：事件可序列化是为了**测试回放**，不是为了存档。
- **不做多棋盘 / 分屏**：`PhysicsServer2D.set_active(false)` 是进程级开关，多棋盘下会互相干扰。
- **不做阶段的并行**：所有阶段严格串行。让"表现"与"下一阶段的准备"重叠执行会让
  状态时序变得不可推理，而收益在当前规模下不存在。
- **不做通用技能/效果 DSL**：效果规则就是 GDScript 类，不发明配置语言。
- **不做敌方 AI 决策**：`ENEMY_TURN` 只做停留。AI 将来会消费同一套事件与查询工具。

## 风险与边界（面向未实现部分）

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| 冻结泄漏导致物理永久停住 | 高（整局卡死） | 闸门引用计数 + 阶段退出断言兜底 + 只允许时间线成对调用 |
| 表现层被要求"跳过" | 中（破坏事件必达的不变量） | 只提供加速，不提供跳过 |
| `PhysicsServer2D.set_active` 是进程级开关 | 中（影响同进程全部 2D 物理） | 当前单棋盘，接受 |
| 高速穿模导致漏碰撞 | 中（伤害丢失） | 当前 600 px/s 下半径 16/14 安全；实测 `CCD_MODE_CAST_SHAPE` 会"提前弹"约 8px。取舍由编辑器手感决定 |
| 碰撞回调拿到的是已反弹状态 | 中（无法"阻止"弹跳） | 明确定义为"覆写引擎已做的响应"；需要在回调里重设速度。已实测可行 |
| 事件链出现环（A 伤害 B、B 反伤 A……） | 高（队列永不排空） | 队列设单次 drain 的事件数上限，超限即中断并输出警告。上限值待实测后定 |
| 表现资产缺失导致事件不触发 | 中 | 事件与表现解耦；表现缺失时 `present` 立即返回 finished，结算照常发生 |

**边界说明**：本方案只管"回合怎么推进、事件怎么流动、物理何时冻结"。
伤害数值、角色属性平衡、卡牌费用与效果、对局胜负判定都不在本方案管辖内。

## 修订记录

| 日期 | 变更 | 原因 |
| --- | --- | --- |
| 2026-10-04 | 初版：阶段图、事件链、三桶架构、物理闸门、九条红线 | 回合生命周期设计 |
| **2026-10-10** | 拆成「当前实现」与「设计储备」两部分；当前实现部分按 5 阶段、4 脚本重写 | 原文档通篇描述一套未实现的架构，读起来像现状。按用户决定改为按当前规模规划 |
| **2026-10-10** | 新增「已验证的引擎事实」「棋子的锁定」「当前生效的结构性红线」三节 | 本轮实测出的引擎行为与两套静止判定的职责边界，此前无文档 |
| **2026-10-10** | 决策 8（三桶）、决策 4/5/6/7/10/12 标注为**未生效** | 它们服务于尚未实现的子系统，不标注会被误读为现状 |
| **2026-10-10** | 测试策略补入 headless 探针的四个已踩坑 | 探针环境与真实场景有四处不一致，曾因此得出错误结论 |
