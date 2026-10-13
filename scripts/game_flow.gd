class_name GameFlow
extends Node

## 回合阶段机。
##
## 阶段图（本期只做回合级；选中/蓄力仍归 TurnController 自己管，不是阶段）：
##
##   TURN_START ─(停留 1s + 全场静止)→ PLAYER_TURN
##   PLAYER_TURN ─┬─(发射)→ MOTION ─(全场静止)→ PLAYER_TURN
##                └─(点结束回合 且 全场静止)→ TURN_END
##   TURN_END ─(停留 1s)→ ENEMY_TURN ─┬─(bot 发射)→ MOTION ─(全场静止)→ ENEMY_TURN
##                                    └─(bot 收工 且 全场静止)→ TURN_START
##
## **`MOTION` 回到"发起方自己的枢纽"**（靠 `_active_owner` 判定），不写死回 PLAYER_TURN ——
## 这是敌方回合能复用同一套运动/静止/ZOC/冻结机制的前提（2026-10-13）。
## 规则本来就对称：`_actor` 机制不区分敌我，谁被发射谁就是行动角色。
##
## 两条来自 design/10-turn/DESIGN.md 的硬规矩：
##   · 每物理帧至多推进一条边（红线 #3，用 if 不用 while），防帧内级联自激
##   · 输入许可集中在这一处发放，棋子和选择层都不自行判断（决策 11）
##
## 本节点是回合状态的唯一持有者，对应 DESIGN.md 里 TurnContext + GameFlow 的位置。
## 本期的回合瞬时量只有"发射边锁"和"结束回合意愿"两项。

enum Phase { TURN_START, PLAYER_TURN, MOTION, TURN_END, ENEMY_TURN }

const NO_TRANSITION := -1
const PIECES_GROUP := &"pieces"
## 归属方血量标签上显示的名字。索引 = `owner_id`，与 `owner_hp` 同序。
const OWNER_NAMES := ["我方", "敌方"]

const PHASE_NAMES := {
	Phase.TURN_START: "TURN_START 回合开始",
	Phase.PLAYER_TURN: "PLAYER_TURN 我的回合",
	Phase.MOTION: "MOTION 移动碰撞",
	Phase.TURN_END: "TURN_END 回合结束",
	Phase.ENEMY_TURN: "ENEMY_TURN 敌方回合",
}

signal phase_changed(from_phase: int, to_phase: int)
signal owner_hp_changed(owner_id: int, hp: int)
## ZOC 检测完成（检测是纯查询，不发伤害）。表现层将来可以挂在这里。
signal zoc_detected(target: RigidBody2D, coverers: Array)
## ZOC 攻击已施加（单向）。携带目标与实际扣掉的血量。
signal zoc_attacked(target: RigidBody2D, damage: int)

## 各归属方的当前血量，索引 = owner_id
var owner_hp: Array[int] = []

@export_group("归属方")
## 归属方血量池（对局级状态，比回合并寿）。索引 = `owner_id`。
## 归零即该方失败、对局结束。
@export var owner_max_hp: int = 99

@export_group("节奏")
## TURN_START / TURN_END / ENEMY_TURN 各自的停留时长。只为看得见，没有规则含义
@export_range(0.0, 5.0, 0.1) var dwell_sec: float = 1.0

@export_group("静止判定")
## 线速度阈值（px/s）。与棋子自己的 rest_speed 对齐
@export_range(0.0, 200.0, 1.0) var rest_lin_speed: float = 10.0
## 角速度阈值（rad/s）。独立于线速度 —— 原地打转不算静止（spec 要求）
@export_range(0.0, 20.0, 0.1) var rest_ang_speed: float = 0.5
## 去抖：连续这么多物理帧都静止才算数。6 帧 @ 60Hz = 0.1 秒（constraints.md 的性能红线）
@export_range(1, 60, 1) var rest_debounce_frames: int = 6
## 超时兜底：等这么久还没静止就强制放行并报警（spec 要求，防死等）
@export_range(0.0, 60.0, 0.5) var rest_timeout_sec: float = 8.0

var phase: Phase = Phase.TURN_START

## 此刻轮到哪一方。`MOTION` 靠它知道该回哪个枢纽；显示层靠它决定画谁的控制域。
## **在 `_enter` 里由阶段决定**，不是从 `phase` 现算的 —— 因为 `MOTION` 期间"轮到谁"不变，
## 而 `phase != PLAYER_TURN` 那种写法会把 `MOTION` 误判成敌方回合（ZOC 圈会画错边）。
var _active_owner := 0

## 发射边锁：**每一位方各自一把**，在自己回合开始时打开，发射一次后关上。
## 这是"边上的开关"，不是"剩余次数"计数器 —— 计数器必须在每条路径上记得扣减，
## 漏一条路径就是一个可被绕过的 bug（设计文档决策 9）。索引 = `owner_id`。
##
## ⚠️ **必须是两把，不能一把。** 玩家出完手之后走的是
## `PLAYER_TURN → TURN_END → ENEMY_TURN`，**不经过 `TURN_START`** ——
## 一把锁的话敌方会被玩家那一发锁死，整个敌方回合动不了。
##（2026-10-13 踩到：探针里 bot 卡在敌方回合 25 秒没动静。）
var launch_available: Array[bool] = [false, false]

