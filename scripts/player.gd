extends RigidBody2D

## 四面墙围出的棋盘区域（世界坐标）：左 161 / 右 621 / 上 61 / 下 401
@export var table_rect: Rect2 = Rect2(161, 61, 460, 340)

## 这枚棋子属于哪一方。`0` = 我方，`1` = 敌方。
## 它决定伤害的最终去向（薄弱点的溢出打到哪一边），也决定能不能被选中。
##
## 原先是 `controllable` 一个布尔同时管"这枚是谁的"和"我能不能操作它"——
## 两件事混在一起，二期接入人类对手时"敌方是另一个玩家"就无处安放（见 20-character PRD）。
@export var owner_id: int = 0

@export_group("角色数值（占位值，等数值设计）")
## 角色还是召唤物。角色不可摧毁；召唤物血量归零即从棋盘移除。
enum Kind { CHARACTER, SUMMON }
@export var kind: Kind = Kind.CHARACTER

## 角色类型。克制三角：护卫 > 斗士 > 施法者 > 护卫，克制方向伤害翻倍。
## 召唤物是 NONE（无属性），既不触发克制也不被克制。
enum RoleType { NONE, PROTECTOR, FIGHTER, CASTER }
@export var role_type: RoleType = RoleType.FIGHTER

## 攻击力。伤害 = 攻击方 atk（碰撞速度不参与，见 20-character PRD 的伤害公式）
@export_range(0, 200, 1) var atk: int = 10

@export_group("动画")
## 一次性状态各停留多久（秒）。这些都只是"播完这个再回到 idle/walk"的时长，
## 由用户在编辑器里对着手感调。
@export var attack_hold_sec: float = 0.8
@export var hit_hold_sec: float = 0.4
@export var zoc_hold_sec: float = 1.4
## 发射后弩机在场上停留多久（秒）。只影响"激发"的表现，不影响物理。
@export var fire_hold_sec: float = 0.08

## 控制域半径（像素）。以棋子中心为圆心的圆；"罩住目标" = 目标中心落在这个圆内。
## 角色和召唤物**一视同仁**（召唤物也有控制域，2026-10-12 决定）。
## 60 是占位值（棋子半径 16 的约 3.75 倍），由用户在编辑器里试出手感。
@export_range(0.0, 200.0, 5.0) var zoc_radius: float = 60.0

## 最大血量。血量降到 0 即成为**薄弱点**：不退场、仍全功能可用，
## 但此后受到的伤害全额转移给归属方。
@export var max_hp: int = 70

## 当前血量，运行时变化，下限 0
var hp: int = 0

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

@export_group("蓄力（拉距）")
## 蓄力上限，避免无限蓄力。mass = 1 时数值≈发射后球的速度（px/s）
@export_range(1.0, 5000.0, 10.0) var max_charge: float = 600.0
## 拉距上限（像素）：鼠标离棋子超过这个距离，蓄力封顶。
## 大圈半径也由它决定，所以它是**输入尺度**，不是美术尺寸。
##
## 75 是当前 720×480 窗口下的上限：棋子贴顶墙时中心到窗口顶边只有 77 px，
## 再大就会出现「某些方向拉不满圈边」。改窗口/相机规格时再统一调。
@export_range(10.0, 300.0, 1.0) var max_pull_radius: float = 75.0
## 弓臂随拉距向内弯的最大角度（度）。只影响表现；负值可以翻转弯曲方向。
@export var limb_flex_deg: float = 5.0
## 蓄力线颜色（正红）
@export var charge_color: Color = Color(1, 0, 0, 1)
## 蓄力线比 AimLine 场景基准宽度加粗的倍数
@export var charge_width_scale: float = 2.5
## 蓄力条最多反弹几次。兜底：夹角极小时段长会趋近 0，不给上限可能画很久
@export_range(1, 128, 1) var max_bounces: int = 32

@export_group("静止判定")
## 速度低于这个值就算静止，恢复画线
@export var rest_speed: float = 10.0
## 兜底：球一直不停时最多锁这么久（0 = 不设上限）
@export var max_lock_time: float = 6.0

