# 回合机制 技术方案

> 模块：`10-turn` ｜ 状态：编写中 ｜ 最近修订：2026-10-04
> 需求见 [PRD.md](PRD.md) ｜ 冻结语义依据见 [实测](../40-physics/freeze-and-pause.md)

## 背景与问题

当前代码是一个"单球弹棋"原型：一枚 `RigidBody2D` 自己处理蓄力、发射、瞄准线、
以及**角色级**的静止判定（`locked` / `lock_armed` / `lock_time`），并且还在
`_integrate_forces` 里读着 `ui_up` / `ui_left` / `ui_right` 的旧推力。
回合概念完全不存在——`main.tscn` 里那个叫 `LifeCycle` 的节点是个空 `Control`。

要把它变成回合制战棋，技术上有四个根因问题，而不是"缺几个阶段"：

1. **没有权威的推进者**。谁来决定"这一步做完了、可以往下走"？现在每枚棋子各有一套
   自己的静止判断，多个角色时互相不知道对方还在动。
2. **没有事件的载体**。碰撞发生了、伤害产生了、有人死了——这些"发生了什么"现在只是
   代码执行路径的副作用，没有可以被结算、被表现、被测试、被 AI 推演消费的数据形态。
3. **没有时间的所有权**。一旦要在碰撞中途插一段表现，就需要有人能"把物理按住一会儿再放开"，
   而且要按得精确、放得无损。现在没有任何东西拥有这个权力。
4. **规则和内容混在一起**。棋子脚本里已经有具体行为（蓄力速率、推力方向、减速常量）。
   角色池、技能池、卡片池一旦长起来，这种混法会让每次加内容都要改核心。

本方案要解决的是这四个根因，而不是先堆出九个阶段。

## 核心思路

**一根脊梁 + 一个队列 + 三个桶。**

- **脊梁**：阶段图。每个阶段只回答四个问题（进入做什么、完成了去哪、退出做什么、收到输入做什么），
  每物理帧轮询一次，**至多走一条边**。
- **队列**：事件队列。结算与表现都挂在事件上——`事件是唯一真相`。链式效果靠
  "处理完一个再把新事件入队"展开，不做递归。
- **三个桶**：契约（接口，零逻辑）、工具类（纯函数，无状态）、桥（把内容接进核心的单向适配层）。
  核心只依赖契约，永远不认识任何具体的角色、卡片或技能。

物理冻结不在这三者里，它是**表现时间线持有的一个闸门**：需要的时候就按住，表现播完就放开。
这样"碰撞中途插一段表现"不会污染规则层，规则层也不需要知道动效有多长。

## 关键决策

### 决策 1：阶段序列 → 阶段图

**选择**：阶段拓扑是一张有向图，每个阶段声明自己完成后去哪；默认后继是声明顺序的下一个，
只有需要的时候才覆盖。

**理由**：`ACTION` 有三个出边（出牌自环、发射、结束回合），`MOTION` 有一条回到 `ACTION` 的回边。
用"固定序列"表达这两件事必须写特例分支（"如果当前是 ACTION 且是发射……否则……"），
而特例分支正是结构性缺陷的温床。图结构下拓扑在一处可见，阶段本身保持愚笨。

**备选**：给 `ACTION` 拆成 `CARD_ACTION` / `LAUNCH_ACTION` 两个阶段来凑成序列。放弃原因：
阶段数量翻倍，而且"出牌不换阶段"的事实被伪装成了两次阶段切换，反而更难读。

### 决策 2：把"是否完成"和"去哪"合并成一个返回值

**选择**：阶段契约只有四个方法，其中推进问题由 `poll(ctx) -> int` 回答：
返回 `NO_TRANSITION` 表示未完成，返回阶段 id 表示完成并去哪里。

**理由**：如果分成 `is_done(ctx) -> bool` 和 `next(ctx) -> int` 两个方法，就存在
"完成了但没声明去向"和"没完成却声明了去向"两种非法状态，必须靠纪律或断言去防。
合并成一个返回值后，这两种状态**在类型上不可能表达**。

**备选**：在 `game_flow` 里维护一张显式边表。放弃原因：`ACTION` 的去向取决于
"玩家做的是哪件事"，边表要实现这个就得读一个可变的 `ctx.pending_transition` 字段——
把非法状态又请了回来。

### 决策 3：轮询驱动，不用信号链，也不用协程

**选择**：每个物理帧检查一次当前阶段的 `poll`，成立就推进一条边（用 `if`，不用 `while`）。

