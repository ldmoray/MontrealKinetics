extends Node3D

var switches : Array[Switch]

func _ready():
	for child in get_children():
		if child is Switch:
			switches.append(child)

func _process(delta):
	if switches.all(func(x): return x.hit_recently):
		remove_door.rpc()


@rpc("authority", "call_local")
func remove_door():
	queue_free()
