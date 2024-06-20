extends Node
# The Holepunch addon has the goal of performing something resembling STUN
# to get NAT traversal working for a higher level API. See Section 10 of the
# STUN RFC: https://datatracker.ietf.org/doc/html/rfc3489#section-10
#
# Holepunch works as follows:
#  * Session host registers with the server.
#  * Multiple clients register with the server.
#    TODO: support sending Host feedback of clients registering?
#  * Either:
#    * The Session Host decides to start (using `finalize_peers`),
#    * Or the maximum number of clients connect.
#  * The server sends _everyone_ (host and clients) the full peer list.
#    ( At this point the server is no longer needed. )
#  * Host & Clients attempt to connect to one another.
#  * Hopefully Host & Clients are connected...
#
#
# Unlike STUN, the protocol implemented here doesn't continue to use the
# server to coordinate connections, we hope we don't run into weird NATs
# while trying to connect. We stumble around in the dark and spew some
# packets hoping that we manage to connect to our peer.
#
# If the server couldn't detect IP address shenanigans between us and our
# peer, we'll never be able to connect. If there's only port rewrites,
# then maybe we'll be fine.
enum State {
  # DEFAULT
  UNINIT = 0,

  # Sending Registration to Server (client or host)
  REGISTERING = 1,

  # Successfully registered session to Server, waiting for peer info.
  # emits 'session_registered' when switching into this state.
	# The Host will emit 'session_client_registered(int)' in this state. 
  WAITING_FOR_PEERS = 2,

  # Server sent peer list, attempting to connect.
  # TODO: emit 'peer_list_received' when switching into this state.
  CONNECTING_PEERS = 3,

  # All peers connected, process complete.
  # emits many 'hole_punched(...)' signals before coming here.
  # TODO: emit something when all peers are connected?
  #
  # There is no enum for this state, we go back to UNINIT.
}

# Signal is emitted when holepunch is complete.
# Connect this signal to your network manager
# Once your network manager received the signal
# they can host or join a game on the host port
signal hole_punched(my_port: int, hosts_port: int, hosts_address)

# This signal is emitted when the server has acknowledged
# your client registration, but before the address and
# port of the other client have arrived.
signal session_registered

# Emit on the Host when a new client joins or leaves the session.
signal session_client_registered(count: int)

# Emit on all players when switching into peer connection mode.
signal peer_list_received

var server_udp: PacketPeerUDP = PacketPeerUDP.new()
var peer_udp: PacketPeerUDP = PacketPeerUDP.new()

# Set the rendevouz address to the IP address or Hostname
# of your third party server.
@export var rendevouz_address: String = "" 
# Set the rendevouz port to the port of your third party server
@export var rendevouz_port: int = 4000
# This is the range of ports you will search if you hear no
# response from the first port tried.
@export var port_cascade_range: int = 10
# The amount of messages of the same type you will send before
# cascading or giving up.
@export var response_window: int = 5

enum PeerConnectStrategy {
	# Initial attempt to connect to the peer. We haven't yet given up on
	# a simple connection from using the address information provided by
	# the Session Server.
	ATTEMPT_GREET = 1,

	# Simple attempts to greet by sending packets have failed.
	# Switch to binding many ports, and spewing many packets from each.
	# Hope that if we do this, and our peer does as well, we might meet
	# each other quickly.
	ATTEMPT_BIRTHDAY_GREET = 2,
}

enum PeerConnectionState {
	# No contact with the peer.
	UNKNOWN = 0,

	# We received a greet.
	GREET = 1,

	# we received a confirm.
	CONFIRM = 2,

	# we're sending keep alive packets back and forth while we wait
	# for other peer connections to establish.
	CONNECTED = 3,
}

var recieved_peer_info: bool = false
var recieved_peer_greet: bool = false
var recieved_peer_confirm: bool = false
var recieved_peer_go: bool = false

var is_host: bool = false

var own_port: int = 0
var peer = {}
var host_address = ""
var host_port: int = 0
var client_name: String
var p_timer: Timer
var session_id: String

var ports_tried = 0
var greets_sent = 0
var gos_sent = 0

const REGISTER_SESSION = "rs"
const REGISTER_CLIENT = "rc"
const EXCHANGE_PEERS = "ep"
const CHECKOUT_CLIENT = "cc"
const PEER_GREET = "greet"
const PEER_CONFIRM = "confirm"
const PEER_GO = "go"
const SERVER_OK = "ok"
const SERVER_INFO = "peers"
const HOST_PEER_COUNT = "pc" # number of members in the session
const PACKET_DELIMITER = "|"