var _end_turn_requested := false
var _launched_this_phase := false
var _dwell := 0.0
var _rest_frames := 0
var _rest_wait := 0.0
var _pieces: Array[Node] = [] # 热路径复用，每物理帧不分配容器
## 本回合的**行动角色**：玩家发射出去的那一枚。
## **只有它与敌方的碰撞才结算伤害**——撞自己人、以及被撞飞的角色再撞到别人，
## 都不执行血量交换（2026-10-10 用户规则）。回合开始清空。
var _actor: Node2D = null

## 本物理帧已经结算过的碰撞对。`body_entered` 对接触双方**各发一次**，
## 不去重就会把同一次碰撞结算两遍。每物理帧重置（一次接触只算一次）。
var _settled_pairs: Dictionary = {}

## 碰撞冻结（2026-10-12）。流程：
##
##   撞上 → 等冲量落地（见下）→ **冻结物理** → 行动角色播 attack、被撞方播 be_hit
##        → 等**行动角色的 attack 动画**播完 → 解冻 → **结算伤害（双向）+ 抖一下** → 物理继续
##
## 为什么能冻：`PhysicsServer2D.set_active(false)` 停的是物理积分，**不停场景树**，
## 所以 `_process` 照常跑、动画照常播。实测（本机 4.7.2）：
## 冻结 1 秒位置零漂移、速度与角速度原样保留，解冻后的轨迹与"从不冻结"逐帧完全一致。
##
## ⚠️ **但 `_physics_process` 也照常跑** —— 阶段机不会自己停。所以 `_physics_process`
## 开头有一道显式的冻结闸门，否则动画还在播、阶段就已经翻页了（决策 4 的"表现排空"）。
var _impact_frozen := false
var _impact_timer := 0.0
## 待结算的碰撞对。同一物理步里撞到两枚会攒成两条，解冻时一起结算。
var _impact_pending: Array = []

## ⚠️ **冻结必须延后几个物理步才生效**（2026-10-13 实测）。
##
## 实测：`body_entered` 回调触发的那一步，只有**撞人的那枚**速度被结算掉，
## 被撞的那枚要再等两步才拿到速度：
##
##   帧 18  行动 v=0    目标 v=0     ← 回调在这一步触发
##   帧 19  行动 v=0    目标 v=0
##   帧 20  行动 v=0    目标 v=395   ← 冲量这才落地
##
## 在回调里当场 `set_active(false)`，这份冲量就**永久被吞掉**：撞人的停住、被撞的纹丝不动。
## 低速接近时冲量早就落完了，看不出来；高速接近（蓄力 480、每秒走 6.7 px）时稳定复现 ——
## 这就是"打完动画之后球没劲"的真凶之一。判断依据见 tools/probe/energy_probe.gd 的 d/e 趟对照。
const FREEZE_DELAY_STEPS := 3
var _freeze_delay := 0
var _freeze_actor: RigidBody2D = null

var _turn_controller: Node = null
var _phase_label: Label = null
var _end_turn_button: Button = null
var _reset_button: Button = null
var _camera: ShakeCamera = null
var _owner_hp_label: Label = null


func _ready() -> void:
	add_to_group(&"game_flow")

	# 本节点在 main.tscn 里排在最后，此时 StaticBody2D 那棵子树已经 ready，
	# pieces 组（含 Mob）已经满了。走 register_piece 是为了顺带把 bumped 信号连上。
	_pieces.clear()
	for p in get_tree().get_nodes_in_group(PIECES_GROUP):
		register_piece(p)
	owner_hp = [owner_max_hp, owner_max_hp]
	_turn_controller = get_tree().get_first_node_in_group(&"turn_controller")

	# ⚠️ **UI 全在 `UI/`（CanvasLayer）下，路径里必须带 `UI/`。**
	# 加相机时这些节点从 `main` 下搬进了 UI 层（世界坐标里的东西会跟着抖，屏幕 UI 不该跟着），
	# 但**搬完忘了改这里的路径**——用的又是 `get_node_or_null`，于是静默失败：
	# 阶段名不显示、"结束回合"与"重置"两个按钮直接变死。这类错不会报错，只会"点了没反应"。
	_phase_label = get_node_or_null("../UI/LifeCycle") as Label
	_end_turn_button = get_node_or_null("../UI/EndTurnButton") as Button

	if _end_turn_button != null:
		_end_turn_button.pressed.connect(request_end_turn)
	_reset_button = get_node_or_null("../UI/ResetButton") as Button
	if _reset_button != null:
		_reset_button.pressed.connect(reset_match)
	_camera = get_node_or_null("../ShakeCamera") as ShakeCamera
	_owner_hp_label = get_node_or_null("../UI/OwnerHp") as Label
	owner_hp_changed.connect(_on_owner_hp_changed)
	_update_owner_hp_label()
	if _turn_controller != null and _turn_controller.has_signal(&"piece_launched"):
		_turn_controller.piece_launched.connect(_on_piece_launched)

	_enter(phase) # 开局停在 TURN_START，让玩家从头看到一整圈


