# 技能系统 技术方案

> 模块：`35-skill` ｜ 状态：**设计储备（未实现）** ｜ 创建/最近修订：2026-11-02
> 需求见 [PRD.md](PRD.md) ｜ 代码状态：**一行都没有**
>
> 本文所有类名、文件、函数名**都还不存在**。它们是为实现预锁的形状，
> 不是现状。读之前请先看 [design/README.md](../README.md) 的「代码」列。

## 0. 现状与差距

| 项 | 现在 | 目标 |
| --- | --- | --- |
| 技能运行时 | 无 | `SkillRuntime` + `SkillInstance` |
| 卡牌入口 | `game_flow.gd` 的 `play_card()` / `load_card()` 空方法 | 挂载/激活技能 |
| 碰撞顺序 | `_end_freeze()` 里先 `_exchange(a,b)` 再 `_exchange(b,a)` | 激活 → 碰撞 → 结算 |
| 伤害去向 | `_apply_damage_to()` 把溢出转给归属方（旧规则） | `hp > 0` 立即扣；`hp == 0` 转成**攻击方归属方**的头像攻击力，`TURN_END` 双方各自结算 |
| 失能 | 旧「薄弱点」全功能可用 | 技能全关、**不提供 ZOC 但仍可被围攻**、可发射；被攻击会给攻击方归属方充能 |
| 周期 | 5 阶段；无 `MATCH_START`、无回合计数、敌方回合无独立 `TURN_END` | `MATCH_START` / `TURN_START(owner)` / `TURN_END(owner)`；`TURN_END` 双方各自结算攻击力 |
| 事件 | 无（只有信号与直接调用） | 最小事实/修正/结果事件 |

> **文档与代码的差异是已知的。** 本轮只更新设计文档，不改代码；
> 在上述规则实现前，`scripts/game_flow.gd` 的实际行为仍是旧规则。

## 1. 架构总览

```
GameFlow / 物理 / 回合
   │ 事实：collision_fact / turn_start / turn_end / manual_activate
   ▼
SkillRuntime（注册表 + 激活 + 结算）
   ├─ 通用技能：SkillInstance（每个技能一个 GDScript 类）
   └─ 全局技能：GlobalSkill / BoardSkill（特殊类，独立棋盘算法）
   │ 修正/事件：damage_modifier / damage_prevented / heal / move / skill_*
   ▼
EffectResolver（唯一应用状态的地方）
   │ 结果事件
   ▼
BattleLog / 表现 / headless 断言
```

四条硬约束：

1. **宿主只登记归属，不自己调用技能。** 否则非发射角色的被动、全局技能、
   多技能排序都会失控。
2. **技能不直接改状态。** 不写 `hp` / `atk` / `linear_velocity`，不播动画，
   不写日志文案；只返回修正与事件。
3. **只有 `EffectResolver` 改状态。** 伤害、治疗、属性修正、位移都从这里落地。
4. **技能之间不互相调用。** 需要链式效果时，产出新事件回到队列/结算序列。

## 2. 契约草案

```gdscript
class_name Skill extends RefCounted

enum State { ARMED, ACTIVE, EXPIRED }

# 静态：这个技能关心哪些时刻
func hooks() -> PackedStringArray:
	return PackedStringArray()

# 生命周期
func bind(_ctx: SkillContext) -> void: pass
func unbind(_ctx: SkillContext) -> void: pass
func state() -> int: return State.ARMED

# 碰撞前：锁定目标 + 登记修正，不直接改世界
func activate(_event: GameEvent, _ctx: SkillContext) -> Activation:
	return null

# 碰撞后 / 回合后：落地剩余效果
func settle(_act: Activation, _ctx: SkillContext) -> Array[GameEvent]:
	return []

# 失能 / 目标全失效 / 被元规则取消
func cancel(_act: Activation, _ctx: SkillContext) -> void: pass

# 联机 / 回放：状态必须是纯数据，不能存节点引用
func snapshot() -> Dictionary: return {}
func restore(_data: Dictionary) -> void: pass
```

配套：

- `SkillDef`：不可变定义（id、参数、演出键）。**运行时状态绝不能放在 `.tres` 里**——
  Godot 的 Resource 默认跨实例共享，两个角色会共用一个计数器。状态放在
  `SkillInstance`，或给 Resource 设 `resource_local_to_scene = true`。
- `Activation`：`{ skill_id, host_id, target_ids, modifiers, cause, state }`。
  它是碰撞前快照，也是"失去条件不注销"的载体。
