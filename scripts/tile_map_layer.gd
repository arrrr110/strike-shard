extends TileMapLayer

# 调试用的两行坐标显示。标签挂在 `main.tscn` 的 `UI`（CanvasLayer）下 ——
# 它们是屏幕 UI，不该跟着相机抖，所以路径里带 `UI/`。
#
# 鼠标那行取的是**世界坐标**：加了相机（还带一点 zoom）之后 `event.position`
# 是屏幕坐标，跟世界坐标不再是一回事，用 `get_global_mouse_position()` 才是标签上写的那个数。


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		$"../UI/WorldPositionLabel".text = "World Position:" + str(get_global_mouse_position())
		$"../UI/PlayerPositionLabel".text = "Player Position:" + str($"../StaticBody2D/Player1".position)