func _physics_process(delta: float) -> void:
	_settled_pairs.clear() # 一次接触开始只结算一次；每物理帧重置（见 _on_piece_bumped）
	_tick_freeze_delay()   # 冻结的延时生效（必须在表现闸门之前）

	# **表现期间不推进阶段、也不累计停留时间**（见 is_presenting）。
	# 不拦的话，冻结时动画还在播、阶段就已经翻页了 —— 这正是决策 4 说的"表现排空"。
	if is_presenting():
		return

	_dwell += delta

	# 至多一条边，用 if 不用 while（红线 #3）
	var next := _poll(delta)
	if next == NO_TRANSITION:
		return

	var from := phase
	_leave(from)
	phase = next
	_enter(next, from)
	phase_changed.emit(from, next)


## 当前阶段的完成条件。未完成返回 NO_TRANSITION。
func _poll(delta: float) -> int:
	match phase:
		Phase.TURN_START:
			# 进新回合也要全场静止 —— 敌方棋子可能还没停稳
			if _dwell >= dwell_sec and _board_at_rest(delta):
				return Phase.PLAYER_TURN
		Phase.PLAYER_TURN:
			if _launched_this_phase:
				_launched_this_phase = false
				return Phase.MOTION
			# 结束回合的意愿可能是在 MOTION 期间点的，所以在这个阶段才被兑现
			if _end_turn_requested and _board_at_rest(delta):
				return Phase.TURN_END
		Phase.MOTION:
			# ZOC 分两拍走完：等静止 → 播 zoc（检查）→ 播 attack/be_hit 并结算。
			# **两拍期间 MOTION 都不结束**，玩家不能趁动画还在播的时候操作（决策 4）。
			if _zoc_stage == ZocStage.DONE:
				return _hub_of(_active_owner) # 谁发起的就回谁那儿，不写死回 PLAYER_TURN
			if _zoc_stage == ZocStage.WINDUP:
				_zoc_timer -= delta
				if _zoc_timer <= 0.0:
					_strike_zoc()
				return NO_TRANSITION
			if _board_at_rest(delta):
				_start_zoc_check()
			return NO_TRANSITION
		Phase.TURN_END:
			if _dwell >= dwell_sec:
				return Phase.ENEMY_TURN
		Phase.ENEMY_TURN:
			# 与 PLAYER_TURN 同构：出手走 MOTION，收工后回 TURN_START。
			# "收工"由 bot 调 `request_end_turn()` 声明 —— 和玩家按按钮是同一个意愿位。
			if _launched_this_phase:
				_launched_this_phase = false
				return Phase.MOTION
			if _end_turn_requested and _board_at_rest(delta):
				return Phase.TURN_START
	return NO_TRANSITION


## 某一方的枢纽阶段。`MOTION` 与"轮到谁"都靠它对应。
func _hub_of(owner: int) -> int:
	return Phase.PLAYER_TURN if owner == 0 else Phase.ENEMY_TURN


## `from` = 从哪个阶段来的。**枢纽阶段会被 `MOTION` 回访**（打完回到发起方的枢纽），
## 所以要区分"回合开始"和"刚出完手回来" —— 靠 `from != MOTION`。
func _enter(p: Phase, from: int = NO_TRANSITION) -> void:
	_dwell = 0.0
	_rest_frames = 0
	_rest_wait = 0.0 # 静止等待按阶段各自计时，免得上个阶段的等待算到这个阶段头上

	match p:
		Phase.TURN_START:
			launch_available[0] = true # 玩家的边锁：新回合重开
			_actor = null # 上回合的行动角色作废
			_active_owner = 0 # 下一个是玩家的回合；显示层照着画控制域
			# 结束回合的意愿在上一个阶段就被兑现了。玩家那条路会经过 TURN_END（在那儿清），
			# 敌方那条路是 ENEMY_TURN → TURN_START 直连 —— 不在这儿一并清，它会一路带到下一回合。
			_end_turn_requested = false
		Phase.PLAYER_TURN:
			_active_owner = 0
		Phase.ENEMY_TURN:
			_active_owner = 1
			# **只有"敌方回合开始"才重开它的边锁**。从 MOTION 回来的那次是它自己刚出完手，
			# 重开会让它一回合打两发 —— 和玩家那边是同一个坑（枢纽会被 MOTION 回访）。
			if from != Phase.MOTION:
				launch_available[1] = true
		Phase.TURN_END:
			_end_turn_requested = false # 意愿被兑现了，清掉

	_update_button()
	_update_label()


func _leave(p: Phase) -> void:
	if p == Phase.MOTION:
		_zoc_stage = ZocStage.NONE # ZOC 表现在 MOTION 内部走完，进来时复位
	# 离开**任何一方的枢纽**都清掉选中/蓄力。否则会出现"棋子停在蓄力态、但已经进了
	# 对方回合"这种悬挂状态 —— 玩家选中棋子后直接点结束回合时，没有任何东西在动，
	# 静止闸门会立刻放行。bot 出手前也会选中它要用的那枚，同样要清。
	if (p == Phase.PLAYER_TURN or p == Phase.ENEMY_TURN) \
			and _turn_controller != null and is_instance_valid(_turn_controller):
		_turn_controller.clear_selection()


# ---------- 对外 ----------

## 操作许可：只有"我的回合"、本回合还没发射过、**且没有表现在播**，才允许选中/蓄力。
## TurnController 每次按下左键前问一句（spec："操作许可由阶段机发放"）。
func can_operate_pieces() -> bool:
	return phase == Phase.PLAYER_TURN and launch_available[0] and not is_presenting()