@export_group("贴图倾斜（不倒翁）")
## 每 1 rad/s 自转对应多少弧度倾斜。
## 0.40 是实测扫出来的：一次像样的偏心碰撞自转峰值 5.29 rad/s，
## 撞完到贴图跟上要几帧、期间自转已在按 1.0/s 衰减，各档实测倾斜峰值：
## 0.30 -> 74.8°，0.40 -> 88.9°，0.50 -> 89.9°，0.70 -> 90.0°（顶到上限）
@export var tilt_per_spin: float = 0.40
## 最大倾斜角度。90 = 贴图可以躺平
@export_range(0.0, 90.0, 1.0) var max_tilt_deg: float = 90.0
## 倾斜跟随 / 回正的速度：越大回正越快
@export_range(1.0, 60.0, 1.0) var tilt_stiffness: float = 14.0
## 贴图左右翻转跟随前进方向（角色贴图默认面朝右）。
## mob.tscn 的贴图节点带 -90° 基准旋转，朝向语义与棋子不同，必要时在那边关掉
@export var flip_to_facing: bool = true
## 翻转死区：|水平速度| 小于它就不改朝向，免得接近静止时来回翻
@export_range(0.0, 100.0, 1.0) var facing_deadzone: float = 10.0

var selected := false          # 是否被 TurnController 选中（全盘至多一枚为 true）
var charge := 0.0              # 当前蓄力值（发射速度，px/s）
var aiming := false            # 是否显示瞄准表现（调整/就绪/角度三态）
var aim_angle_live := false    # 鼠标是否在改方向
var aim_charge_live := false   # 鼠标是否在改力度
## 角度语义：false = 弹弓反向（鼠标在扳机端，ADJUST）；true = 直接指向鼠标（ANGLE）。
var aim_point_mode := false
var pull_ratio := 0.0          # 拉距 / max_pull_radius，0..1（弩机表现直接用这个）
var locked := false            # 球还在运动：禁止选中/蓄力
var lock_armed := false        # 冲量生效、速度真的起来后才置 true
var lock_time := 0.0
var tilt := 0.0                # 贴图当前倾斜（弧度），0 = 正朝上
var facing_right := true       # 贴图当前朝向：角色贴图默认面朝右

## 动画状态。棋子只"报告"自己处于什么状态，播哪个动画由这张表决定。
enum Anim { IDLE, WALK, ATTACK, BE_HIT, ZOC }
## AnimatedSprite2D 里的动画名。**在编辑器里改名的话只改这里一处。**
const ANIM_NAMES := {
	Anim.IDLE: &"idle",
	Anim.WALK: &"walk",
	Anim.ATTACK: &"attack",
	Anim.BE_HIT: &"be_hit",
	Anim.ZOC: &"zoc",
}
var _anim_override := -1       # 一次性状态（-1 = 没有，按"动没动"决定）
var _anim_left := 0.0
var _anim_current := -1
var _anim_warned := {}         # 已经警告过的缺失动画名，避免每帧刷屏

## 开局快照。ResetButton 靠它把棋子"恢复如初"——
## **在 _ready 里存**，所以你在编辑器里摆的位置/数值就是"初始"。
var home_position := Vector2.ZERO
var home_rotation := 0.0
var home_atk := 0
var aim_dir := Vector2.UP      # 发射方向（单位向量）。鼠标压在棋子中心时保留上一次的值

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var aura_material: ShaderMaterial = sprite.material as ShaderMaterial
@onready var body_radius: float = _read_body_radius() # 预测路径要在棋盘内缩一个半径
## 撞墙的**有效**弹性：把球和墙两边的 bounce 都读出来，按 Godot 自己的规则合并。
@onready var wall_bounce: float = _effective_bounce()
@onready var sprite_base_rotation: float = sprite.rotation # 场景里设的基准朝向（Mob 被覆盖成 -90°）
@onready var sprite_base_position: Vector2 = sprite.position
@onready var max_tilt: float = deg_to_rad(max_tilt_deg)
@onready var line_2d := get_node_or_null("../AimLine") as Line2D
@onready var idle_width: float = line_2d.width if line_2d != null else 1.0

