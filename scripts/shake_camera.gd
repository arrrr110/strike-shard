class_name ShakeCamera
extends Camera2D

## 屏幕抖动。模式参考炉石传说：**短促的位移 + 一点点旋转，衰减收敛**，
## 不是正弦振荡（正弦看起来像"晃"，随机取样才像"抖"）。
##
## ⚠️ 本节点在 `main.tscn` 里**必须摆在视口中心 (360, 240)**。
## `Camera2D` 默认把视野中心对到自己的位置，摆在 (0,0) 会让整个世界偏移
## —— 实测：一台没设位置的相机生效后，世界原点从 (0,0) 变成 (-32,-32)。
##
## ⚠️ 相机一动，`get_global_mouse_position()` 就跟着变（实测：相机 offset (12,-8)
## → 鼠标的世界坐标也偏 (12,-8)）。所以**抖动期间阶段机不推进、也不发操作许可**，
## 免得玩家在画面还在抖的时候瞄准。见 `game_flow.gd` 的 `is_presenting()`。
##
## 抖动是**纯表现**：实测相机 offset ±12px 时棋子轨迹偏差 0.000000000
##（见 design/00-overview/constraints.md 的实测表）。所以这里用真随机不破坏确定性。

enum Level { MILD, SEVERE, DESTRUCTIVE }

@export_group("幅度（像素）")
@export var mild_strength: float = 3.0
@export var severe_strength: float = 8.0
@export var destructive_strength: float = 16.0

@export_group("时长（秒）")
@export var mild_sec: float = 0.18
@export var severe_sec: float = 0.30
@export var destructive_sec: float = 0.50

@export_group("旋转")
## 抖动时带一点旋转（炉石那味儿）。0 = 不转
@export_range(0.0, 5.0, 0.1) var max_roll_deg: float = 0.8

@export_group("伤害 → 档位")
## 打出这么多伤害就升档。规则层只播报"掉了多少血"，抖多狠由这里决定 ——
## 规则层不认识"轻微/严重/毁灭"。默认值对齐当前的占位数值（`atk = 10`、`max_hp = 70`）：
## 单次普通碰撞（10）＝ 严重；围攻叠加、或薄弱点全额转给归属方（≥ 20）＝ 毁灭。
@export_range(1, 500, 1) var severe_at: int = 10
@export_range(2, 500, 1) var destructive_at: int = 20

@export_group("抖动留白")
## 相机视野比窗口**小**一圈（像素），给抖动留余量：任一方向抖到最大，
## 画面边缘仍落在世界之内，不露出外面的空白。
##
## **必须 ≥ `destructive_strength`**，否则毁灭级抖动会露馅（见下方配置警告）。
## `zoom` 由这个值现算 —— 在编辑器里直接改 `zoom` 会被覆盖，要调画面大小就改这里。
@export var reserve_px: float = 20.0

var _left := 0.0       # 剩余抖动时间
var _total := 0.0      # 本次抖动的总时长（用来算衰减）
var _strength := 0.0


func _ready() -> void:
	offset = Vector2.ZERO
	rotation = 0.0
	_fit_zoom()


## 把视野收进"窗口减去留白"的范围。**必须等比**：两轴各算各的会把画面拉伸。
## 取更严的那一轴 —— 短边的余量本来就少，这样两轴的余量都 ≥ reserve_px。
func _fit_zoom() -> void:
	var vp := get_viewport_rect().size
	var margin := reserve_px * 2.0
	if margin <= 0.0 or vp.x <= margin or vp.y <= margin:
		return # 留白大到吃掉整个窗口：不缩放，免得算出 0 或负数
	var z := maxf(vp.x / (vp.x - margin), vp.y / (vp.y - margin))
	zoom = Vector2(z, z)


func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if reserve_px < destructive_strength:
		out.append("抖动留白 reserve_px(%.0f) 小于毁灭级幅度 destructive_strength(%.0f)：毁灭级抖动会露出画面外的空白。把 reserve_px 提到 %.0f，或把幅度调小。"
				% [reserve_px, destructive_strength, destructive_strength])
	return out


func _process(delta: float) -> void:
	if _left <= 0.0:
		if offset != Vector2.ZERO or rotation != 0.0:
			offset = Vector2.ZERO
			rotation = 0.0
		return

	_left -= delta
	# 衰减曲线：用平方，前段猛、后段收得快
	var t: float = clampf(_left / maxf(_total, 0.001), 0.0, 1.0)
	var amp: float = _strength * t * t

	# 每帧重新取样，得到"抖"而不是"晃"
	offset = Vector2(randf_range(-amp, amp), randf_range(-amp, amp))
	rotation = deg_to_rad(randf_range(-1.0, 1.0) * max_roll_deg * t)


## 触发抖动。已经在抖且新的更猛时会**接管**；更弱的不会打断它。
func shake(level: int) -> void:
	var s := mild_strength
	var d := mild_sec
	match level:
		Level.SEVERE:
			s = severe_strength
			d = severe_sec
		Level.DESTRUCTIVE:
			s = destructive_strength
			d = destructive_sec
	if _left > 0.0 and s <= _strength:
		return # 正在抖得更猛，别打断
	_strength = s
	_total = d
	_left = d


## 按**打出的伤害量**自动选档。伤害落地的那一刻调它（见 `game_flow.gd` 的
## `_shake_for_damage`）。想要固定档位就直接调 `shake()`。
func shake_for_damage(amount: int) -> void:
	if amount <= 0:
		return
	if amount >= destructive_at:
		shake(Level.DESTRUCTIVE)
	elif amount >= severe_at:
		shake(Level.SEVERE)
	else:
		shake(Level.MILD)


## 立刻停下，画面归位。重置时用 —— 不留半截抖动给新一局。
func stop() -> void:
	_left = 0.0
	_total = 0.0
	_strength = 0.0
	offset = Vector2.ZERO
	rotation = 0.0


## 还在抖吗。阶段机靠它决定要不要放行。
## 抖动是纯表现，不影响任何规则状态 —— 所以这里用真随机不会破坏确定性。
func is_shaking() -> bool:
	return _left > 0.0
