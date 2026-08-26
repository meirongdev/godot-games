#!/usr/bin/env python3
"""本地起静态站点跑 Godot Web 导出,并把 Nakama 反代成同源。

用法:  python3 tools/serve_web.py [端口]
然后浏览器开:
    http://localhost:8080/?player=a
    http://localhost:8080/?player=b
    http://localhost:8080/?player=c
?player= 是必须的 —— 浏览器所有标签共享 IndexedDB,不带的话
三个标签会登进同一个 Nakama 账号,当成同一个人。

**为什么这里要反代,不只是发静态文件:**
Web 客户端从页面自身的地址推导服务器地址(godot/src/autoload/NakamaConfig.gd),
线上靠部署侧把 /v2/* 和 /ws 路由到 Nakama(契约 §3.3)。本地要是只起静态服务,
客户端就会去打这个静态服务的 /v2/ —— 本地跑通、线上跑不通,那正是
2026-08-26 那个故障的形状。所以这里照抄线上的路由规则,让本地和线上
拓扑一致:/v2/* 和 /ws 都转给 Nakama。

Nakama 不在默认位置时用环境变量指:
    NAKAMA_HOST=192.168.1.50 NAKAMA_PORT=7350 python3 tools/serve_web.py
"""
import http.server
import http.client
import mimetypes
import os
import socket
import sys
import threading

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build", "web")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080

NAKAMA_HOST = os.environ.get("NAKAMA_HOST", "127.0.0.1")
NAKAMA_PORT = int(os.environ.get("NAKAMA_PORT", "7350"))

mimetypes.add_type("application/wasm", ".wasm")
mimetypes.add_type("application/javascript", ".js")

# 逐跳头不能原样转发。
HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade",
}


class Handler(http.server.SimpleHTTPRequestHandler):
    # 关掉读缓冲:WebSocket 要接管这个连接自己收发,rfile 里留着没读完的
    # 字节就会丢帧。代价是读请求头变成逐字节,对本地开发无所谓。
    rbufsize = 0

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    # ---- 路由:哪些路径归 Nakama ----

    def _target(self):
        path = self.path
        if path.startswith("/ws"):
            return "ws"
        if path.startswith("/v2/"):
            return "http"
        return None

    def _dispatch(self):
        t = self._target()
        if t == "ws":
            self._proxy_websocket()
        elif t == "http":
            self._proxy_http()
        else:
            return False
        return True

    def do_GET(self):
        if not self._dispatch():
            super().do_GET()

    def do_HEAD(self):
        if not self._dispatch():
            super().do_HEAD()

    def do_POST(self):
        if not self._dispatch():
            self.send_error(405)

    def do_PUT(self):
        self.do_POST()

    def do_DELETE(self):
        self.do_POST()

    def do_OPTIONS(self):
        self.do_POST()

    # ---- 反代 ----

    def _proxy_http(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        headers = {
            k: v for k, v in self.headers.items()
            if k.lower() not in HOP_BY_HOP and k.lower() != "host"
        }
        try:
            conn = http.client.HTTPConnection(NAKAMA_HOST, NAKAMA_PORT, timeout=30)
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
            payload = resp.read()
        except OSError as e:
            self.send_error(502, f"Nakama {NAKAMA_HOST}:{NAKAMA_PORT} 连不上: {e}")
            return
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() in HOP_BY_HOP or k.lower() == "content-length":
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def _proxy_websocket(self):
        """接管连接,原样把握手和后续字节双向搬运。

        不解析 WebSocket 帧 —— 握手让 Nakama 自己回,之后纯字节转发。
        """
        try:
            upstream = socket.create_connection((NAKAMA_HOST, NAKAMA_PORT), timeout=10)
        except OSError as e:
            self.send_error(502, f"Nakama {NAKAMA_HOST}:{NAKAMA_PORT} 连不上: {e}")
            return
        upstream.settimeout(None)

        req = [f"GET {self.path} HTTP/1.1"]
        for k, v in self.headers.items():
            if k.lower() == "host":
                v = f"{NAKAMA_HOST}:{NAKAMA_PORT}"
            req.append(f"{k}: {v}")
        upstream.sendall(("\r\n".join(req) + "\r\n\r\n").encode("latin-1"))

        self.close_connection = True
        client = self.connection
        t = threading.Thread(target=_pump, args=(upstream, client), daemon=True)
        t.start()
        _pump(client, upstream)

    # ---- 其它 ----

    def end_headers(self):
        if self._target() is None:
            # 导出时关了 thread_support,所以这两个头不是必需的;
            # 留着是为了将来万一开启多线程导出时不用回来改。
            # 反代出去的响应不加 —— 那是 API 响应,不是文档。
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
            self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        if "404" in (fmt % args):
            sys.stderr.write("  404: %s\n" % (fmt % args))


def _pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


if not os.path.isdir(ROOT):
    sys.exit(f"没有找到 {ROOT}\n先导出:见 tools/build_web.sh")

# WebSocket 是长连接,静态请求不能被它堵住 —— 必须多线程。
http.server.ThreadingHTTPServer.allow_reuse_address = True
with http.server.ThreadingHTTPServer(("", PORT), Handler) as httpd:
    print(f"  serving {ROOT}")
    print(f"  /v2/* 和 /ws → {NAKAMA_HOST}:{NAKAMA_PORT}(照抄线上路由)")
    print(f"  http://localhost:{PORT}/?player=a")
    print(f"  http://localhost:{PORT}/?player=b")
    print(f"  http://localhost:{PORT}/?player=c")
    print("  Ctrl-C 停止")
    httpd.serve_forever()
