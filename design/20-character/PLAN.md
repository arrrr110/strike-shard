# 角色开发专题 开发计划

> 模块：`20-character` ｜ 状态：计划（未开工） ｜ 创建：2026-11-12
> 需求见 [PRD.md](PRD.md) ｜ 技术方案见 [DESIGN.md](DESIGN.md)
>
> 本计划只解决“角色成为可构筑、可扩展的内容单元”。
> **不包含**构筑页面、卡组、技能运行时、召唤物、联机、数值平衡。

## 1. 目标与非目标

### 目标

1. 双方各固定 3 名角色；我方 3 名从 4 人角色池中选（构筑页暂不做，调试用固定配置）。
2. 角色身份、形象、基础属性、固有特性声明由**一份数据定义**决定，不再由场景实例决定。
3. 换任意 3 人组合时，只改数据文件，不改 `.tscn`、不改脚本。
4. 每个角色可以有不同的静态图、攻击精灵图、打击特效与基础数值。
5. 基础属性与共享行为留在棋子基类，角色池扩大时不需要复制脚本。
6. 为后期“可用卡组”和“技能生成临时角色”留出清晰的接缝，但本阶段不实现。

### 非目标（本阶段明确不做）

- 构筑页面 / 选人 UI / 存档。
- 卡牌系统与角色卡组绑定。
- 技能运行时、固有特性的实际执行（只声明 id）。
- 召唤物、临时角色、运行时生成棋子。
- 逐角色修改发射物理（`max_charge` / `decel` / 碰撞半径）。
- 完整 idle/walk 精灵图；本阶段只用“静态图 + 攻击精灵图 + 程序化动效”。
- 角色平衡数值的最终定稿。

## 2. 交付物

### 代码

| 文件 | 作用 | 状态 |
| --- | --- | --- |
| `scripts/character/character_def.gd` | `CharacterDef`：角色定义资源 | 【未实现】 |
| `scripts/character/character_pool.gd` | `CharacterPool`：角色池 | 【未实现】 |
| `scripts/character/roster_def.gd` | `RosterDef`：本局双方阵容 | 【未实现】 |
| `scripts/battle_setup.gd` | 读取池子/阵容、校验、贴到棋子槽位 | 【未实现】 |
| `scripts/player.gd` | 增加 `character_def` / `apply_character_def()`；重置从定义取基础属性 | 改造 |
| `sences/main.tscn` | 加 `BattleSetup`；棋子加 `slot_index` | 改造 |
| `tools/probe/character_probe.gd` | 角色装载/校验/重置的 headless 断言 | 【未实现】 |
| `tools/verify.sh` | 默认回归里加上 `character_probe.gd` | 改造 |

### 数据

| 文件 | 作用 |
| --- | --- |
| `data/characters/*.tres` | 4 份 `CharacterDef`（先占位，内容待定） |
| `data/characters/visuals/*.tres` | 4 份 `SpriteFrames`（静态 idle + 攻击图，切片 C 接入） |
| `data/character_pool.tres` | 4 人角色池 |
| `data/rosters/debug_roster.tres` | 调试阵容：我方 3 人、敌方 3 人 |

> 目录名可以调整，但**数据必须与场景分离**；不要把角色定义塞回 `.tscn` 的导出覆盖里。

## 3. 切片划分

### 切片 A：契约与文档（本次交付，无代码）

**内容**

- 新增 [DESIGN.md](DESIGN.md) 与本文。
- 更新 [PRD.md](PRD.md)：角色池/构筑、3v3、静态图+攻击图、特性接缝、决策表。
- 更新 [design/README.md](../README.md) 的模块状态。
- 更新 [design/TODO.md](../TODO.md) 的熵账本对账。
- 更新 [glossary.md](../00-overview/glossary.md)：角色定义、角色池、构筑、固有特性。

**验收**

- 所有“未实现”的内容都显式标注【未实现】/「设计储备」。
- 决策带日期；被保留的旧结论不删除。
- 与本计划一致的代码落点、数据落点、验收标准写清楚。

### 切片 B：数据层与装载（本专题核心）

**目标**：4 选 3 的组合能通过数据文件切换，棋子属性/名字随之变化，不改场景。

**任务**

1. **新增 `CharacterDef`**
   - 字段按 DESIGN 第 3.1 节；先填 `id` / `display_name` / 基础属性。
   - 形象字段先指向**现有可区分的占位资源**（Tiny Swords / zhangfei 素材即可），
     确保切片 B 就能看到“换人换形象”；正式静态图/攻击图在切片 C 接入。
2. **新增 `CharacterPool` 与 4 份 `.tres`**
   - 4 个占位角色：A/B/C/D，id 稳定（建议英文 slug，如 `guardian` / `duelist` / `caster` / `support`）。
   - 数值先用占位值，但**四个角色至少在一个维度上不同**（atk / hp / zoc / role_type / 占位形象），
     用来验证数据确实被读取。
