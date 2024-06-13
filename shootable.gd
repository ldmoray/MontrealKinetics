extends CharacterBody3D
class_name Shootable

var health = 10

func deal_damage(damage: int):
	health -= damage
	if health <= 0:
		queue_free()
