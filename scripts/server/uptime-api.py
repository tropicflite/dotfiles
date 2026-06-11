#!/usr/bin/env python3
from http.server import HTTPServer, BaseHTTPRequestHandler
import json

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        with open('/proc/uptime') as f:
            secs = int(float(f.read().split()[0]))
        d, secs = divmod(secs, 86400)
        h, secs = divmod(secs, 3600)
        m = secs // 60
        parts = []
        if d: parts.append(f'{d}d')
        if h: parts.append(f'{h}h')
        parts.append(f'{m}m')
        body = json.dumps({'uptime': ' '.join(parts)}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

HTTPServer(('0.0.0.0', 7070), Handler).serve_forever()
