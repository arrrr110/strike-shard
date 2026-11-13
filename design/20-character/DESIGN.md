# 角色机制 技术方案

> 模块：`20-character` ｜ 状态：编写中 ｜ 创建/最近修订：2026-11-12
> 需求见 [PRD.md](PRD.md) ｜ 本阶段计划见 [PLAN.md](PLAN.md)
> 技能接入见 [35-skill/DESIGN](../35-skill/DESIGN.md)
>
> **代码状态：本文的 `CharacterDef` / `CharacterPool` / `RosterDef` / `BattleSetup`
> 全部【未实现】。** 现有代码只有 `scripts/player.gd` 的棋子属性与 `main.tscn` 里
> 写死的六枚实例。本文描述的是目标形态，不是现状。

## 0. 结论先说

现有架构 **能承载“基础属性”，不能承载“角色差异化”**：

- `scripts/player.gd` 事实上已经是**棋子行为基类**：玩家与敌人共用同一个脚本，
  `atk` / `max_hp` / `zoc_radius` / `role_type` / `kind` / `owner_id` 都在它身上。
  所以“基础属性抽象到父类”这件事，**已经做了一半**，缺的是内容层与装载层。
- 但“角色是谁”目前等于“场景里的哪个实例”：
  形象是 `player.tscn` 里的一套 SpriteFrames 全盘共用；阵容是 `main.tscn` 里
  写死的 `Player1-3` / `Mob-Mob3`；特性只存在于文档的 `mounted_skills` 字段里。
  **加第 4 个角色 = 复制场景 / 改贴图 / 改主场景摆位**，不可扩展。

本专题要补的不是“每个角色一个 GDScript 子类”，而是**内容定义层**：

```
CharacterDef（这个角色是什么）
   + CharacterPool（池子里有谁）
   + RosterDef（这一局双方各上哪三个）
   + BattleSetup（装载、校验、贴到棋子槽位）
```

**行为父类继续由棋子脚本承担；角色差异用数据表达；独有机制用技能/特性表达。**
理由见第 2 节。

## 1. 现状盘点（代码事实）

