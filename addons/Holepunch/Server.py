from twisted.internet.protocol import DatagramProtocol
from twisted.internet import reactor

from enum import Enum
from time import sleep
from typing import Optional
import sys


def address_to_string(address):
	ip, port = address
	return ':'.join([ip, str(port)])


class RpcKind(Enum):
	OK = "ok" # Response OK
	Err= "er" # Error.

	RegisterSession = "rs"
	RegisterClient	= "rc"
	ExchangePeers	 = "ep"
	CheckoutClient	= "cc"
	PeerList				= "peers"

	@classmethod
	def try_from(s: str) -> Optional["RpcKind"]:
		try:
			return RpcKind(s)
		except ValueError:
			return None



class Client:
	def __init__(self, c_name: str, c_session: str, c_ip, c_port):
		self.name = c_name
		self.session_id = c_session
		self.ip = c_ip
		self.port = c_port


class Session:
	def __init__(self, session_id: str, max_clients: int, server: "ServerProtocol"):
		self.id = session_id
		self.client_max = max_clients
		self.server = server
		self.registered_clients = {}

	def client_checkout(self, c_name: str):
		if c_name not in self.registered_clients:
			return

		del self.registered_clients[c_name]

	def client_registered(self, client: Client):
		if client.name in self.registered_clients:
			return

		# TODO: update the session host that there's some peers waiting?

		# print("Client %c registered for Session %s" % client.name, self.id)
		self.registered_clients[client.name] = client
		if len(self.registered_clients) == self.client_max:
			sleep(1) # transport.write call probably hits system call immediately.
			print("waited for OK message to send, sending out info to peers")
			self.exchange_peer_info()

	def exchange_peer_info(self):
		for addressed_client in self.registered_clients.values():
			address_list = []
			for client in self.registered_clients.values():
				if client.name == addressed_client.name:
					# Clients don't need to be told about themselves.
					continue
				address_list.append(client.name + ":" + address_to_string((client.ip, client.port)))
			address_string = ",".join(address_list)
			# Format: ( name ":" ip ":" port )","
			message = bytes( "peers:" + address_string, "utf-8")
			self.server.transport.write(message, (addressed_client.ip, addressed_client.port))

		print(f"Peer info has been sent. Terminating Session: {self.id}")
		for client in self.registered_clients:
			self.server.client_checkout(client.name)
		self.server.remove_session(self.id)


class ServerProtocol(DatagramProtocol):

	def __init__(self):
		# TODO: add some sort of garbage collection to clients and sessions.
		#       Clients and Sessions shouldn't live forever.
		self.active_sessions = {}
		self.registered_clients = {}

	def name_is_registered(self, name):
		return name in self.registered_clients

	def create_session(self, s_id: str, max_clients: int):
		if s_id in self.active_sessions:
			print("Tried to create existing session")
			return

		self.active_sessions[s_id] = Session(s_id, max_clients, self)


	def remove_session(self, s_id):
		try:
			del self.active_sessions[s_id]
		except KeyError:
			print("Tried to terminate non-existing session")


	def register_client(self, c_name: str, c_session: str, c_ip, c_port):
		if self.name_is_registered(c_name):
			print(f"Client {c_name} is already registered.")
			return
		if not c_session in self.active_sessions:
			print(f"Client registered for non-existing session: {c_session}")
			return
		# TODO: this function should own sending the OK message.

		new_client = Client(c_name, c_session, c_ip, c_port)
		self.registered_clients[c_name] = new_client
		self.active_sessions[c_session].client_registered(new_client)

	def exchange_info(self, c_session):
		"""Manually trigger exchanging peers because the host decided to start"""
		if not c_session in self.active_sessions:
			return
		self.active_sessions[c_session].exchange_peer_info()

	def client_checkout(self, name):
		if name not in self.registered_clients:
			print("Tried to checkout unregistered client")
			return

		client = self.registered_clients.pop(name)
		self.active_sessions[client.session_id].client_checkout(client.name)

	def datagramReceived(self, datagram, address):
		"""Handle incoming datagram messages."""
		print(datagram)
		c_ip, c_port = address
		data_string = datagram.decode("utf-8")
		msg_type = RpcKind.try_from(data_string[:2])

		if msg_type == RpcKind.RegisterSession:
			_type, session, max_clients, *bad = data_string.split(":")
			# TODO: Shouldn't we register the host as a client in the session???
			try:
				self.create_session(session, int(max_clients))
			except ValueError:
				print("bad max client setting.")

			# Say OK only after the session is actually setup.
			self.transport.write(bytes('ok:'+str(c_port),"utf-8"), address)

		elif msg_type == RpcKind.RegisterClient:
			_type, c_name, c_session, *bad = data_string.split(":")

			# TODO: fix this, ok should be sent after we confirm the session exists.
			self.transport.write(bytes('ok:'+str(c_port),"utf-8"), address)
			self.register_client(c_name, c_session, c_ip, c_port)

		elif msg_type == RpcKind.ExchangePeers:
			_type, c_session, *bad = data_string.split(":")
			self.exchange_info(c_session)

		elif msg_type == RpcKind.CheckoutClient:
			_type, c_name, *bad = data_string.split(":")
			self.client_checkout(c_name)

		else:
			# Ignore bad packets.
			pass


if __name__ == '__main__':
	if len(sys.argv) < 2:
		print("Usage: ./server.py PORT")
		sys.exit(1)

	port = int(sys.argv[1])
	reactor.listenUDP(port, ServerProtocol())
	print('Listening on *:%d' % (port))
	reactor.run()