## 敌方回合的出手许可。**与玩家共用同一个发射边锁机制**（决策 11：
## 输入许可统一由阶段机发放）—— bot 不问这套，就绕过了边锁，"每回合一次"立刻失效。
func can_enemy_launch() -> bool:
	return phase == Phase.ENEMY_TURN and launch_available[1] and not is_presenting()


## 全场是否已停稳。**纯查询，不碰阶段机的去抖计数** —— bot 用它决定"现在能不能出手"，
## 若直接调 `_board_at_rest(0)` 会把阶段机的 `_rest_frames` / `_rest_wait` 搅乱。
func board_is_resting() -> bool:
	for node in _pieces:
		if not is_instance_valid(node):
			continue
		var body := node as RigidBody2D
		if body != null and _piece_is_moving(body):
			return false
	return true


## 这一枚在动吗。**"什么算在动"只在这里定义一次**，`_board_at_rest` 与 `board_is_resting` 共用。
func _piece_is_moving(body: RigidBody2D) -> bool:
	return body.linear_velocity.length_squared() > rest_lin_speed * rest_lin_speed \
			or absf(body.angular_velocity) > rest_ang_speed


## 表现是否还在播（碰撞冻结 / 屏幕抖动）。**阶段机与操作许可都靠它放行**（决策 4 的"表现排空"）。
##
## 两件事都要拦，理由各不一样：
##   · 冻结：物理停了，但 `_physics_process` 照常被调用（实测），不拦阶段就自己翻页了
##   · 抖动：相机一动，`get_global_mouse_position()` 就跟着偏（实测），
##     不拦的话玩家会在画面还抖着的时候开始蓄力，瞄准方向是抖的
func is_presenting() -> bool:
	if _impact_frozen:
		return true
	return _camera != null and is_instance_valid(_camera) and _camera.is_shaking()


## 此刻轮到哪一方行动。**显示层靠它来决定画谁的控制域**，选择层靠它决定"哪些棋子能点"
## —— 归属判定收在这里，而不是写死在棋子身上（写死会让敌方永远选不中，见 player.gd 的 is_selectable）。
##
## 值是 `_enter` 里按阶段写下的，**不是从 `phase` 现算**：`MOTION` 期间"轮到谁"不变，
## 而 `phase == PLAYER_TURN ? 0 : 1` 这种写法会把 `MOTION` 判成敌方回合，ZOC 圈会画错边。
func active_owner_id() -> int:
	return _active_owner


## 本回合的行动角色（发射出去的那一枚）。NULL 表示本回合还没发射过。
## ZOC 结算从它的控制域出发；调试显示也用它来高亮。
func actor_piece() -> Node2D:
	return _actor if _actor != null and is_instance_valid(_actor) else null


## 把伤害结算到某个归属方的血量池上。返回实际扣掉多少（血量下限 0）。
##
## 调用方是 `_apply_damage_to()`：角色血量扣不完的溢出、以及已是薄弱点的全额伤害，
## 都从这里转到归属方头上（见 [20-character PRD] 的伤害去向表）。
func damage_owner(who: int, amount: int) -> int:
	if who < 0 or who >= owner_hp.size() or amount <= 0:
		return 0
	var before := owner_hp[who]
	owner_hp[who] = maxi(0, before - amount)
	var dealt := before - owner_hp[who]
	if dealt > 0:
		owner_hp_changed.emit(who, owner_hp[who])
		if owner_hp[who] == 0:
			# 对局结束的判定点。胜负的表现（结算画面 / 重开）属其他模块，这里只记录事实
			push_warning("归属方 %d 血量归零 —— 对局结束（胜负的表现尚未实现）" % who)
	return dealt


## 棋子名单增删。阶段机 `_ready` 时从 `pieces` 组播一次种；
## 之后**运行时新生成 / 被销毁的棋子**（将来的召唤物）靠这两个方法进出名单。
##
## 不做成每帧重新扫组：`get_nodes_in_group` 每次调用都会新建一个数组，
## 会违反"静止判定每物理帧零分配"的性能红线（见 constraints.md）。
func register_piece(p: Node) -> void:
	if p == null or _pieces.has(p):
		return
	_pieces.append(p)
	# 连上"撞到另一枚棋子"的上报。棋子只报事实，怎么结算由这里决定。
	if p.has_signal(&"bumped") and not p.bumped.is_connected(_on_piece_bumped):
		p.bumped.connect(_on_piece_bumped.bind(p))


func unregister_piece(p: Node) -> void:
	_pieces.erase(p)


## 声明"轮到的那一方不再出手了"。**玩家按结束回合按钮、bot 决策完都走这里** ——
## 同一个意愿位，所以"点了只记下、静止后才真的走"这条对双方自动成立。
func request_end_turn() -> void:
	if phase == Phase.PLAYER_TURN or phase == Phase.MOTION or phase == Phase.ENEMY_TURN:
		_end_turn_requested = true


