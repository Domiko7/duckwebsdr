import socket
import threading
import unittest

from owrx.rtl_tcp_relay import RtlTcpRelay


class RtlTcpRelayTest(unittest.TestCase):
    def setUp(self):
        self.upstream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.upstream.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.upstream.bind(("127.0.0.1", 0))
        self.upstream.listen(4)
        self.upstream.settimeout(5)
        self.upstreamPort = self.upstream.getsockname()[1]
        self.received = []
        self.receivedLock = threading.Lock()
        self.serving = True
        serving = threading.Thread(target=self.serve, daemon=True)
        serving.start()

        self.relay = RtlTcpRelay("127.0.0.1", 0, "127.0.0.1", self.upstreamPort)
        self.relay.start()
        self.assertTrue(self.relay.ready.wait(5), "relay did not start listening")

    def tearDown(self):
        self.serving = False
        self.relay.stop()
        self.upstream.close()

    def serve(self):
        while self.serving:
            try:
                conn, _ = self.upstream.accept()
            except OSError:
                return
            threading.Thread(target=self.echo, args=(conn,), daemon=True).start()

    def echo(self, conn):
        conn.sendall(b"RTL0")
        try:
            while True:
                data = conn.recv(1024)
                if not data:
                    break
                with self.receivedLock:
                    self.received.append(data)
                conn.sendall(data)
        except OSError:
            pass
        finally:
            conn.close()

    def connect(self):
        client = socket.create_connection(("127.0.0.1", self.relay.bind_port), timeout=5)
        client.settimeout(5)
        return client

    def test_forwards_both_directions(self):
        client = self.connect()
        self.assertEqual(client.recv(4), b"RTL0")
        client.sendall(b"\x01\x02\x03")
        self.assertEqual(client.recv(3), b"\x01\x02\x03")
        client.close()

    def test_supports_multiple_clients(self):
        first = self.connect()
        second = self.connect()
        self.assertEqual(first.recv(4), b"RTL0")
        self.assertEqual(second.recv(4), b"RTL0")
        first.sendall(b"\x01\x02")
        second.sendall(b"\x03\x04")
        self.assertEqual(first.recv(2), b"\x01\x02")
        self.assertEqual(second.recv(2), b"\x03\x04")
        first.close()
        second.close()

    def test_stop_disconnects_clients(self):
        client = self.connect()
        self.assertEqual(client.recv(4), b"RTL0")
        self.relay.stop()
        self.assertEqual(client.recv(16), b"")
        client.close()

    def test_stop_closes_listener(self):
        self.relay.stop()
        self.relay.join(5)
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", self.relay.bind_port), timeout=1)


if __name__ == "__main__":
    unittest.main()