const MAX_PLAYER_COUNT: int = 2

# warning-ignore:unused_argument
func _process(delta):
	if server_udp.get_available_packet_count() > 0:
		var array_bytes = server_udp.get_packet()
		var m: PackedStringArray = _split_packet(array_bytes)

		if m.size() == 2 && m[0] == SERVER_OK && m[1] == session_id:
			# Host is auto registered.
			emit_signal('session_registered')

		elif m.size() == 2 && m[0] == HOST_PEER_COUNT:
			var count = int(m[1])
			print("session_client_registered(", count, ")")
			emit_signal('session_client_registered', count)

		elif not recieved_peer_info && m.size() == 2 && m[0] == SERVER_INFO:
			recieved_peer_info = true
			emit_signal('peer_list_received')
			server_udp.close()

			var peers = m[1].split(",")
			for p in peers:
				var peer_parts = p.split(":")
				peer[peer_parts[0]] = {
					"port": int(peer_parts[1]),
					"address": peer_parts[1],
					"name": peer_parts[0],

					"strategy": PeerConnectStrategy.ATTEMPT_GREET,
					"packets_sent": 0,
				}

			start_peer_contact()

	# Can only be handling one of session registration or peer connection at once.
	elif peer_udp.get_available_packet_count() > 0:
		var array_bytes = peer_udp.get_packet()
		# These are where the packet came from,
		# not where the sender says they sent it from.
		var peer_addr: String = peer_udp.get_packet_ip()
		var peer_port: int    = peer_udp.get_packet_port()

		var m: PackedStringArray = _split_packet(array_bytes)

		if not recieved_peer_greet:
			if m[0] == PEER_GREET:
				_handle_greet_message(m[1], int(m[2]), int(m[3]))

		elif not recieved_peer_confirm:
			if m[0] == PEER_CONFIRM:
				_handle_confirm_message(m[1], int(m[2]), int(m[3]), bool(int(m[4])))

		elif not recieved_peer_go:
			if m[0] == PEER_GO:
				_handle_go_message(m[1])



func _handle_greet_message(peer_name: String, peer_port: int, my_port: int):
	if own_port != my_port:
		own_port = my_port
		peer_udp.close()
		peer_udp.listen(own_port, "*")
	recieved_peer_greet = true


func _handle_confirm_message(peer_name: String, peer_port: int, my_port: int, is_host: bool):
	if peer[peer_name].port != peer_port:
		peer[peer_name].port = peer_port

	peer[peer_name].is_host = is_host
	if is_host:
		host_address = peer[peer_name].address
		host_port = int(peer[peer_name].port)
	peer_udp.close()
	peer_udp.listen(own_port, "*")
	recieved_peer_confirm = true


func _handle_go_message(peer_name: String):
	recieved_peer_go = true
	emit_signal("hole_punched", own_port, host_port, host_address)
	peer_udp.close()
	p_timer.stop()
	set_process(false)


func _cascade_peer(add, peer_port):
	for i in range(peer_port - port_cascade_range, peer_port + port_cascade_range):
		var buffer: PackedByteArray = _build_packet(
				[PEER_GREET, client_name, str(own_port), str(i)])
		peer_udp.set_dest_address(add, i)
		peer_udp.put_packet(buffer)
		ports_tried += 1


func _process_peer(peer):
	pass

func _ping_peer():
	
	if not recieved_peer_confirm and greets_sent < response_window:
		for p in peer.keys():
			var buffer: PackedByteArray = _build_packet(
					[PEER_GREET, client_name, str(own_port), peer[p].port])
			peer_udp.set_dest_address(peer[p].address, int(peer[p].port))
			peer_udp.put_packet(buffer)
			greets_sent+=1
			if greets_sent == response_window:
				print("Receiving no confirm. Starting port cascade")
				#if the other player hasn't responded we should try more ports

	if not recieved_peer_confirm and greets_sent == response_window:
		for p in peer.keys():
			_cascade_peer(peer[p].address, int(peer[p].port))
		greets_sent += 1

	if recieved_peer_greet and not recieved_peer_go:
		for p in peer.keys():
			var buffer: PackedByteArray = _build_packet(
					[PEER_CONFIRM, client_name, str(own_port), str(peer[p].port), str(int(is_host))])
			peer_udp.set_dest_address(peer[p].address, peer[p].port)
			peer_udp.put_packet(buffer)

	if  recieved_peer_confirm:
		for p in peer.keys():
			var buffer: PackedByteArray = _build_packet(
					[PEER_GO, client_name])
			peer_udp.set_dest_address(peer[p].address, int(peer[p].port))
			peer_udp.put_packet(buffer)
		gos_sent += 1

		if gos_sent >= response_window: #the other player has confirmed and is probably waiting
			emit_signal("hole_punched", int(own_port), int(host_port), host_address)
			p_timer.stop()
			set_process(false)