## 瞄准表现节点。**mob.tscn 没有这些节点**（它挂同一个脚本），
## 所以全部用 get_node_or_null：缺席时静默跳过，不能报错。
@onready var charge_ring := get_node_or_null("ChargeRing") as Line2D
@onready var crossbow_pivot := get_node_or_null("CrossbowPivot") as Node2D
@onready var upper_limb := get_node_or_null("CrossbowPivot/UpperLimb") as Sprite2D
@onready var lower_limb := get_node_or_null("CrossbowPivot/LowerLimb") as Sprite2D
## 弓臂绕着它转的**贴图连接点**（Marker2D 子节点）。没有它时退化为绕节点原点转。
@onready var upper_pivot := get_node_or_null("CrossbowPivot/UpperLimb/UpperPivot") as Marker2D
@onready var lower_pivot := get_node_or_null("CrossbowPivot/LowerLimb/LowerPivot") as Marker2D
@onready var upper_tip := get_node_or_null("CrossbowPivot/UpperLimb/UpperTip") as Marker2D
@onready var lower_tip := get_node_or_null("CrossbowPivot/LowerLimb/LowerTip") as Marker2D
@onready var string_line := get_node_or_null("CrossbowPivot/String") as Line2D
@onready var bolt := get_node_or_null("CrossbowPivot/Bolt") as Sprite2D
@onready var nock := get_node_or_null("CrossbowPivot/Bolt/Nock") as Marker2D
@onready var bolt_rest := get_node_or_null("CrossbowPivot/BoltRest") as Marker2D
@onready var bolt_pulled := get_node_or_null("CrossbowPivot/BoltPulled") as Marker2D
## 编辑器里摆好的弩臂基准姿态。脚本只在它上面叠加 flex/补偿，不覆盖组装姿态。
var _upper_base_rotation := 0.0
var _lower_base_rotation := 0.0
var _upper_base_position := Vector2.ZERO
var _lower_base_position := Vector2.ZERO
## 发射"激发"表现：弩机在发射点多留 fire_hold_sec，然后隐藏。
var _firing := false
var _fire_left := 0.0

## 与**另一枚棋子**撞上了（撞四壁不算）。只上报事实，不判断要不要结算、更不自己扣血——
## 结算规则属于规则层（见 game_flow.gd 的 `_resolve_collision`）。
signal bumped(other: RigidBody2D)


func _ready() -> void:
	aim_dir = Vector2.UP
	_build_charge_ring()
	_cache_crossbow_base()
	_hide_aim_visuals()
	hp = max_hp
	home_position = global_position # 快照：编辑器里摆的位置就是"初始位置"
	home_rotation = rotation
	home_atk = atk
	add_to_group(&"pieces") # GameFlow 靠这个组找到全盘棋子
	# 撞到别的东西时上报。contact_monitor 已在 .tscn 里打开。
	body_entered.connect(_on_body_entered)
	_register_with_game_flow()


## 恢复如初：位置、自转、速度、血量、攻击力、朝向、动画、蓄力、选中、描边。
## 由 ResetButton 经 `GameFlow.reset_match()` 调用。
func reset_to_home() -> void:
	global_position = home_position
	rotation = home_rotation
	linear_velocity = Vector2.ZERO
	angular_velocity = 0.0
	scale = Vector2.ONE
	hp = max_hp
	atk = home_atk
	tilt = 0.0
	facing_right = true
	locked = false
	lock_armed = false
	lock_time = 0.0
	charge = 0.0
	pull_ratio = 0.0
	aiming = false
	aim_angle_live = false
	aim_charge_live = false
	aim_point_mode = false
	_firing = false
	_fire_left = 0.0
	selected = false
	aim_dir = Vector2.UP
	_anim_override = -1
	_anim_left = 0.0
	_anim_current = -1 # 让下一帧重新播 idle
	if sprite != null:
		sprite.flip_h = false
	if aura_material != null:
		aura_material.set_shader_parameter(&"aura_width", 0.0)
	_hide_aim_visuals()


## 碰撞回调：**只上报事实**。撞墙（StaticBody2D）直接过滤掉，
## 只有"撞到另一枚棋子"才算一次角色碰撞。
func _on_body_entered(body: Node) -> void:
	var other := body as RigidBody2D
	if other == null or other == self:
		return
	if not other.is_in_group(&"pieces"):
		return
	bumped.emit(other)


