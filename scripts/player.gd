extends RigidBody2D

## 四面墙围出的棋盘区域（世界坐标）：左 161 / 右 621 / 上 61 / 下 401
@export var table_rect: Rect2 = Rect2(161, 61, 460, 340)

## false = 不可操作的球（棋子 / 靶子）：不可被选中、不画瞄准线，但照样被撞着走
@export var controllable := true

@export_group("选择")
## 点选半径（世界坐标 px）：鼠标落在这个圆内就算点中这枚棋子。
## 略大于碰撞圆半径（16.03），点到贴图边缘也算命中。
@export_range(8.0, 64.0, 1.0) var pick_radius: float = 20.0
## 选中时的高亮描边宽度。单位是【贴图像素】，屏上厚度 = 该值 × AnimatedSprite2D 的 scale
##（本项目 scale = 0.3，所以 6.0 ≈ 屏上 1.8px）。设成 0 就是不显示高亮。
@export_range(0.0, 24.0, 0.5) var aura_width_selected: float = 6.0

@export_group("运动")
## 滚动阻力减速（px/s²）：停止时间 = v₀ / decel，滚动距离 = v₀² / (2 · decel)
@export_range(0.0, 2000.0, 10.0) var decel: float = 300.0

@export_group("蓄力")
## 蓄力上限，避免无限蓄力。mass = 1 时数值≈松开后球的速度（px/s）
@export_range(1.0, 5000.0, 10.0) var max_charge: float = 600.0
## 每秒蓄力值：600 / 300 = 2 秒蓄满。鼠标移出棋盘时暂停积蓄，回到盘内接着涨。
@export_range(1.0, 5000.0, 10.0) var charge_rate: float = 300.0
## 蓄力条颜色（正红）
@export var charge_color: Color = Color(1, 0, 0, 1)
## 蓄力条比指示线加粗的倍数
@export var charge_width_scale: float = 2.5
## 蓄力条最多反弹几次。兜底：夹角极小时段长会趋近 0，不给上限可能画很久
@export_range(1, 128, 1) var max_bounces: int = 32

@export_group("静止判定")
## 速度低于这个值就算静止，恢复画线
@export var rest_speed: float = 10.0
## 兜底：球一直不停时最多锁这么久（0 = 不设上限）
@export var max_lock_time: float = 6.0

@export_group("贴图倾斜（不倒翁）")
## 每 1 rad/s 自转对应多少弧度倾斜：越大倾得越明显
@export var tilt_per_spin: float = 0.06
## 最大倾斜角度
@export_range(0.0, 90.0, 1.0) var max_tilt_deg: float = 25.0
## 倾斜跟随 / 回正的速度：越大回正越快
@export_range(1.0, 60.0, 1.0) var tilt_stiffness: float = 14.0

var selected := false          # 是否被 TurnController 选中（全盘至多一枚为 true）
var charge := 0.0              # 当前蓄力值
var charging := false          # 是否正在蓄力（左键按住；鼠标出盘则暂停积蓄）
var locked := false            # 球还在运动：禁止选中/蓄力
var lock_armed := false        # 冲量生效、速度真的起来后才置 true
var lock_time := 0.0
var tilt := 0.0                # 贴图当前倾斜（弧度），0 = 正朝上
var aim_target := Vector2.ZERO # 瞄准终点（世界坐标），鼠标出界时保留上一次的值
var aim_dir := Vector2.ZERO    # 瞄准方向（单位向量），鼠标贴在棋子中心时保留上一次的值

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var aura_material: ShaderMaterial = sprite.material as ShaderMaterial
@onready var body_radius: float = _read_body_radius() # 预测路径要在棋盘内缩一个半径
## 撞墙的**有效**弹性：把球和墙两边的 bounce 都读出来，按 Godot 自己的规则合并。
@onready var wall_bounce: float = _effective_bounce()
@onready var sprite_base_rotation: float = sprite.rotation # 场景里设的基准朝向（Mob 被覆盖成 -90°）
@onready var sprite_base_position: Vector2 = sprite.position
@onready var max_tilt: float = deg_to_rad(max_tilt_deg)
@onready var line_2d := get_node_or_null("../AimLine") as Line2D
@onready var idle_color: Color = line_2d.default_color if line_2d != null else Color.WHITE
@onready var idle_width: float = line_2d.width if line_2d != null else 1.0

