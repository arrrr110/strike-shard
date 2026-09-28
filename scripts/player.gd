extends RigidBody2D

## 四面墙围出的棋盘区域（世界坐标）：左 161 / 右 621 / 上 61 / 下 401
@export var table_rect: Rect2 = Rect2(161, 61, 460, 340)

## false = 不可操作的球（棋子 / 靶子）：不接受输入、不画瞄准线，但照样被撞着走
@export var controllable := true

@export_group("运动")
## 滚动阻力减速（px/s²）：停止时间 = v₀ / decel，滚动距离 = v₀² / (2 · decel)
@export_range(0.0, 2000.0, 10.0) var decel: float = 300.0

@export_group("蓄力")
## 蓄力上限，避免无限蓄力。mass = 1 时数值≈松开后球的速度（px/s）
@export_range(1.0, 5000.0, 10.0) var max_charge: float = 600.0
## 每秒蓄力值：600 / 600 = 1 秒蓄满
@export_range(1.0, 5000.0, 10.0) var charge_rate: float = 600.0
## 蓄力条颜色（正红）
@export var charge_color: Color = Color(1, 0, 0, 1)
## 蓄力条比指示线加粗的倍数
@export var charge_width_scale: float = 2.5

@export_group("静止判定")
## 速度低于这个值就算静止，恢复画线
@export var rest_speed: float = 10.0
## 兜底：球一直不停时最多锁这么久（0 = 不设上限）
@export var max_lock_time: float = 6.0

var thrust = Vector2(0, -250)
var torque = 20000

var charge := 0.0              # 当前蓄力值
var charging := false          # 是否正在蓄力（左键按住且鼠标在盘内）
var locked := false            # 球还在运动：禁止画线
var lock_armed := false        # 冲量生效、速度真的起来后才置 true
var lock_time := 0.0
var aim_target := Vector2.ZERO # 瞄准终点（世界坐标），鼠标出界时保留上一次的值

@onready var line_2d := get_node_or_null("../AimLine") as Line2D
@onready var idle_color: Color = line_2d.default_color if line_2d != null else Color.WHITE
@onready var idle_width: float = line_2d.width if line_2d != null else 1.0

func _ready() -> void:
	aim_target = global_position

func _process(delta: float) -> void:
	if charging:
		charge = minf(charge + charge_rate * delta, max_charge)

	if locked:
		lock_time += delta
		if linear_velocity.length() > rest_speed:
			lock_armed = true # 冲量要到下一个物理帧才生效，先等速度真的起来
		elif lock_armed or (max_lock_time > 0.0 and lock_time >= max_lock_time):
			locked = false

	_update_line()

func _input(event: InputEvent) -> void:
	if not controllable:
		return # 不可操作的球完全不接受输入
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_start_charge()
		else:
			_release_charge()

func _start_charge() -> void:
	if charging or locked:
		return
	var mouse := get_global_mouse_position()
	if not table_rect.has_point(mouse):
		return # 鼠标在棋盘外：不开始蓄力
	charging = true
	charge = 0.0
	aim_target = mouse

func _release_charge() -> void:
	if not charging:
		return
	charging = false
	var power := charge
	charge = 0.0

	if line_2d != null:
		line_2d.clear_points() # 1. 先清空线条（不可操作的球没有瞄准线）

	if power > 0.0: # 2. 球开始运动
		var dir := (aim_target - global_position).normalized()
		apply_central_impulse(dir * power)

	locked = true # 3. 静止前禁止再次绘制
	lock_armed = false
	lock_time = 0.0

## 画线：把"画什么"收在一个地方按状态分支，
## 指示线和蓄力条就不会各写一份 points 互相覆盖。
func _update_line() -> void:
	# 不可操作的球没有瞄准线；球还在动时也不画
	if not controllable or line_2d == null or locked:
		return
	var mouse := get_global_mouse_position()
	if table_rect.has_point(mouse):
		aim_target = mouse # 只在盘内更新方向，出界保持上一次
	if charging:
		line_2d.default_color = charge_color
		line_2d.width = idle_width * charge_width_scale
		_set_line(global_position.lerp(aim_target, clampf(charge / max_charge, 0.0, 1.0)))
	else:
		line_2d.default_color = idle_color
		line_2d.width = idle_width
		_set_line(aim_target)

func _set_line(end: Vector2) -> void:
	line_2d.points = PackedVector2Array([
		line_2d.to_local(global_position),
		line_2d.to_local(end),
	])

func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	# 恒定减速（滚动阻力）：与速度无关，减到 0 就精确停住，不像阻尼那样留一条长尾
	var velocity := state.linear_velocity
	var speed := velocity.length()
	if speed > 0.0:
		var drop := decel * state.step
		state.linear_velocity = Vector2.ZERO if drop >= speed else velocity - velocity / speed * drop

	if controllable: # 只有玩家球读输入；不可操作的球只受物理驱动
		if Input.is_action_pressed("ui_up"):
			state.apply_force(thrust.rotated(rotation))
		else:
			state.apply_force(Vector2())
		var rotation_direction = 0
		if Input.is_action_pressed("ui_right"):
			rotation_direction += 1
		if Input.is_action_pressed("ui_left"):
			rotation_direction -= 1
		state.apply_torque(rotation_direction * torque)
