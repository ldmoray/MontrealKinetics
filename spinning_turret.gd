extends Shootable

# Get the gravity from the project settings to be synced with RigidBody nodes.
var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var player_body
var accuracy = 1

@onready var player_pos = $PlayerPos

func _physics_process(delta):
	if player_body:
		player_pos.position = lerp(player_pos.position, player_body.position, delta*accuracy)
		look_at(Vector3(player_pos.position.x, 0.0, player_pos.position.z))


func _on_area_3d_body_entered(body):
	player_body = body


func _on_area_3d_body_exited(body):
	player_body = null
