extends Node

## 回合阶段机。
##
## 阶段图（本期只做回合级；选中/蓄力仍归 TurnController 自己管，不是阶段）：
##
##   TURN_START ─(停留 1s + 全场静止)→ PLAYER_TURN
##   PLAYER_TURN ─┬─(发射)→ MOTION ─(全场静止)→ PLAYER_TURN
##                └─(点结束回合 且 全场静止)→ TURN_END
##   TURN_END ─(停留 1s)→ ENEMY_TURN ─(停留 1s)→ TURN_START
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

const PHASE_NAMES := {
	Phase.TURN_START: "TURN_START 回合开始",
	Phase.PLAYER_TURN: "PLAYER_TURN 我的回合",
	Phase.MOTION: "MOTION 移动碰撞",
	Phase.TURN_END: "TURN_END 回合结束",
	Phase.ENEMY_TURN: "ENEMY_TURN 敌方回合",
}

signal phase_changed(from_phase: int, to_phase: int)
signal owner_hp_changed(owner_id: int, hp: int)

## 各归属方的当前血量，索引 = owner_id
var owner_hp: Array[int] = []

@export_group("归属方")
## 归属方血量池（对局级状态，比回合并寿）。索引 = `owner_id`。
## 归零即该方失败、对局结束。
@export var owner_max_hp: int = 99

@export_group("节奏")
## TURN_START / TURN_END / ENEMY_TURN 各自的停留时长。只为看得见，没有规则含义
@export_range(0.0, 5.0, 0.1) var dwell_sec: float = 1.0

@export_group("静止判定")## 线速度阈值（px/s）。与棋子自己的 rest_speed 对齐
@export_range(0.0, 200.0, 1.0) var rest_lin_speed: float = 10.0
## 角速度阈值（rad/s）。独立于线速度 —— 原地打转不算静止（spec 要求）
@export_range(0.0, 20.0, 0.1) var rest_ang_speed: float = 0.5
## 去抖：连续这么多物理帧都静止才算数。6 帧 @ 60Hz = 0.1 秒（constraints.md 的性能红线）
@export_range(1, 60, 1) var rest_debounce_frames: int = 6
## 超时兜底：等这么久还没静止就强制放行并报警（spec 要求，防死等）
@export_range(0.0, 60.0, 0.5) var rest_timeout_sec: float = 8.0

var phase: Phase = Phase.TURN_START

## 发射边锁：TURN_START 打开，发射一次后关闭，到下一个 TURN_START 才重开。
## 这是"边上的开关"，不是"剩余次数"计数器 —— 计数器必须在每条路径上记得扣减，
## 漏一条路径就是一个可被绕过的 bug（设计文档决策 9）。
var launch_available := false

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

var _turn_controller: Node = null
var _phase_label: Label = null
var _end_turn_button: Button = null


func _ready() -> void:
	add_to_group(&"game_flow")

	# 本节点在 main.tscn 里排在最后，此时 StaticBody2D 那棵子树已经 ready，
	# pieces 组（含 Mob）已经满了。走 register_piece 是为了顺带把 bumped 信号连上。
	_pieces.clear()
	for p in get_tree().get_nodes_in_group(PIECES_GROUP):
		register_piece(p)
	owner_hp = [owner_max_hp, owner_max_hp]
	_turn_controller = get_tree().get_first_node_in_group(&"turn_controller")
	_phase_label = get_node_or_null("../LifeCycle") as Label
	_end_turn_button = get_node_or_null("../EndTurnButton") as Button

	if _end_turn_button != null:
		_end_turn_button.pressed.connect(request_end_turn)
	if _turn_controller != null and _turn_controller.has_signal(&"piece_launched"):
		_turn_controller.piece_launched.connect(_on_piece_launched)

	_enter(phase) # 开局停在 TURN_START，让玩家从头看到一整圈