| 事实 | 位置 | 对差异化的影响 |
| --- | --- | --- |
| 六枚棋子共用 `player.gd`；`mob.tscn` 也挂同一脚本，只覆盖 `owner_id = 1` | [player.gd](../../scripts/player.gd)、[mob.tscn](../../sences/mob.tscn) | 共享行为已经统一；缺的是“角色内容” |
| 基础属性是导出变量：`atk=10`、`max_hp=70`、`zoc_radius=60`、`role_type`、`kind` | [player.gd:13-45](../../scripts/player.gd#L13-L45) | 可以逐实例覆盖，但**没有集中定义**，也没有角色 id |
| 形象写死在 `player.tscn` 的 `SpriteFrames`；三枚玩家棋子共用同一套动画 | [player.tscn:159-306](../../sences/player.tscn#L159-L306) | 四个角色不能有不同的静态图/攻击图 |
| `mob.tscn` 只带一张静态贴图，缺 `idle/walk/attack/be_hit/zoc` 五个动画 | [mob.tscn:12-38](../../sences/mob.tscn#L12-L38) | 敌方角色也无法差异化；运行时会刷“缺动画”警告 |
| 双方各三枚棋子写死在主场景里 | [main.tscn:94-114](../../sences/main.tscn#L94-L114) | “从 4 个里选 3 个”无处表达 |
| `_ready()` 把 `atk` 等存成开局快照；`reset_to_home()` 用快照恢复 | [player.gd:176-223](../../scripts/player.gd#L176-L223) | **装载顺序陷阱**：定义若在 `_ready` 之后才贴，重置会退回旧值 |
| `_update_sprite_tilt()` 每帧用缓存的 `sprite_base_position` / `sprite_base_rotation` 覆写贴图 transform | [player.gd:740-758](../../scripts/player.gd#L740-L758) | **视觉偏移陷阱**：直接改一次 `sprite.position` 会被下一帧覆盖 |
| 碰撞冻结与 ZOC 的时长从 `SpriteFrames` 现算（`anim_duration`） | [player.gd:317-339](../../scripts/player.gd#L317-L339) | 静态图角色必须显式保证动画名与时长，否则节奏会意外变化 |
| `aura.gdshader` **直接覆写 `COLOR`**，`modulate` / `self_modulate` 会被忽略 | [aura.gdshader](../../shaders/aura.gdshader) | 受击闪白、队伍染色不能靠 `modulate`，要加 shader uniform 或独立特效节点 |
| `mounted_skills` 只在 PRD 的属性契约里出现，代码里没有这个字段 | [PRD.md](PRD.md) 的「属性契约」 | 特性目前不可挂载、不可执行 |

### 1.1 三个必须提前知道的陷阱

1. **开局快照顺序。** `player.gd` 在 `_ready()` 里存 `home_atk`，`reset_to_home()` 用它恢复。
   如果 `BattleSetup` 在棋子 `_ready()` 之后才贴角色定义，第一次重置就会把攻击力退回场景默认值。
   解决：贴定义时**重新采样基础属性**，或者让 `reset_to_home()` 从 `CharacterDef` 重新取值。
   本方案选后者——**定义是基础属性的唯一真相**。
2. **贴图基座每帧被覆写。** `_update_sprite_tilt()` 每帧写 `sprite.position` / `sprite.rotation`，
   来源是 `@onready` 时缓存的 `sprite_base_position` / `sprite_base_rotation`。
   逐角色的视觉偏移/旋转必须改这两个缓存值，不能只改一次节点当前值。
3. **动画名缺席不是“没表现”，是“表现卡在上一帧”。** `_play_anim()` 缺动画时只警告一次并
   直接 `return`，当前帧不会被切走。静态图角色若只配了 `idle` 和 `attack`，
   打完进入 `walk`/`be_hit` 时可能停在攻击帧。解决：每个角色的 SpriteFrames
   **必须凑齐五个动画名**（可以是一帧静态图），再加一层 `idle` 兜底。

## 2. 为什么不建议“每个角色一个子类”

用户说的“角色作为父类”，在 Godot 里有两种落法。本方案选第二种：

| 方案 | 新增第 5 个角色要改什么 | 构筑页怎么枚举 | 跨角色改动（加受击闪白/新特效） | 联机/回放快照 |
| --- | --- | --- | --- | --- |
| 每角色一个 GDScript 子类 | 新建 `.gd` + `.tscn` + 注册引用 | 需要额外维护一张“角色类注册表” | 每个子类各改一遍，或抽一个基类方法 | 需要给每个子类写序列化 |
| **`CharacterDef` 数据 + 棋子行为基类** | **新建一个 `.tres` + 美术 + 特性 id** | **池子本身就是可枚举数组** | **改一处**（棋子基类/表现层） | **定义是纯数据，天然可快照** |

这不是“不要继承”，而是把继承用对地方：

- **行为父类**：`player.gd`（将来可改名 `piece.gd`）。管物理、蓄力、碰撞上报、
  动画状态机、重置——所有角色共享。
- **内容定义**：`CharacterDef`（`Resource`）。管 id、名字、基础属性、形象、
  打击表现、固有特性 id。每个角色一份 `.tres`。
- **独有机制**：特性/技能类（`Skill`，见 [35-skill](../35-skill/DESIGN.md)）。
  不是 `class ZhangFei extends Piece`，而是 `CharacterDef.innate_trait_ids = ["..."]`。

**判断标准**：如果新角色只需要“不同的数、不同的图、不同的特性组合”，就只加 `.tres`；
如果它需要“引擎层面不同的控制方式”（例如完全不同的发射规则），才考虑新的行为脚本，
而且优先做成可插拔的 trait/strategy，而不是复制一份棋子脚本。

## 3. 数据契约 v0

### 3.1 `CharacterDef`（角色定义）

不可变内容，一份 `.tres` 对应一个角色。建议落点：`scripts/character/character_def.gd`。

```gdscript
class_name CharacterDef
extends Resource

## 稳定 id：存档、联机、构筑页、特性注册表都用它，不用节点名/文件名
@export var id: StringName = &""
@export var display_name: String = ""
## 构筑页/角色说明用；棋盘上不显示
@export_multiline var description: String = ""

@export_group("基础属性")
## 枚举的单一出处：player.gd 的 role_type 改为引用 CharacterDef.RoleType。
## 同序：NONE / PROTECTOR / FIGHTER / CASTER，与现有 .tscn 的整数值兼容。
enum RoleType { NONE, PROTECTOR, FIGHTER, CASTER }
@export var role_type: RoleType = RoleType.FIGHTER
@export var atk: int = 10
@export var max_hp: int = 70
@export var zoc_radius: float = 60.0
## 内容层定序键；当前未接入技能系统，先留字段
@export var card_index: int = 0

@export_group("形象")
## 必须包含 idle / walk / attack / be_hit / zoc 五个动画名。
## 本阶段 idle/walk/be_hit/zoc 用一帧静态图，attack 用攻击精灵图。
## **为空时整组形象字段都不覆盖场景默认**——切片 B 可以只填数值，先不接美术。
@export var sprite_frames: SpriteFrames
## 构筑页/头像用；棋盘上暂不显示
@export var portrait: Texture2D
@export var visual_scale: Vector2 = Vector2(0.3, 0.3)
@export var visual_offset: Vector2 = Vector2(0, 2)
@export var visual_rotation_deg: float = 0.0
@export var flip_to_facing: bool = true
## 静态图移动时的程序化上下浮动（px / Hz）；0 = 关。只影响表现，不影响物理。
@export var walk_bob_px: float = 2.0
@export var walk_bob_hz: float = 4.0
## 一次性动画的视觉停留（秒）。默认值与棋子现有导出值一致；
## 换更长的攻击图时，attack_hold_sec 要 ≥ 动画长度，否则会被切回 idle。
@export var attack_hold_sec: float = 0.8
@export var hit_hold_sec: float = 0.4
@export var zoc_hold_sec: float = 1.4

@export_group("打击表现")
## 世界坐标特效场景；为空时只有动画，不报错
@export var attack_effect: PackedScene
@export var hit_effect: PackedScene
@export var attack_sfx: AudioStream
@export var hit_sfx: AudioStream

@export_group("特性（设计储备）")
## 固有特性的技能 id；运行时由 SkillRuntime 以 origin = innate 挂载。
## 本阶段只声明，不执行——执行随 35-skill 第一切片落地。
@export var innate_trait_ids: Array[StringName] = []
```

**枚举归属**：`RoleType` 上移到 `CharacterDef`，`player.gd` 删掉自己那份、改为引用
`CharacterDef.RoleType`——否则“护卫/斗士/施法者”会有两个同序枚举，改一个漏一个。
`Kind`（角色/召唤物）留在棋子层：它描述的是物理实体的寿命，不是角色内容。

**形象字段先平铺**：当前只有一套外貌，平铺在 `CharacterDef` 里最省事。
如果以后要支持多套皮肤/换装，再抽成 `CharacterVisual` 子资源；
现在不预造这层空壳（YAGNI，见 [TODO](../TODO.md) 的用法说明）。

**`CharacterDef` 是只读内容，不得存运行时状态**：`hp` / 计数器 / 冷却 / 待发标记
都不放这里。Godot 的 `Resource` 默认跨实例共享，两个角色引用同一个 `.tres` 时
会把状态互相污染（35-skill 的 `SkillDef` 也踩过同一条）。运行时状态住在棋子上，
或将来住在 `SkillInstance` 上。

**边界：`CharacterDef` 不放物理常量。** `max_charge` / `decel` / `body_radius` /
`bounce` / `mass` 暂时留在棋子脚本或场景上，所有角色共享。原因：

- 本作的核心手感是“台球”，发射预算（`max_charge²/(2·decel)`）与棋盘尺寸绑定；
  逐角色改这些会立刻改变 bot 的“满蓄力一定够得着”假设（见 `enemy_bot.gd` 的注释）。
- 如果将来某角色的特性要改这些，走技能/特性系统显式登记，而不是悄悄多一个导出字段。

同理，`pick_radius`、碰撞半径、质量暂时统一。**视觉大小 ≠ 物理大小**：
`RigidBody2D.scale` 不改物理（已实测，见 [constraints](../00-overview/constraints.md)），
所以放大只改 `AnimatedSprite2D.scale`，碰撞圆仍是 16 px。若要让大角色更“好点中”，
再单独评估 `pick_radius`，不要顺手改碰撞体。

### 3.2 `CharacterPool`（角色池）

建议落点：`scripts/character/character_pool.gd`。

```gdscript
class_name CharacterPool
extends Resource

@export var characters: Array[CharacterDef] = []

func get_by_id(id: StringName) -> CharacterDef: ...
func all_ids() -> Array[StringName]: ...
```

池子负责“有哪些角色”，不负责“这局上谁”。构筑页将来直接枚举这个数组。
当前池子 4 个；以后是否按阵营拆成多个池，等敌方构筑需求出现再定。
**池子内 `id` 必须唯一**——重复时构建 id 字典要报错，不能让后一个静默覆盖前一个。

**为什么不用目录扫描**：`res://data/characters/` 下还会有 `visuals/`、临时文件，
导出版本的文件包含与遍历顺序也要额外处理；显式池子资源没有这些歧义，
也方便构筑页按顺序展示。新增角色 = 新建一份 `.tres` + 加进池子。

### 3.3 `RosterDef`（本局阵容）

建议落点：`scripts/character/roster_def.gd`。

```gdscript
class_name RosterDef
extends Resource

@export var player_ids: Array[StringName] = []   # 我方三人
@export var enemy_ids: Array[StringName] = []    # 敌方三人
```

规则：

- 每边**恰好 3 个**；id 必须能在池子里找到；同一边**不允许重复**。
- **数组顺序 = 槽位顺序**：`player_ids[i]` 贴到 `slot_index == i` 的我方棋子；
  敌方同理。构筑页的拖拽顺序直接对应开局站位。
- 当前调试用 `data/rosters/debug_roster.tres` 固定选 3 个；第 4 个在池子里但不登场。
- 构筑页未开发，**`RosterDef` 就是它将来要写的数据**；不需要另造一套存档格式。
- 技能生成的临时角色**不进** `RosterDef`。`RosterDef` 只定义开局三枚；
  临时角色走召唤物/技能的生成路径（本阶段不做，见 PRD「召唤物」）。

### 3.4 为什么用 `.tres` 而不是 JSON

- `CharacterDef` 要引用 `SpriteFrames` / `PackedScene` / `AudioStream`，`.tres` 是**类型安全**的
  资源引用；JSON 只能存路径字符串，加载时还要自己校验。
- 用户可以在 Godot 检视面板里直接改，不用另做一套编辑器。
- 纯文本、可 diff、可进 git。
- 只有“外部工具必须读写”时才考虑 JSON；当前没有这个需求。

## 4. 装载与初始化

### 4.1 站位不变，定义后贴（本阶段方案）

`main.tscn` 里已经摆好了六枚棋子的位置，且 `player.tscn` 带瞄准弩机、`mob.tscn` 不带。
本阶段**不改成运行时生成**，而是：

1. 六枚棋子仍然作为“槽位”留在场景里，各自加一个 `@export var slot_index: int`。
2. `BattleSetup` 节点读取 `CharacterPool` + `RosterDef`，按
   `(owner_id, slot_index)` 排序，把第 i 个定义贴到第 i 枚棋子上。
   **只处理 `kind == CHARACTER` 且 `slot_index` 在 0–2 的棋子**——召唤物不参与开局编成。
3. 棋子的 `_ready()` 之后、`GameFlow._ready()` 之前完成（`BattleSetup` 放在
   `StaticBody2D` 之后、`GameFlow` 之前即可；即使顺序变了，物理也要下一帧才跑，
   只要 `BattleSetup` 在任意 `_ready` 里完成贴定义，就不会丢帧）。

**为什么不现在改成“从场景生成”**：

- 槽位方案保留了用户在编辑器里摆好的位置与弩机装配，改动最小；
- 运行时生成的真正需求来自**召唤物**（棋子名单会在对局中变化）和**构筑页**，
  那时再统一“生成/销毁/登记”的路径更合适（见 [TODO](../TODO.md) 第 2 条）。
- 槽位方案同样能验证“换阵容不改场景”这个核心目标；生成方案只是它的下一步。

**什么时候必须切换**：技能开始生成临时角色、或构筑页要在开局前动态生成三枚棋子时。
届时 `CharacterDef` 可以加一个 `piece_scene: PackedScene` 字段，`BattleSetup`
从“贴定义到槽位”改成“按定义实例化到槽位 Marker2D”。数据契约不需要重写。

### 4.2 初始化顺序（关键）

```
场景实例化
  → 各棋子 _ready()：登记 pieces 组、存 home_position、hp=max_hp
  → BattleSetup._ready()：读池子/阵容、校验、逐槽 apply_character_def()
       ├─ 写 atk / max_hp / zoc_radius / role_type / 形象 / 表现
       ├─ **重新采样基础属性**（或让 reset_to_home 直接从 def 取）
       └─ 强制下一帧重播 idle
  → GameFlow._ready()：扫描 pieces 组、进入 TURN_START
```

`apply_character_def(def)` 必须做四件事：

1. **应用基础属性**：`atk` / `max_hp` / `zoc_radius` / `role_type`，并令 `hp = max_hp`
   （否则初始血量会停在旧 `max_hp`）。同时刷新 `home_atk` / `home_max_hp` 之类兜底值。
2. **应用形象**：`sprite_frames` / `visual_scale` / `visual_offset` / `visual_rotation_deg` /
   `flip_to_facing` / `walk_bob_px` / `walk_bob_hz`。**`sprite_frames` 为空时整组形象字段都不覆盖场景默认**——切片 B 先只验证数据层，
   形象字段可以留空；切片 C 才要求每个角色都有完整视觉定义。
3. **更新视觉基座**：`sprite_base_position` / `sprite_base_rotation`（不是只改当前
   `sprite.position`），并把 `_anim_current = -1`，让下一帧重播 `idle`。
4. **让 `reset_to_home()` 能从 `character_def` 重新取基础属性**，而不是只依赖 `home_atk`。
   `home_atk` 保留给没有定义的探针/旧场景作兜底。

### 4.3 校验规则

`BattleSetup.validate_roster(pool, roster) -> PackedStringArray` 做纯函数校验，
返回人类可读的错误列表：

- 每边不是 3 个；
- 池子里 `id` 重复；
- 同一边 `player_ids` / `enemy_ids` 内部重复；
- id 不在池子里；
- 槽位数量与阵容数量不一致（场景里少摆/多摆了一枚）；
- 同一方的 `slot_index` 重复（两枚棋子都填 0）；
- 出现 `slot_index < 0` 或 `>= 3` 的角色棋子（召唤物不算）。

失败时 **`push_error` + 保持场景默认值**，不要“自动取池子前三个”静默兜底——
那会让“我明明换了阵容却没生效”变成无法排查的问题。探针会断言错误路径。
**先整体校验、全部通过后再逐槽 apply**；不要边校验边写，失败时棋盘会处于半装载状态。

**空数据是合法的**：`pool` 或 `roster` 没配时，`BattleSetup` 不装载、只
`push_warning`，让单独加载 `player.tscn` 的探针和没有数据层的旧场景继续跑。
“没配”与“配错了”要分开：前者是兼容路径，后者必须报错。

## 5. 视觉契约：静态图 + 攻击精灵图 + 动效

### 5.1 五个动画名怎么落

棋子的 `Anim` 枚举固定是 `IDLE / WALK / ATTACK / BE_HIT / ZOC`，
`ANIM_NAMES` 把名字映射到 SpriteFrames。每个角色的 SpriteFrames **必须凑齐五个名字**：

| 动画名 | 本阶段来源 | 说明 |
| --- | --- | --- |
| `idle` | **静态图**，1 帧，循环 | 角色站立形象 |
| `walk` | **静态图**，1 帧，循环 | 可叠加程序化上下浮动/倾斜，不等于必须有行走精灵图 |
| `attack` | **攻击精灵图**，N 帧，非循环 | 唯一的逐帧角色动画；冻结时长由它现算 |
| `be_hit` | **静态图**，1 帧 | 受击表现靠闪白/抖动/特效，不靠帧 |
| `zoc` | **静态图**，1 帧 | ZOC 检查表现靠环/特效；时长走 `zoc_windup_sec()` 的兜底 |

再加一层防御：`_play_anim()` 找不到目标动画时，**回退到 `idle`**，而不是停在上一帧。
这样即使某个角色的 SpriteFrames 漏配，也只会“看起来没变化”，不会出现“打完一直举着刀”。

`SpriteFrames` 可以安全共享：帧序列是只读的，当前帧/播放进度在 `AnimatedSprite2D`
节点上。所以同一个角色出现在双方时，共用同一个 `SpriteFrames` 资源没有问题。

### 5.2 程序化动效（不引入精灵图的部分）

- **移动**：`_update_sprite_tilt()` 已经在做“抵消刚体自转 + 按角速度倾斜 + 朝向翻转”。
  可以再加一个很小的正弦上下浮动（`walk_bob_px` / `walk_bob_hz`），让静态图在滚动时有生命感。
  这属于表现，不影响物理。
- **受击**：`aura.gdshader` 直接覆写 `COLOR`，`modulate` 无效。三种做法：
  1. 给 shader 加 `uniform float flash`，`COLOR.rgb = mix(COLOR.rgb, vec3(1.0), flash)`，
     由 `play_be_hit()` 驱动一个短 Tween；
  2. 在棋子上叠一个同贴图的 `Sprite2D` 做闪白层；
  3. 用独立的受击特效场景（`hit_effect`），不碰 shader。
  **推荐 1 或 3**；不要用 `modulate`，会被 shader 吃掉。
  `reset_to_home()` / 重置时必须把 `flash` 归零、停掉/释放正在播的特效，
  否则重置后角色会一直亮着或残留上一局的特效。
- **攻击特效**：`play_attack(target)` 已经拿到目标，可以在接触点生成 `attack_effect`，
  并播 `attack_sfx`。**受击特效第一版只播在自身位置**（`play_be_hit()` 拿不到来源方向）；
  定向特效等表现时间线/事件携带来源后再做，**不要为了它改规则层的调用签名**。
  ⚠️ 特效节点**不要直接挂在棋子下面**：棋子是刚体、会自转，特效会跟着转。
  加成 `top_level = true`，或挂到棋盘/世界节点，用全局坐标定位（和 `hp_overlay` 同样的理由）。
- **ZOC**：`play_zoc()` 目前只切动画。可以先叠一个环/光效；正式表现等
  [表现时间线](../50-presentation/timeline-and-markers.md) 落地。

> **渲染后端限制**：本机是 `gl_compatibility`（见 [全局约束](../00-overview/constraints.md)）。
> 角色特效优先用序列帧 `AnimatedSprite2D` 或 `CPUParticles2D`；
> 不要在角色特效里引入只在 Forward+/Mobile 可用的计算管线——本机建不出来。

### 5.3 视觉尺寸、锚点与描边

- **物理尺寸不变**：碰撞圆仍是 16 px；`AnimatedSprite2D.scale` 只改视觉。
  大角色不会更难被撞、也不会更容易卡住。
- **锚点**：静态图默认居中（`centered = true`）。如果立绘是“脚底锚点”，
  用 `visual_offset` 把脚底对到棋子中心下方；不要改碰撞体。
- **描边厚度**：`aura_width` 的单位是贴图像素，屏上厚度 = `aura_width × sprite.scale`。
  四个角色如果 scale 不同，同样的 `aura_width_selected` 会看起来粗细不一；
  而且不同角色图集的分辨率不同，同样的 texel 宽度也会不一样。**尽量统一图集分辨率**，
  要么按 scale / 贴图尺寸反算宽度。
- **导入设置**：贴图的 **Premultiply Alpha 必须关闭**（`aura.gdshader` 会再乘一次 alpha）；
  攻击图集的帧尺寸/边距要一致，SpriteFrames 的 pivot 要对齐。

### 5.4 时长与节奏

`attack_windup_sec()` 从攻击动画的“帧数 ÷ speed”现算，所以**每个角色的碰撞冻结时长会不同**。
这是特性也是风险：

- 攻击图 12 帧 @ 12 fps = 1.0 秒，与现在的占位手感一致；
- 攻击图 6 帧 @ 12 fps = 0.5 秒，这一角色的碰撞冻结会缩短一半；
- 如果不想让节奏跟美术绑定，给 `CharacterDef` 加 `attack_windup_override`，
  但这会制造“动画时长”和“冻结时长”两个真相，默认不这么做。

⚠️ **棋子上还有一个 `attack_hold_sec`（视觉停留，默认 0.8 秒）**，它和冻结时长是两个值：
`_set_anim(ATTACK, attack_hold_sec)` 到点后会把动画切回 `idle`/`walk`。当前的攻击图是
12 帧 @ 12 fps = 1.0 秒，而 `attack_hold_sec = 0.8`，所以最后 0.2 秒其实已经被切掉了。
逐角色换更长的攻击图时，**这个值也要跟着调到 ≥ 动画长度**，否则“冻结还在、刀已经收了”。
`CharacterDef` 里带 `attack_hold_sec` / `hit_hold_sec` / `zoc_hold_sec`，
`apply_character_def()` 一并应用；默认值与棋子现有值一致，避免切片 B 改变旧手感。

`zoc_windup_sec()` 取 `zoc` 动画长度，缺动画时兜底 0.35 秒。一帧静态图的 `zoc`
只有 0.2 秒（1 帧 @ 5 fps），会落到 0.35 秒兜底；要更长的检查拍，就在 SpriteFrames
里把 `zoc` 做成 2 帧，或后续给定义加显式时长。**不要在代码里再写死一套常量。**

## 6. 特性（Traits）契约

**固有特性 = 以 `origin = innate` 挂载的技能。不另造一套 trait 运行时。**

- `CharacterDef.innate_trait_ids` 里放技能 id；开战时 `BattleSetup` / `SkillRuntime`
  把这些技能挂到宿主上，并标记来源 `innate`。
- **定义里的是只读来源**：运行时只在棋子/`SkillRuntime` 上维护 `mounted_skills`，
  不要把可变列表写回 `CharacterDef`。否则同一份技能列表会有两个真相。
- 卡牌授予的技能标记 `origin = card`；召唤物自带的标记 `origin = summon`。
  同一个 `Skill` 契约、同一个排序键、同一个 EffectResolver。
- 本阶段**只声明、不执行**。理由：35-skill 的第一切片还没落地，
  现在写一套“角色特性钩子”会和技能系统形成两个真相来源，
  将来必然要合并（见 [35-skill/DESIGN](../35-skill/DESIGN.md) 第 11 节）。
- **实例身份**：`CharacterDef.id` 回答“是哪个角色”，不能单独当技能系统的 `host_id`
  ——同一个角色可能在双方各出现一次。开局棋子的稳定实例 id 至少需要
  `(owner_id, slot_index)`；召唤物以后要有自己的生成序号。技能状态不要存 `Node` 引用。

四个角色的特性可以先按能力面占位（**不是最终内容**）：

| 角色槽位 | 想验证的能力面 | 可复用的标杆技能 |
| --- | --- | --- |
| A | 高攻低血、短攻击图 | 纯数值，不用技能 |
| B | 高血高 ZOC、防御型 | #3 受击只掉 1 |
| C | 碰撞后停止/位移控制 | #2 碰撞后停止 |
| D | 充能/护盾/回合开始类 | #5 能量护盾或 #4 延迟治疗 |

这张表只用于验证数据层能装下不同特性的声明；**真正的特性执行随 35-skill 第一切片**。

## 7. 与其它模块的接缝

| 模块 | 本专题要不要改 | 说明 |
| --- | --- | --- |
| `10-turn` | **不改** | 阶段机不关心角色身份；棋子仍从 `pieces` 组进出 |
| `turn_controller` | **不改** | 选择按 `owner_id` 过滤；角色差异不影响归属 |
| `game_flow` 碰撞/ZOC | **不改** | 只读 `piece.atk` / `hp` / `zoc_radius`；数值来自定义 |
| `enemy_bot` | **不改** | 读 `hp` / 位置 / `max_charge`；属性差异自然影响决策。若将来逐角色改物理常量，要重算“满蓄力一定够得着” |
| `30-card` | **预留 join key** | 卡组按 `CharacterDef.id` 绑定；本阶段不建 `card_pool_ids`，等 30-card 定稿再定形状 |
| `35-skill` | **只加来源标记** | 固有特性以 `origin = innate` 挂载；不是第二套系统 |
| `50-presentation` | **临时直连** | 攻击/受击特效先挂在棋子的 `play_attack` / `play_be_hit`；时间线落地后迁到 `hit` 标记 |

## 8. 风险与坑

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| 定义贴在开局快照之后 | 高：重置退回旧属性 | 贴定义时重采样；或 `reset_to_home` 从 def 取基础属性；探针断言 |
| 属性有两个真相（场景覆盖 + 定义） | 高：改定义不生效 | 切片 B 起把 `main.tscn` 里的 `atk/max_hp/zoc_radius/role_type` 覆盖删掉；探针断言 `piece.atk == def.atk` |
| 静态图角色缺动画名 | 中：表现停在上一帧、时长异常 | 五动画名强制齐全 + `_play_anim` 回退 idle；探针检查 `has_animation` |
| 视觉偏移被 `_update_sprite_tilt` 覆盖 | 中：角色偏移每帧被抹掉 | 改 `sprite_base_position/rotation`，不要只改当前值 |
| `modulate` 被 aura shader 吃掉 | 中：受击闪白不生效 | 用 shader `flash` uniform 或独立特效节点 |
| 视觉大小与物理大小不一致 | 中：看起来大、实际碰撞小 | 明确只改 `AnimatedSprite2D.scale`；调试画碰撞圆 |
| 攻击图帧数改变冻结时长 | 中：角色节奏不一致 | 先统一帧数/帧率；要逐角色调就显式记录为设计参数 |
| 逐角色改物理常量 | 中：bot 的可达性假设失效 | 本阶段不放物理常量；将来走特性显式登记 |
| `.tres` 引用断链/改名 | 低：加载失败 | `id` 稳定、文件名与 id 对齐；校验时点名缺失 id |
| 新增 `class_name` 后探针找不到类型 | 低：看起来像功能没生效 | `verify.sh` 的类注册表扫描要递归到 `scripts/character/`（当前只 `grep scripts/*.gd`）；新增类后跑一次 |

## 9. 熵账本对账（2026-11-12）

- **同一个概念现在有几个出处？**
  - 基础属性：`player.gd` 默认值 + `.tscn` 逐实例覆盖 + 设计文档占位值；
  - 形象：`player.tscn` 的 SpriteFrames（六个实例共用）+ `mob.tscn` 的一张静态图；
  - 阵容：`main.tscn` 的节点顺序/数量。
  本专题把这三样各收敛到一个来源：`CharacterDef` / `SpriteFrames` / `RosterDef`。
- **这次逼出了哪条旧债？** [TODO](../TODO.md) 第 2 条（Player/Mob 名不副实、两个场景重复物理配置）
  被部分逼出：棋子行为基类继续保留，`CharacterDef` 把“内容”从场景里拆走；
  但 `player.tscn` / `mob.tscn` 的装配差异（弩机 vs 无弩机）仍然保留，**不强行合并**。
- **会不会制造新的中间产物？** 会：`CharacterPool` / `RosterDef` / `BattleSetup` 三个新文件。
  它们不是空架构——构筑页、敌方编成、探针都要读同一份数据；没有它们，
  “4 选 3”只能写死在场景里。**这三个是功能逼出来的，保留。**
- **这次新增的债**：
  - `player.tscn` / `mob.tscn` 仍然各有一份物理配置（TODO #2 残留）；
  - 运行时生成棋子的路径还没统一（召唤物时做）；
  - 特性的执行依赖 35-skill 第一切片（已挂账）。
- **不做**：全量“契约/工具类/桥”三桶拆分；那需要事件链/表现时间线支撑，
  当前规模下会得到一堆空文件（见 [10-turn/DESIGN](../10-turn/DESIGN.md) 的教训）。

## 10. 已确认与待定

### 已确认（2026-11-12）

| # | 事项 | 结论 |
| --- | --- | --- |
| C1 | 上场数量 | 双方各 **3 个**，固定；技能临时角色本阶段不考虑 |
| C2 | 角色池 | 初定 **4 个**；我方从池中构筑 3 个；构筑页暂不开发 |
| C3 | 差异化来源 | 形象 + 基础属性 + 固有特性（+ 后期卡组）；三者都由 `CharacterDef` 承载 |
| C4 | 架构 | **数据定义 + 行为基类 + 特性/技能**；不做“每角色一个 GDScript 子类” |
| C5 | 本阶段核心目标 | `CharacterDef` / `CharacterPool` / `RosterDef` / `BattleSetup` + 固定三人调试装载 |
| C6 | 形象方案 | **静态图 + 攻击精灵图 + 程序化动效**；不引入完整 idle/walk 精灵图 |
| C7 | 特性执行时机 | 本阶段只声明 `innate_trait_ids`；执行随 35-skill 第一切片 |
| C8 | 物理常量 | `max_charge` / `decel` / 碰撞半径等暂留棋子层，所有角色共享 |

### 待定

- 四个角色的具体名字、形象、数值、特性（内容层，需要用户定）。
- 敌方三人从哪个池子选、是否允许与我方重复。
- 允许同边重复角色吗？**建议不允许**；等构筑页需要“重复/禁用”规则时再改校验。
- 是否把 `player.gd` 改名为 `piece.gd`、是否合并 `player.tscn` / `mob.tscn`。
  本阶段**不做**，留给召唤物/场景整理时一起做。
- 受击闪白用 shader uniform 还是独立特效节点（实现时按美术资源定）。
- 攻击特效是否要按方向旋转；当前只保证左右翻转。
- 卡组与角色的绑定形状（等 30-card 定稿）。

## 11. 修订记录

| 日期 | 变更 | 原因 |
| --- | --- | --- |
| 2026-11-12 | 初版：现状盘点、数据定义层、装载顺序、视觉契约、特性接缝、风险与熵账本对账 | 用户提出“角色池 / 构筑 / 形象差异化 / 基础属性父类”专题；本轮只做设计与计划，不改代码 |
