"""Local HTTP-200 error-body fixture. Supply a known valid MP4; no external requests."""
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import sys

media = Path(sys.argv[1]).read_bytes()
port = int(sys.argv[2]) if len(sys.argv) > 2 else 18761

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        data = media if self.path == '/good.mp4' else b'<html>verification required</html>'
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass

HTTPServer(('127.0.0.1', port), Handler).serve_forever()
