"""Isolated four-still XHS source-fallback fixture; never contacts a remote host."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
import sys
import signal
import time

signal.pthread_sigmask(signal.SIG_SETMASK, [])

root = Path(sys.argv[1])
image = (root / "valid.png").read_bytes()
request_lock = Lock()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        with request_lock:
            with (root / "requests.txt").open("a") as log:
                log.write(self.path + "\n")
        payload = b"<html>temporary media source failure</html>" if self.path.startswith("/invalid-") else image
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if self.path.startswith("/waiting-"):
            time.sleep(6)
        elif self.path.startswith("/stall-"):
            time.sleep(30)
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(root / "port").write_text(str(server.server_address[1]))
server.serve_forever()