## 我打对方时的伤害倍率。
##
## ⚠️ **类型克制暂时屏蔽**（2026-10-10 决定，以后再实现）——现在恒为 1.0，
## 所以 `role_type` 目前对伤害**没有任何影响**。调用点保留着，重新启用时只改这一个函数。
##
## 以后再实现时的规则（保留在这里免得忘）：
##   护卫 > 斗士 > 施法者 > 护卫，克制方向伤害翻倍；
##   任一方是 NONE（召唤物）则不参与克制，恒为 1 倍。
func damage_multiplier_against(_other: RigidBody2D) -> float:
	return 1.0


func _exit_tree() -> void:
	# 被释放时从阶段机的名单里摘掉。召唤物会走这条路（角色永不退场）。
	var gf := get_tree().get_first_node_in_group(&"game_flow")
	if gf != null:
		gf.unregister_piece(self)


## 棋子就绪时向阶段机登记。阶段机在我们之前就已经从组里扫过一遍了，
## 这里是给**运行时新生成的**棋子（将来的召唤物）用的，加进名单才会被静止判定扫到。
func _register_with_game_flow() -> void:
	var gf := get_tree().get_first_node_in_group(&"game_flow")
	if gf != null:
		gf.register_piece(self)

func _process(delta: float) -> void:
	if _firing:
		_fire_left -= delta
		if _fire_left <= 0.0:
			_finish_fire_effect()

	if aiming:
		# 鼠标不按下也在持续取力/取角；出棋盘照常更新，硬边界是窗口。
		update_aim(get_global_mouse_position())
		_update_aim_visuals()

	if locked:
		lock_time += delta
		if linear_velocity.length() > rest_speed:
			lock_armed = true # 冲量要到下一个物理帧才生效，先等速度真的起来
		elif lock_armed or (max_lock_time > 0.0 and lock_time >= max_lock_time):
			locked = false

	_update_sprite_tilt(delta)
	_update_anim(delta)


# ---------- 动画状态 ----------
# 棋子只报告"我处于什么状态"，由 _update_anim 决定播哪个。
# 规则层（game_flow.gd）在结算时调用下面三个 play_*。

## 我攻击了（碰撞里我是撞人的那方，或 ZOC 里我参与了围攻）。
## 传 target 就把贴图**转向它** —— 攻击完不特意恢复（2026-10-12 用户要求）。
## 实际上攻击方在碰撞后是停住的（弹性交换），速度≈0 时朝向不会被改写，所以这个朝向会留住；
## 之后一旦移动起来，就由移动方向接管（见 `_update_sprite_tilt`）。
func play_attack(target: Node2D = null) -> void:
	if target != null:
		_face_towards(target)
	_set_anim(Anim.ATTACK, attack_hold_sec)


## 贴图转向某个目标。角色贴图只有左右两向，所以只做左右翻转、不旋转。
func _face_towards(target: Node2D) -> void:
	var dx: float = target.global_position.x - global_position.x
	if absf(dx) > 1.0:
		facing_right = dx > 0.0
		sprite.flip_h = not facing_right


## 我被打了
func play_be_hit() -> void:
	_set_anim(Anim.BE_HIT, hit_hold_sec)


## 我参与了 ZOC 检查
func play_zoc() -> void:
	_set_anim(Anim.ZOC, zoc_hold_sec)


## 某个动画播完要多久 —— **按你在编辑器里配的帧数和 speed 现算**，不写死常量。
## 改帧率/帧数时这里自动跟着走。贴图里没有该动画时返回 0。
func anim_duration(a: Anim) -> float:
	var frames := sprite.sprite_frames
	var n: StringName = ANIM_NAMES[a]
	if frames == null or not frames.has_animation(n):
		return 0.0
	var speed: float = frames.get_animation_speed(n)
	if speed <= 0.0:
		return 0.0
	return float(frames.get_frame_count(n)) / speed


## ZOC"检查"这一拍该停多久。取 zoc 动画自己的长度（7 帧 @ speed 5 = 1.4 秒）；
## 缺动画时给一个兜底值，免得表现为 0、玩家什么都看不到。
func zoc_windup_sec() -> float:
	return maxf(anim_duration(Anim.ZOC), 0.35)


