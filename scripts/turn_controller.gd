extends Node2D

## 棋盘级选择协调 + 瞄准状态机：全盘至多一枚棋子处于选中态，鼠标点击也由这里统一解释。
##
## 为什么选择权不放在棋子自己身上：如果每枚棋子各自在 _input 里抢选中，裁决结果就取决于
## Godot 派发 _input 的节点树序 —— 那正是 design/10-turn/DESIGN.md 结构性红线 #2
##（"不依赖引擎回调顺序、字典迭代顺序、节点树顺序"）要防的东西。
## 这里一次性挑出"鼠标下最近的那枚"，结果只由几何决定。
##
## 用 Node2D 而不是 Node，是为了让 get_global_mouse_position() 和棋子那边
## 落在同一个坐标空间里。`main.tscn` 里现在有 Camera2D（还带一点 zoom），
## 但 `get_global_mouse_position()` 照样返回世界坐标 —— 它**包含** canvas transform，
## 所以这里、棋子的 `table_rect`、以及盘面上的瞄准线依然是同一套坐标。
##
##（副作用：相机抖动时鼠标的世界坐标也跟着偏。抖动的表现闸门因此也拦操作许可，
##  见 game_flow.gd 的 is_presenting()。）
##
## ── 四态瞄准（2026-11-08 改版） ─────────────────────────────────────
##
##   未选中 NONE
##     └─左键点本方棋子→ 调整 ADJUST（鼠标**不按下**：移动即改角度/力度）
##          ├─左键（任意地图位置，力度>0）→ 就绪 READY（角度/力度冻结）
##          └─右键→ NONE
##   就绪 READY
##     ├─左键圈外→ 角度 ANGLE（整机随鼠标转；**角度 = 棋子→鼠标延长线，直接指向目标**）
##     ├─左键圈内→ ADJUST（按当前鼠标重新取力）
##     └─右键→ ADJUST
##   角度 ANGLE
##     ├─左键圈外→ READY
##     ├─左键圈内→ ADJUST
##     └─右键→ READY
##
## **方向语义分两套**（2026-11-10 修正）：ADJUST 是弹弓逻辑，鼠标在扳机端，
## 发射 = 鼠标→棋子的反向延长线；ANGLE 是直接瞄准，发射 = 棋子→鼠标的延长线。
## 两者由 `player.gd` 的 `aim_point_mode` 区分，不要复用同一个取角公式。
##
## **按下才锁定，松手不发射。** 发射只从 GameFlow 的合并按钮走（就绪/角度两态，
## 按钮文字变成「发射」），见 `try_launch()`。其余状态同一个按钮只是空过。
##
## 棋盘边界不再是输入边界：鼠标可以离开棋盘，大圈也会画到棋盘外。
## 旧规则「鼠标出棋盘暂停蓄力」已删除；鼠标的硬边界是窗口。
##
## 右键是一级一级退，不是清空：ANGLE → READY → ADJUST → NONE。

const PIECES_GROUP := &"pieces"

## 真的发射出去了一枚棋子。阶段机靠它关上"发射边锁"。
signal piece_launched(piece: Node2D)
## 瞄准子态变化。GameFlow 用它刷新合并按钮的文字/配色。
signal aim_state_changed(state: int)

enum AimState { NONE, ADJUST, READY, ANGLE }

## 当前被选中的棋子（全盘唯一）。null 表示没有选中任何棋子。
var selected_piece: Node2D = null
## 当前瞄准子态。真相在这里；棋子的 aiming/aim_angle_live/aim_charge_live 是它的镜像。
var aim_state: int = AimState.NONE

## 阶段机（见 scripts/game_flow.gd）。**延迟到第一次用到时才去找** ——
## TurnController 在 main.tscn 里排在 GameFlow 之前，_ready 那会儿 GameFlow 还没进组。
## 找不到就当作永远允许操作，这样不建 GameFlow 的 headless 探针照样能把棋子逻辑单独跑起来。
var _game_flow: Node = null


func _ready() -> void:
	add_to_group(&"turn_controller")


## _input 只是薄适配层：把引擎事件翻成"带坐标的裁决请求"，
## 这样 headless 探针可以不依赖渲染，直接喂坐标复现整套选择逻辑。
func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# UI 按钮（合并的发射/结束回合、重置）在 CanvasLayer 里，_input 比 GUI 先跑。
		# 不拦的话，按「发射」会同时被当成地图点击 —— 尤其它就在棋盘外，
		# 而棋盘外现在也是合法的瞄准区域。
		#
		# **只拦按钮，不拦所有 Control**：棋盘底板 ColorRect 也是 Control，
		# 用「hovered != null」会把整个棋盘的左键全部吃掉。
		if get_viewport().gui_get_hovered_control() is BaseButton:
			return
		handle_left_press(get_global_mouse_position())
	elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		handle_right_press(get_global_mouse_position())


## 左键按下。状态机唯一的点击入口；**松手不做事**（蓄力不是按住的）。
func handle_left_press(mouse: Vector2) -> void:
	match aim_state:
		AimState.NONE:
			if not _can_operate():
				return
			var hit := _pick(mouse)
			if hit == null:
				return
			select(hit)
			_enter_adjust(true)
		AimState.ADJUST:
			if selected_piece == null:
				return
			# 用点击那一刻的位置再采样一次，保证锁定用的不是上一帧的缓存。
			selected_piece.update_aim(mouse)
			if selected_piece.charge <= 0.0:
				return # 零力度按下不锁定，避免误触
			_enter_ready()
		AimState.READY:
			if selected_piece == null:
				return
			if _inside_ring(mouse):
				_enter_adjust(false)
			else:
				_enter_angle(mouse)
		AimState.ANGLE:
			if selected_piece == null:
				return
			if _inside_ring(mouse):
				_enter_adjust(false)
			else:
				selected_piece.update_aim(mouse) # 角度仍活：锁定到点击方向
				_enter_ready()