func _physics_process(delta: float) -> void:
	_settled_pairs.clear() # 一次接触开始只结算一次；每物理帧重置（见 _on_piece_bumped）
	_dwell += delta

	# 至多一条边，用 if 不用 while（红线 #3）
	var next := _poll(delta)
	if next == NO_TRANSITION:
		return

	var from := phase
	_leave(from)
	phase = next
	_enter(next)
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
			if _board_at_rest(delta):
				return Phase.PLAYER_TURN
		Phase.TURN_END:
			if _dwell >= dwell_sec:
				return Phase.ENEMY_TURN
		Phase.ENEMY_TURN:
			if _dwell >= dwell_sec:
				return Phase.TURN_START
	return NO_TRANSITION


func _enter(p: Phase) -> void:
	_dwell = 0.0
	_rest_frames = 0
	_rest_wait = 0.0 # 静止等待按阶段各自计时，免得上个阶段的等待算到这个阶段头上

	match p:
		Phase.TURN_START:
			launch_available = true # 发射边重新打开
			_actor = null # 上回合的行动角色作废
		Phase.TURN_END:
			_end_turn_requested = false # 意愿被兑现了，清掉

	_update_button()
	_update_label()


func _leave(p: Phase) -> void:
	if p == Phase.PLAYER_TURN and _turn_controller != null and is_instance_valid(_turn_controller):
		# 离开我的回合就清掉选中/蓄力。否则会出现"棋子停在蓄力态、但已经进了敌方回合"
		# 这种悬挂状态 —— 玩家选中棋子后直接点结束回合时，没有任何东西在动，
		# 静止闸门会立刻放行。
		_turn_controller.clear_selection()


# ---------- 对外 ----------

## 操作许可：只有"我的回合"且本回合还没发射过，才允许选中/蓄力。
## TurnController 每次按下左键前问一句（spec："操作许可由阶段机发放"）。
func can_operate_pieces() -> bool:
	return phase == Phase.PLAYER_TURN and launch_available


## 把伤害结算到某个归属方的血量池上。返回实际扣掉多少（血量下限 0）。
##
## 目前**没有调用方**——碰撞伤害是下一步（见 [20-character PRD] 的伤害去向表）。
## 先放在这里是为了让血量池**能被改**：不然显示出来的 99 永远是个常量，没法验证显示是否真的连着状态。
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


## 请求结束回合。按钮和 headless 探针都走这里。
## 只记下意愿、不直接切阶段 —— 真正的切换由 PLAYER_TURN 的完成条件在"全场静止"
## 满足时执行。这样"任何时候都能点、但静止后才真的走"就自然成立，不需要额外的等待态。
func request_end_turn() -> void:
	if phase == Phase.PLAYER_TURN or phase == Phase.MOTION:
		_end_turn_requested = true


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


## 一次棋子碰撞的结算。**双向**：双方各打出自己的 atk（互相交换，
## 不是"撞的一方打人、被撞的一方挨打"）。
func _resolve_collision(a: RigidBody2D, b: RigidBody2D) -> void:
	_exchange(a, b)
	_exchange(b, a)


## attacker 打 defender 一次。伤害 = 攻击方 atk × 克制倍率。
##
## 去向按 20-character PRD 的伤害三档表：先扣角色血量（下限 0），扣不完的部分转给归属方；
## 已经是薄弱点（hp == 0）则 absorbed 为 0、全额转移。三档由 `mini()` 这一行自然涵盖。
func _exchange(attacker: RigidBody2D, defender: RigidBody2D) -> void:
	var dmg := int(round(float(attacker.atk) * attacker.damage_multiplier_against(defender)))
	if dmg <= 0:
		return
	var absorbed: int = mini(dmg, defender.hp)
	defender.hp -= absorbed
	var overflow := dmg - absorbed
	if overflow > 0:
		damage_owner(defender.owner_id, overflow)


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


# ---------- 内部 ----------

func _on_piece_launched(piece: Node) -> void:
	launch_available = false # 边锁关上，本回合不能再选任何棋子
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

	var lin_sq := rest_lin_speed * rest_lin_speed
	var moving: RigidBody2D = null
	for node in _pieces:
		if not is_instance_valid(node):
			continue
		var body := node as RigidBody2D
		if body == null:
			continue
		if body.linear_velocity.length_squared() > lin_sq or absf(body.angular_velocity) > rest_ang_speed:
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
