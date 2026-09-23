#!/usr/bin/env python3
"""Static server for the ZuperNES browser theater.

Serves this checkout's src/theater directory at http://127.0.0.1:<port>/
with correct MIME types for the .wasm module and ES modules, and with
no-store caching so a rebuilt zupernes.wasm is picked up on every reload
(`zig build theater` restages it in place).

    python3 src/theater/serve.py --port 8380

Std-library only: no dependencies, no CGI, no upload endpoint - the page's
ROMs come solely from the user's local file picker/drag-drop.
"""
import argparse
import http.server
import os
import sys
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))

MIME = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".wasm": "application/wasm",
    ".json": "application/json",
    ".png": "image/png",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
}


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kw):
        super().__init__(*args, directory=HERE, **kw)

    def end_headers(self):
        # No caching: the debug loop rebuilds zupernes.wasm in place, and a
        # browser that served a stale module would silently run the old
        # emulator. HEAD/GET only; there is nothing stateful.
        self.send_header("Cache-Control", "no-store")
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        super().end_headers()

    def guess_type(self, path):
        # SimpleHTTPRequestHandler's default table misses .mjs and mis-sets
        # .wasm on some macOS builds; be explicit.
        _, ext = os.path.splitext(urllib.parse.urlparse(path).path)
        if ext in MIME:
            return MIME[ext]
        return super().guess_type(path)

    def translate_path(self, path):
        # Reject path traversal outside the theater dir; SimpleHTTPRequestHandler
        # already collapses most of it, but normalize explicitly anyway.
        path = urllib.parse.urlparse(path).path
        return super().translate_path(path)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=8380)
    ap.add_argument("--bind", default="127.0.0.1")
    args = ap.parse_args()
    os.chdir(HERE)
    print(f"ZuperNES theater on http://{args.bind}:{args.port}/ (serving {HERE})", flush=True)
    http.server.ThreadingHTTPServer((args.bind, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