3. **新增 `RosterDef` 与 `debug_roster.tres`**
   - 我方选 A/B/C，敌方选 D/A/B（或用户指定的组合）。
   - 校验：每边 3 个、不重复、都在池中。
4. **棋子加 `slot_index`**
   - `player.gd` 增加 `@export var slot_index: int = 0`。
   - `main.tscn` 六枚棋子分别填 0/1/2（按 owner 各自编号）。
   - 不改棋子位置、不改碰撞体、不改物理材质。
5. **新增 `BattleSetup`**
   - 放在 `main.tscn` 的 `StaticBody2D` 之后、`GameFlow` 之前。
   - `@export var pool: CharacterPool`、`@export var roster: RosterDef`。
   - `_ready()`：扫描 `pieces` 组 → **只取 `kind == CHARACTER` 且 `slot_index` 0–2 的棋子**
     → 按 `(owner_id, slot_index)` 排序 → 校验 → 逐个 `apply_character_def()`。
   - 暴露 `apply_roster(pool, roster) -> PackedStringArray`，供探针/未来构筑页调用；
     **先整体校验、全部通过后再逐槽 apply**；校验失败返回错误列表并 `push_error`，
     **不静默兜底**、不留半装载棋盘。
   - `pool` / `roster` 为空时视为“没配数据”：不装载、只 `push_warning`，
     保证单独加载 `player.tscn` 的探针和旧场景继续跑。
6. **`player.gd` 改造**
   - 增加 `var character_def: CharacterDef`。
   - `apply_character_def(def)`：写基础属性（并令 `hp = max_hp`）、形象、表现字段；
     **`sprite_frames` 为空时整组形象字段都不覆盖场景默认**；更新
     `sprite_base_position` / `sprite_base_rotation`；把 `_anim_current = -1` 强制重播 idle。
   - `RoleType` 枚举上移到 `CharacterDef`；`player.gd` 改为引用 `CharacterDef.RoleType`，
     不再保留第二份同序枚举；`hp_overlay.gd` 的 `TYPE_NAMES` 注释同步。
   - `reset_to_home()`：优先从 `character_def` 重新取 `atk` / `max_hp` / `zoc_radius` /
     `role_type`，再走现有复位；没有定义时退回 `home_atk`（探针兼容）。
   - `display_name` 可暴露成 `piece.character_name()`，调试 UI 用。
   - 可选：`hp_overlay.gd` 的调试标签第一行加上角色名/id，方便在编辑器里确认
     “换阵容真的生效了”；最终 UI 会替换它。
7. **探针与 verify**
   - ⚠️ `tools/verify.sh` 现在的 `class_name` 扫描只 `grep "$ROOT"/scripts/*.gd`，
     不递归子目录。新增 `scripts/character/*.gd` 后，要把它改成递归扫描
     （`find` 或 globstar），否则临时副本的类注册表不刷新，探针会报
     `Could not find type "CharacterDef"` ——看起来像“功能没生效”。
   - `character_probe.gd` 加载真实 `main.tscn`，断言：
     - 六枚棋子都拿到了定义，`piece.character_def.id` 与阵容一致；
     - `atk/max_hp/zoc_radius/role_type` 与定义一致（不是场景默认值）；
     - 交换 `debug_roster.tres` 的 id 后，同一槽位的属性/名字变化；
     - `reset_match()` 后属性仍等于定义（不是旧快照）；
     - 非法阵容（少人/重复/未知 id/槽位重复）返回错误且不半装载。
   - `verify.sh` 默认同时跑 `mechanism_probe.gd` 与 `character_probe.gd`。
8. **删掉场景里的属性覆盖**
   - `main.tscn` 的棋子实例上不再覆盖 `atk` / `max_hp` / `zoc_radius` / `role_type`；
     这些只来自定义。`owner_id` / `slot_index` 保留在实例上。

**验收**

- 在编辑器里把 `debug_roster.tres` 的我方第三个 id 从 C 换成 D，运行后第三枚棋子的
  名字、数值、占位形象随之变化，未改任何 `.tscn`；切片 C 后换成正式美术。
- 三个槽位能通过数据切换出可区分的形象（哪怕只是占位图），证明形象字段确实被读取。
- `bash tools/verify.sh` 退出码 0，新增断言全过。
- `reset_match()` 后属性与定义一致。
- 非法阵容有明确错误，不出现“只贴了一半”的棋盘。
- 阶段机、碰撞、ZOC、bot 的旧回归全过。

**风险 / 注意**

- `BattleSetup` 的执行顺序：见 DESIGN 第 4.2 节。若把 `BattleSetup` 放到 `GameFlow` 之后，
  物理下一帧才跑，通常仍安全，但**不要依赖这个巧合**；按推荐顺序摆。
