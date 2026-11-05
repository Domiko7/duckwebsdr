import logging
import socket
import threading

logger = logging.getLogger(__name__)


class RtlTcpRelay(threading.Thread):
    def __init__(self, bind_address, bind_port, target_address, target_port):
        super().__init__(name="rtl_tcp_relay", daemon=True)
        self.bind_address = bind_address
        self.bind_port = bind_port
        self.target_address = target_address
        self.target_port = target_port
        self.running = True
        self.server = None
        self.ready = threading.Event()
        self.lock = threading.Lock()
        self.connections = set()

    def run(self):
        try:
            self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.server.bind((self.bind_address, self.bind_port))
            self.server.listen(4)
            self.server.settimeout(1.0)
        except OSError as e:
            logger.error(
                "rtl_tcp relay could not listen on {0}:{1}: {2}".format(self.bind_address, self.bind_port, e)
            )
            self.closeSocket(self.server)
            self.server = None
            self.running = False
            self.ready.set()
            return

        self.bind_port = self.server.getsockname()[1]
        logger.info("rtl_tcp relay listening on {0}:{1}".format(self.bind_address, self.bind_port))
        self.ready.set()

        while self.running:
            try:
                client, address = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self.handleClient, args=(client, address), daemon=True).start()

        self.closeSockets()

    def handleClient(self, client, address):
        try:
            upstream = socket.create_connection((self.target_address, self.target_port), timeout=5)
            upstream.settimeout(None)
        except OSError as e:
            logger.warning(
                "rtl_tcp relay could not reach {0}:{1}: {2}".format(self.target_address, self.target_port, e)
            )
            self.closeSocket(client)
            return

        with self.lock:
            if not self.running:
                self.closeSocket(client)
                self.closeSocket(upstream)
                return
            self.connections.add((client, upstream))

        logger.info("rtl_tcp relay client {0} connected".format(address[0]))
        try:
            self.pump(client, upstream)
        finally:
            with self.lock:
                self.connections.discard((client, upstream))
            self.closeSocket(client)
            self.closeSocket(upstream)
            logger.info("rtl_tcp relay client {0} disconnected".format(address[0]))

    def pump(self, client, upstream):
        def forward(source, destination):
            try:
                while self.running:
                    data = source.recv(65536)
                    if not data:
                        break
                    destination.sendall(data)
            except OSError:
                pass
            try:
                destination.shutdown(socket.SHUT_WR)
            except OSError:
                pass

        threads = [
            threading.Thread(target=forward, args=(client, upstream), daemon=True),
            threading.Thread(target=forward, args=(upstream, client), daemon=True),
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

    def closeSockets(self):
        with self.lock:
            connections = list(self.connections)
            self.connections.clear()
            server = self.server
            self.server = None
        for client, upstream in connections:
            self.closeSocket(client)
            self.closeSocket(upstream)
        self.closeSocket(server)

    @staticmethod
    def closeSocket(sock):
        if sock is None:
            return
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            sock.close()
        except OSError:
            pass

    def stop(self):
        self.running = False
        self.closeSockets()