func _ready() -> void:
	aim_target = global_position
	add_to_group(&"pieces") # TurnController 靠这个组找到全盘可选的棋子

func _process(delta: float) -> void:
	var mouse := get_global_mouse_position()
	var in_board := table_rect.has_point(mouse)

	if charging:
		# 只在鼠标位于盘内时积蓄；移出盘外就停住（不涨也不退），回到盘内接着涨。
		if in_board:
			charge = minf(charge + charge_rate * delta, max_charge)

	if locked:
		lock_time += delta
		if linear_velocity.length() > rest_speed:
			lock_armed = true # 冲量要到下一个物理帧才生效，先等速度真的起来
		elif lock_armed or (max_lock_time > 0.0 and lock_time >= max_lock_time):
			locked = false

	_update_line(mouse, in_board)
	_update_sprite_tilt(delta)

# ---------- 供 TurnController 调用的能力 ----------
# 棋子自己不解释鼠标事件：选中是排他的，裁决必须收在一个地方做
#（见 scripts/turn_controller.gd 的注释）。这里只暴露"能不能被点中"和"选中后能做什么"。

## 鼠标落点是否点中这枚棋子。
func hit_test(pos: Vector2) -> bool:
	return controllable and not locked and global_position.distance_to(pos) <= pick_radius

## 切换选中态。高亮开关就是切 aura_width：0 = 无描边。
func set_selected(on: bool) -> void:
	if selected == on:
		return
	selected = on
	if not on:
		cancel_charge() # 顺带清掉瞄准线，否则取消选中后线上还留着上一笔
	if aura_material != null:
		aura_material.set_shader_parameter(&"aura_width", aura_width_selected if on else 0.0)

## 开始蓄力。只在已选中时生效。at = 按下左键时鼠标所在的棋盘坐标
##（由 TurnController 传入，不再自己去读全局鼠标：点击位置只有一个来源）。
func begin_charge(at: Vector2) -> void:
	if not selected or charging or locked:
		return
	if not table_rect.has_point(at):
		return # 鼠标在棋盘外：不开始蓄力
	charging = true
	charge = 0.0
	aim_target = at

## 松开左键：施加冲量，返回是否真的发射了。
## 蓄力值不足时返回 false，调用方据此决定要不要交还选择权。
func release_charge() -> bool:
	if not charging:
		return false
	charging = false
	var power := charge
	charge = 0.0

	if line_2d != null:
		line_2d.clear_points() # 1. 先清空线条（不可操作的球没有瞄准线）

	if power <= 0.0:
		return false # 空点不发射，也不上锁

	# 2. 球开始运动。方向用 aim_dir 而不是现算 (aim_target - global_position)：
	#    必须和蓄力条画出来的是同一个方向，否则鼠标压在球心上时两者会分叉
	#   （条子指着上一次的方向，冲量却算出个零向量，球原地锁死）。
	var dir := aim_dir if aim_dir != Vector2.ZERO else Vector2.UP
	apply_central_impulse(dir * power)

	locked = true # 3. 静止前禁止再次选中/蓄力
	lock_armed = false
	lock_time = 0.0
	return true

## 清掉蓄力值和瞄准线。不动 locked —— 发射后的锁定归 _process 的静止判定管。
func cancel_charge() -> void:
	charging = false
	charge = 0.0
	if line_2d != null:
		line_2d.clear_points()

# ---------- 表现 ----------

