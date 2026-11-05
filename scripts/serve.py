"""LAN-accessible local preview and correct model MIME types for Safari."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class Handler(SimpleHTTPRequestHandler):
    extensions_map = {**SimpleHTTPRequestHandler.extensions_map, '.usdz': 'model/vnd.usdz+zip', '.glb': 'model/gltf-binary', '.js': 'text/javascript'}

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()


print('Open http://localhost:8765/ ; iPhone: use this Mac LAN address on the same Wi-Fi.', flush=True)
ThreadingHTTPServer(('0.0.0.0', 8765), partial(Handler, directory=str(ROOT))).serve_forever()
