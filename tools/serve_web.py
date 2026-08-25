#!/usr/bin/env python3
"""本地起个静态站点跑 Godot Web 导出。

用法:  python3 tools/serve_web.py [端口]
然后浏览器开:
    http://localhost:8080/?player=a
    http://localhost:8080/?player=b
    http://localhost:8080/?player=c
?player= 是必须的 —— 浏览器所有标签共享 IndexedDB,不带的话
三个标签会登进同一个 Nakama 账号,当成同一个人。
"""
import http.server, socketserver, sys, os, mimetypes

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build", "web")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080

mimetypes.add_type("application/wasm", ".wasm")
mimetypes.add_type("application/javascript", ".js")


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def end_headers(self):
        # 导出时关了 thread_support,所以这两个头不是必需的;
        # 留着是为了将来万一开启多线程导出时不用回来改。
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        if "404" in (fmt % args):
            sys.stderr.write("  404: %s\n" % (fmt % args))


if not os.path.isdir(ROOT):
    sys.exit(f"没有找到 {ROOT}\n先导出:见 tools/build_web.sh")

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", PORT), Handler) as httpd:
    print(f"  serving {ROOT}")
    print(f"  http://localhost:{PORT}/?player=a")
    print(f"  http://localhost:{PORT}/?player=b")
    print(f"  http://localhost:{PORT}/?player=c")
    print("  Ctrl-C 停止")
    httpd.serve_forever()
