extends SceneTree

## 机制回归探针：把"发射 → 碰撞 → 冻结 → 伤害 → 抖动 → ZOC → 收尾"整条链跑一遍，
## 顺带检查 UI 接线。**这是这个项目唯一一个不依赖 Agent 的机制验证** ——
## 你或任何 Agent 改完 `scripts/` 之后跑 `bash tools/verify.sh`，看它输出「0 项失败」。
##
## 两条设计纪律：
##   · **不依赖棋盘摆法**：探针自己把棋子摆到固定跑道（见 `probe_lib.gd`），
##     所以你在编辑器里重排棋盘不会让它误报。
##   · **不写死数值**：蓄力由 `charge_to_reach()` 按棋子自己的 `decel` 现算，
##     阈值改了探针自动跟着走。
##
## 判据不看速度快照（那一帧取样会骗人），看真凭实据：
## 冻结 = 速度不为零、位置却一动不动；伤害 = 敌方血量真的掉了。
##
## 跑法：`bash tools/verify.sh`（它负责拷副本、找 Godot、传退出码）

const Lib = preload("probe_lib.gd")

const MAIN := "res://sences/main.tscn"
## 希望行动角色撞上目标时还剩多少速度。取 200 是为了让目标撞上后滚得短、
## 不会接着撞到顶壁折返（那会多出一次碰撞，虽然断言仍然成立，但结论不好读）。
const ARRIVE_SPEED := 200.0

enum St { SETTLE, BOOT, LAYOUT, WAIT_TURN, LAUNCHED, BUTTONS, ENEMY_TURN, RESET, DONE }

var _scene: Node = null
var _flow: Node = null
var _camera: Camera2D = null
var _turn: Node = null
var _actor: RigidBody2D = null
var _target: RigidBody2D = null

var _now := 0.0
var _f := 0
var _state: St = St.SETTLE
var _state_at := 0.0
var _fails: Array[String] = []
var _skips: Array[String] = []

# 观察到的
var _prev_frozen := false
var _freeze_at := -1.0
var _thaw_at := -1.0
var _freeze_dead_frames := 0
var _freeze_drift := 0.0          # 冻结生效**之后**的最大位移
var _freeze_speed_seen := false   # 冻着却有速度 —— 证明物理真被停，不是本来就没动
var _hp_before: Dictionary = {}
var _damaged: Array[String] = []
var _shake_events: Array = []
var _shaking := false
var _shake_at := -1.0
var _phase_flips_during_shake := 0
var _last_phase := -1
var _resumed_at := -1.0
var _target_pos_prev := Vector2.ZERO

# 敌方回合（bot）
var _saw_enemy_turn := false
var _enemy_pos_before: Dictionary = {}
var _enemy_moved := 0.0


func _initialize() -> void:
	_scene = load(MAIN).instantiate()
	root.add_child(_scene)
	_flow = _scene.get_node("GameFlow")
	_camera = _scene.get_node("ShakeCamera")
	_turn = _scene.get_node("TurnController")
	print("== 机制回归探针 ==")


func _check(ok: bool, what: String) -> void:
	print(("  [ok]   " if ok else "  [FAIL] ") + what)
	if not ok:
		_fails.append(what)


func _skip(what: String) -> void:
	print("  [skip] " + what)
	_skips.append(what)


func _process(delta: float) -> bool:
	_now += delta
	_f += 1
	if _f < 3:
		return false # 等 _ready 全部跑完

	match _state:
		St.SETTLE:
			_boot()
		St.LAYOUT:
			_layout()
		St.WAIT_TURN:
			_wait_turn()
		St.LAUNCHED:
			_observe()
		St.BUTTONS:
			_buttons()
		St.ENEMY_TURN:
			_enemy_turn()
		St.RESET:
			_reset()
		St.DONE:
			return true
	return _now > 60.0 and _give_up()


# ---------- 各阶段 ----------