## 重开一局（ResetButton）：棋子回到**开局快照**、归属方血量回满、回合从 `TURN_START` 重来。
##
## 棋子那边的快照是它在 `_ready` 时自己存的，所以"初始位置/血量/攻击力"就是你在编辑器里摆的值。
func reset_match() -> void:
	# 1. 棋子：位置 / 自转 / 速度 / 血量 / 攻击力 / 朝向 / 动画 / 蓄力 / 选中 / 描边
	for node in _pieces:
		if is_instance_valid(node) and node.has_method(&"reset_to_home"):
			node.reset_to_home()

	# 2. 归属方血量池回满
	for i in owner_hp.size():
		owner_hp[i] = owner_max_hp
		owner_hp_changed.emit(i, owner_hp[i])

	# 3. 本回合瞬时量
	_actor = null
	_end_turn_requested = false
	_launched_this_phase = false
	_settled_pairs.clear()

	# 4. ZOC 表现有可能停在半路（比如重置时正播着 zoc），一并清掉
	_zoc_stage = ZocStage.NONE
	_zoc_timer = 0.0
	_zoc_damage = 0
	_zoc_target = null
	_zoc_coverers = []

	# 5. 表现闸门也要清：可能正冻着物理（重置落在冻结窗口内）、或正抖着画面。
	#    不清冻结会把伤害打到刚复位的棋子上；不清抖动会让新一局开局先抖一下。
	#    按钮不受阶段机管辖，所以这两个状态是真的够得着的。
	_clear_impact_freeze()
	if _camera != null and is_instance_valid(_camera):
		_camera.stop()

	if _turn_controller != null and is_instance_valid(_turn_controller):
		_turn_controller.clear_selection()

	# 6. 回到开局阶段（_enter 会打开发射边锁、复位 _actor、刷新按钮与阶段名）
	var from := phase
	phase = Phase.TURN_START
	_enter(phase)
	phase_changed.emit(from, Phase.TURN_START)


# ---------- 卡牌装载（占位） ----------
#
# 回合机制的三个环节之一是"卡牌装载"：卡牌可以装载到角色上，也可以由玩家直接使用。
# 机制本身由 design/30-card/PRD.md 独立设计，这里只留落点，**尚未实现**。
#
# 为什么放在阶段机上：出牌是 PLAYER_TURN 枢纽上的**动作**（不切阶段），
# 而"此刻允不允许操作"也由阶段机发放，所以接口放这里最容易找到。
#
# 实现时三条不能破（写在这里免得以后忘）：
#   · 它是动作，MUST NOT 引起阶段切换
#   · 它 MUST NOT 把"每回合一次发射"变成可累加的次数资源
#   · 0 费卡使"还能操作"永不为空，所以回合结束只能由按钮显式声明


## 玩家直接使用一张牌。返回是否真的打出了。
func play_card(_card: Variant) -> bool:
	push_warning("GameFlow.play_card 尚未实现，见 design/30-card/PRD.md")
	return false


## 把一张牌装载到一枚角色上。返回是否装载成功。
func load_card(_card: Variant, _piece: Node) -> bool:
	push_warning("GameFlow.load_card 尚未实现，见 design/30-card/PRD.md")
	return false


# ---------- 碰撞结算 ----------
#
# 这是结算的**最简形态**：撞上了就当场扣血。
#
# 文档里的完整设计是"冻结物理 → 生成事件 → 事件队列按全序键串行结算 → 表现 → 排空 → 解冻"
# （见 DESIGN.md 的设计储备部分）。那套服务的核心需求是**表现**——让伤害数字在撞击那一刻跳出来、
# 而运动暂停等待。现在还没有表现，先不引入闸门与队列，免得架构先于需求定型。
# 接表现时再补，届时 `_resolve_collision` 就是"生成一个碰撞事件"的位置。


## 一次棋子碰撞的结算。**伤害是双向的**（双方各打出自己的 atk，
## 不是"撞的一方打人、被撞的一方挨打"），
## 但**表现是单向的**：`a` 是行动角色（撞过去的那一枚），它播 attack，`b` 播 be_hit。
func _resolve_collision(a: RigidBody2D, b: RigidBody2D) -> void:
	# 1. 表现：行动角色挥剑并转向被撞的那一枚，被撞的挨打
	a.play_attack(b)
	b.play_be_hit()
	# 2. 记下这一对，等冲量落地之后才冻（同一物理步撞两枚会攒成两条，一起结算）
	_impact_pending.append([a, b])
	if not _impact_frozen and _freeze_delay <= 0:
		_freeze_delay = FREEZE_DELAY_STEPS # **不在这里 set_active**，理由见 FREEZE_DELAY_STEPS 的注释
		_freeze_actor = a
	# 3. 伤害**不在这里结算** —— 等行动角色的攻击动画播完，见 `_end_freeze()`


## 把 amount 点伤害打到 defender 身上。**伤害去向的唯一出口**（碰撞与 ZOC 共用）。
## 按三档表：先扣角色血量（下限 0），扣不完的转给归属方；已是薄弱点（hp == 0）则全额转移。
## 返回实际施加的伤害量（含溢出的部分）。
func _apply_damage_to(defender: RigidBody2D, amount: int) -> int:
	if amount <= 0:
		return 0
	var absorbed: int = mini(amount, defender.hp)
	defender.hp -= absorbed
	var overflow := amount - absorbed
	if overflow > 0:
		damage_owner(defender.owner_id, overflow)
	return amount


