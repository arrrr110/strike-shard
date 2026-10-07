## ADDED Requirements

### Requirement: 回合阶段图

回合生命周期 SHALL 建模为一张阶段有向图，节点为 `TURN_START`、`ACTION`、`SELECT`、`CHARGE`、`MOTION`、`HIT_SETTLE`、`ZOC_SETTLE`、`TURN_END`、`ENEMY_TURN`。其中 `ACTION` 是枢纽节点：出牌自环回 `ACTION`，发射经 `SELECT → CHARGE → MOTION → HIT_SETTLE → ZOC_SETTLE` 回到 `ACTION`，结束回合经 `TURN_END → ENEMY_TURN` 回到 `TURN_START`。

#### Scenario: 一个回合走完发射链路

- **WHEN** 玩家在 `ACTION` 点选一枚本方角色并完成蓄力激发，且棋盘最终静止
- **THEN** 阶段依次经过 `SELECT` → `CHARGE` → `MOTION` → `HIT_SETTLE` → `ZOC_SETTLE`，随后回到 `ACTION`

#### Scenario: 出牌不切换阶段

- **WHEN** 玩家在 `ACTION` 阶段打出一张卡片，且该卡的结算与表现均已完成
- **THEN** 阶段机仍停留在 `ACTION`，不推进到 `SELECT`

#### Scenario: 回合可循环

- **WHEN** 阶段机完成 `ENEMY_TURN`
- **THEN** 下一个阶段是 `TURN_START`，且回合计数递增 1

### Requirement: 阶段完成条件轮询推进

阶段机 MUST 在每个物理帧检查当前阶段的完成条件，并在条件成立时推进到下一个阶段；每物理帧至多推进一个阶段。

#### Scenario: 单帧只推进一个阶段

- **WHEN** 当前阶段完成，且下一阶段的完成条件在同一物理帧内也成立
- **THEN** 本物理帧只推进到下一个阶段，不继续向后推进

#### Scenario: 等待型阶段不被跳过

- **WHEN** 阶段机位于 `ACTION`，玩家尚未点选棋子也未点"结束回合"
- **THEN** 阶段机停留在 `ACTION`，不向后推进

#### Scenario: 连续占位阶段逐帧穿过

- **WHEN** 阶段机连续经过两个完成条件恒真的占位阶段
- **THEN** 这两个阶段分别在连续两个物理帧内各推进一次，不出现同一帧内的循环推进

### Requirement: 完成条件包含结算与表现排空

阶段机 MUST 仅在"当前阶段的规则条件成立、事件队列为空、表现时间线已排空"三者同时满足时才推进；表现播放期间 MUST NOT 推进阶段，也 MUST NOT 接受玩家输入。

#### Scenario: 表现播放中不推进阶段

- **WHEN** `MOTION` 阶段全场已静止，但碰撞表现尚未播完
- **THEN** 阶段机停留在 `MOTION`，不推进到 `HIT_SETTLE`

#### Scenario: 表现播放中不接受输入

- **WHEN** 任意阶段正在播放表现
- **THEN** 玩家的鼠标按下与松开不改变选中态、不开始蓄力、不触发任何阶段切换

#### Scenario: 表现排空后立即推进

- **WHEN** 表现时间线进入完成状态，且当前阶段的规则条件早已成立
- **THEN** 阶段机在下一个物理帧推进一条边

### Requirement: 未实现阶段的占位语义

本期不实现的阶段 MUST 以"完成条件恒真"的方式占位，照常发出阶段变更信号，且不得阻断阶段图的推进；后续填充这些阶段的内容时，不得要求改动阶段机本身。

#### Scenario: 占位阶段不阻断流程

- **WHEN** 阶段机进入 `TURN_END`（本期为占位阶段）
- **THEN** 该阶段在下一个物理帧即被判定完成并推进到 `ENEMY_TURN`，无需任何外部输入

#### Scenario: 占位阶段仍发出信号

- **WHEN** 阶段机从 `TURN_END` 推进到 `ENEMY_TURN`
- **THEN** 订阅方收到 `TURN_END` 的退出与 `ENEMY_TURN` 的进入通知，与实现阶段的行为一致

### Requirement: 阶段变更可观察

阶段机 MUST 在每次阶段切换时发出可订阅的信号，携带切换前后的阶段标识，供 UI 与棋子查询当前操作许可。

#### Scenario: 订阅方收到阶段切换

- **WHEN** 阶段机从 `SELECT` 推进到 `CHARGE`
- **THEN** 订阅方收到一次阶段变更通知，其中切换前阶段为 `SELECT`、切换后阶段为 `CHARGE`

#### Scenario: 棋子按阶段查询操作许可

- **WHEN** 阶段机位于 `ENEMY_TURN`
- **THEN** 任何己方棋子查询操作许可均返回不允许，且棋子不响应鼠标输入

### Requirement: 发射机会每回合仅一次

`ACTION` → `SELECT` → `CHARGE` → `MOTION` SHALL 每回合至多经过一次。发射机会 MUST 表达为阶段图上"发射边"的开关——`TURN_START` 时打开、一次发射后关闭；阶段机 MUST NOT 包含"本回合剩余发射次数"的可变计数器。

#### Scenario: 发射后回到 ACTION 但发射边已关闭

- **WHEN** 一枚角色被激发并走完 `MOTION` → `HIT_SETTLE` → `ZOC_SETTLE`
- **THEN** 阶段机回到 `ACTION`，且本回合内点击任何本方角色都不再进入 `SELECT`

#### Scenario: 返回 ACTION 是为了继续出牌

- **WHEN** 发射流程走完并回到 `ACTION`
- **THEN** 玩家仍可在 `ACTION` 上出牌，直到主动结束回合

#### Scenario: 下回合发射机会恢复

- **WHEN** 阶段机经过 `TURN_END` → `ENEMY_TURN` 回到 `TURN_START`
- **THEN** 发射边重新打开，玩家可再次发射一枚角色

#### Scenario: 结束回合跳过发射流程

- **WHEN** 玩家在 `ACTION` 阶段点击"结束回合"
- **THEN** 阶段机跳过 `SELECT`、`CHARGE`、`MOTION`、`HIT_SETTLE`、`ZOC_SETTLE`，直接进入 `TURN_END`
