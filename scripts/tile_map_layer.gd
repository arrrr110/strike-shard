extends TileMapLayer

@onready var tilemap = $""
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass

func _input(event):
	if event is InputEventMouseMotion:
		##print(str(event.position))
		# update labels ,node不是子节点，不能用$
		$"../WorldPositionLabel".text = "World Position:" + str(event.position)