## attacker 打 defender 一次。伤害 = 攻击方 atk × 倍率（倍率目前恒为 1，克制已屏蔽）。
##
## ⚠️ **这里只管数值，不碰表现**。返回**实际打出的伤害量**，由调用方决定怎么表现
## （抖动档位）；动画由调用方按"谁是行动角色"决定（见 `_resolve_collision`）。
## 曾经把 `play_attack/play_be_hit` 写在这里，结果：它在同一帧被调用两次，
## 后一次把前一次覆盖掉 —— 攻击方播了 be_hit、被撞的播了 attack，完全反了。
func _exchange(attacker: RigidBody2D, defender: RigidBody2D) -> int:
	var dmg := int(round(float(attacker.atk) * attacker.damage_multiplier_against(defender)))
	if dmg <= 0:
		return 0
	_apply_damage_to(defender, dmg)
	return dmg


# ---------- ZOC 结算（环节 3） ----------
#
# 规则见 [10-turn PRD 功能 5]。要点：
#   · **单向伤害**：只有目标掉血，本方一概不掉
#   · 从**本回合发射的那枚棋子**的控制域出发挑目标
#   · 优先挑被本方**最多**控制域交叠的敌方（≥2 个即**围攻**）；没有围攻则挑最近的那个
#   · **每回合只结算一个目标**
#   · 伤害 = **所有罩住目标的本方棋子的 atk 之和**（2026-10-12 决定）
#   · 角色与召唤物**一视同仁**（召唤物也有控制域）
#
# 触发点：`MOTION` 结束时（全场静止后的一次性收口）。没有发射就没有行动角色，也就没有 ZOC。


## 控制域是否与目标**交叠**。
##
## ZOC 的定义（2026-10-12 用户明确）：以棋子为圆心、半径 `zoc_radius` 的圆，
## **没有碰撞体积**（不是物理体、不进碰撞检测），**只在 ZOC 步骤里查一次**。
## 判定的是"ZOC 圆与目标的 **CollisionShape2D** 交叠"，所以要把目标自己的
## 形状半径算进来 —— 不是"目标中心落在圆内"。
func _zoc_hits(holder: Node2D, target: RigidBody2D) -> bool:
	return holder.global_position.distance_to(target.global_position) \
			<= holder.zoc_radius + target.body_radius


## 罩住 target 的**我方**棋子。纯查询、不缓存（红线 #4），召唤物也算。
func coverers_of(target: RigidBody2D) -> Array[Node2D]:
	var out: Array[Node2D] = []
	if _actor == null or not is_instance_valid(_actor):
		return out
	var mine: int = _actor.owner_id
	for node in _pieces:
		var p := node as Node2D
		if p == null or not is_instance_valid(p) or p.owner_id != mine:
			continue
		if _zoc_hits(p, target):
			out.append(p)
	return out


## ZOC 表现分两拍（2026-10-12 用户决定"先 zoc 再 attack"）：
##   NONE   —— 还没开始，MOTION 在等全场静止
##   WINDUP —— 参与方都在播 zoc（检查/列阵），MOTION **不结束**
##   DONE   —— 已结算，MOTION 可以走了
## 中途卡住 MOTION 是必须的：不然动画还在播，玩家已经能操作了（决策 4 的"表现排空"）。
enum ZocStage { NONE, WINDUP, DONE }
var _zoc_stage := ZocStage.NONE
var _zoc_timer := 0.0
var _zoc_damage := 0
## 上一次 ZOC 检测的结果。**检测与攻击分成两拍**（见上面的 ZocStage）：
##   · `detect_zoc()` 是纯查询，只把结果写在这里，不改任何状态
##   · `_start_zoc_check()` 是第一拍：检测 + 让参与方播 zoc
##   · `_strike_zoc()` 是第二拍：读这份结果施加一次单向伤害
## 分开的好处：检测结果**可观察**（调试显示、表现层、以后的 bot 都用得上），
## 而且"检查"和"生效"不再是一件事。
var _zoc_target: RigidBody2D = null
var _zoc_coverers: Array[Node2D] = []


## ZOC 检测。**纯查询、不改状态**，返回"这次有没有检测到目标"。
##
## 步骤（2026-10-12 用户明确）：
##   1. 以**刚发射过的那枚棋子**（行动角色）的控制域为主
##   2. 逐个看我方**所有**棋子的控制域，统计每个敌方被几枚交叠
##   3. 优先挑交叠最多的（≥2 枚即**围攻**）；数目相同时挑离行动角色最近的
##   4. 没有交叠就没检测到
func detect_zoc() -> bool:
	_zoc_target = null
	_zoc_coverers = []
	if _actor == null or not is_instance_valid(_actor):
		return false # 本回合没发射过：没有行动角色，就不检测

	var mine: int = _actor.owner_id
	var best: RigidBody2D = null
	var best_cover := 0
	var best_dist := INF
	for node in _pieces:
		var e := node as RigidBody2D
		if e == null or not is_instance_valid(e) or e.owner_id == mine:
			continue
		if not _zoc_hits(_actor, e):
			continue # 不在**行动角色**的控制域里 —— 不参选（"以它为主"）
		var n := coverers_of(e).size()
		var d: float = _actor.global_position.distance_to(e.global_position)
		# 用"严格更优"比较，结果不依赖遍历顺序（红线 #2）
		if n > best_cover or (n == best_cover and d < best_dist):
			best = e
			best_cover = n
			best_dist = d

	if best == null:
		return false
	_zoc_target = best
	_zoc_coverers = coverers_of(best)
	zoc_detected.emit(_zoc_target, _zoc_coverers)
	return true


## 本次检测到的目标（null = 没检测到）
func zoc_target() -> RigidBody2D:
	return _zoc_target if _zoc_target != null and is_instance_valid(_zoc_target) else null


