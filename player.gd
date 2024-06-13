extends CharacterBody3D

@export var player:= 1 : 
	set(id):
		player = id
		$PlayerInput.set_multiplayer_authority(id)

@onready var camera = get_node("Camera3D")
@onready var input = $PlayerInput

const SPEED = 5.0
const JUMP_VELOCITY = 4.5

var camera_rotation := Vector2.ZERO
var mouse_sense := 0.001

# Get the gravity from the project settings to be synced with RigidBody nodes.
var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var gun

func _ready():
	if player == multiplayer.get_unique_id():
		camera.current = true
	gun = $Camera3D/GunPoint.get_children()[0]
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	$MultiplayerSynchronizer.set_multiplayer_authority(player)

func _input(event):
	if event.is_action_pressed("ui_cancel"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	
	if event is InputEventMouseMotion:
		var mouse_event = event.relative * mouse_sense
		camera_look(mouse_event)


func camera_look(movement: Vector2):
	camera_rotation += movement
	camera_rotation.y = clamp(camera_rotation.y, -1.5, 1.2)
	
	transform.basis = Basis()
	camera.transform.basis = Basis()
	rotate_object_local(Vector3(0, 1, 0), -camera_rotation.x)
	camera.rotate_object_local(Vector3(1, 0, 0), -camera_rotation.y)

func _physics_process(delta):
	# Add the gravity.
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Handle jump.
	if input.jumping and is_on_floor():
		velocity.y = JUMP_VELOCITY
	input.jumping = false

	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	var direction = (transform.basis * Vector3(input.direction.x, 0, input.direction.y)).normalized()
	if direction:
		velocity.x = direction.x * SPEED
		velocity.z = direction.z * SPEED
	else:
		velocity.x = 0.0
		velocity.z = 0.0
	move_and_slide()
	
	if input.primary_firing:
		gun.shoot()
	input.primary_firing = false
