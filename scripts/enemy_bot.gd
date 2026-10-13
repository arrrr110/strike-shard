extends Node

## 敌方回合的执行者。**第一版是"会还手"的对手，不是"聪明"的对手**（决策 38 / 39）。
##
## 策略就一句话：**目标 = 对方血量最低的棋子 → 射手 = 离它最远的那一枚 → 力度 = 极限**。
##
## 为什么是这套（2026-10-13 用户定的）：
##
##   · 之前那版"挑最近的一对、蓄刚好够到的力"实测下来**总是同一枚棋子在动**，
##     其余棋子整局不动，也谈不上任何策略感；
##   · "从最远处用全力打最弱的"一次给出三件事：**射手会换**（最远的离得远）、
##     **目标会换**（血最少的被持续针对，血线一变几何就变）、
##     以及**最夸张的位移**（满蓄力射程 600 px，撞飞距离 = 射程 − 已走距离）。
##
## **不做轨迹预测**（瞄直线，不预测撞墙反射）、**不做搜索**、**不做评分函数**。
##
## 为什么单独一个节点、不写进 `game_flow`：那边已经 750+ 行、占全项目 44%
##（见 design/TODO.md 第 3 条）。**bot 是"决策"，不是"规则"**，理应分开；
## 卡牌落地时要拆 game_flow，这算提前把它往对的方向推了一步。
##
## 它与玩家的关系是**对称**的，不是特权通道：
##
##   · 出手前问 `GameFlow.can_enemy_launch()` —— 和玩家问的 `can_operate_pieces()` 是同一道边锁
##   · 出手走 `TurnController.launch()` —— 和玩家松手走同一个 `piece_launched` 出口
##   · 收工调 `GameFlow.request_end_turn()` —— 和玩家按按钮是同一个意愿位
##
## 所以规则层不知道、也不需要知道"这次是谁在打"。

const PIECES_GROUP := &"pieces"

@export_group("出手前")
## 出手前停顿多久（秒）。让玩家看清"敌方在用哪一枚、瞄哪里"。
## 0 = 立刻出手，你会只看到一枚球突然飞出去。
@export_range(0.0, 3.0, 0.1) var think_sec: float = 0.8

@export_group("准不准")
## 瞄准抖动（度）。0 = 百发百中；想给玩家让一手就调它。
## ⚠️ 非 0 会让每局出手不可复现 —— headless 跑批对比会失去意义。
@export_range(0.0, 30.0, 0.5) var aim_jitter_deg: float = 0.0

var _flow: GameFlow = null
var _turn: Node = null
var _timer := 0.0
var _armed := false
var _last_phase := -1


func _ready() -> void:
	_flow = get_tree().get_first_node_in_group(&"game_flow") as GameFlow
	_turn = get_tree().get_first_node_in_group(&"turn_controller")


func _process(delta: float) -> void:
	if _flow == null or not is_instance_valid(_flow):
		return
	var p: int = _flow.phase

	# **"敌方回合开始"= 从 TURN_END 进来。** 从 MOTION 回来那次是它自己刚出完手，
	# 要是再起意就会一回合打两发 ——（阶段机那边用 `from != MOTION` 区分同一件事）。
	if p != _last_phase:
		var from := _last_phase
		_last_phase = p
		if p == GameFlow.Phase.ENEMY_TURN and from != GameFlow.Phase.MOTION:
			_armed = true
			_timer = think_sec

	if p != GameFlow.Phase.ENEMY_TURN or not _armed:
		return
	if not _flow.board_is_resting() or _flow.is_presenting():
		return # 场上还有球在飞，或表现（冻结/抖动）还没播完

	_timer -= delta
	if _timer > 0.0:
		return

	# **不管有没有打出去都要收工。** 够不着、边锁关着，都只是"这一回合不发射"，
	# 和玩家选择不发射是同一件事；漏掉这一步会把整个敌方回合卡死。
	_armed = false
	take_shot()
	_flow.request_end_turn()


