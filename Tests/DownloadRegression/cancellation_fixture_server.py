"""Local fault-injection server. No external requests or user media are used."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import threading
import time

root = Path(sys.argv[1])
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        with lock:
            with (root / "requests.txt").open("a") as log:
                log.write(self.path + "\n")
        if self.path.endswith("slow"):
            self.send_response(200)
            self.send_header("Content-Length", "200004")
            self.end_headers()
            try:
                self.wfile.write(b"x" * 200000)
                self.wfile.flush()
                time.sleep(10)
                self.wfile.write(b"tail")
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        data = b"<html>verification required</html>" if self.path == "/bad" else (root / "valid.png").read_bytes()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(root / "port").write_text(str(server.server_port))
server.serve_forever()