- 新增 `class_name` 后第一次跑 verify 会重新扫类注册表（约 5 秒），不是卡死。
- 先不要动 `player.tscn` / `mob.tscn` 的结构；切片 B 只改 `main.tscn` 的节点与字段。

### 切片 C：形象与打击表现

**目标**：四个角色在棋盘上“一眼能认出”，攻击时有辨识度；仍不引入完整精灵图。

**任务**

1. **四份 `SpriteFrames`**
   - 每份包含 `idle` / `walk` / `attack` / `be_hit` / `zoc` 五个名字。
   - `idle` / `walk` / `be_hit` / `zoc` 用一帧静态图；`attack` 用攻击精灵图。
   - 攻击图的帧数/帧率先统一（建议 12 帧 @ 12 fps，与当前占位一致），避免冻结节奏突变。
2. **`CharacterDef` 形象字段接入**
   - `sprite_frames` / `visual_scale` / `visual_offset` / `visual_rotation_deg` / `flip_to_facing`。
   - `walk_bob_px` / `walk_bob_hz` 驱动静态图的移动浮动（0 = 关）。
   - `attack_hold_sec` / `hit_hold_sec` / `zoc_hold_sec` 一并接入；换更长的攻击图时
     `attack_hold_sec` 要 ≥ 动画长度，否则动画会在冻结结束前被切回 idle。
   - `portrait` 先给构筑页/调试用，不在棋盘上显示。
3. **`_play_anim` 兜底**
   - 缺动画时回退 `idle`；保留“只警告一次”的行为。
4. **程序化动效**
   - 移动：静态图 + 轻微上下浮动（可选 `walk_bob_px` / `walk_bob_hz`）。
   - 受击：shader `flash` uniform 或独立 `hit_effect`；**不要用 `modulate`**。
   - 攻击：`attack_effect` 在接触点生成；`attack_sfx` 播放（可选）。
   - **重置**：`reset_to_home()` 要把 flash uniform、正在播的特效/音效清掉，
     否则重置后角色会一直亮着或残留上一局的特效。
   - **渲染后端是 `gl_compatibility`**：特效优先用序列帧 `AnimatedSprite2D` 或
     `CPUParticles2D`，不要在角色特效里引入只在 Forward+/Mobile 可用的计算管线。
5. **调试辅助**
   - 在 `hp_overlay` 或一个新的调试节点上画碰撞圆与视觉包围盒，
     方便用户对齐贴图与 16 px 碰撞体。调试级，最终可删。
6. **资源导入**
   - 贴图 Premultiply Alpha 关闭；帧尺寸/边距/pivot 一致；攻击图默认朝右，靠 `flip_h` 翻转。

**验收**

- 四个角色在棋盘上可区分；`idle` 能循环；碰撞时播放各自的 `attack`；
  打完回到 `idle`/`walk`，不会停在攻击帧。
- `bash tools/verify.sh` 输出里，玩家棋子没有“缺动画”警告。
- 攻击图时长与冻结时长一致（或用户明确接受逐角色差异）。
- 用户在编辑器里确认贴图缩放/偏移/描边厚度可接受。

**风险 / 注意**

- 视觉缩放不改物理；大角色不会更好撞或更难撞。
- 描边厚度随 `AnimatedSprite2D.scale` 变化；四个角色 scale 不同时要单独调 `aura_width`。
- 攻击图是左右单向的；如果画的是正面/斜向，`flip_h` 可能不自然，需要美术侧统一。
- 受击闪白不要用 `modulate`，`aura.gdshader` 会覆写 `COLOR`。

### 切片 D：特性接缝（与 35-skill 合流）

**目标**：四个角色能声明不同的固有特性，并在技能系统第一切片落地时执行。

**任务**

1. `CharacterDef.innate_trait_ids` 填占位 id（每个角色 0–2 个）。
2. 在 35-skill 的 `SkillRuntime.mount()` 契约里加 `origin`（`innate` / `card` / `summon`）；
   固有特性开战挂载，卡牌授予运行时挂载。`host_id` 用 `(owner_id, slot_index)`，
   **不要用 `CharacterDef.id` 单独标识实例**（同一角色可能双方各一个）。
3. 选择 1–2 个标杆技能作为第一批角色特性（建议 #3 受击只掉 1、#5 能量护盾），
   按 35-skill 第一切片实现。
4. 探针断言：固有特性只在开局挂载一次；失能后关闭；卡牌授予的同名技能不重复挂载。

**验收**

- 至少两个角色在数值之外有机制差异，且差异走同一套技能契约。
- 没有第二套“角色特性”运行时；`mounted_skills` / `innate_trait_ids` 不出现两个真相。
- `bash tools/verify.sh` 全过。

**前置条件**