## 右键：一级一级退（不是清空）。
func handle_right_press(mouse: Vector2) -> void:
	match aim_state:
		AimState.ANGLE:
			if selected_piece != null:
				selected_piece.update_aim(mouse) # 角度活、力度冻结
			_enter_ready()
		AimState.READY:
			_enter_adjust(false)
		AimState.ADJUST:
			clear_selection()
		_:
			pass


func _inside_ring(mouse: Vector2) -> bool:
	return selected_piece != null \
			and selected_piece.global_position.distance_to(mouse) <= selected_piece.max_pull_radius


func _enter_adjust(fresh: bool) -> void:
	if selected_piece == null:
		return
	if fresh:
		selected_piece.begin_aim() # 第一次点选：力度从 0 开始
	else:
		selected_piece.set_aim_live(true, true) # 从就绪/角度回来：按当前鼠标重新取力
	_set_aim_state(AimState.ADJUST)


func _enter_ready() -> void:
	if selected_piece == null:
		return
	selected_piece.set_aim_live(false, false)
	_set_aim_state(AimState.READY)


func _enter_angle(mouse: Vector2) -> void:
	if selected_piece == null:
		return
	selected_piece.set_aim_live(true, false, true) # 直接瞄准：棋子→鼠标延长线
	selected_piece.update_aim(mouse) # 圈外第一次点击直接指到点击处
	_set_aim_state(AimState.ANGLE)


func _set_aim_state(s: int) -> void:
	aim_state = s
	aim_state_changed.emit(aim_state)


## 真的发射一枚。**玩家合并按钮和 bot 出手都落到这里** —— 所以阶段机看到的永远是同一件事
##（`piece_launched`），不需要第二条代码路径，也不会出现"某条路径忘了关边锁"。
func _release(piece: Node2D) -> bool:
	if not piece.release_charge():
		return false
	clear_selection()
	piece_launched.emit(piece)
	return true


## 玩家的合并按钮：只有就绪/角度两态允许发射。
func is_launch_ready() -> bool:
	if selected_piece == null or not is_instance_valid(selected_piece):
		return false
	if aim_state != AimState.READY and aim_state != AimState.ANGLE:
		return false
	return _can_operate()


func try_launch() -> bool:
	if not is_launch_ready():
		return false
	return _release(selected_piece)


## 程序化发射（敌方回合的 `EnemyBot` 走这里）。与玩家路径的差别**只有"谁决定方向与力度"**：
## 玩家的方向/力度来自鼠标，bot 的两者都由它自己算出来。**不进入玩家的瞄准表现**。
func launch(piece: Node2D, aim_at: Vector2, charge: float) -> bool:
	if piece == null or not is_instance_valid(piece) or piece.locked:
		return false
	select(piece)
	var dir := aim_at - piece.global_position
	piece.aim_dir = dir.normalized() if dir.length_squared() > 1.0 else Vector2.UP
	piece.charge = charge
	piece.pull_ratio = clampf(charge / piece.max_charge, 0.0, 1.0)
	piece.aiming = false # bot 不闪玩家那套圈/弩机
	return _release(piece)


## 操作许可由阶段机发放（spec："棋子 MUST NOT 自行判断当前是否可被操作"）。
## 问不到阶段机时放行 —— headless 探针不建 GameFlow，棋子逻辑要能独立验证。
## 这不是鼠标热路径（每次按下左键才问一次），所以现找即可，不必缓存。
func _can_operate() -> bool:
	if _game_flow == null or not is_instance_valid(_game_flow):
		_game_flow = get_tree().get_first_node_in_group(&"game_flow")
		if _game_flow == null:
			return true
	return _game_flow.can_operate_pieces()


## 选中一枚棋子。调用方只会在"当前没有选中者"时调它；
## 这里仍然先清旧的是为了让"至多一枚亮着"成为这条路径自身的不变量，而不是靠调用方守规矩。
func select(piece: Node2D) -> void:
	if piece == selected_piece:
		return
	clear_selection()
	selected_piece = piece
	selected_piece.set_selected(true)


## 取消当前选中。若正在瞄准，由棋子自己把圈/弩机/瞄准线一起清掉。
func clear_selection() -> void:
	if selected_piece != null and is_instance_valid(selected_piece):
		selected_piece.set_selected(false)
	selected_piece = null
	_set_aim_state(AimState.NONE)


## 鼠标落点命中的棋子；万一多枚同时命中，取最近的一枚。
##
## **归属过滤在这里**：只挑"此刻轮到的那一方"的棋子。棋子自己不知道轮到谁，
## 也不该知道（见 player.gd 的 is_selectable）。
func _pick(mouse: Vector2) -> Node2D:
	var best: Node2D = null
	var best_distance := INF
	var who := _active_owner()
	for node in get_tree().get_nodes_in_group(PIECES_GROUP):
		var piece := node as Node2D
		if piece == null or not piece.hit_test(mouse):
			continue
		if piece.owner_id != who:
			continue # 不是轮到的那一方的棋子
		var distance: float = piece.global_position.distance_squared_to(mouse)
		if distance < best_distance:
			best_distance = distance
			best = piece
	return best


## 此刻轮到哪一方。问不到阶段机时按我方算 —— headless 探针里单跑选择逻辑时用。
func _active_owner() -> int:
	if _game_flow == null or not is_instance_valid(_game_flow):
		return 0
	return _game_flow.active_owner_id()