func start_peer_contact():	
	if peer_udp.is_bound():
		peer_udp.close()

	var err = peer_udp.listen(own_port, "*")
	if err != OK:
		print("Error listening on port: " + str(own_port) +" Error: " + str(err))
	p_timer.start()


# this function can be called to the server if you want to end the
# session building before it's full, eg: if you're done waiting
# for new peers and just want to start the game.
#
# Can only be called by the host.
func finalize_peers(id):
	if !is_host:
		return

	var buffer: PackedByteArray = _build_packet(
			[EXCHANGE_PEERS, str(id)])
	server_udp.set_dest_address(rendevouz_address, rendevouz_port)
	server_udp.put_packet(buffer)


# Disconnect from session as a client.
#
# Can only be called as a client.
# TODO: rename to "leave_session" or some such.
func checkout():
	if is_host:
		return

	var buffer: PackedByteArray = _build_packet(
			[CHECKOUT_CLIENT, client_name])
	server_udp.set_dest_address(rendevouz_address, rendevouz_port)
	server_udp.put_packet(buffer)


#Call this function when you want to start the holepunch process
# TODO: rename to "start_session" or some such.
func start_traversal(session_code: String, are_we_host: bool, player_name: String):
	if server_udp.is_bound():
		server_udp.close()

	var err: Error = Error.ERR_ALREADY_IN_USE
	while err == Error.ERR_ALREADY_IN_USE:
		# Bind to a random port, it's fine.
		own_port = _random_port()
		err = server_udp.bind(own_port, "*")

	if err != OK:
		print("Error binding port: ", own_port, " ", error_string(err), ":", err)
		return

	is_host = are_we_host
	client_name = player_name
	recieved_peer_info = false
	recieved_peer_greet = false
	recieved_peer_confirm = false
	recieved_peer_go = false
	peer = {}

	ports_tried = 0
	greets_sent = 0
	gos_sent = 0
	session_id = session_code
	
	if (is_host):
		var buffer: PackedByteArray = _build_packet(
				[REGISTER_SESSION, session_id, client_name, str(MAX_PLAYER_COUNT)])
		print("setting address: ", rendevouz_address, ":", rendevouz_port)
		server_udp.set_dest_address(rendevouz_address, rendevouz_port)
		server_udp.put_packet(buffer)
	else:
		_register_client_to_server()


func _build_packet(parts: Array[String]) -> PackedByteArray:
	for p in parts:
		assert(PACKET_DELIMITER not in p)
	print("Building packet: %s", parts)
	return PACKET_DELIMITER.join(parts).to_utf8_buffer()

func _split_packet(packet: PackedByteArray) -> PackedStringArray:
	var s: String = packet.get_string_from_utf8()
	return s.split(PACKET_DELIMITER)

func _random_port() -> int:
	const MAX_PORT = 2 ** 16 - 1
	const RESERVED_PORTS = 1024
	return randi() % (MAX_PORT - RESERVED_PORTS) + RESERVED_PORTS


#Register a client with the server
func _register_client_to_server():
  # TODO: random timer, why is it needed?
	await get_tree().create_timer(2.0).timeout
	var buffer: PackedByteArray = _build_packet(
			[REGISTER_CLIENT, session_id, client_name])
	server_udp.set_dest_address(rendevouz_address, rendevouz_port)
	server_udp.put_packet(buffer)


func _exit_tree():
	server_udp.close()


func _ready():
	p_timer = Timer.new()
	get_node("/root/").call_deferred("add_child", p_timer)
	p_timer.timeout.connect(_ping_peer)
	p_timer.wait_time = 0.1