**理由**：本作最主要的"完成信号"是**物理静止**，它天生是轮询的（没有"静止"这个事件，
只有"连续 N 帧都足够慢"）。用信号链表达就要把静止包装成一个信号，反而绕。
用协程则会让规则层的执行顺序依赖 GDScript 的调度细节，无法在 headless 下稳定回放。

**备选**：`await` 协程式流程；或信号驱动的状态机。放弃原因见上，两者都会让
"规则能脱离渲染回放"这条硬要求变得难以保证。

### 决策 4：阶段完成条件 = 规则条件 AND 表现排空

**选择**：`MOTION` / `HIT_SETTLE` / `ZOC_SETTLE` / `ACTION` 的完成除了各自的规则条件，
还要加上"事件队列与表现时间线都已排空"。

**理由**：表现是**时间性**的，而规则条件是瞬时的布尔。如果不把"表现排空"算进去，
回合会在动画还在播的时候翻页——伤害数字还没跳完，局面已经变了。
反过来把"播完动画"塞进规则条件里，规则层就要知道动画时长。折中是把表现排空
作为**完成条件的一个加法项**：阶段机不知道动画细节，只知道"还有东西没播完"。

**备选**：让表现层直接调用阶段机"我播完了，你推进吧"。放弃原因：这就变成了信号链，
违背决策 3，并且表现层获得了推进规则的权力——耦合方向反了。

### 决策 5：事件是唯一真相，结算与表现同源

**选择**：一次碰撞/攻击产生 `GameEvent`（纯数据）。结算读事件改状态；表现读事件画东西。
表现**只读事件，不回查规则**。

**理由**：用户澄清过——动效上必然会有结算表现（`-8` 白字、爆炸、从角色表面跳出），
所以"结算归规则还是归动效"是个假问题。真正的结构问题是**两者必须看到同一份真相**，
否则会出现"数字显示 -8、血量实际扣了 9"这类不可排查的错位。

**备选**：让表现层自己算要显示什么（读血量差）。放弃原因：表现层于是需要理解结算规则，
加一个技能就要改一处表现，而且同帧多事件时无法确定"这个数字对应哪一次伤害"。

### 决策 6：链式效果用队列串行，禁止递归

**选择**：效果规则的签名是"输入一个事件，输出一组新事件"；新事件回到队列，
由队列排序后继续处理，直到队列为空。规则之间**不互相调用**。

**理由**：本作有一条真实的四层链：碰撞 → 双向伤害 → 某方血量转负 → 溢出伤害 →
玩家血量扣减 → 可能对局结束。用递归写，深度和顺序都不可控；用队列写，
顺序是显式的、可断点的、可序列化回放的。

**备选**：规则直接调用规则。放弃原因：递归深度不可控 + 顺序依赖调用栈 + 无法回放。

### 决策 7：全序键定序，核心不认识"卡片"

**选择**：每个事件带一个 `order_key: PackedInt32Array`，队列按字典序比较，
末尾以入队序号 `seq` 兜底，保证任意两个事件都有确定先后。
`order_key` 的首字段由**内容层**提供（当前是角色对应卡片的序号）。

**理由**：用户要求"同帧碰撞按敌方卡片 index 区分先后"。但"卡片"是内容概念，
核心一旦认识它，就再也没法把这个策略换成"按速度"或"按攻击力"了。
把策略值降级成"内容层填的一个整数序列"，核心只做排序——换策略时改的是内容层，核心零改动。

**备选**：核心直接读 `Combatant.card_index` 排序。放弃原因：核心依赖内容字段，
违反决策 8；而且比较逻辑散落在使用处，无法保证全局一致。

### 决策 8：契约 / 工具类 / 桥 三桶分离

**选择**：

| 桶 | 内容 | 硬约束 |
| --- | --- | --- |
| 契约 | 阶段、事件、效果规则、表现、角色数据 | 零逻辑；不得出现任何具体角色名/卡名 |
| 工具类 | 棋盘查询、全序键比较、蓄力换算 | 纯函数、无状态、不缓存 |
| 桥 | 规则注册表、内容注册表、表现桥、物理闸门 | 单向：核心不认识内容，只有桥认识 |

**理由**：用户明确要求"底层精炼为一批工具类、桥或契约文件，以便扩展角色池、技能池"。
这三桶的边界正好对应三种依赖方向：契约被所有人依赖、工具类谁都能用、
桥是唯一的"内容 → 核心"入口。

