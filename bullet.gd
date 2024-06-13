extends Area3D

var SPEED = 100
var DAMAGE = 1

# Called when the node enters the scene tree for the first time.
func _ready():
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	position += transform.basis * Vector3(0, 0, SPEED) * delta


func _on_body_entered(body):
	body.deal_damage(DAMAGE)
	queue_free()


func _on_area_entered(area):
	queue_free()
