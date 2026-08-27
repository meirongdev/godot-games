#!/usr/bin/env python3
"""冒烟测试:在**真浏览器**里把 Web 制品从登录页跑进大厅。

用法:  python3 tools/web_smoke.py            # 自己起 serve_web.py
       python3 tools/web_smoke.py <url>     # 打一个已经在跑的地址
前置:  cd nakama && docker compose up -d;先 tools/build_web.sh 出过制品

**为什么非要真浏览器:**
Web 版的客户端行为,桌面运行和 Python e2e 都验不出来 —— 它们各自走自己的
HTTP 栈。2026-08-27 上线卡死就是这么漏的:Godot 的 HTTPRequest 在 Web 上
底层是浏览器 fetch,响应体已经被浏览器解过 gzip,Godot 按 Content-Encoding
再解一次,必然失败(result=8),服务端 200 而客户端拿不到响应。
桌面版自己收发 HTTP 拿到真 gzip 字节,解得开;e2e_match.py 根本不经过 Godot。
两层测试全绿,页面一开就废。

契约 §4.2.1 原本写的是「必须单独做一次:真的开一次页面」—— 手动步骤。
这个脚本就是把那一步变成门禁。

⚠️ 标签页必须是**可见**的。Chrome 对隐藏标签不跑 requestAnimationFrame,
而 Godot 的主循环就挂在 rAF 上 —— 标签一隐藏,引擎直接不转,任何等待都会
超时,看起来像「网络卡住」。无头模式没有这个问题,所以这里固定用无头。
"""
import asyncio
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

import websockets

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 9333

# 每次都要换名字:Chrome profile 是临时目录,IndexedDB 每跑一次都是空的,
# 于是 Nakama 的设备 ID 每次重新生成 → 每次都是新账号。而 Nakama 的 username
# 全局唯一,固定名字第二次跑就会撞上「Username is already in use」。
# Login.gd 限名字最长 12 个字,所以只取时间戳后 6 位。
NAME = "smoke" + str(int(time.time()))[-6:]

CHROME_CANDIDATES = [
    os.environ.get("CHROME", ""),
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
]


def find_chrome():
    for c in CHROME_CANDIDATES:
        if c and (os.path.exists(c) or shutil.which(c)):
            return c
    sys.exit("找不到 Chrome(用 CHROME=/path/to/chrome 指定)")


class Page:
    """够用就好的 CDP 客户端:开页面、发输入、收控制台。"""

    def __init__(self, ws):
        self.ws = ws
        self._id = 0
        self.logs = []

    async def send(self, method, params=None):
        self._id += 1
        await self.ws.send(json.dumps(
            {"id": self._id, "method": method, "params": params or {}}))
        return self._id

    async def pump(self):
        async for raw in self.ws:
            m = json.loads(raw)
            if m.get("method") == "Runtime.consoleAPICalled":
                text = " ".join(
                    str(a.get("value", a.get("description", "")))
                    for a in m["params"]["args"])
                self.logs.append(text)
            elif m.get("method") == "Runtime.exceptionThrown":
                self.logs.append("EXCEPTION " + m["params"]["exceptionDetails"].get("text", ""))
            elif m.get("id") in self._shots:
                path = self._shots.pop(m["id"])
                open(path, "wb").write(base64.b64decode(m["result"]["data"]))

    _shots = {}

    async def click(self, x, y):
        for t, buttons in (("mousePressed", 1), ("mouseReleased", 0)):
            await self.send("Input.dispatchMouseEvent", {
                "type": t, "x": x, "y": y, "button": "left",
                "clickCount": 1, "buttons": buttons})
            await asyncio.sleep(0.05)

    async def type(self, text):
        # Godot 的 canvas 只认带 key/code 的完整键事件,光给 text 不动。
        for ch in text:
            code = ("Digit" + ch) if ch.isdigit() else ("Key" + ch.upper())
            vk = ord(ch.upper())
            base = {"key": ch, "code": code, "windowsVirtualKeyCode": vk,
                    "nativeVirtualKeyCode": vk, "text": ch, "unmodifiedText": ch}
            for t in ("keyDown", "char", "keyUp"):
                await self.send("Input.dispatchKeyEvent", dict(base, type=t))
                await asyncio.sleep(0.02)

    async def shot(self, path):
        mid = await self.send("Page.captureScreenshot", {"format": "png"})
        self._shots[mid] = path