## 碰撞冻结该冻多久。取 **attack** 动画自己的长度（2026-10-12 用户决定：只看行动角色的动画）。
## 缺动画时给兜底值，免得冻 0 秒、等于没冻。
func attack_windup_sec() -> float:
	return maxf(anim_duration(Anim.ATTACK), 0.2)


func _set_anim(a: int, hold_sec: float) -> void:
	_anim_override = a
	_anim_left = hold_sec


## 优先级：一次性状态（受击/攻击/ZOC）> 移动 > 静止。
## 用"当前值比对"避免每帧重复赋值（重复 play() 会把非循环动画一直重头播）。
func _update_anim(delta: float) -> void:
	if _anim_override >= 0:
		_anim_left -= delta
		if _anim_left <= 0.0:
			_anim_override = -1
	var want: int = _anim_override
	if want < 0:
		want = Anim.WALK if linear_velocity.length() > rest_speed else Anim.IDLE
	if want == _anim_current:
		return
	_anim_current = want
	_play_anim(ANIM_NAMES[want])


## 真正切动画。**贴图里没有这个动画时不报错**——只警告一次并点名，
## 免得还沿用旧 SpriteFrames 的棋子（比如还没配动画的 Mob）每帧刷屏。
func _play_anim(anim_name: StringName) -> void:
	var frames := sprite.sprite_frames
	if frames == null:
		return
	if not frames.has_animation(anim_name):
		if not _anim_warned.has(anim_name):
			_anim_warned[anim_name] = true
			push_warning("'%s' 的 AnimatedSprite2D 里没有动画 '%s' —— 需要在编辑器里给它配上" % [name, anim_name])
		return
	sprite.animation = anim_name
	sprite.play()

# ---------- 供 TurnController 调用的能力 ----------
# 棋子自己不解释鼠标事件：选中是排他的，裁决必须收在一个地方做
#（见 scripts/turn_controller.gd 的注释）。这里只暴露"能不能被点中"和"选中后能做什么"。

## 鼠标落点是否点中这枚棋子。
##
## 只管**几何**和"这枚球现在动没动"。归属过滤在选择层做（turn_controller.gd 的 `_pick`），
## 角色/召唤物的区别**不在这里**——召唤物也能被发射（2026-10-12 决定），
## 所以这里不为它开特例。设计原则：少给棋子类加约束，平衡用数值/技能/机制去调。
func hit_test(pos: Vector2) -> bool:
	return not locked and global_position.distance_to(pos) <= pick_radius

## 切换选中态。高亮开关就是切 aura_width：0 = 无描边。
func set_selected(on: bool) -> void:
	if selected == on:
		return
	selected = on
	if not on:
		end_aim() # 顺带清掉圈/弩机/瞄准线，否则取消选中后线上还留着上一笔
	if aura_material != null:
		aura_material.set_shader_parameter(&"aura_width", aura_width_selected if on else 0.0)

## 进入矢量调整（第一次点选棋子）。力度从 0 开始，方向沿用上一次。
func begin_aim() -> void:
	if not selected or locked:
		return
	aiming = true
	aim_angle_live = true
	aim_charge_live = true
	aim_point_mode = false # ADJUST：弹弓反向（鼠标在扳机端）
	charge = 0.0
	pull_ratio = 0.0
	_show_aim_visuals()


## 切换瞄准子态：angle_live = 鼠标改方向；charge_live = 鼠标改力度；
## point_mode = 角度语义（false 弹弓反向 / true 直接指向鼠标）。
## 就绪 = (false, false)；角度调整 = (true, false, true)；矢量调整 = (true, true, false)。
##
## **角度语义只在角度活着时更新**。就绪态冻结时保留上一次的模式，弩机的 180° 姿态
## 才不会在锁定时突然翻回来。
func set_aim_live(angle_live: bool, charge_live: bool, point_mode: bool = false) -> void:
	if not selected or locked:
		return
	aiming = true
	aim_angle_live = angle_live
	aim_charge_live = charge_live
	if angle_live:
		aim_point_mode = point_mode
	_show_aim_visuals()