- `SkillContext`：稳定 id、归属方、棋盘查询、注入的 RNG、`emit(event)`。
  不把 `Node` 暴露给技能逻辑；需要位置时用 `ctx.piece_position(host_id)`。
- `SkillRuntime`：`mount(host_id, skill_instance)` / `dispatch(hook, event)` /
  `unmount(skill_instance)`。注册表按 hook 索引，派发前排序。

### 排序

```
priority（显式，默认 0）
  → host.card_index（内容层提供）
  → mount_seq（挂载顺序，最后兜底）
```

不依赖字典迭代顺序、节点树顺序或信号回调顺序。这一条与项目红线 #2 一致。

## 3. 碰撞管线

```
collision_fact（原始事实，已去重）
  → damage_collision（行动角色 × 敌方，具备伤害资格）
  → activate(主动方) → activate(被动方)
  → 双向伤害交换（应用已登记的修正）
  → settle(所有已激活；失能宿主取消)
  → 日志 / 表现
```

### 3.1 事实与资格必须分层

现在 `player.gd:184` 的 `bumped` 会过滤掉墙壁，但 `game_flow.gd:654` 的
`_on_piece_bumped()` 又过滤掉友方与非行动角色。**#5 要数"每次与敌方棋子的碰撞"，
它需要的是事实层，不是伤害资格层。** 实现时在伤害过滤之前先发一个
`collision_fact`，由 runtime 去重后派发。

- `collision_fact`：任意两枚棋子的接触（墙壁仍由棋子脚本过滤）。
- `damage_collision`：`collision_fact` 中满足"行动角色 × 敌方"的子集，
  才进入激活/碰撞/结算序列。

### 3.2 伤害意图

```gdscript
class DamageIntent:
	var source_kind: StringName   # &"collision" / &"zoc" / &"skill"
	var source_id: int
	var target_id: int
	var amount: int
	var modifiers: Array          # 已登记的修正
	var cause: GameEvent
```

`source_kind` 是必须的：没有它，#3 会把 ZOC 伤害也钳成 1，#5 会把围攻也免疫掉。
当前 `_apply_damage_to()` 是碰撞与 ZOC 的共用出口，实现时先在这里接意图。

### 3.3 归属方头像攻击力

`apply_damage(intent)` 的行为（目标形态）：

```gdscript
if target.hp > 0:
    absorbed = min(amount, target.hp)
    target.hp -= absorbed
    # 造成失能的那一下，超出部分丢弃
else:
    # 目标已失能：伤害转成攻击方归属方的一次性头像攻击力
    attacker_owner.owner_attack_power += amount
```

- `owner_attack_power` 是 **owner 级、一次性**状态（建议与 `owner_hp` 放在一起），
  不是某个技能或棋子的状态。多个失能角色/多次攻击的伤害汇总到同一个头像。
- **攻击力只是结算形式/表演**：唯一用途是回合末扣对方归属方血量；它不是可消费资源，
  不能拿来做别的用途，也不改变角色 `atk`。
- 只有「敌方对已失能角色」的伤害计入；友方伤害、造成失能那一下的超出部分不计入。
- **每次 `TURN_END` 的最后**（回合结束技能之后）：双方各自把攻击力打到**对方归属方**，
  各打各的、不抵消：

  ```gdscript
  var to_0 := owner_attack_power[1]   # 敌方攻击力打我方
  var to_1 := owner_attack_power[0]   # 我方攻击力打敌方
  owner_hp[0] -= to_0
  owner_hp[1] -= to_1
  owner_attack_power = [0, 0]
  # 双方都结算完再检查胜负；同时归零 = 平局
  ```

- 进入攻击力的数值是**技能修正后的最终伤害**；被 `damage_prevented` 的伤害不计入。
- 不要立即调用 `damage_owner()`；当前代码的即时溢出是待改行为。

### 3.4 失能与取消

- 失能发生在碰撞阶段（伤害落地后）。
- 已登记的**伤害修正**在碰撞阶段已经生效，不回滚。
- 宿主失能后，它的**未结算 `Activation`** 立即取消；这是「失去条件不注销」的元规则例外。
- 失能期间受到的伤害计入**攻击方归属方**的 `owner_attack_power`；它自己的技能
  （#3/#5 等）全部关闭。
- **ZOC**：失能角色不提供覆盖（不算 `coverers_of` 的成员），但仍可作为 ZOC 目标；
  对它的围攻伤害同样给攻击方归属方充能。