**备选**：用 autoload 单例直接在各处取角色数据。放弃原因：核心会出现
`ContentRegistry.get_character("关羽")` 这类调用，内容倒灌一旦开始就不可逆。

### 决策 9：发射边用锁，不用剩余次数

**选择**：`ACTION` 的发射出边有一个开关，`TURN_START` 打开，发射后关闭。

**理由**：用"剩余发射次数"计数器，就必须在每条可能的路径上记得扣减，
漏一条路径就是一个可被绕过的 bug。边上的开关没有"记得扣"这个动作——
发射这条边要么通要么不通，由阶段图本身保证。

**备选**：`ctx.shots_left` 计数器。放弃原因见上。

### 决策 10：物理闸门是引用计数，且只在 `MOTION` 内使用

**选择**：`PhysicsGate` 用计数封装 `PhysicsServer2D.set_active(false/true)`，
计数归零才真正解冻。冻结只允许在 `MOTION` 阶段发生。

**理由**：一次行动里可能出现嵌套（一段碰撞表现还没播完，围攻结算又要播一段），
如果谁先播完谁解冻，物理会在中途被意外放开。计数让"最后一个离开的人关门"。
限定只在 `MOTION` 内使用，是因为结算阶段全场已经静止，没有冻结的必要——
限制使用范围比事后排查泄漏便宜。

**备选**：
- `RigidBody2D.freeze = true`：实测解冻后速度归零（默认 STATIC 模式），
  KINEMATIC 模式速度被改写成旧值，且要逐枚冻结、漏一枚就继续滚。
- `get_tree().paused`：实测确实能停住 2D 物理，但它停的是整棵树，
  动画、Tween、`_process`、`_input` 都要逐个设 `PROCESS_MODE_ALWAYS`，等于跟暂停系统对抗。
- `Engine.time_scale = 0`：delta 直接变 0，动画一起冻死。

### 决策 11：输入闸门统一由阶段机发放

**选择**：只有当"事件队列与表现均已排空"且"当前阶段允许操作"时，输入才被转交给当前阶段。
角色不自行判断自己能否被操作。

**理由**：表现播放期间如果还能点选，玩家会在动画中途改选角色，产生无法复现的状态。
把许可集中在阶段机一处，角色脚本里不再有"我该不该响应"的分支。

**备选**：每枚角色自查 `controllable` 标志。放弃原因：这就是当前的实现方式，
已经导致"永久属性"和"动态许可"混淆，加一个新阶段就要改所有角色脚本。

### 决策 12：表现时间线可加速，不可跳过

**选择**：时间线永远运行，事件按序触发；可变的只是时间源（真实 delta / ×N 倍速 / 立即完成）。
不提供"关闭表现"的开关。

**理由**：用户的不变量是"动效不可被关闭，所以挂在动效上的结算一定会发生"。
提供"跳过"就会破坏这个不变量（事件可能被漏触发）；而提供"加速"既不破坏它，
又能让 AI 推演、平衡跑批、`--headless` 回归测试跑得动。

**备选**：给规则层一条"无表现"的快路径。放弃原因：两条路径意味着两套顺序语义，
早晚会出现"快路径和真实路径结果不一致"的幽灵 bug。

## 故意不做（YAGNI）

- **不做表现层的对象池**：单场 ≤ 10 枚角色，伤害表现峰值不超过十几个节点。等实测有压力再说。
- **不做事件的持久化 / 存档**：事件可序列化是为了**测试回放**，不是为了存档。
  存档格式属于另一个模块的决策。
- **不做多棋盘 / 分屏**：`PhysicsServer2D.set_active(false)` 是进程级开关，
  多棋盘下会互相干扰。当前是单棋盘游戏，不为此加复杂度；真要做分屏时再引入
  `World2D` 隔离或逐体冻结。
- **不做阶段的并行**：所有阶段严格串行。曾经考虑让"表现"与"下一阶段的准备"重叠执行，
  放弃原因是会让状态时序变得不可推理，而收益在当前规模下不存在。
- **不做通用技能/效果 DSL**：效果规则就是 GDScript 类，不发明配置语言。
  等到技能数量多到写 GDScript 明显成为瓶颈时再考虑。
- **不做敌方 AI 决策**：`ENEMY_TURN` 保持 pass。AI 会消费同一套事件与查询工具，
  但那是另一个模块的事。

## 阶段图与推进

```
TURN_START ─→ ACTION ─┬─[出牌]──────────────────────────→ ACTION
                      ├─[发射，锁开]→ SELECT → CHARGE → MOTION
                      │                            → HIT_SETTLE → ZOC_SETTLE → ACTION
                      └─[结束回合]────────────────→ TURN_END → ENEMY_TURN → TURN_START
```