## 罩住本次目标的这些我方棋子
func zoc_coverers() -> Array[Node2D]:
	return _zoc_coverers


## ZOC 的**第一拍**：检测 + 让参与方摆出 zoc 姿态（检查/列阵）。**不结算伤害**。
func _start_zoc_check() -> void:
	_zoc_damage = 0
	if not detect_zoc():
		_zoc_stage = ZocStage.DONE # 没检测到目标，直接放行
		return
	var who: Node2D = _actor
	_zoc_timer = who.zoc_windup_sec() if who != null else 0.35
	for p in _zoc_coverers:
		_zoc_damage += p.atk
		p.play_zoc() # 罩住目标的我方棋子：摆出检查姿态
	_zoc_target.play_zoc() # 被检查的目标：同样进入 ZOC 表现（不想要的话去掉这一行）
	_zoc_stage = ZocStage.WINDUP


## ZOC 的**第二拍**：攻击方摆攻击姿态、目标挨打，**单向**结算伤害。
func _strike_zoc() -> void:
	_zoc_stage = ZocStage.DONE
	if _zoc_target == null or not is_instance_valid(_zoc_target) or _zoc_damage <= 0:
		return
	for p in _zoc_coverers:
		if is_instance_valid(p):
			p.play_attack(_zoc_target) # 参与围攻的每一枚都转向目标
	_zoc_target.play_be_hit()
	var dealt := _apply_damage_to(_zoc_target, _zoc_damage) # 单向：只有目标掉血
	if dealt > 0:
		zoc_attacked.emit(_zoc_target, dealt)
	_shake_for_damage(dealt)


## 棋子来报"我撞到另一枚棋子了"。
##
## **只有"本回合的行动角色 × 敌方"这一种碰撞才结算**（2026-10-10 用户规则）：
## 撞自己人不结算，被撞飞的角色再撞到别人也不结算。所以一次发射最多只在
## 行动角色与敌方之间发生血量交换。
##
## 同一对在同一物理帧里会收到两次（接触双方各报一次），用**与顺序无关**的键去重
## ——不依赖谁先被回调（结构性红线 #2）。
func _on_piece_bumped(reported: RigidBody2D, reporter: RigidBody2D) -> void:
	if reported == null or not is_instance_valid(reported):
		return

	var a := _actor
	if a == null or not is_instance_valid(a):
		return # 本回合还没发射过：谁撞谁都不结算

	# 这一对里谁不是行动角色，谁就是"另一方"
	var b: RigidBody2D = null
	if reporter == a:
		b = reported
	elif reported == a:
		b = reporter
	if b == null:
		return # 两边都不是行动角色：本方互撞，或被撞飞的角色再撞人
	if b.owner_id == a.owner_id:
		return # 撞的是自己人

	var lo := mini(a.get_instance_id(), b.get_instance_id())
	var hi := maxi(a.get_instance_id(), b.get_instance_id())
	var key := "%d_%d" % [lo, hi]
	if _settled_pairs.has(key):
		return
	_settled_pairs[key] = true
	_resolve_collision(a, b)


# ---------- 碰撞冻结 ----------
#
# 计时用 `_process` 的 delta，不用 `_physics_process` 的 —— 动画是在 `_process` 里推进的，
# 两边用同一个时钟，帧率与物理帧率不一致时才不会对不上。


func _process(delta: float) -> void:
	if not _impact_frozen:
		return
	_impact_timer -= delta
	if _impact_timer <= 0.0:
		_end_freeze()


## 冻结的延时生效：数够 `FREEZE_DELAY_STEPS` 个物理步之后才真的拉闸。
## 计数在 `_physics_process` 里走，所以"步"就是物理步，跟帧率无关。
func _tick_freeze_delay() -> void:
	if _freeze_delay <= 0:
		return
	_freeze_delay -= 1
	if _freeze_delay > 0:
		return
	_impact_frozen = true
	_impact_timer = _freeze_actor.attack_windup_sec() if is_instance_valid(_freeze_actor) else 0.2
	PhysicsServer2D.set_active(false)


## 解冻 + 结算。**先解冻再结算**：结算会改血量、发信号，不该在一个"物理停着"的状态里做。
func _end_freeze() -> void:
	_impact_frozen = false
	_impact_timer = 0.0
	_freeze_delay = 0 # 延时闸门也要撤，否则解冻之后它还会再冻我一次
	PhysicsServer2D.set_active(true)

	var pairs := _impact_pending
	_impact_pending = []
	# 这一批里**最重的一下**决定抖多狠：同一物理步撞了两枚时，
	# 别让后结算的轻伤盖掉重伤（ShakeCamera 自己也会拦"更弱的别打断更猛的"）
	var worst := 0
	for pair in pairs:
		var a: RigidBody2D = pair[0]
		var b: RigidBody2D = pair[1]
		if is_instance_valid(a) and is_instance_valid(b):
			worst = maxi(worst, _exchange(a, b)) # 双向：双方各打出自己的 atk
			worst = maxi(worst, _exchange(b, a))
	_shake_for_damage(worst)


