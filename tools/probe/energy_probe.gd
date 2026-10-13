extends SceneTree

## 冻结/动能的 A/B 测量（比机制探针慢，默认不跑）。
##
## 回答两个问题：
##   1. **冻结/解冻吃不吃饭动能？** 同一发球，冻结开着跑一遍、关掉跑一遍，逐物理帧比轨迹。
##      "冻结关闭" = 冻结拉起的那一物理帧立刻 `_end_freeze()`，等价于没有冻结机制。
##   2. **撞飞距离的账本**：撞飞多远 = 这一发的解析射程 − 行动角色已经跑掉的那段。
##      （等质量 + 完全弹性 + 同一个 `decel` 时，动能只是在两枚之间**转手**，
##       所以全场总路程 ≈ 解析射程。2026-10-12 实测 +1.9% ~ +2.7%。）
##
## 跑法：`bash tools/verify.sh --energy`

const Lib = preload("probe_lib.gd")

const MAIN := "res://sences/main.tscn"
const ARRIVE := {300.0: 200.0, 600.0: 400.0} # 蓄力 → 希望撞上时还剩多少速度

## 逐物理帧记录器。`_physics_process` 在物理步**之后**跑，读到的是该步结算完的状态。
class Recorder extends Node:
	var frames: Array = []   # [t, 物理这一步没跑?, [每枚的 位置+速度 ]]
	var t := 0.0
	var _pieces: Array = []

	func setup(pieces: Array) -> void:
		_pieces = pieces

	func clear_all() -> void:
		frames.clear()
		t = 0.0

	func _physics_process(delta: float) -> void:
		t += delta
		var states: Array = []
		var all_still := true
		var any_speed := false
		for p in _pieces:
			if not is_instance_valid(p):
				continue
			states.append([p.global_position, p.linear_velocity.length()])
		if frames.size() > 0:
			var prev: Array = frames[-1][2]
			for i in states.size():
				if i < prev.size() and (states[i][0] as Vector2).distance_to(prev[i][0]) > 0.000001:
					all_still = false
			for s in states:
				if s[1] > 1.0:
					any_speed = true
		frames.append([t, all_still and any_speed, states])

	## 物理真的没跑的那些帧（速度不为零却一动不动）
	func dead_frames() -> int:
		var n := 0
		for f in frames:
			if f[1]:
				n += 1
		return n

	func live() -> Array:
		var out: Array = []
		for f in frames:
			if not f[1]:
				out.append(f)
		return out

	func path_of(idx: int) -> float:
		var total := 0.0
		for k in range(1, frames.size()):
			var a: Array = frames[k - 1][2]
			var b: Array = frames[k][2]
			if idx < a.size() and idx < b.size():
				total += (b[idx][0] as Vector2).distance_to(a[idx][0])
		return total

	func end_of(idx: int) -> Vector2:
		return Vector2.ZERO if frames.is_empty() else frames[-1][2][idx][0]


var _scene: Node = null
var _flow: Node = null
var _turn: Node = null
var _rec: Recorder = null
var _pieces: Array = []
var _actor: RigidBody2D = null
var _target: RigidBody2D = null
## 记录器只跟这两枚（其余棋子被停放在四角，不参与这一发）
const _idx_actor := 0
const _idx_target := 1

## 每行：蓄力、冻结开不开。两趟同配置 = 量本征差异（控制组）。
const RUNS := [
	{"tag": "a", "charge": 300.0, "freeze": false},
	{"tag": "b", "charge": 300.0, "freeze": false},
	{"tag": "c", "charge": 300.0, "freeze": true},
	{"tag": "d", "charge": 600.0, "freeze": true},
	{"tag": "e", "charge": 600.0, "freeze": false},
]
var _ri := 0
var _results: Array = []
## 这一趟**实际用的**蓄力值（由 `charge_to_reach` 现算，不是 RUNS 里的名义值）。
## 账本必须用它 —— 用名义值算出来的解析射程是错的（踩过：把 333 记成 300，误差 +26%）。
var _actual_charge := 0.0
## 临时调试：`PROBE_DEBUG=d bash tools/verify.sh --energy` 只逐帧打印 d 趟
var _dbg := OS.get_environment("PROBE_DEBUG")
var _dbg_last := -1
var _now := 0.0
var _f := 0
var _waiting := true
var _since := 0.0
var _still := 0


func _initialize() -> void:
	_scene = load(MAIN).instantiate()
	root.add_child(_scene)
	_flow = _scene.get_node("GameFlow")
	_turn = _scene.get_node("TurnController")
	print("== 冻结 / 动能 A/B 测量 ==")


func _process(delta: float) -> bool:
	_now += delta
	_f += 1
	if _f < 3:
		return false

	if _ri >= RUNS.size():
		_report()
		return true
	if _now > 120.0:
		print("超时，只跑完了 %d 趟" % _ri)
		_report()
		return true

	var run: Dictionary = RUNS[_ri]

	if _waiting:
		if _flow.phase == 1 and Lib.all_at_rest(get_nodes_in_group(Lib.PIECES_GROUP)):
			_start(run)
		return false

	# 冻结关闭的趟：冻结一拉起就立刻解冻（物理最多丢 1 帧）
	if not run["freeze"] and _flow.get("_impact_frozen"):
		_flow._end_freeze()

	_since += delta
	if _dbg != "" and run["tag"] == _dbg and _rec.frames.size() != _dbg_last:
		_dbg_last = _rec.frames.size()
		print("    [%s] p帧%3d t=%5.3f phase=%d frozen=%s  行动 v=%6.1f @%s  目标 v=%6.1f @%s"
				% [run["tag"], _dbg_last, _now, _flow.phase, str(_flow.get("_impact_frozen")),
				   _actor.linear_velocity.length(), str(_actor.global_position.round()),
				   _target.linear_velocity.length(), str(_target.global_position.round())])
	if Lib.all_at_rest(get_nodes_in_group(Lib.PIECES_GROUP)):
		_still += 1
	else:
		_still = 0
	if _still > 40:
		_finish(run)
	return false


