extends Node3D
class_name Level

@export var PlayerScene : PackedScene

# Called when the node enters the scene tree for the first time.
func _ready():
	var index = 0
	for i in GameManager.players:
		var curr_player = PlayerScene.instantiate()
		curr_player.player = GameManager.players[i].id
		add_child(curr_player)
		for spawn in get_tree().get_nodes_in_group("player_spawn_point"):
			if spawn.name == str(index):
				curr_player.global_position = spawn.global_position
		index += 1
	pass # Replace with function body.