func _boot() -> void:
	print("\n-- 开机 --")
	var label := _scene.get_node_or_null("UI/OwnerHp") as Label
	var phase_label := _flow.get("_phase_label") as Label
	_check(_camera != null, "ShakeCamera 在场景里")
	if _camera != null:
		_check(_camera.zoom.x > 1.0,
				"相机视野比窗口小（zoom = %.4f，留白 %.1f px）"
				% [_camera.zoom.x, (480.0 - 480.0 / _camera.zoom.y) * 0.5])
		_check(_camera.reserve_px >= _camera.destructive_strength,
				"抖动留白 %.0f ≥ 毁灭级幅度 %.0f"
				% [_camera.reserve_px, _camera.destructive_strength])
	_check(_flow != null, "GameFlow 在场景里")
	_check(label != null and label.text.contains("/"),
			"归属方血量标签有字（%s）" % ("—" if label == null else label.text.replace("\n", " ｜ ")))
	_check(phase_label != null and phase_label.text != "",
			"阶段名标签接通了（%s）" % ("—" if phase_label == null else phase_label.text))
	_check(_flow.get("_end_turn_button") != null, "结束回合按钮接通了")
	_check(_flow.get("_reset_button") != null, "重置按钮接通了")
	for pair in [["UI/WorldPositionLabel", "调试坐标标签 A"], ["UI/PlayerPositionLabel", "调试坐标标签 B"]]:
		_check(_scene.get_node_or_null(pair[0]) != null, pair[1] + " 在 UI 层")
	_goto(St.LAYOUT)


func _layout() -> void:
	print("\n-- 摆跑道 --")
	var lane := Lib.setup_lane(self)
	if lane.is_empty():
		_fails.append("场景里缺我方或敌方棋子，探针没法起跑")
		_report()
		return
	_actor = lane[0]
	_target = lane[1]
	_target_pos_prev = _target.global_position
	print("  行动角色 %s @ %s → 目标 %s @ %s"
			% [_actor.name, str(_actor.global_position.round()),
			   _target.name, str(_target.global_position.round())])
	_goto(St.WAIT_TURN)


func _wait_turn() -> void:
	if not Lib.all_at_rest(get_nodes_in_group(Lib.PIECES_GROUP)):
		_state_at = _now # 还没停稳，重新计时
		return
	if _flow.phase != 1: # PLAYER_TURN
		if _now - _state_at > 10.0:
			_check(false, "10 秒内没进 PLAYER_TURN（卡在阶段 %d）" % _flow.phase)
			_report()
		return
	print("\n-- 发射 --")
	_check(_flow.can_operate_pieces(), "PLAYER_TURN 里能操作棋子")
	var charge := Lib.charge_to_reach(_actor, _target, ARRIVE_SPEED)
	_check(Lib.launch(_turn, _actor, _target.global_position, charge), "发射成功并上了锁")
	for p in get_nodes_in_group(Lib.PIECES_GROUP):
		_hp_before[p.name] = p.hp
	print("  蓄力 %.0f（撞上时应剩约 %.0f px/s）" % [charge, ARRIVE_SPEED])
	_goto(St.LAUNCHED)


func _observe() -> void:
	var frozen: bool = _flow.get("_impact_frozen")
	var shaking: bool = _camera.is_shaking()
	var phase: int = _flow.phase
	var tpos: Vector2 = _target.global_position

	if frozen and _freeze_at < 0.0:
		_freeze_at = _now
		print("\n-- 撞上了（t=%.3fs）--" % _now)
	elif frozen:
		_freeze_dead_frames += 1
		_freeze_drift = maxf(_freeze_drift, tpos.distance_to(_target_pos_prev))
		if _target.linear_velocity.length() > 1.0:
			_freeze_speed_seen = true
	elif _freeze_at > 0.0 and _thaw_at < 0.0:
		_thaw_at = _now
		for p in get_nodes_in_group(Lib.PIECES_GROUP):
			if p.hp < int(_hp_before.get(p.name, p.hp)):
				_damaged.append(p.name)
		print("  解冻（t=%.3fs，冻了 %.3fs）：掉血的是 %s"
				% [_now, _now - _freeze_at, ", ".join(_damaged) if _damaged.size() > 0 else "（无人）"])

	if _thaw_at > 0.0 and _resumed_at < 0.0 and tpos.distance_to(_target_pos_prev) > 0.5:
		_resumed_at = _now

	if shaking and not _shaking:
		_shaking = true
		if _shake_at < 0.0:
			_shake_at = _now
		_shake_events.append([_now, _camera.get("_strength"), phase])
		print("  抖动 #%d（t=%.3fs）：强度 %.1f px，阶段 = %d"
				% [_shake_events.size(), _now, _camera.get("_strength"), phase])
	elif not shaking and _shaking:
		_shaking = false
	if shaking and _last_phase >= 0 and phase != _last_phase:
		_phase_flips_during_shake += 1
	_last_phase = phase
	_target_pos_prev = tpos

	if _resumed_at > 0.0 and phase == 1 and _shake_events.size() > 0:
		_judge()
		_goto(St.BUTTONS)


