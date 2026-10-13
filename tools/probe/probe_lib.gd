extends RefCounted

## 探针公用件。
##
## **为什么放在 `tools/` 下**：`tools/.gdignore` 把这个目录挡在 Godot 资源树之外，
## 于是你正常打开项目时，编辑器**看不见这些文件** —— 不会冒出探针的报错，也不会给它们生成 `.uid`。
## `tools/verify.sh` 会把它们拷进临时副本的 `res://probe/`，在那里才被 Godot 看见。
##
## **引用用相对路径** `preload("probe_lib.gd")`：仓库里（`tools/probe/`）和临时副本里（`res://probe/`）
## 都能解析，两边不需要各写一份。

const PIECES_GROUP := &"pieces"

## 测试跑道：行动角色在下方、目标在上方，中间 150 px 空走廊。
## **探针自己把棋子摆到这儿**，所以棋盘重排不会让它误报 —— 它不读你在编辑器里摆的位置。
const ACTOR_AT := Vector2(390, 330)
const TARGET_AT := Vector2(390, 180)
## 其余棋子的停放点（四角，离走廊足够远）
const PARK_AT := [Vector2(190, 90), Vector2(590, 90), Vector2(190, 380), Vector2(590, 380)]


## 场景里所有棋子，按 [我方的, 敌方的] 分好。
static func pieces_by_side(tree: SceneTree) -> Array:
	var mine: Array = []
	var foe: Array = []
	for n in tree.get_nodes_in_group(PIECES_GROUP):
		var p := n as RigidBody2D
		if p == null or not is_instance_valid(p):
			continue
		if p.owner_id == 0:
			mine.append(p)
		else:
			foe.append(p)
	return [mine, foe]


## 把场景摆成一条确定的测试跑道，返回 `[行动角色, 目标]`；棋子不够时返回 `[]`。
##
## 摆放只改位置与速度，**不改任何规则状态** —— 棋子的开局快照（`home_position`）
## 是它们在 `_ready` 时自己存的，所以 `reset_match()` 照样能把它们送回你摆的原始位置。
static func setup_lane(tree: SceneTree) -> Array:
	var sides := pieces_by_side(tree)
	var mine: Array = sides[0]
	var foe: Array = sides[1]
	if mine.is_empty() or foe.is_empty():
		return []

	var actor := mine[0] as RigidBody2D
	var target := foe[0] as RigidBody2D
	var others: Array = mine.slice(1) + foe.slice(1)

	_place(actor, ACTOR_AT)
	_place(target, TARGET_AT)
	for i in others.size():
		var spot: Vector2 = PARK_AT[i % PARK_AT.size()]
		# 停放点用完了就沿 x 挪开一点，保证不叠在一起
		_place(others[i], spot + Vector2(0.0, -34.0 * float(i / PARK_AT.size())))
	return [actor, target]


## 把一枚棋子瞬移到某处并停稳。刚体是"服务器单向推 transform"的，所以这里
## 是**覆盖**它的位置 —— 探针跑在临时副本上，动的是副本，碰不到你的工作区。
static func _place(p: RigidBody2D, at: Vector2) -> void:
	p.linear_velocity = Vector2.ZERO
	p.angular_velocity = 0.0
	p.global_position = at
	p.rotation = 0.0


## 算"要让 action 以 arrive_speed 撞上 target，该蓄多少力"。
## 用的是棋子自己那份运动方程（`路程 = v²/(2·decel)`），所以调了 `decel` / `max_charge`
## 探针自动跟着走，不会写死一个数字然后悄悄失效。
static func charge_to_reach(actor: RigidBody2D, target: RigidBody2D, arrive_speed: float) -> float:
	var travel: float = actor.global_position.distance_to(target.global_position) \
			- actor.body_radius - target.body_radius
	var v0: float = sqrt(arrive_speed * arrive_speed + 2.0 * actor.decel * maxf(travel, 0.0))
	return minf(v0, actor.max_charge)


## 发一发。方向与蓄力值**直接写死**，不依赖鼠标 ——
## 无头环境没有真鼠标（`get_global_mouse_position()` 固定返回一个假位置，
## 而且 `Input.parse_input_event()` 也改不动它，实测）。
## `release_charge()` 用的是 `aim_dir` 而不是现算方向，所以这样写不会被覆盖。
static func launch(turn: Node, actor: RigidBody2D, aim_at: Vector2, charge: float) -> bool:
	turn.handle_left_press(actor.global_position) # 第一拍：选中
	turn.handle_left_press(aim_at)                # 第二拍：开始蓄力
	actor.aim_target = aim_at
	actor.aim_dir = (aim_at - actor.global_position).normalized()
	actor.charge = charge
	turn.handle_left_release()
	return actor.locked


## 全体都停稳了吗（线速度与角速度都低于阈值）
static func all_at_rest(pieces: Array, eps: float = 1.0) -> bool:
	for p in pieces:
		var b := p as RigidBody2D
		if b == null or not is_instance_valid(b):
			continue
		if b.linear_velocity.length() > eps or absf(b.angular_velocity) > 0.5:
			return false
	return true