## 画线：把"画什么"收在一个地方按状态分支，
## 指示线和蓄力条就不会各写一份 points 互相覆盖。
func _update_line(mouse: Vector2, in_board: bool) -> void:
	# 不可操作的球没有瞄准线；没被选中的棋子也不画（全盘只有一枚在写这条共享线）；
	# 球还在动时同样不画
	if not controllable or not selected or line_2d == null or locked:
		return
	if in_board:
		aim_target = mouse # 只在盘内更新方向，出界保持上一次
	# 鼠标正好压在棋子中心时方向无定义，保留上一次的方向，别让蓄力条缩成一个点
	var to_mouse := aim_target - global_position
	if to_mouse.length_squared() > 1.0:
		aim_dir = to_mouse.normalized()

	if charging:
		# 蓄力条 = 理想轨迹预测：从棋子出发沿 aim_dir 走，撞到棋盘边就完全反射，
		# 一直画到总路程用尽。不预测与其他棋子的碰撞（那是打出去才知道的事）。
		line_2d.default_color = charge_color
		line_2d.width = idle_width * charge_width_scale
		_set_points(_predict_path(global_position, aim_dir, charge))
	else:
		# 未蓄力时是"指向鼠标"的指示线，长度自然跟着鼠标走
		line_2d.default_color = idle_color
		line_2d.width = idle_width
		_set_points(PackedVector2Array([global_position, aim_target]))


## 理想轨迹 = 把球按真实物理推一遍，只是不算其他棋子。
##
## 每一段都跟物理引擎正在做的事对齐：
##   1. 恒定减速 decel —— _integrate_forces 每帧施加的就是这个
##   2. 撞墙按 wall_bounce 掉速度 —— PhysicsMaterial.bounce 在做的同一件事
## 于是"条子画到哪"和"球停到哪"用的是同一组参数、同一条运动方程：
## 调 decel 或 bounce，真实运动和预测同时跟着变，不需要改两处逻辑。
##
## 为什么不能真的共用一份代码：真实运动是引擎的接触求解器驱动的，预测是解析算的，
## 没法共享同一个积分循环。能共用、也真正共用了的是参数与运动方程。
## 残留差别只有离散误差 —— 物理逐帧积分，实测总比预测多走 1~3%。
##
## 前提：四壁必须无摩擦（main.tscn 的 PhysicsMaterial_6strp 设了 friction = 0）。
## 有摩擦时，斜着撞墙会把一部分平动转成自转，入射角 ≠ 反射角，条子就会高估。
## 实测（四壁 friction=1，斜射）：偏差 -7% ~ -22%；改成 0 之后收敛到 ±3%。
## 只归零四壁即可 —— 棋子之间保留摩擦，球球碰撞照样产生自转（不倒翁倾斜的来源）。
##
## 已知不适用：贴着墙角发射。引擎在角上是两个接触点联立求解，
## 和这里逐面依次镜像反射不是一回事，偏差可以很大。
##
## 返回世界坐标的点列表：起点 + 每个反弹点 + 终点。
func _predict_path(start: Vector2, dir: Vector2, v0: float) -> PackedVector2Array:
	var pts := PackedVector2Array([start])
	if v0 <= 0.0 or dir == Vector2.ZERO:
		return pts

	# 内缩一个球半径：球是圆心撞墙的，不是贴图边缘撞墙
	var bounds := table_rect.grow(-body_radius)
	var pos := start.clamp(bounds.position, bounds.end) # 被挤在墙角时把起点拉回合法区域
	var d := dir
	var speed := v0
	var bounces := 0

	while bounces < max_bounces:
		# 分别算沿 x / y 走多远撞墙，取先到的那个
		var tx := INF
		var ty := INF
		if d.x > 0.0:
			tx = (bounds.end.x - pos.x) / d.x
		elif d.x < 0.0:
			tx = (bounds.position.x - pos.x) / d.x
		if d.y > 0.0:
			ty = (bounds.end.y - pos.y) / d.y
		elif d.y < 0.0:
			ty = (bounds.position.y - pos.y) / d.y
		var t: float = minf(tx, ty)

		# 现有速度够不够走到墙？不够就停在半路 —— 那就是球真正停下的地方
		var stop_distance := _stop_distance(speed)
		if stop_distance <= t:
			pts.append(pos + d * stop_distance)
			return pts

		# 撞墙：先把速度耗在路程上，再乘一次弹性，然后反射
		pos += d * t
		speed = _speed_after(t, speed)
		pts.append(pos)
		if speed * wall_bounce <= rest_speed:
			return pts # 撞完基本没速度了，画到这里为止
		speed *= wall_bounce
		# 撞哪面就翻哪个分量；正好撞在角上（tx == ty）两个都翻
		if tx <= ty:
			d.x = -d.x
		if ty <= tx:
			d.y = -d.y
		bounces += 1

	return pts # 反弹次数用尽（夹角极小时才可能），画到哪算哪