func _judge() -> void:
	print("\n-- 判定 --")
	_check(_freeze_at > 0.0, "发生了碰撞冻结")
	_check(_thaw_at > _freeze_at, "冻结正常结束（冻了 %.3fs）" % (_thaw_at - _freeze_at))
	_check(_freeze_speed_seen and _freeze_drift == 0.0,
			"冻结期间物理真停了：速度不为零、位置零漂移（最大 %.6f px）" % _freeze_drift)
	_check(_damaged.size() > 0, "解冻时结算了伤害（掉血：%s）"
			% (", ".join(_damaged) if _damaged.size() > 0 else "无"))
	_check(_resumed_at > 0.0, "解冻后运动照常继续")
	_check(_shake_events.size() > 0, "伤害落地时抖了（%d 次）" % _shake_events.size())
	_check(_shake_at >= _thaw_at, "抖动在解冻之后")
	_check(_phase_flips_during_shake == 0,
			"抖动期间阶段机没翻页（翻了 %d 次）" % _phase_flips_during_shake)


func _buttons() -> void:
	print("\n-- 结束回合 --")
	var btn: Button = _flow.get("_end_turn_button")
	if btn == null:
		_skip("结束回合按钮为空，跳过按钮链路检查")
		_goto(St.RESET)
		return
	btn.pressed.emit()
	_state_at = _now
	_goto(St.ENEMY_TURN)


## 敌方回合：等 bot 出手，并且等这一回合自己走完回到玩家这边。
func _enemy_turn() -> void:
	var phase: int = _flow.phase
	if not _saw_enemy_turn:
		if phase != 4: # ENEMY_TURN
			if _now - _state_at > 10.0:
				_check(false, "10 秒内没进 ENEMY_TURN（卡在阶段 %d）" % phase)
				_goto(St.RESET)
			return
		_saw_enemy_turn = true
		print("  进入敌方回合（t=%.3fs）" % _now)
		for node in get_nodes_in_group(Lib.PIECES_GROUP):
			if node.owner_id != 0:
				_enemy_pos_before[node.name] = node.global_position
		return

	# 记录敌方棋子动了多少 —— bot 真的出手了才会动
	for node in get_nodes_in_group(Lib.PIECES_GROUP):
		if node.owner_id != 0 and _enemy_pos_before.has(node.name):
			_enemy_moved = maxf(_enemy_moved,
					node.global_position.distance_to(_enemy_pos_before[node.name]))

	if phase == 0 or phase == 1: # 回到 TURN_START / PLAYER_TURN：敌方回合走完了
		print("  敌方回合结束（t=%.3fs），敌方棋子移动了 %.1f px" % [_now, _enemy_moved])
		print("\n-- 判定：敌方回合 --")
		_check(_enemy_moved > 20.0,
				"bot 真的出了一手（敌方棋子移动 %.1f px）" % _enemy_moved)
		_check(_flow.can_operate_pieces() or phase == 0,
				"回合交回玩家手里（阶段 = %d）" % phase)
		_goto(St.RESET)
		return

	if _now - _state_at > 25.0:
		_check(false, "25 秒内敌方回合没走完（卡在阶段 %d）" % phase)
		_goto(St.RESET)


func _reset() -> void:
	var before: int = _target.hp
	var btn: Button = _flow.get("_reset_button")
	if btn != null:
		btn.pressed.emit()
	_check(_flow.phase == 0, "重置后回到 TURN_START（阶段 = %d）" % _flow.phase)
	_check(_target.hp == int(_hp_before.get(_target.name, _target.hp)),
			"重置后目标血量回满（%d → %d）" % [before, _target.hp])
	_report()


func _goto(s: St) -> void:
	_state = s
	_state_at = _now


func _give_up() -> bool:
	_check(false, "60 秒还没跑完（卡在状态 %d，阶段 %d）" % [_state, _flow.phase])
	_report()
	return true


func _report() -> void:
	print("\n== 结果：%d 项失败%s ==" % [_fails.size(),
			("，%d 项跳过" % _skips.size()) if _skips.size() > 0 else ""])
	for f in _fails:
		print("  FAIL: " + f)
	for s in _skips:
		print("  SKIP: " + s)
	if _fails.is_empty() and _skips.is_empty():
		print("  机制链路完好。")
	quit(1 if _fails.size() > 0 else 0)