推进规则（`game_flow.gd`，每物理帧执行一次）：

```
_accept_input = 当前阶段允许操作 AND 事件队列为空 AND 表现已排空

if _accept_input and 有缓存输入:
	当前阶段.on_input(输入)

next = 当前阶段.poll(ctx)
if next != NO_TRANSITION:          # 至多一条边，用 if 不用 while
	当前阶段.exit(ctx)
	当前阶段 = next
	当前阶段.enter(ctx)
	phase_changed.emit(旧, 新)
```

`HIT_SETTLE` 的定位见 [PRD 功能 1](PRD.md#功能-1回合阶段图)：
它承接的是全场静止后的收口（死亡判定、溢出血量落地、技能条件复核），
不是"发起攻击"——攻击在 `MOTION` 内就即时结算了。

## 事件链

这是整套机制的心脏，用用户给的场景走一遍完整链路：

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
   │      → DamageEvent(A→B, 8) → B.hp: 7 → -1
   │          → OverflowEvent(B, 1) → 玩家血量 -1 → (可能) MatchOverEvent
   │      → DamageEvent(B→A, 6) → A.hp: 12 → 6
   │
[表现] 时间线消费事件，依次播出"-8 白字 + 爆炸"
   │
[闸门] 表现排空 → gate.release()             ← PhysicsServer2D.set_active(true)
   │                                          运动以冻结前的速度继续（已实测）
[物理] 运动继续，直到全场静止
```

**"结算挂在动效标记上"怎么落地**：不需要两条路径。规则在 `apply` 里有两个选择——

- 不关心时机 → 直接改状态（默认）
- 关心时机 → 不改状态，改为在 `present` 上订阅某个具名标记（`hit` / `end`），
  标记到达时再改状态

两条路走的是同一个队列、同一个时间线，只是改状态的时刻不同。
所以"结算委托给动效"不是一个必须遵守的铁律，而是可用可不用的能力。

## 物理闸门协议

- **唯一实现**：`PhysicsServer2D.set_active(false/true)`。禁止在别处直接调用这两个函数，
  也禁止用 `RigidBody2D.freeze` 或 `SceneTree.paused` 顶替。
- **唯一持有者**：表现时间线。`acquire` 与 `release` 成对出现在表现桥内部。
- **使用范围**：仅 `MOTION` 阶段。
- **安全网**：`MOTION` 的 `exit()` 里断言计数为 0；不为 0 说明有表现没播完就退出了阶段，
  强制释放并输出警告日志。这条断言是"冻结泄漏"的唯一兜底。

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

## 结构性红线

以下九条是**结构上杜绝**，不是靠纪律遵守。每条都能指出"它防的是哪一类缺陷"：

| # | 红线 | 防的是什么 |
| --- | --- | --- |
| 1 | 效果链走队列串行，规则之间禁止互相调用 | 递归深度不可控、顺序不可回放 |
| 2 | 一切会互相影响的处理都有全序键；不依赖引擎回调顺序、字典迭代顺序、节点树顺序 | "本地跑三次结果不同"的幽灵 bug |
| 3 | 每物理帧至多推进一条边；同帧多事件排序后串行 | 帧内级联导致的状态机自激 |
| 4 | 覆盖关系一类查询一律纯函数现算，不存状态 | 忘记更新缓存（沿用 spec 中"查询是纯查询"的原则） |
| 5 | 状态唯一归属：数值只在 `Combatant`，本回合瞬时量只在 `TurnContext` | 两处都能改同一个值 |
| 6 | 核心不得出现具体角色名/卡名 | 内容倒灌，加一个角色就要改核心 |
| 7 | 每个等待都必须有终止条件：`MOTION` 有超时兜底；玩家输入阶段按设计无限等待；时间线每一步可结束 | 死等 |
| 8 | 事件是纯数据、可序列化；时间线可加速跑完 | 规则无法脱离渲染验证 |
| 9 | 物理闸门引用计数，只在时间线内成对出现，且限 `MOTION` 使用 | 漏放（物理永久冻死）与早放（中途解冻） |

## 改动范围

### `scripts/core/contracts/`（新增）

五个契约文件，零逻辑：`turn_phase.gd` / `game_event.gd` / `effect_rule.gd` /
`presenter.gd` / `combatant.gd`。它们定义的是"核心能看见什么"，
所以**任何具体角色、卡片、技能的名字都不允许出现在这里**。

### `scripts/core/utils/`（新增）

`board_query.gd`（静止判定、覆盖集合、围攻判定）、`ordering.gd`（全序键比较）、
`charge.gd`（蓄力 → 冲量换算）。全部是 `static` 纯函数。
注意区分冷热路径：`all_resting` 每物理帧调用且零分配；覆盖/围攻查询在结算时才调，
允许返回新数组。这条边界写清楚，是为了避免"为了零分配把冷路径也写成传缓冲区"的过度设计。

### `scripts/core/bridge/`（新增）

`rule_registry.gd`（事件类型 → 效果规则列表）、`content_registry.gd`（id → 角色/卡片定义）、
`present_bridge.gd`（事件 → 时间线，闸门的持有者）、`physics_gate.gd`。
核心与内容的唯一接触面就在这里。

### `scripts/core/event_queue.gd`（新增）

排序 + 串行排空。`drain` 不是每帧热路径（只在有效果碰撞/结算时调用），
所以允许在排空时做数组交换；但**排序必须是稳定的全序**。

### `scripts/game_flow.gd`（新增）

阶段图、推进循环、输入闸门、`phase_changed` 信号、`MOTION` 退出时的闸门断言。
它是唯一持有 `TurnContext` 与阶段实例的地方。

### `scripts/board.gd`（新增）

持有**唯一一份**角色数组（静止判定与覆盖查询共用它，不各自构造临时列表）。
对外暴露棋盘级查询入口与"有效果碰撞"的判定入口。

### `scripts/turn_context.gd`（新增）

一个回合的瞬时状态：当前行动角色、瞄准点、力度、命中记录、发射边锁状态。
回合结束即丢弃，不承担跨回合数据。

### `scripts/player.gd` → `scripts/piece.gd`（修改 + 重命名）

保留：蓄力、瞄准线、贴图倾斜。
上移：`locked` / `lock_armed` / `lock_time` 等角色级静止判定交给 `board.gd`。
改造：`controllable` 从导出常量改为向阶段机查询的动态许可。
删除：`_integrate_forces` 里的 `ui_up` / `ui_left` / `ui_right` 旧推力。
新增：碰撞只**上报事实**（对方、法线、相对速度），不判断是否有效果。

### `scripts/tile_map_layer.gd`（修改）

只维护调试用的鼠标/角色坐标 Label。节点改名后同步引用路径。

### `sences/main.tscn`（修改）

`LifeCycle`（空 `Control`，会按 `mouse_filter` 消费鼠标事件）→ 普通 `Node`；
棋盘容器 `StaticBody2D` → `Board`；`AimLine` 相对路径随之调整；
新增"结束回合" `Button` 并连到阶段机。

## 关键接口

以下为接口草案（GDScript），用于锁定形状，不是最终实现。

```gdscript
# ---------- 契约 ----------

class_name TurnPhase extends RefCounted
const NO_TRANSITION := -1

func enter(_ctx: TurnContext) -> void: pass
func exit(_ctx: TurnContext) -> void: pass
func on_input(_event: InputEvent, _ctx: TurnContext) -> void: pass
## 未完成 → NO_TRANSITION；完成 → 下一个阶段 id
func poll(_ctx: TurnContext) -> int: return NO_TRANSITION


class_name GameEvent extends RefCounted
var type: StringName                       # &"collision" / &"damage" / &"overflow" / ...
var source_id: int = -1
var target_ids: PackedInt32Array = PackedInt32Array()
var payload: Dictionary = {}               # 结算与表现所需的一切；表现只读这里
var order_key: PackedInt32Array = PackedInt32Array()   # 内容层填写（如卡片序号）
var seq: int = 0                           # 入队序号，全序的最终兜底


class_name EffectRule extends RefCounted
## 只回答"这类事件我管不管"
func matches(_e: GameEvent, _ctx: TurnContext) -> bool: return false
## 只产出新事件，绝不直接调用另一条规则
func apply(_e: GameEvent, _ctx: TurnContext) -> Array[GameEvent]: return []


class_name Presenter extends RefCounted
signal finished
signal marker_reached(marker: StringName, event: GameEvent)

func play(_events: Array[GameEvent]) -> void: pass
func is_finished() -> bool: return true


class_name Combatant extends RefCounted
var id: int
var owner_id: int          # 0 = 玩家方，1 = 敌方
var card_index: int        # 定序用；由内容层给出
var atk: int
var hp: int
var max_hp: int
var zoc_radius: float
var mounted_skills: Array[StringName] = []


# ---------- 工具类 ----------

class_name BoardQuery extends RefCounted
## 热路径：每物理帧调用，零分配
static func all_resting(pieces: Array, lin_sq: float, ang_sq: float) -> bool
## 冷路径：结算时调用
static func cover_set(pieces: Array, target_id: int, radius: float) -> PackedInt32Array
## 围攻：必须包含行动者，且覆盖数 >= 2
static func siege_of(pieces: Array, target_id: int, actor_id: int, radius: float) -> PackedInt32Array


class_name Ordering extends RefCounted
## 字典序比较 order_key，长度不同则短者在前，最后以 seq 兜底 → 全序
static func less(a: GameEvent, b: GameEvent) -> bool


# ---------- 桥与服务 ----------

class_name RuleRegistry extends RefCounted
func register(event_type: StringName, rule: EffectRule) -> void
func apply(e: GameEvent, ctx: TurnContext) -> Array[GameEvent]


class_name PhysicsGate extends RefCounted    # 见"物理闸门协议"
func acquire() -> void
func release() -> void
func is_frozen() -> bool


# ---------- 脊梁 ----------

class_name GameFlow extends Node
signal phase_changed(from_phase: int, to_phase: int)

var ctx: TurnContext
var _phase: TurnPhase
var _accept_input := false

func _physics_process(_delta: float) -> void:
	_accept_input = _phase_allows_input() and _queue.is_empty() and _present.is_finished()
	_phase.on_input(_cached_input, ctx) if _accept_input else null
	var next := _phase.poll(ctx)
	if next != TurnPhase.NO_TRANSITION:
		_phase.exit(ctx)
		_phase = _phases[next]
		_phase.enter(ctx)
		phase_changed.emit(prev, next)
```

## 测试策略

- **机制语义用探针项目验证**：像本项目已经做过的那样，在 `$TMPDIR` 建一个最小 Godot 项目，
  用 `--headless --fixed-fps 60` 跑确定性物理帧，逐帧打印状态。
  冻结是否零漂移、速度是否保留、解冻是否连续，都是这样测出来的（见
  [冻结与暂停策略](../40-physics/freeze-and-pause.md)）。**这类结论不靠推理，靠实测。**
- **规则在 headless 下回放**：事件是纯数据，用固定的事件序列回放，断言
  "状态改变 + 产出的事件序列"都一致。这是决策 8 与红线 8 的直接收益。
- **定序测试**：构造同帧多碰撞，重复运行多次，断言结算顺序稳定不变。
  再改一次内容层提供的 `order_key`，断言顺序随之改变而核心代码零改动。
- **手工验证（用户在编辑器里做）**：手感类结论——蓄力速率、去抖窗口、ZOC 半径、
  CCD 开关带来的"提前弹"——全部以编辑器实测为准，文档只锁机制不锁数值。

## 风险与边界

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| 冻结泄漏导致物理永久停住 | 高（整局卡死） | 闸门引用计数 + `MOTION.exit()` 断言兜底 + 只允许时间线成对调用 |
| 表现层被要求"跳过" | 中（破坏事件必达的不变量） | 只提供加速，不提供跳过；无表现的动作退化为零长时间线 |
| `PhysicsServer2D.set_active` 是进程级开关 | 中（影响同进程全部 2D 物理） | 当前单棋盘，接受；将来分屏需改用 `World2D` 隔离——已记入"故意不做" |
| 高速穿模导致漏碰撞 | 中（伤害丢失） | 当前 600 px/s 下半径 16/14 安全；实测 `CCD_MODE_CAST_SHAPE` 会"提前弹"约 8px。取舍由编辑器手感决定 |
| 碰撞回调拿到的是已反弹状态 | 中（无法"阻止"弹跳） | 明确定义为"覆写引擎已做的响应"；需要在回调里重设速度。已实测可行 |
| 事件链出现环（A 伤害 B、B 反伤 A……） | 高（队列永不排空） | 队列设单次 drain 的事件数上限，超限即中断并输出警告。上限值待实测后定 |
| 表现资产缺失导致事件不触发 | 中 | 事件与表现解耦；表现缺失时 `present` 立即返回 finished，结算照常发生 |

**边界说明**：本方案只管"回合怎么推进、事件怎么流动、物理何时冻结"。
伤害数值、角色属性平衡、卡牌费用与效果、对局胜负判定都不在本方案管辖内，
它们通过 `EffectRule` 与 `ContentRegistry` 接入，接入时不需要改动本方案的任何文件。
