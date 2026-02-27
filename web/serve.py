#!/usr/bin/env python3
"""Minimal dev server with correct WASM MIME type."""
import http.server
import sys

class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        '.wasm': 'application/wasm',
    }

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8086
print(f"Serving on http://localhost:{port}")
http.server.HTTPServer(("", port), Handler).serve_forever()