## 速度 v 在恒定减速下还能滚多远：v² / (2·decel)。
## decel = 0 时永远滚下去，返回 INF，交给 _predict_path 的反弹次数上限兜底。
func _stop_distance(v: float) -> float:
	if decel <= 0.0:
		return INF
	return v * v / (2.0 * decel)


## 滚过 d 距离之后还剩多少速度：v² = v₀² - 2·decel·d
func _speed_after(d: float, v: float) -> float:
	if decel <= 0.0:
		return v
	var sq := v * v - 2.0 * decel * d
	return 0.0 if sq <= 0.0 else sqrt(sq)


## 撞墙的有效弹性。Godot 的 2D 弹性是把**两边相加再夹到 1**
##（godot_body_pair_2d.cpp 的 combine_bounce；实测确认：0.8+0.0→0.8，0.8+0.8→1.0 完全弹性，
##  不是取最大值）。这里照同一条规则把两个材质合起来，所以预测和物理读到的是同一个数，
## 调任何一个材质，真实运动和蓄力条同时跟着变。
func _effective_bounce() -> float:
	var ball := 0.0
	if physics_material_override != null:
		ball = physics_material_override.bounce
	var wall := 0.0
	var board := get_parent() as StaticBody2D
	if board != null and board.physics_material_override != null:
		wall = board.physics_material_override.bounce
	return clampf(ball + wall, 0.0, 1.0)


func _set_points(world_points: PackedVector2Array) -> void:
	var local := PackedVector2Array()
	local.resize(world_points.size())
	for i in world_points.size():
		local[i] = line_2d.to_local(world_points[i])
	line_2d.points = local


## 读碰撞圆半径。球是圆心撞墙的，所以预测路径要把棋盘内缩这么多。
## 从碰撞形状现读而不是另开一个导出变量：墙在哪、球多大只该有一个出处。
func _read_body_radius() -> float:
	var node := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if node != null and node.shape is CircleShape2D:
		return (node.shape as CircleShape2D).radius
	return 0.0

## 不倒翁贴图：抵消刚体的自转，只按"自转趋势"左右倾斜，转停了自己回正朝上。
## 刚体照样在物理世界里转（碰撞/摩擦需要），只是视觉上不让它跟着翻。
func _update_sprite_tilt(delta: float) -> void:
	# 顺时针（angular_velocity > 0）向右倾，逆时针向左倾；角度上限由 max_tilt 夹住
	var target := clampf(angular_velocity * tilt_per_spin, -max_tilt, max_tilt)
	# 指数平滑：帧率无关，且自带"回正时略有惯性"的不倒翁感
	tilt = lerpf(tilt, target, 1.0 - exp(-tilt_stiffness * delta))

	sprite.rotation = sprite_base_rotation - rotation + tilt
	# 位置偏移也要抵消父节点旋转，否则贴图会绕着球心画一个 4px 的圈
	sprite.position = sprite_base_position.rotated(-rotation)

func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	# 恒定减速（滚动阻力）：与速度无关，减到 0 就精确停住，不像阻尼那样留一条长尾
	var velocity := state.linear_velocity
	var speed := velocity.length()
	if speed > 0.0:
		var drop := decel * state.step
		state.linear_velocity = Vector2.ZERO if drop >= speed else velocity - velocity / speed * drop
