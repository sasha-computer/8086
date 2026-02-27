#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# ///
"""Minimal dev server with correct WASM MIME type."""
import http.server
import os
import sys

class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        '.wasm': 'application/wasm',
    }

# Always serve from the directory this script lives in.
os.chdir(os.path.dirname(os.path.abspath(__file__)))

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8086
print(f"Serving on http://localhost:{port}")
http.server.HTTPServer.allow_reuse_address = True
http.server.HTTPServer(("", port), Handler).serve_forever()
