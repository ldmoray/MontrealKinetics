from twisted.internet.protocol import DatagramProtocol
from twisted.internet import reactor

from enum import Enum
from time import sleep
from typing import Optional, Tuple
import sys

PACKET_DELIMITER = "|"

class RpcKind(Enum):
	OK = "ok" # Response OK

	HostPeerCount   = "pc"
	RegisterSession = "rs"
	RegisterClient  = "rc"
	ExchangePeers   = "ep"
	CheckoutClient  = "cc"
	PeerList        = "peers"

	@staticmethod
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
	def __init__(self, session_id: str, max_clients: int, host_addr):
		self.id = session_id
		self.client_max = max_clients
		self.registered_clients = {}
		self.host_addr = host_addr

	def client_checkout(self, c_name: str) -> Optional[Tuple[bool, int]]:
		if c_name not in self.registered_clients:
			return None

		del self.registered_clients[c_name]

		count = len(self.registered_clients)
		return (count == self.client_max, count)

	def client_registered(self, client: Client) -> Optional[Tuple[bool, int]]:
		if client.name in self.registered_clients:
			return None

		# print("Client %c registered for Session %s" % client.name, self.id)
		self.registered_clients[client.name] = client

		count = len(self.registered_clients)
		return (count == self.client_max, count)

	def exchange_peer_info(self, transport):
		addresses = {}
		for name, client in self.registered_clients.items():
			addresses[name] = name + ":" + client.ip + ":" + str(client.port)

		for name, client in self.registered_clients.items():
			current = addresses.pop(name)
			# Format: ( name ":" ip ":" port )","
			address_string = ",".join(addresses.values())
			addresses[name] = current

			transport.write(
					_build_packet([RpcKind.PeerList.value, address_string]),
					(client.ip, client.port))

		print(f"Peer info has been sent. Terminating Session: {self.id}")


class ServerProtocol(DatagramProtocol):
	def __init__(self):
		print("created server protocol")
		# TODO: add some sort of garbage collection to clients and sessions.
		#       Clients and Sessions shouldn't live forever.
		self.active_sessions = {}
		self.registered_clients = {}

	def create_session(self, s_id: str, max_clients: int, host_addr):
		if s_id in self.active_sessions:
			print("Tried to create existing session")
			return

		session = Session(s_id, max_clients, host_addr)
		self.active_sessions[s_id] = session
		return session

	def remove_session(self, session: Session):
		try:
			del self.active_sessions[session.id]
		except KeyError:
			print("Tried to terminate non-existing session")

		for c in session.registered_clients:
			self.registered_clients.pop(c)

	def register_client(self, c_name: str, c_session: str, c_ip, c_port):
		if c_name in self.registered_clients:
			print(f"Client {c_name} is already registered.")
			return
		if not c_session in self.active_sessions:
			print(f"Client registered for non-existing session: {c_session}")
			return

		self.transport.write(
				_build_packet([RpcKind.OK.value, c_session]),
				(c_ip, c_port))

		new_client = Client(c_name, c_session, c_ip, c_port)
		self.registered_clients[c_name] = new_client
		session = self.active_sessions[c_session]
		result = session.client_registered(new_client)

		if result is not None:
			done, count = result

			if done:
				sleep(1) # transport.write call probably hits system call immediately.
				print("waited for OK message to send, sending out info to peers")
				session.exchange_peer_info(self.transport)
				self.remove_session(session)
			else:
				self.transport.write(
						_build_packet([RpcKind.HostPeerCount.value, str(count)]),
						session.host_addr)
				pass

	def exchange_info(self, c_session):
		"""Manually trigger exchanging peers because the host decided to start"""
		if not c_session in self.active_sessions:
			return
		session = self.active_sessions[c_session]
		session.exchange_peer_info(self.transport)
		self.remove_session(session)

	def client_checkout(self, name):
		if name not in self.registered_clients:
			print("Tried to checkout unregistered client")
			return

		client = self.registered_clients.pop(name)
		session = self.active_sessions[client.session_id]
		result = session.client_checkout(client.name)
		if result is not None:
			_done, count = result

			# Update the host that a peer left.
			self.transport.write(
					_build_packet([RpcKind.HostPeerCount.value, str(count)]),
					session.host_addr)

	def datagramReceived(self, datagram, address):
		"""Handle incoming datagram messages."""
		c_ip, c_port = address
		packet_parts = _split_packet(datagram)
		print("got datagram:", packet_parts)
		msg_type = RpcKind.try_from(packet_parts[0])

		if msg_type == RpcKind.RegisterSession:
			_type, session, c_name, max_clients, *bad = packet_parts

			try:
				self.create_session(session, int(max_clients), address)
				self.register_client(c_name, session, c_ip, c_port)
			except ValueError:
				print("bad max client setting.")

		elif msg_type == RpcKind.RegisterClient:
			_type, c_session, c_name, *bad = packet_parts
			self.register_client(c_name, c_session, c_ip, c_port)

		elif msg_type == RpcKind.ExchangePeers:
			_type, c_session, *bad = packet_parts
			self.exchange_info(c_session)

		elif msg_type == RpcKind.CheckoutClient:
			_type, c_name, *bad = packet_parts
			self.client_checkout(c_name)

		else:
			# Ignore bad packets.
			pass


def _build_packet(parts) -> bytes:
	for p in parts:
		assert PACKET_DELIMITER not in p
	return bytes(PACKET_DELIMITER.join(parts), "utf-8")


def _split_packet(packet: bytes):
	return packet.decode("utf8").split(PACKET_DELIMITER)


class Echo(DatagramProtocol):
	def datagramReceived(self, datagram, address):
		print("datagram:", datagram, "from", address)
		self.transport.write(datagram, address)


if __name__ == '__main__':
	if len(sys.argv) < 2:
		print("Usage: ./server.py PORT")
		sys.exit(1)

	port = int(sys.argv[1])
	reactor.listenUDP(port, ServerProtocol())
	print('Listening on *:%d' % (port))
	reactor.run()