- 日志发 `skill_cancelled`（原因 `disabled`）与 `owner_attack_power_gained`
  （金额、攻击方 owner、来源）。

## 4. 周期调度

```gdscript
class Schedule:
	var phase: StringName        # &"turn_start" / &"turn_end"
	var owner_filter: int        # 0 / 1 / -1（任意）
	var remaining: int           # 还差几次
	var payload: Dictionary      # 技能 id、目标快照、数值
```

- 由 `GameFlow` 的阶段进入/离开驱动，**不用真实时间**。
- `TURN_START(owner)` 触发时，本回合归属方的技能先结算，对手的
  「在对方回合开始时」效果后结算。
- **`TURN_END(owner)`**：先派发 `turn_end` hook（回合结束技能，主动方先、被动方后），
  **最后**双方各自把头像攻击力打到对方归属方（各打各的，不抵消），随后清零；
  同时归零 = 平局。
- #4 的调度是 `{phase: turn_start, owner_filter: me, remaining: 1}`。
- `MATCH_START` 不作为周期项：对局初始化后派发一次 `match_start` hook，然后进入正常回合。
  当前未实现。
- ⚠️ **当前阶段图只有玩家回合的 `TURN_END`**，敌方回合直接回 `TURN_START`。
  要实现「每回合末攻击力结算」，必须先补一个 `turn_end(owner=1)` 钩子
  （或在回 `TURN_START` 前发一次事件）。这是新增的接缝，不是现有代码的现成能力。
- 建议加只读的 `turn_index`（全局单调）与 `owner_turn_index`，用于日志与回放；
  它们不参与规则判定。

## 5. 全局技能特殊类

全局技能（#6）不强行塞进通用组件。它复用：

- 宿主 / 归属方；
- 激活 / 失能 / 日志事件；
- 元规则校验（尤其是不重叠）。

但它的效果由**专门的棋盘算法**实现：

```gdscript
class_name GlobalSkill extends Skill
# 不进入通用 hook 派发；由 GameFlow / 归属方动作直接调用
func execute(_ctx: SkillContext) -> Array[GameEvent]: ...
```

#6 的实现约束：

- **不重叠是元规则**：先算出完整的新布局，校验通过后再原子应用；
  校验失败则整体不生效，不能"改一半"。
- 第一版建议「随机交换两枚棋子的位置」：交换天然保持占用点集合不变；
  若棋子半径不同，交换后仍需校验。
- 随机源用可注入种子的 `RandomNumberGenerator`（参考 `enemy_bot.gd` 的
  `rng_seed`），不用全局 `randi()`。
- 重排是传送，不是运动：不触发碰撞伤害、不充能 #5、不消费 #2 的"下一次碰撞"。
- 物理冻结：复用 `PhysicsServer2D.set_active(false/true)`，与碰撞冻结同一套
  安全点；不要在物理回调里直接改刚体位置。

## 6. 确定性与回放

技能系统会先于联机落地，但不能把联机的路堵死：

- **稳定 id**：技能状态里只存 `host_id` / `target_id` / `card_index`，
  不存 `Node` 引用。否则 `_impact_pending` 那种"过不了网线"的债会再来一遍。
- **种子随机**：所有随机效果走注入的 RNG；同一 seed = 同一结果。
- **回合驱动**：延迟效果不用 `Timer` / 真实时间；用 `Schedule`。
- **攻击力的状态**：`owner_attack_power` 是 owner 级纯数据，跟 `owner_hp` 一起进入快照；
  每次 `TURN_END` 双方各自结算后清零，避免跨回合重复攻击。
- **快照**：`snapshot()` 存计数器、待发标记、层数、到期回合；
  不存节点、不存闭包。
- **事件日志**：`skill_*` / `damage_*` 事件本身就是回放轨迹，也是玩家战报的来源。

## 7. 与现有代码的接缝