## 伤害落地那一刻的抖动。**这是抖动的唯一入口** —— 想改"多少伤害抖多狠"，
## 去 `ShakeCamera` 上调 `severe_at` / `destructive_at`，别在这里判断档位。
## 相机缺席（headless 探针、或忘了摆相机）时静默跳过：表现不该拦住规则。
##
## ⚠️ **临时直连**：`50-presentation` 的设计里，这类表现应由时间线的 `hit` 标记驱动
##（见 design/50-presentation/timeline-and-markers.md）。时间线落地后，
## 这个调用点要挪到标记上；在那之前"奖励直连、惩罚空等"（决策 4 的取向）。
func _shake_for_damage(amount: int) -> void:
	if amount <= 0:
		return
	if _camera != null and is_instance_valid(_camera):
		_camera.shake_for_damage(amount)


## 解冻 + 丢掉待结算的碰撞对。重置时用。
## 不丢的话：冻结窗口内点"重置"，`_process` 里的计时器照常走到头，会把伤害
## 结算到**刚复位的棋子**身上（计时器只管解冻，不认自己已经过期了）。
func _clear_impact_freeze() -> void:
	if _impact_frozen:
		PhysicsServer2D.set_active(true)
	_impact_frozen = false
	_impact_timer = 0.0
	_freeze_delay = 0 # 还没拉闸的延时也要撤，否则重置之后它会把新一局冻住
	_freeze_actor = null
	_impact_pending.clear()


## 兜底：万一在冻结中途退出（切场景 / 关游戏），别把物理永久冻死。
func _exit_tree() -> void:
	_clear_impact_freeze()


# ---------- 内部 ----------

func _on_piece_launched(piece: Node) -> void:
	var body := piece as RigidBody2D
	if body != null:
		launch_available[body.owner_id] = false # **只关出手那一方**的边锁，另一方的原样
	_launched_this_phase = true
	_actor = piece as Node2D # 它成为本回合的行动角色，只有它能造成伤害


func _update_button() -> void:
	if _end_turn_button == null:
		return
	# 我的回合和移动碰撞期间都能点。点了只是记下意愿，不会立刻切阶段
	_end_turn_button.disabled = phase != Phase.PLAYER_TURN and phase != Phase.MOTION


func _update_label() -> void:
	if _phase_label != null:
		_phase_label.text = str(PHASE_NAMES.get(phase, "?"))


# ---------- 归属方血量显示 ----------
#
# 标签本身在 `main.tscn` 的 `UI`（CanvasLayer）下。**世界坐标里的东西会跟着相机抖，
# 屏幕 UI 不该跟着抖** —— 加了相机之后，它就从 hp_overlay.gd 的 `_draw` 挪到了这里。
#
# 只在这里刷新、不在 `_process` 里每帧刷：归属方血量是**对局级状态**（比回合并寿），
# 只有 `damage_owner()` 与 `reset_match()` 会改它，两处都发 `owner_hp_changed`。


func _on_owner_hp_changed(_owner_id: int, _hp: int) -> void:
	_update_owner_hp_label()


func _update_owner_hp_label() -> void:
	if _owner_hp_label == null or not is_instance_valid(_owner_hp_label):
		return
	var lines := PackedStringArray()
	var any_zero := false
	for i in owner_hp.size():
		var who: String = OWNER_NAMES[i] if i < OWNER_NAMES.size() else "归属方 %d" % i
		lines.append("%s  %d / %d" % [who, owner_hp[i], owner_max_hp])
		if owner_hp[i] <= 0:
			any_zero = true
	_owner_hp_label.text = "\n".join(lines)
	# 有一方归零就整体标红。**逐行上色做不到**（一个 Label 只有一个颜色），
	# 要分色得拆成两个标签或换 RichTextLabel —— 那是最终 UI 的事，等美术定。
	_owner_hp_label.modulate = Color(1.0, 0.4, 0.4) if any_zero else Color.WHITE


## 全场静止：所有棋子的线速度与角速度各自低于阈值，且连续 N 个物理帧都如此。
##
## 去抖是必须的：碰撞瞬间速度会恰好过零，单帧判定会误判（spec 明确要求）。
## 角速度用独立阈值：线速度接近 0 但还在原地打转不算静止。
## 每物理帧调用，_pieces 在 _ready 里缓存，热路径上不分配容器。
##
##（文档规划的是独立的 scripts/core/utils/board_query.gd，这一版先放在这里，
##  等 HIT_SETTLE / ZOC_SETTLE 那批一起拆出去。）
func _board_at_rest(delta: float) -> bool:
	_rest_wait += delta

	var moving: RigidBody2D = null
	for node in _pieces:
		if not is_instance_valid(node):
			continue
		var body := node as RigidBody2D
		if body == null:
			continue
		if _piece_is_moving(body):
			moving = body
			break

	if moving == null:
		_rest_frames += 1
		if _rest_frames < rest_debounce_frames:
			return false
		_rest_frames = 0
		_rest_wait = 0.0
		return true

	_rest_frames = 0 # 有东西重新动起来，去抖计数归零重来
	if rest_timeout_sec > 0.0 and _rest_wait >= rest_timeout_sec:
		# 超时兜底：强制放行，但要留下能排查的线索
		push_warning("静止判定超时 %.1fs，强制放行。仍在动的是 %s（线速度 %.1f，角速度 %.2f）" % [
			_rest_wait, moving.name, moving.linear_velocity.length(), moving.angular_velocity])
		_rest_wait = 0.0
		_rest_frames = 0
		return true
	return false
