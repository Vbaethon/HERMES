"""Local fixture: MP4 [port] [silent MP4] [original MOV] [silent original MOV]."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
import json
import sys
import time

media = Path(sys.argv[1]).read_bytes()
port = int(sys.argv[2]) if len(sys.argv) > 2 else 18761
silent = Path(sys.argv[3]).read_bytes() if len(sys.argv) > 3 else None
original = Path(sys.argv[4]).read_bytes() if len(sys.argv) > 4 else None
silent_original = Path(sys.argv[5]).read_bytes() if len(sys.argv) > 5 else None
requests = {}
request_lock = Lock()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/requests.json':
            with request_lock:
                data = json.dumps(requests).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        with request_lock:
            requests[self.path] = requests.get(self.path, 0) + 1
        data = media if self.path in ('/good.mp4', '/waiting.mp4') else b'<html>verification required</html>'
        if self.path in ('/silent.mp4', '/silent-fallback.mp4') and silent is not None:
            data = silent
        if self.path in ('/original.mov', '/original-backup.mov') and original is not None:
            data = original
        if self.path == '/silent-original.mov' and silent_original is not None:
            data = silent_original
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try:
            if self.path == '/waiting.mp4':
                # Real file growth, stall and renewed growth let the shared monitor
                # report waiting and recovery without fabricating status callbacks.
                boundary = 128 * 1024
                self.wfile.write(data[:boundary])
                self.wfile.flush()
                # Leave more than one monitor tick on either side of the stall;
                # Swift compilation can temporarily contend with the test process.
                time.sleep(8.2)
                self.wfile.write(data[boundary:2 * boundary])
                self.wfile.flush()
                time.sleep(4.2)
                self.wfile.write(data[2 * boundary:])
            else:
                self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass

ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
