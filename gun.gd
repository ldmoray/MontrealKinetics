extends Node3D


@onready var anim_player = $AnimationPlayer
@onready var ray_cast = $RayCast3D
var bullet_scene = load("res://bullet.tscn")
var bullet

func shoot():
	if !anim_player.is_playing():
		anim_player.play("shoot")
		bullet = bullet_scene.instantiate()
		bullet.position = ray_cast.global_position
		bullet.transform.basis = ray_cast.global_basis
		get_tree().get_first_node_in_group("level").add_child(bullet)
		