| 位置 | 现在 | 目标 |
| --- | --- | --- |
| `game_flow.gd:469` `_resolve_collision` | 直接记 `_impact_pending` | 先发 `collision_fact`，再判断伤害资格 |
| `game_flow.gd:654` `_on_piece_bumped` | 只保留行动角色 × 敌方 | 拆成事实层与资格层；去重在事实层完成 |
| `game_flow.gd:710` `_end_freeze` | 先 `_exchange(a,b)` 再 `_exchange(b,a)` | 主动方激活 → 被动方激活 → 双向碰撞 → 结算 |
| `game_flow.gd:484` `_apply_damage_to` | 溢出转给归属方 | 接 `DamageIntent`；`hp > 0` 立即扣，`hp == 0` 加到**攻击方归属方**的 `owner_attack_power`；造成失能那一下超出部分丢弃 |
| `game_flow.gd:245` `_enter` | 阶段进入 | 发 `TURN_START` / `TURN_END`，驱动 `Schedule`；`TURN_END` 双方各自结算攻击力；**补敌方回合结束钩子** |
| `game_flow.gd:389` `reset_match` | 复位血量与回合状态 | 同时清零 `owner_attack_power` 与技能状态 |
| `game_flow.gd:797` `_update_owner_hp_label` | 只在 `owner_hp_changed` 时刷 | 攻击力结算后触发一次刷新；头像上的攻击力另做显示，不改归属方血量 |
| `game_flow.gd:445` / `451` | `play_card` / `load_card` 空方法 | 手动激活 / 挂载技能 |
| `player.gd:153` `reset_to_home` | 复位位置/血量/atk | 全局技能重排位置的参照；同时清空技能状态 |
| `player.gd:184` `_on_body_entered` | 过滤墙壁后发 `bumped` | 保留；确保事实层能拿到友方/被撞方的碰撞 |
| `enemy_bot.gd` | 可注入种子的 RNG | 全局技能随机源的参照；bot 攻击失能角色会给自己的归属方充能，仍是有效目标 |

### 为什么先不重写整个 game_flow

