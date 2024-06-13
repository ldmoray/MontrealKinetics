extends Control

@export var address = "146.190.246.136"
@export var port = 8666

var peer
var is_host
var game_code
@onready var hole_puncher = $HolePunch
@onready var name_input = %NameInput
@onready var code_input = %CodeInput

func _ready():
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)

@rpc("any_peer", "call_local")
func start_game():
	var scene = load("res://main.tscn").instantiate()
	get_tree().root.add_child(scene)
	self.hide()
	
@rpc("any_peer")
func send_player_info(id: int):
	if !GameManager.players.has(id):
		GameManager.players[id] = {"id": id}
	
	if multiplayer.is_server():
		for i in GameManager.players:
			send_player_info.rpc(GameManager.players[i].id)

func generate_game_code():
	var letters = ["A", "B", "C", "D", "E"]
	return letters.pick_random() + letters.pick_random() + letters.pick_random()

func traverse_nat():
	var player_id = OS.get_unique_id()
	var player_host = 'host' if is_host else 'client'
	var traversal_id = '%s_%s' % [OS.get_unique_id(), player_host]
	hole_puncher.start_traversal(game_code, is_host, traversal_id)
	return await hole_puncher.hole_punched
	

func _on_host_pressed():
	is_host = true
	game_code = generate_game_code()
	code_input.text = game_code
	var punched_details = await traverse_nat()
	port = punched_details[0]
	peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(port, 4)
	if error != OK:
		return
	peer.get_host().compress(ENetConnection.COMPRESS_RANGE_CODER)
	multiplayer.set_multiplayer_peer(peer)
	
	send_player_info(multiplayer.get_unique_id())
	print("waiting for players")


func _on_join_pressed():
	game_code = code_input.text
	is_host = false
	var punched_details = await traverse_nat()
	var own_port = punched_details[0]
	var host_port = punched_details[1]
	var host_ip = punched_details[2]
	
	peer = ENetMultiplayerPeer.new()
	peer.create_client(host_ip, host_port, 0, 0, 0, own_port)
	peer.get_host().compress(ENetConnection.COMPRESS_RANGE_CODER)
	multiplayer.set_multiplayer_peer(peer)


func _on_start_pressed():
	start_game.rpc()


func _on_peer_connected(id):
	print("peer connected " + str(id))
	
func _on_peer_disconnected(id):
	pass
	
func _on_connected_to_server():
	send_player_info.rpc_id(1, multiplayer.get_unique_id())

func _on_connection_failed():
	pass