func _start(run: Dictionary) -> void:
	# 每趟都重摆跑道：`reset_match()` 会把棋子送回开局位置，不重摆就换了工况。
	var lane := Lib.setup_lane(self)
	if lane.size() < 2:
		print("场景里缺棋子（我方或敌方为空）")
		quit(2)
		return
	_actor = lane[0]
	_target = lane[1]
	_pieces = [_actor, _target]
	if _rec == null:
		_rec = Recorder.new()
		_scene.add_child(_rec)
	_rec.setup(_pieces)

	var arrive: float = ARRIVE.get(run["charge"], 200.0)
	var charge := Lib.charge_to_reach(_actor, _target, arrive)
	_actual_charge = charge
	Lib.launch(_turn, _actor, _target.global_position, charge)
	_rec.clear_all()
	_waiting = false
	_since = 0.0
	_still = 0
	print("\n-- %s：蓄力 %.0f，冻结%s --" % [run["tag"], charge, "开" if run["freeze"] else "关"])


func _finish(run: Dictionary) -> void:
	_results.append({
		"tag": run["tag"], "charge": _actual_charge, "freeze": run["freeze"],
		"frames": _rec.frames.duplicate(), "live": _rec.live(),
		"dead": _rec.dead_frames(),
		"actor_path": _rec.path_of(_idx_actor), "target_path": _rec.path_of(_idx_target),
		"ends": [_rec.end_of(_idx_actor), _rec.end_of(_idx_target)],
		"actor_speed": _peak_speed(_idx_actor), "target_speed": _peak_speed(_idx_target),
	})
	var r: Dictionary = _results[-1]
	print("  物理帧 %d（其中物理没在跑 %d 帧）；行动角色 %.2f px（峰值 %.0f），目标 %.2f px（峰值 %.0f）"
			% [r["frames"].size(), r["dead"], r["actor_path"], r["actor_speed"],
			   r["target_path"], r["target_speed"]])
	_ri += 1
	_waiting = true
	_flow.reset_match()


func _peak_speed(idx: int) -> float:
	var m := 0.0
	for f in _rec.frames:
		if idx < f[2].size():
			m = maxf(m, f[2][idx][1])
	return m


func _report() -> void:
	print("\n== 冻结无损性：同配置下「冻结开」与「关」逐帧比 ==")
	print("  （控制组：两趟同配置都关，用来量本征差异）")
	_pair("a", "b", "对照：两趟都关（本征差异）")
	_pair("a", "c", "蓄力 300：关 vs 开")
	_pair("e", "d", "蓄力 600：关 vs 开")

	print("\n== 动能账本：全场总路程 vs 这一发的解析射程 ==")
	print("  （等质量 + 完全弹性 + 同一个 decel 时，动能只在两枚之间转手，总量应当守恒）")
	for r in _results:
		var de: RigidBody2D = _actor
		var total: float = r["actor_path"] + r["target_path"]
		var range_px: float = r["charge"] * r["charge"] / (2.0 * de.decel)
		print("  %s 蓄力 %.0f：总路程 %7.2f px，解析射程 %7.2f px（%+.2f%%）"
				% [r["tag"], r["charge"], total, range_px, (total / range_px - 1.0) * 100.0])

	print("\n== 撞飞距离 = 射程 − 撞击点距离 ==")
	for r in _results:
		print("  %s 蓄力 %.0f：行动角色 %7.2f px + 目标 %7.2f px = %7.2f px"
				% [r["tag"], r["charge"], r["actor_path"], r["target_path"],
				   r["actor_path"] + r["target_path"]])
	quit(0)


func _pair(x: String, y: String, title: String) -> void:
	var a := _find(x)
	var b := _find(y)
	if a.is_empty() or b.is_empty():
		print("  %s：缺趟次" % title)
		return
	var fx: Array = a["live"]
	var fy: Array = b["live"]
	var n: int = mini(fx.size(), fy.size())
	var worst := 0.0
	var worst_speed := 0.0
	for k in range(n):
		var sx: Array = fx[k][2]
		var sy: Array = fy[k][2]
		for i in mini(sx.size(), sy.size()):
			worst = maxf(worst, (sx[i][0] as Vector2).distance_to(sy[i][0] as Vector2))
			worst_speed = maxf(worst_speed, absf(sx[i][1] - sy[i][1]))
	var end_worst: float = (a["ends"][0] as Vector2).distance_to(b["ends"][0] as Vector2)
	end_worst = maxf(end_worst, (a["ends"][1] as Vector2).distance_to(b["ends"][1] as Vector2))
	print("  %s：运动帧 %d vs %d，逐帧位置偏差 %.6f px，逐帧速度偏差 %.6f px/s，终点偏差 %.6f px"
			% [title, fx.size(), fy.size(), worst, worst_speed, end_worst])


func _find(tag: String) -> Dictionary:
	for r in _results:
		if r["tag"] == tag:
			return r
	return {}