## 用给定鼠标位置采样一次瞄准（世界坐标）。
## `_process` 每帧调用；TurnController 在「按下锁定」时也调用一次，
## 保证锁定用的是点击那一刻的位置，而不是上一帧的缓存。
func update_aim(mouse: Vector2) -> void:
	if not aiming:
		return
	if aim_angle_live:
		# ADJUST：弹弓反向（鼠标在扳机端）→ 发射方向 = 鼠标→棋子的反向延长线。
		# ANGLE ：直接瞄准 → 发射方向 = 棋子→鼠标的延长线。
		var dir := (mouse - global_position) if aim_point_mode else (global_position - mouse)
		if dir.length_squared() > 1.0:
			aim_dir = dir.normalized()
	if aim_charge_live:
		var d := clampf(global_position.distance_to(mouse), 0.0, max_pull_radius)
		pull_ratio = d / max_pull_radius
		charge = max_charge * pull_ratio


## 施加冲量并结束瞄准，返回是否真的发射了。
## **唯一发射出口**：玩家合并按钮和 bot 都走这里。
func release_charge() -> bool:
	var power := charge
	var dir := aim_dir if aim_dir != Vector2.ZERO else Vector2.UP
	# 玩家的弩机在发射点演一下"激发"；bot 没有瞄准表现，跳过。
	var show_fire := aiming and power > 0.0 \
			and crossbow_pivot != null and crossbow_pivot.visible
	if show_fire:
		_start_fire_effect()
	end_aim() # 先清表现，再施加冲量
	if power <= 0.0:
		return false # 零力度不发射，也不上锁

	apply_central_impulse(dir * power)
	locked = true # 静止前禁止再次选中/蓄力
	lock_armed = false
	lock_time = 0.0
	return true


## 结束瞄准表现（取消选中、发射、重置都走这里）。不动 locked ——
## 发射后的锁定归 _process 的静止判定管。
func end_aim() -> void:
	aiming = false
	aim_angle_live = false
	aim_charge_live = false
	aim_point_mode = false
	charge = 0.0
	pull_ratio = 0.0
	_hide_aim_visuals()


## 旧名字保留给外部调用；语义等同结束瞄准。
func cancel_charge() -> void:
	end_aim()

# ---------- 表现 ----------

## 瞄准表现的显隐与变换。节点全部走 get_node_or_null，mob 缺席时静默跳过。
func _show_aim_visuals() -> void:
	# 新的瞄准开始：取消还没播完的激发表现，避免它把新瞄准藏掉。
	_firing = false
	_fire_left = 0.0
	if bolt != null:
		bolt.centered = false # 每次出现都从默认形态开始
	if charge_ring != null:
		charge_ring.visible = true
	if crossbow_pivot != null:
		crossbow_pivot.visible = true
	_update_aim_visuals()


## 每帧刷新瞄准表现。这些都只是**表现**：真相是 `aim_dir` / `pull_ratio` / `charge`。
func _update_aim_visuals() -> void:
	if charge_ring != null:
		# 圈是 top_level 的，每帧对齐棋子；半径由生成时的 points 固定
		charge_ring.global_position = global_position

	if crossbow_pivot != null:
		crossbow_pivot.global_position = global_position
		# 弩机的美术正面在局部 -X，所以整机恒定 +180°，视觉正面才会沿 aim_dir
		#（引导线 / 发射方向）指。矢量调整和角度调整都适用。
		crossbow_pivot.global_rotation = aim_dir.angle() + PI
		_set_crossbow_pose(pull_ratio)

	_update_line()


## 把弩机摆到指定拉距（0..1）：弓臂旋转 + 位置补偿、箭后拉、弦的 V。
## 弓臂的位置补偿是必须的：Sprite2D 的贴图有 offset，直接 rotation 会绕节点原点
## 甩动整根弓臂（连接点会漂）。这里按 pivot marker 反算位置，把连接点钉住。
func _set_crossbow_pose(pull: float) -> void:
	var flex := deg_to_rad(limb_flex_deg) * pull
	_apply_limb_flex(upper_limb, upper_pivot,
			_upper_base_position, _upper_base_rotation, flex)
	_apply_limb_flex(lower_limb, lower_pivot,
			_lower_base_position, _lower_base_rotation, -flex)

	if bolt != null and bolt_rest != null and bolt_pulled != null:
		bolt.position = bolt_rest.position.lerp(bolt_pulled.position, pull)

	if string_line != null and upper_tip != null and nock != null and lower_tip != null:
		string_line.points = PackedVector2Array([
			string_line.to_local(upper_tip.global_position),
			string_line.to_local(nock.global_position),
			string_line.to_local(lower_tip.global_position),
		])


