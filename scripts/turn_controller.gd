extends Node2D

## 棋盘级选择协调：全盘至多一枚棋子处于选中态，鼠标输入也由这里统一解释。
##
## 为什么选择权不放在棋子自己身上：如果每枚棋子各自在 _input 里抢选中，裁决结果就取决于
## Godot 派发 _input 的节点树序 —— 那正是 design/10-turn/DESIGN.md 结构性红线 #2
##（"不依赖引擎回调顺序、字典迭代顺序、节点树顺序"）要防的东西。
## 这里一次性挑出"鼠标下最近的那枚"，结果只由几何决定。
##
## 用 Node2D 而不是 Node，是为了让 get_global_mouse_position() 和棋子那边
## 落在同一个坐标空间里（棋盘上没有 Camera2D，两者都是世界坐标）。
##
## 后续接回合阶段机时，"此刻是否允许选中/蓄力"就在这里裁决（对应 spec 的
## "操作许可由阶段机发放"）。棋子只提供能力，不自己判断。

const PIECES_GROUP := &"pieces"

## 当前被选中的棋子（全盘唯一）。null 表示没有选中任何棋子。
var selected_piece: Node2D = null


func _ready() -> void:
	add_to_group(&"turn_controller")


## _input 只是薄适配层：把引擎事件翻成"带坐标的裁决请求"，
## 这样 headless 探针可以不依赖渲染，直接喂坐标复现整套选择逻辑。
func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			handle_left_press(get_global_mouse_position())
		else:
			handle_left_release()
	elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		clear_selection()


## 左键按下。两步式的第一拍只选中，第二拍才开始蓄力。
## 选中态是"粘"的：一旦有棋子被选中，只有右键能取消它，左键点别的棋子不会改选。
## 但点在别的棋子上**照样开始蓄力** —— 瞄准的时候鼠标经常会压到别的棋子，
## 那时候不让蓄力就没法瞄了。
func handle_left_press(mouse: Vector2) -> void:
	var hit := _pick(mouse)
	if selected_piece == null:
		if hit != null:
			select(hit) # 第一拍：只选中，不蓄力
		return
	selected_piece.begin_charge(mouse) # 第二拍：点在哪都是给已选中的那枚蓄力


## 左键松开。真的发射出去了才交还选择权；落空的点击不取消选中
## （否则第一次"点选"的松开就会立刻把刚选中的棋子取消掉）。
func handle_left_release() -> void:
	if selected_piece != null and selected_piece.release_charge():
		clear_selection()


## 选中一枚棋子。调用方只会在"当前没有选中者"时调它；
## 这里仍然先清旧的是为了让"至多一枚亮着"成为这条路径自身的不变量，而不是靠调用方守规矩。
func select(piece: Node2D) -> void:
	if piece == selected_piece:
		return
	clear_selection()
	selected_piece = piece
	selected_piece.set_selected(true)


## 取消当前选中。若正在蓄力，由棋子自己把蓄力值和瞄准线一起清掉。
func clear_selection() -> void:
	if selected_piece != null and is_instance_valid(selected_piece):
		selected_piece.set_selected(false)
	selected_piece = null


## 鼠标落点命中的棋子；万一多枚同时命中，取最近的一枚。
## 棋子的点选半径 20、碰撞圆半径 16，正常站位下命中区互不重叠；
## 撞到一起时"取最近"给出的仍是由几何唯一确定的结果。
func _pick(mouse: Vector2) -> Node2D:
	var best: Node2D = null
	var best_distance := INF
	for node in get_tree().get_nodes_in_group(PIECES_GROUP):
		var piece := node as Node2D
		if piece == null or not piece.hit_test(mouse):
			continue
		var distance: float = piece.global_position.distance_squared_to(mouse)
		if distance < best_distance:
			best_distance = distance
			best = piece
	return best