`game_flow.gd` 已经 851 行、一个人管六件事（见 [TODO #3](../TODO.md)）。
现在就把整条链改成事件驱动，会得到一个没有表现时间线支撑的半成品队列。
更小的路径是：

1. 先加**事实/修正/结果事件**这一层薄的；
2. 技能 runtime 同步派发，`EffectResolver` 立即应用；
3. 等表现时间线真的要做时，再把同步派发换成队列 + 时间线；
   **技能侧契约不变**。

这也是项目一贯的「让功能逼出抽象」，而不是先铺空架构。

## 8. 测试策略

实现后应能在 `--headless --fixed-fps 60` 下断言：

- 一次碰撞只派发一次（去重）。
- 主动方技能先于被动方；同阵营按 priority/card_index/mount_seq。
- #3 只钳碰撞，不钳 ZOC；#5 只挡自己受到的伤害。
- 第三层 #5 的伤害照常结算；下一次碰撞免疫并发 `damage_prevented`。
- 宿主失能后，未结算效果取消；已应用的伤害修正不回滚。
- **失能角色仍可被碰撞/围攻**；伤害当场不扣归属方血，而是计入**攻击方归属方**的
  `owner_attack_power`。
- **造成失能的那一下**超出部分丢弃，不计入攻击力；之后的伤害才计入。
- 攻击力只由**敌方对已失能角色**的伤害累积；友方伤害/自伤不计入。
- `TURN_END` 双方各自把攻击力打到对方：10 vs 4 → 敌方 -10、我方 -4；
  结算后双方清零；玩家回合与敌方回合都要结算；结算在回合结束阶段的最后；
  **同时归零 = 平局**。
- 失能角色不提供 ZOC（不算覆盖者），但可作为 ZOC 目标；围攻伤害给攻击方归属方充能。
- #4 只在"下一次我方 TURN_START"触发，不在敌方回合触发。
- #6 的任何输出都通过不重叠校验；同 seed 同结果。
- `bash tools/verify.sh` 仍为退出码 0（改 `scripts/` 后必须跑）。

## 9. 故意不做

- **不做技能 DSL**：技能就是 GDScript 类。模板是必填清单，不是配置文件。
- **不做技能死循环检测**：用户明确暂不处理；实践中遇到再加排空上限/触发计数。
- **不重写整个事件队列/表现时间线**：先把薄的一层接上。
- **不做隐藏技能/战争迷雾**：棋盘上的操作、技能触发、攻击力、ZOC、角色状态全部可见；
  只有各自手牌不可见。技能 UI 只负责呈现，不做可见性判定。
- **不做复活**：未来是代价较大的全局技能，单独设计。
- **不做联机序列化**：但状态形状按可序列化设计，不存节点引用。

## 10. 风险

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| 事实层/资格层拆分碰热路径 | 中（碰撞结算回归） | 先加事实事件，不改现有伤害路径；分两步验证 |
| `_end_freeze` 顺序改动 | 高（双向伤害、冻结、抖动都受影响） | 用 headless 探针固定旧行为基线，再逐条替换 |
| 归属方攻击力与回合末结算 | 高（胜负、回合边界、双方同时归零） | 攻击力是 owner 级结算状态；先补敌方 `TURN_END` 钩子；同时归零 = 平局 |
| 攻击力未在回合末清零/重置 | 中（跨回合重复攻击） | `TURN_END` 的最后结算后立即清零；`reset_match` 清零；headless 断言 |
| 失能取消与动画/结算时序冲突 | 中（表现播一半） | 取消只作用于未结算的 Activation；已应用修正不回滚 |
| 全局技能不重叠校验失败 | 中（卡死/重叠） | 先算完整布局再原子应用；失败不改棋盘 |
| 技能顺序不确定 | 高（回放/联机不一致） | 显式排序键；禁止依赖字典/节点/回调顺序 |
| 技能状态存节点引用 | 中（联机/回放失效） | 稳定 id；`snapshot()` 校验 |

## 11. 实现架构（第一切片）

> 目标：用最小代码验证技能契约，不一次铺开 #2/#4/#6。
> 第一切片 = **技能契约 + #1 立即增益 + #3 受击只掉 1 + #5 能量护盾
> + 归属方攻击力累积 + 双方 `TURN_END` 结算**。

### 11.1 文件落点

| 文件 | 职责 |
| --- | --- |
| `scripts/skills/skill.gd` | `Skill` 契约基类；`State` 枚举；hooks / bind / unbind |
| `scripts/skills/skill_runtime.gd` | 注册表、挂载/卸载、hook 派发、排序 |
| `scripts/skills/skill_context.gd` | 宿主/owner/查询/事件出口 |
| `scripts/skills/game_event.gd` | 最小事件载体（type / source / targets / payload / cause） |
| `scripts/skills/impl/buff_skill.gd` | #1 立即增益 |
| `scripts/skills/impl/damage_cap_skill.gd` | #3 受击只掉 1 |
| `scripts/skills/impl/energy_shield_skill.gd` | #5 能量护盾 |
| `scripts/battle_log.gd` | 事件日志：headless 断言 + 玩家战报的雏形 |

> 先不建 `scripts/core/` 三桶。`GameEvent` 暂放 `scripts/skills/`，等事件队列/表现时间线
> 真落地时再移动到核心；第一切片不为它铺空架构。

### 11.2 契约

复用本文第 2 节的 `Skill` 草图，第一切片只实现这些：

```gdscript
class_name Skill extends RefCounted
enum State { ARMED, ACTIVE, EXPIRED }

func hooks() -> PackedStringArray: return []
func bind(_ctx: SkillContext) -> void: pass
func unbind(_ctx: SkillContext) -> void: pass
func on_hook(_hook: StringName, _event: GameEvent, _ctx: SkillContext) -> Array[GameEvent]:
	return []
func snapshot() -> Dictionary: return {}
func restore(_data: Dictionary) -> void: pass
```

- `SkillRuntime` 由 `GameFlow` 持有（不是 autoload）；`mount(host, skill)` 登记实例。
- **来源标记**：`SkillInstance` 带 `origin`（`innate` / `card` / `summon`）。角色固有特性
  在开战时由 `BattleSetup` 以 `origin = innate` 挂载，卡牌授予的技能在出牌时挂载；
  排序与契约不变。**不另造一套 trait 运行时**（2026-11-12，见 [角色技术方案](../20-character/DESIGN.md)）。
- `SkillContext` 暴露 `host_id` / `owner_id` / 查询 / `emit`；技能不持有 `Node`。
- 排序：`priority → card_index → mount_seq`。
- **技能只返回事件/修正**，不直接写 `hp` / `atk` / 速度。
- 第一切片先**同步派发**，不引入完整事件队列/时间线；等表现时间线落地再换队列，
  技能侧契约不变。

### 11.3 `game_flow` 接缝

| 位置 | 变更 |
| --- | --- |
| `_on_piece_bumped` | 先发 `collision_fact`（去重后），再判断伤害资格；#5 听事实层 |
| `_apply_damage_to` | 先问 `runtime.modify_damage(intent)`（#3/#5），再落血；`hp == 0` 时把伤害加到**攻击方归属方**的 `owner_attack_power`；造成失能那一下超出部分丢弃 |
| `_end_freeze` | 保持现有解冻/结算节奏；技能激活/结算按 35-skill 的顺序接入 |
| `_enter(TURN_END)` + 敌方回合结束 | 先结算回合结束技能，**最后**双方各自结算 `owner_attack_power`；同时归零 = 平局 |
| `play_card` / `load_card` | 手动激活 / 挂载技能；第一切片先加一个调试入口 |
| `player.gd` | `mounted_skills` 列表 + 稳定宿主 id；全局技能重排时复用 `reset_to_home` |

> **敌方回合结束钩子**是第一切片的一部分：当前 `ENEMY_TURN` 直接回 `TURN_START`，
> 若不补这个钩子，「每回合末」会漏掉敌方回合。

### 11.4 第一切片行为

- **#1**：手动激活 → 改 `atk` / `hp` → `skill_triggered` + `stat_changed` 事件。
- **#3**：碰撞伤害意图 → 总伤害钳到 1 → `damage_modified`；失能后关闭。
- **#5**：敌方棋子碰撞事实 +1 层；3 层后护盾待发；下一次伤害意图取消 →
  `damage_prevented`；层数清零。
- **归属方攻击力**：敌方打失能角色的伤害计入攻击方 `owner_attack_power`；
  `TURN_END` 最后双方各自把攻击力打到对方，随后清零。
- **日志**：`BattleLog` 收集事件；headless 断言事件序列与 HP。

### 11.5 明确不做

- 完整事件队列 / 表现时间线：先同步派发。
- #2（碰撞后停止）、#4（延迟治疗）、#6（乱斗）。
- 隐藏技能 / 战争迷雾：棋盘全可见，只有手牌隐藏。
- 复活 / 全局技能特殊类。
- 完整的卡牌系统：只用 `load_card` / `play_card` 的调试入口挂载/激活。

### 11.6 测试

- `--headless --fixed-fps 60` 探针：
  - #1 数值与事件；
  - #3 伤害钳制、失能后关闭；
  - #5 三层、待发、免疫、清零；
  - 失能伤害 → 攻击方 `owner_attack_power`；造成失能那一下不计入；
  - `TURN_END` 双方各打各的；10 vs 4 → 敌方 -10、我方 -4；同时归零 = 平局；
  - 攻击力清零；敌方回合结束也结算。
- 改 `scripts/` 后跑 `bash tools/verify.sh`。

### 11.7 第一切片先用的默认口径

- **#3**：只钳碰撞伤害，不钳 ZOC（当前默认）。
- **#5**：只统计与敌方棋子的碰撞，墙壁/友方不充能（当前默认）。
- **#1**：增益持续到对局结束；加 `max_hp` 时同步加当前 `hp`（当前默认）。
- 这三条都是内容参数，不阻塞契约与运行时；实测后可再调。

## 12. 修订记录

| 日期 | 变更 | 原因 |
| --- | --- | --- |
| 2026-11-02 | 初版：契约、碰撞管线、无溢出、失能取消、周期调度、全局技能特殊类、接缝与风险 | 用户与 Agent 的技能机制讨论；六个标杆技能作为能力阶梯 |
| 2026-11-02（补充） | 把「无溢出」改为**失能伤害延迟池**：owner 级累计、`TURN_END` 汇总扣血；失能角色仍可被碰撞/围攻、不提供 ZOC；补敌方回合结束钩子与池的测试/风险 | 用户澄清：失能期间的伤害每回合末汇总给归属方，不是丢弃，也不是只由技能扣 |
| 2026-11-02（最终口径） | 改为**归属方头像攻击力**：对敌方失能角色的伤害记入**攻击方归属方**的一次性攻击力；`TURN_END` 双方各自把攻击力打到对方归属方，**各打各的、不抵消**，随后清零 | 用户明确攻击力归攻击方头像；10 vs 4 → 敌方 -10、我方 -4 |
| 2026-11-02（定稿补充） | 攻击力只是结算形式/表演；归属方结算放在 `TURN_END` 的**最后**；同时归零 = 平局；失能 = 赛点；棋盘可见、只有手牌不可见 | 用户确认四条收口规则 |
| 2026-11-02（实现架构） | 补第一切片：文件落点、`Skill`/`GameEvent` 契约、`game_flow` 接缝、#1/#3/#5、归属方攻击力累积与双方 `TURN_END` 结算；明确不做 #2/#4/#6 | 让契约先落代码，而不是继续加规则 |
| 2026-11-12 | 补 `SkillInstance.origin`（`innate` / `card` / `summon`）：角色固有特性在开战时以 `origin = innate` 挂载，复用同一套技能契约 | 角色池/构筑专题与技能系统对齐 |
