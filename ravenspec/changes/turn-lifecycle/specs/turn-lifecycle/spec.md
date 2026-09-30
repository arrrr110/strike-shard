## ADDED Requirements

### Requirement: 回合阶段序列

回合生命周期 SHALL 建模为一条固定的阶段序列：`TURN_START`、`ACTION`、`SELECT`、`CHARGE`、`MOTION`、`HIT_SETTLE`、`ZOC_SETTLE`、`TURN_END`、`ENEMY_TURN`；走完 `ENEMY_TURN` 后回到 `TURN_START` 开始新回合。

#### Scenario: 一个回合按序走完全部阶段

- **WHEN** 一个回合开始，玩家完成一次完整的点选、蓄力、激发流程，且棋盘最终静止
- **THEN** 阶段依次经过 `TURN_START` → `ACTION` → `SELECT` → `CHARGE` → `MOTION` → `HIT_SETTLE` → `ZOC_SETTLE` → `TURN_END` → `ENEMY_TURN`，随后回到 `TURN_START`

#### Scenario: 阶段序列可循环

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

#### Scenario: 连续 pass 阶段逐帧穿过

- **WHEN** 阶段机位于 `MOTION` 之后的 `HIT_SETTLE`，且 `ZOC_SETTLE`、`TURN_END`、`ENEMY_TURN` 的完成条件均为恒真
- **THEN** 这 4 个阶段分别在连续 4 个物理帧内各推进一次，不出现同一帧内的循环推进

### Requirement: 未实现阶段的占位语义

本期不实现的阶段 MUST 以"完成条件恒真"的方式占位，照常发出阶段变更信号，且不得阻断阶段序列的推进；后续填充这些阶段的内容时，不得要求改动阶段机本身。

#### Scenario: 占位阶段不阻断流程

- **WHEN** 阶段机进入 `HIT_SETTLE`（本期为占位阶段）
- **THEN** 该阶段在下一个物理帧即被判定完成并推进到 `ZOC_SETTLE`，无需任何外部输入

#### Scenario: 占位阶段仍发出信号

- **WHEN** 阶段机从 `ZOC_SETTLE` 推进到 `TURN_END`
- **THEN** 订阅方收到 `ZOC_SETTLE` 的退出与 `TURN_END` 的进入通知，与实现阶段的行为一致

### Requirement: 阶段变更可观察

阶段机 MUST 在每次阶段切换时发出可订阅的信号，携带切换前后的阶段标识，供 UI 与棋子查询当前操作许可。

#### Scenario: 订阅方收到阶段切换

- **WHEN** 阶段机从 `SELECT` 推进到 `CHARGE`
- **THEN** 订阅方收到一次阶段变更通知，其中切换前阶段为 `SELECT`、切换后阶段为 `CHARGE`

#### Scenario: 棋子按阶段查询操作许可

- **WHEN** 阶段机位于 `ENEMY_TURN`
- **THEN** 任何己方棋子查询操作许可均返回不允许，且棋子不响应鼠标输入

### Requirement: 每回合只走一次发射流程

由于"每回合只能发射一枚棋子"是硬规则，`ACTION` → `SELECT` → `CHARGE` → `MOTION` SHALL 每回合只经过一次；阶段机不得包含"本回合剩余发射次数"的循环结构。

#### Scenario: 发射后不再回到 ACTION

- **WHEN** 一枚棋子被激发并完成 `MOTION` 阶段
- **THEN** 阶段机继续走向 `HIT_SETTLE`，不回到 `ACTION` 等待第二次发射

#### Scenario: 结束回合跳过发射流程

- **WHEN** 玩家在 `ACTION` 阶段点击"结束回合"
- **THEN** 阶段机跳过 `SELECT`、`CHARGE`、`MOTION`，直接进入 `TURN_END`
