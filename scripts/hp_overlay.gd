extends Node2D

## 血量显示（**调试级，不是最终 UI**）：
## 在每枚棋子头上画当前血量，左下角画两个归属方的血量池。
##
## 为什么用 `_draw` 而不是给每枚棋子挂一个 `Label`：
##   棋子是刚体，会自转；挂在它下面的 Label 会跟着转，要再写一份抵消旋转的逻辑。
##   这个节点挂在 `main` 下（不在棋盘容器里），用世界坐标画，不受刚体旋转影响，
##   而且不必改 `player.tscn` / `mob.tscn`。
##
## 代价：设计期在编辑器里看不到它，只有运行起来才画。最终的血条 / 头像框
## 属于美术与布局工作，由用户在编辑器里做 —— 那时把这个节点删掉即可。

const PIECE_GROUP := &"pieces"
const OWNER_NAMES := ["我方", "敌方"]
## 与 player.gd 的 RoleType 同序：NONE / PROTECTOR / FIGHTER / CASTER
const TYPE_NAMES := ["无属性", "护卫", "斗士", "施法者"]

## 字号
@export var font_size: int = 16
## 血量文字相对棋子中心的偏移（向上为负）
@export var piece_label_offset := Vector2(0, -26)
## 归属方血量面板的绘制位置
@export var owner_panel_pos := Vector2(8, 424)

var _font: Font
var _game_flow: Node = null


func _ready() -> void:
	_font = ThemeDB.fallback_font
	z_index = 100 # 保证画在棋子之上
	_game_flow = get_tree().get_first_node_in_group(&"game_flow")


func _process(_delta: float) -> void:
	queue_redraw() # 棋子在动，每帧重画


func _draw() -> void:
	if _font == null:
		return
	_draw_piece_hp()
	_draw_owner_hp()


func _draw_piece_hp() -> void:
	for node in get_tree().get_nodes_in_group(PIECE_GROUP):
		var piece := node as RigidBody2D
		if piece == null or not is_instance_valid(piece):
			continue

		var hp: int = piece.hp
		var max_hp: int = piece.max_hp
		# 只显示当前血量，不显示上限（用户要求）
		var label := "薄弱点" if hp <= 0 else str(hp)
		var color := Color(0.92, 0.92, 0.92)
		if hp <= 0:
			color = Color(1.0, 0.35, 0.35) # 薄弱点：显眼地标出来
		elif float(hp) <= float(max_hp) * 0.34:
			color = Color(1.0, 0.78, 0.3)

		var pos: Vector2 = piece.global_position + piece_label_offset
		# 第一行：类型 + 攻击力。颜色**跟着血量走**（用户要求"和血量一致"），
		# 所以薄弱点时两行一起变红，低血时一起变黄。
		var tag := "%s %d" % [TYPE_NAMES[piece.role_type], piece.atk]
		_draw_centered(tag, pos - Vector2(0.0, font_size + 2.0), color)
		# 第二行：血量
		_draw_centered(label, pos, color)


## 以 x 为中心画一行字
func _draw_centered(text: String, pos: Vector2, color: Color) -> void:
	var w: float = _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(_font, pos - Vector2(w * 0.5, 0.0), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


func _draw_owner_hp() -> void:
	if _game_flow == null or not is_instance_valid(_game_flow):
		_game_flow = get_tree().get_first_node_in_group(&"game_flow")
		if _game_flow == null:
			return

	for i in _game_flow.owner_hp.size():
		var hp: int = _game_flow.owner_hp[i]
		var who: String = OWNER_NAMES[i] if i < OWNER_NAMES.size() else "归属方 %d" % i
		var text := "%s  %d / %d" % [who, hp, _game_flow.owner_max_hp]
		var color := Color(1.0, 0.4, 0.4) if hp <= 0 else Color(1.0, 1.0, 1.0)
		draw_string(_font, owner_panel_pos + Vector2(0.0, i * (font_size + 6)), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
