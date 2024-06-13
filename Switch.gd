extends Area3D
class_name Switch

@export var wait_time: float = 0.5

@export var hit_recently: bool
var timer: Timer

func _ready():
	timer = Timer.new()
	timer.timeout.connect(_on_timeout)
	add_child(timer)

func _on_area_entered(area):
	hit_recently = true
	timer.start(wait_time)

func _on_timeout():
	hit_recently = false