async def run(url, shot_path):
    profile = tempfile.mkdtemp(prefix="web-smoke-")
    chrome = subprocess.Popen([
        find_chrome(), "--headless=new", f"--remote-debugging-port={PORT}",
        f"--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check",
        "--enable-unsafe-swiftshader", "--window-size=1280,860",
        "about:blank",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    ws_url = None
    for _ in range(120):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json/list", timeout=1) as r:
                pages = [t for t in json.load(r) if t.get("type") == "page"]
            if pages:
                ws_url = pages[0]["webSocketDebuggerUrl"]
                break
        except Exception:
            pass
        await asyncio.sleep(0.25)
    if not ws_url:
        chrome.kill()
        sys.exit("Chrome 起不来")

    try:
        async with websockets.connect(ws_url, max_size=20_000_000) as ws:
            page = Page(ws)
            await page.send("Runtime.enable")
            await page.send("Page.enable")
            pump = asyncio.create_task(page.pump())

            await page.send("Page.navigate", {"url": f"{url}/?player={NAME}"})
            await asyncio.sleep(10)          # 38 MB wasm,给足加载时间

            await page.click(640, 392)        # 名字输入框
            await page.type(NAME)
            await asyncio.sleep(1)
            await page.click(640, 464)        # 「进入大厅」
            await asyncio.sleep(12)
            if shot_path:
                await page.shot(shot_path)
                await asyncio.sleep(1)
            pump.cancel()
            return page.logs
    finally:
        chrome.kill()
        shutil.rmtree(profile, ignore_errors=True)


def check(logs):
    """判定:进没进大厅。"""
    blob = "\n".join(logs)
    problems = []

    # 只有 Lobby 场景会发 list_rooms —— 它出现,就说明
    # 认证 → 改名 → 刷 session → socket → 切场景 整条链都过了。
    if "/v2/rpc/list_rooms" not in blob:
        problems.append("没看到 list_rooms:没能进大厅")

    # 这条是 gzip 双重解压的指纹,单独拎出来报,免得下次又从部署侧查起。
    if "result: 8" in blob or "stream_peer_gzip" in blob:
        problems.append("HTTP 响应解压失败(result=8)"
                        " —— NakamaHTTPAdapter 的 accept_gzip=false 丢了?")

    if "HTTPRequest failed" in blob:
        problems.append("有请求失败(HTTPRequest failed)")

    if "[config]" not in blob:
        problems.append("客户端没打印 [config]:服务器地址没推导出来")

    return problems


def main():
    url = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else None
    shot = os.path.join(tempfile.gettempdir(), "web_smoke.png")
    server = None

    if url is None:
        if not os.path.isdir(os.path.join(ROOT, "build", "web")):
            sys.exit("没有 build/web/ —— 先跑 tools/build_web.sh")
        server = subprocess.Popen(
            [sys.executable, os.path.join(ROOT, "tools", "serve_web.py"), "8080"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        url = "http://localhost:8080"
        time.sleep(2)

    try:
        logs = asyncio.run(run(url, shot))
    finally:
        if server:
            server.terminate()

    problems = check(logs)
    print(f"  截图:{shot}")
    if problems:
        print("\n✗ Web 冒烟失败:")
        for p in problems:
            print(f"    - {p}")
        print("\n  控制台最后 25 行:")
        for line in logs[-25:]:
            print("    " + line[:200])
        return 1
    print("✓ Web 冒烟通过:登录 → 大厅走通")
    return 0


if __name__ == "__main__":
    sys.exit(main())