- 35-skill 第一切片（`Skill` / `SkillRuntime` / `SkillContext` / `GameEvent` / #1/#3/#5）
  已经落地。**如果技能系统还没开始，切片 D 不启动**——不要为了角色专题先造一套临时特性钩子。

### 后续（本阶段不做）

- **构筑页**：读 `CharacterPool`，强制 3 人、不重复，写 `RosterDef`；可预览形象/特性/卡组。
- **敌方编成**：从池子选 3 人；是否镜像、是否允许与玩家重复、bot 是否按角色特性调策略。
- **卡组绑定**：以 `CharacterDef.id` 为 join key，等 30-card 定稿。
- **运行时生成**：召唤物/临时角色；届时把 `BattleSetup` 从“贴定义到槽位”升级为
  “按定义实例化到 Marker2D”，并统一 `register_piece` / 销毁路径。

## 4. 验证方案

### 自动验证

```bash
bash tools/verify.sh            # 默认回归：机制 + 角色装载
bash tools/verify.sh --fresh    # 新加美术资源/新 class_name 后跑一次
```

- `character_probe.gd` 必须断言：
  - 阵容 → 棋子属性的映射；
  - 换阵容后的变化；
  - 重置后的属性；
  - 非法阵容的拒绝；
  - 五动画名齐全（切片 C 后）。
- 探针**不依赖棋盘摆法**，不写死具体数值；从 `CharacterDef` 现算期望值。

### 手工验证（用户在编辑器）

- 四个角色的静态图/攻击图缩放、偏移、朝向、描边厚度。
- 攻击动画与碰撞冻结的观感是否匹配。
- 受击闪白/特效强度。
- 换阵容后，三枚棋子的辨识度与站位是否合适。
- 手感类结论以编辑器为准，文档只锁机制。

## 5. 分工

| 事项 | 负责 |
| --- | --- |
| `CharacterDef` / `CharacterPool` / `RosterDef` / `BattleSetup` 脚本 | Agent |
| `.tres` 数据文件（占位） | Agent |
| `player.gd` / `main.tscn` / 探针 / verify.sh 改造 | Agent |
| 四个角色的名字、形象、数值、特性方向 | 用户 |
| 静态图、攻击精灵图、特效素材的导入与切片 | 用户在编辑器 |
| SpriteFrames 的 pivot / 帧序 / 帧率确认 | 用户 |
| 视觉缩放、偏移、描边、打击感 | 用户在编辑器 |
| 构筑页 UI | 后续专题 |

> Agent 只做“简单 `.tscn` / `.tres`”的范围；复杂场景装配与美术导入仍归用户。
> 如果切片 B 需要改 `player.tscn` 结构，先停下来和用户确认，不要擅自重排。

## 6. 待拍板

1. **四个角色是谁？** 名字、id、基础数值、类型（护卫/斗士/施法者）、大致特性方向。
2. **敌方三人怎么选？** 固定同一套、镜像我方、还是从池中另选？
3. **同边允许重复角色吗？** 建议不允许；如果构筑页需要“双张同名”再改。
4. **特性现在做不做？** 建议只声明 id，等 35-skill 第一切片；如果希望本阶段就看到
   机制差异，需要先排技能系统的第一切片，而不是临时写一套。
5. **`player.gd` 要不要顺手改名 `piece.gd`？** 建议本阶段不改，等召唤物/场景整理一起做。
6. **`player.tscn` / `mob.tscn` 要不要合并？** 建议不合并：两者的差异是“有没有瞄准弩机”，
   这是控制装配的差异，不是角色身份；强行合并会把敌人也塞进玩家操作装配。

## 7. 完成标准（本专题的 Definition of Done）

- [ ] `data/` 下有 4 份角色定义、1 份角色池、1 份调试阵容；数据与场景分离。
- [ ] `BattleSetup` 能把任意 3 人阵容贴到双方六枚棋子；非法阵容明确报错。
- [ ] 换阵容只改 `.tres`，不改 `.tscn` / 脚本。
- [ ] `reset_match()` 后基础属性仍等于角色定义。
- [ ] 四个角色有可区分的静态图与攻击图；攻击动画时长与冻结节奏一致或已明确接受差异。
- [ ] 每个角色能声明固有特性 id；执行路径与 35-skill 对齐（切片 D，可后置）。
- [ ] `bash tools/verify.sh` 退出码 0，且新增断言覆盖上述行为。
- [ ] `design/20-character/PRD.md` / `DESIGN.md` / `PLAN.md` 与本计划一致；
      README、TODO、glossary 同步。

## 8. 修订记录

| 日期 | 变更 | 原因 |
| --- | --- | --- |
| 2026-11-12 | 初版：目标/非目标、A–D 切片、文件落点、验收、分工、待拍板 | 用户提出角色池/构筑/形象差异化专题；本轮只做调研与计划 |