## 让弓臂绕 pivot marker 转 flex，同时反向平移节点，使连接点在父空间里不动。
func _apply_limb_flex(limb: Sprite2D, pivot: Marker2D,
		base_pos: Vector2, base_rot: float, flex: float) -> void:
	if limb == null:
		return
	var p := pivot.position if pivot != null else Vector2.ZERO
	limb.rotation = base_rot + flex
	limb.position = base_pos + p.rotated(base_rot) - p.rotated(base_rot + flex)


## 发射"激发"：在发射点保留弩机，弓臂归位、箭切到 centered=true，停 fire_hold_sec。
func _start_fire_effect() -> void:
	_firing = true
	_fire_left = fire_hold_sec


func _finish_fire_effect() -> void:
	_firing = false
	_fire_left = 0.0
	# 弓臂归位、箭回静止位、centered 恢复默认；弩机隐藏。下一发重新出现时是默认形态。
	_hide_aim_visuals()


## 藏掉瞄准表现并把弩机/箭恢复基准姿态。重置和取消选中都走这里。
## 发射的激发窗口内（_firing）**不藏弩机**：让玩家看到撞针杆被激发出去。
func _hide_aim_visuals() -> void:
	if charge_ring != null:
		charge_ring.visible = false
	if line_2d != null:
		line_2d.clear_points()
		line_2d.visible = false
	if crossbow_pivot == null:
		return

	_set_crossbow_pose(0.0)
	if _firing:
		crossbow_pivot.visible = true
		if bolt != null:
			bolt.centered = true # 激发形态；下次 _show/_finish 会恢复 false
	else:
		crossbow_pivot.visible = false
		if bolt != null:
			bolt.centered = false


## 画线：瞄准期间**只有一种线**——理想轨迹预测。
## 旧的分支（未蓄力时画"指向鼠标"的短线、蓄力时画轨迹）已随蓄能机制改版删除。
func _update_line() -> void:
	if not aiming or line_2d == null or locked:
		return
	line_2d.visible = true
	line_2d.default_color = charge_color
	line_2d.width = idle_width * charge_width_scale
	_set_points(_predict_path(global_position, aim_dir, charge))


## 按 max_pull_radius 生成大圈的线点。圈的半径只有一个真相来源：
## Player 的 `max_pull_radius`，**不是场景里 Line2D 的缩放**。
func _build_charge_ring() -> void:
	if charge_ring == null:
		return
	var n := 96
	var pts := PackedVector2Array()
	pts.resize(n)
	for i in n:
		var a := TAU * float(i) / float(n)
		pts[i] = Vector2(cos(a), sin(a)) * max_pull_radius
	charge_ring.points = pts


## 记录弓臂在编辑器里摆好的基准姿态，以及箭的静止位。
func _cache_crossbow_base() -> void:
	if upper_limb != null:
		_upper_base_rotation = upper_limb.rotation
		_upper_base_position = upper_limb.position
	if lower_limb != null:
		_lower_base_rotation = lower_limb.rotation
		_lower_base_position = lower_limb.position
	if bolt != null and bolt_rest != null:
		bolt.position = bolt_rest.position
	if bolt != null:
		bolt.centered = false


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
	# 贴图朝向：角色贴图默认面朝右，向左走时左右翻转，让它始终面朝前进方向（x 轴）。
	# 用死区而不是速度正负，避免接近静止时来回翻。
	if flip_to_facing:
		if linear_velocity.x > facing_deadzone:
			facing_right = true
		elif linear_velocity.x < -facing_deadzone:
			facing_right = false
		sprite.flip_h = not facing_right

	# 顺时针（angular_velocity > 0）向右倾，逆时针向左倾；角度上限由 max_tilt 夹住。
	# 倾斜方向不用随翻转取反：自转和前进方向本来就同源，翻转后依然是"朝前进方向倾"。
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
