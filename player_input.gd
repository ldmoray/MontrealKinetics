extends MultiplayerSynchronizer

# Set via RPC to simulate is_action_just_pressed.
@export var jumping := false
@export var primary_firing := false

# Synchronized property.
@export var direction := Vector2()

func _ready():
	# Only process for the local player.
	set_process(get_multiplayer_authority() == multiplayer.get_unique_id())

	
@rpc("call_local")
func jump():
	jumping = true

@rpc("call_local")
func primary_fire():
	primary_firing = true


func _process(delta):
	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	direction = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if Input.is_action_just_pressed("jump"):
		jump.rpc()
		
	if Input.is_action_pressed("primary_fire"):
		primary_fire.rpc()