## 打一发。返回是否真的发射了。
##
## 没打出去时**要说清楚是哪一步卡住的** —— 否则"敌方回合什么都没发生"根本没法排查。
func take_shot() -> bool:
	if _turn == null or not is_instance_valid(_turn):
		push_warning("EnemyBot：找不到 TurnController，本回合不发射")
		return false
	var shot := pick_shot()
	if shot.is_empty():
		push_warning("EnemyBot：挑不出发射组合（没有可发射的棋子 / 没有一个目标），本回合不发射")
		return false
	var ok: bool = _turn.launch(shot["shooter"], shot["aim_at"], shot["charge"])
	if not ok:
		var s: RigidBody2D = shot["shooter"]
		# 把发射入口那几条前置条件摊开，免得"被拒了"变成没法排查的一件事
		push_warning("EnemyBot：发射被拒（%s → %s，蓄力 %.0f）｜ locked=%s charging=%s selected=%s 板内=%s"
				% [s.name, shot["target"].name, shot["charge"],
				   s.locked, s.charging, s.selected, s.table_rect.has_point(shot["aim_at"])])
	return ok


## 挑一发。返回 `{}` 表示这一回合打不了。
func pick_shot() -> Dictionary:
	var mine: Array = []
	var foes: Array = []
	for node in get_tree().get_nodes_in_group(PIECES_GROUP):
		var p := node as RigidBody2D
		if p == null or not is_instance_valid(p):
			continue
		# 归属判定：0 = 玩家，其余 = 敌方。与 `owner_id` 的约定一致。
		if p.owner_id == 0:
			foes.append(p)
		else:
			mine.append(p)
	if mine.is_empty() or foes.is_empty():
		return {}

	var target := _weakest(foes)
	if target == null:
		return {}
	var shooter := _farthest_from(mine, target)
	if shooter == null:
		return {}
	return plan_shot(shooter, target)


## 血量最低的那一枚。**并列时按名字定序** —— 结构性红线 #2：不依赖节点树 / 字典的迭代顺序。
##
## 血量归零的角色（**薄弱点**，决策 25）自然排在最前 —— 打它就是直接啃对方的血池，
## 不需要再单独写一条"优先打薄弱点"。
func _weakest(pool: Array) -> RigidBody2D:
	var best: RigidBody2D = null
	for p in pool:
		if best == null or _lower_hp_wins(p, best):
			best = p
	return best


## 离目标最远的那一枚。并列时同样按名字定序。
## 还在飞（`locked`）的棋子不能发射，直接排除。
func _farthest_from(pool: Array, target: RigidBody2D) -> RigidBody2D:
	var best: RigidBody2D = null
	for p in pool:
		if p.locked:
			continue
		if best == null or _farther_wins(p, best, target):
			best = p
	return best


func _lower_hp_wins(a: RigidBody2D, b: RigidBody2D) -> bool:
	if a.hp != b.hp:
		return a.hp < b.hp
	return String(a.name) < String(b.name)


func _farther_wins(a: RigidBody2D, b: RigidBody2D, target: RigidBody2D) -> bool:
	var da: float = a.global_position.distance_squared_to(target.global_position)
	var db: float = b.global_position.distance_squared_to(target.global_position)
	if not is_equal_approx(da, db):
		return da > db
	return String(a.name) < String(b.name)


## 给这一对算好方向与力度；打不了就返回 `{}`。
func plan_shot(shooter: RigidBody2D, target: RigidBody2D) -> Dictionary:
	var travel: float = shooter.global_position.distance_to(target.global_position) \
			- shooter.body_radius - target.body_radius
	if travel <= 0.0:
		return {} # 已经贴上了

	# **极限力量**：直接给满，不省力。
	#
	# 满蓄力一定够得着：射程 = max_charge²/(2·decel) = 600²/600 = 600 px，
	# 而棋盘对角线只有 √(460²+340²) ≈ 572 px，减去两个半径还有富余。
	# 下面的兜底是给"以后不同棋子配不同 max_charge"留的，不影响现在。
	var charge: float = shooter.max_charge
	if charge * charge / (2.0 * shooter.decel) < travel:
		return {}

	var aim: Vector2 = target.global_position
	if aim_jitter_deg > 0.0:
		var a := deg_to_rad(randf_range(-aim_jitter_deg, aim_jitter_deg))
		aim = shooter.global_position + (aim - shooter.global_position).rotated(a)

	return {"shooter": shooter, "target": target, "aim_at": aim, "charge": charge}
