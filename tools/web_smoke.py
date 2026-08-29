#!/usr/bin/env python3
"""冒烟测试:在**真浏览器**里把 Web 制品从登录页跑进大厅、再跑进房间。

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

**为什么要点别人的房间、还要退出来再建一个:**
「建房进房间」和「点房间列表进房间」是两条完全不同的路径 —— 前者点的是 Button,
后者点的是 ItemList 的一行,而 2026-08-28 那个 bug 正好只在后者上现形。所以
冒烟测试先用另一个玩家(Python 客户端,不走 Godot)建一个房,浏览器**从列表里
点进去**,再点「退出」回大厅,最后才自己建房 —— 顺带盖住「退出房间后回大厅」
这条路。

**为什么要一路点到房间里:**
2026-08-27 上线后手机端报「进不了房间」,根因是进房那一刻服务端广播的
ROOM_STATE 被客户端丢掉(见 ServerConnection.join_room_async 的注释),
房间页停在写死的「房间」+ 空花名册 —— 长得和「进房失败」一模一样。
这个 bug 躲过了全部 7 层测试:Lua 单测只管服务端;e2e_match.py 用的是
自己写的 Python 客户端,根本不跑 ServerConnection;而这个脚本当时停在大厅。
所以门禁必须往前推一步:真的进到房间里,并断言房间页拿到了状态。

**为什么手机档位必须用真的 touch 事件:**
2026-08-28 上线后手机端报「双击进不了房间」。原因是 ItemList 的 item_activated
只在事件带「双击」标记时才发,而 Godot Web 的触屏回调根本不传这个标记
(见 Lobby.gd 里 item_clicked 那段注释)。这个脚本当时用 Input.dispatchMouseEvent
点按钮 —— 鼠标的双击是引擎按时间差自己算的,永远是好的 —— 于是**手机档位在用
鼠标测手机**,这类「只有手指点不动」的 bug 一条都看不见。现在手机档位一律发
Input.dispatchTouchEvent。

⚠️ 标签页必须是**可见**的。Chrome 对隐藏标签不跑 requestAnimationFrame,
而 Godot 的主循环就挂在 rAF 上 —— 标签一隐藏,引擎直接不转,任何等待都会
超时,看起来像「网络卡住」。无头模式没有这个问题,所以这里固定用无头。
"""
import asyncio
import base64
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

import websockets

# 同目录的两个本地模块。显式把 tools/ 放进 sys.path —— 只靠 sys.path[0]
# 的话,换个方式调用(python3 -m、从别处 import)就会 ImportError。
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# 「另一个玩家」直接复用 e2e_match 里的设备认证和 RPC —— 它不经过 Godot,
# 起一个房间只要两个 HTTP 请求,比再开一个浏览器便宜得多。
import e2e_match
# 客户端诊断记录的解析。语法与 godot/src/net/Probe.gd 一一对应,
# 契约由 check_probe.gd | probe.py --verify 守着(tools/build_web.sh 里跑)。
import probe

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 9333

# 名字每次都要换,而且两个档位之间也要不一样(理由见上)。
# Login.gd 限名字最长 12 个字,所以 5 位时间戳 + 1 位档位标记。
NAME_BASE = "smoke" + str(int(time.time()))[-5:]

# 两个档位都要过。手机档位是这次的重点,桌面档位防回归。
# dsf = deviceScaleFactor。逻辑坐标换 CSS 像素时要用(CDP 的输入坐标是 CSS 像素,
# 而客户端 viewport 记录里的窗口尺寸是物理像素)。桌面档位不覆写 metrics,所以是 1。
# 这一栏是**唯一**的 dsf 来源:CDP 的 setDeviceMetricsOverride 也读它。
# pointer:桌面发鼠标事件,手机发**真的触屏事件**。这一栏不是形式主义 ——
# 用鼠标点手机档位,等于没测手机(见上面的说明)。
TIERS = [
    {"name": "桌面", "win": None, "tag": "d", "dsf": 1, "pointer": "mouse"},
    {"name": "手机竖屏", "win": (390, 844), "tag": "m", "dsf": 3, "pointer": "touch"},
]

# 逻辑视口宽度的上限(手机档位)。基准分辨率不对时这里会是 1280,
# 内容被缩到 30%,按钮实际高约 18pt —— iOS 的最小点击目标是 44pt。
MOBILE_VIEWPORT_MAX = 480

CHROME_CANDIDATES = [
    os.environ.get("CHROME", ""),
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
]


def assert_port_free():
    """调试端口必须是干净的,否则会连错浏览器。

    ⚠️ 这不是洁癖。PORT 是固定的,而 run() 靠 `/json/list` 找页面 target ——
    端口上要是还挂着上一次没退干净的 Chrome(比如被 kill 掉的自动化任务留下的),
    我们会**连上那个旧浏览器**并驱动它。它身上可能还留着上次的
    setDeviceMetricsOverride,于是「桌面档位」跑出手机视口,断言以
    「没能进大厅」的形式失败 —— 症状和真实的代码回归一模一样,
    2026-08-27 为此白查了一轮。宁可一开始就报错。
    """
    with socket.socket() as sock:
        if sock.connect_ex(("127.0.0.1", PORT)) == 0:
            sys.exit(
                f"✗ 调试端口 {PORT} 已被占用 —— 很可能是上次没退干净的 Chrome。\n"
                f"  先清掉再跑:lsof -ti tcp:{PORT} | xargs -r kill -9")


def guest_room(name):
    """让「另一个玩家」建一个房,返回房名 —— 浏览器等下要从列表里点它。

    刻意不再开一个浏览器:这一步只需要往房间列表里放一行可点的东西,
    两个 HTTP 请求就够了(e2e_match 的设备认证 + create_room RPC),
    而且顺带保证了这个房**不是这个客户端自己建的**。
    ⚠️ 空房间 60 秒会被 room.lua 自动关掉,所以建完要马上点。
    """
    room = "别人的房" + name
    tok, _uid = e2e_match.auth("web-smoke-guest-" + name)
    e2e_match.rpc(tok, "create_room", {"game": "rps", "name": room})
    return room


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

    # 点一下。⚠️ kind 一定要跟档位走:手机档位发鼠标事件等于没测手机 ——
    # 鼠标和触屏在引擎里是两条不同的路径,而「只有手指点不动」的 bug
    # 只在触屏那条上现形(见模块文档)。
    async def point(self, x, y, kind="mouse"):
        await (self.tap(x, y) if kind == "touch" else self.click(x, y))

    async def tap(self, x, y):
        await self.send("Input.dispatchTouchEvent", {
            "type": "touchStart", "touchPoints": [{"x": x, "y": y}]})
        await asyncio.sleep(0.05)
        await self.send("Input.dispatchTouchEvent", {
            "type": "touchEnd", "touchPoints": []})
        await asyncio.sleep(0.05)

    # 登录流程已经不用坐标了,但点按钮这个原语留着 —— 大厅/房间的交互
    # (建房、准备、开局)只能靠点,扩冒烟测试的人需要它。
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

    async def press_enter(self):
        base = {"key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13,
                "nativeVirtualKeyCode": 13, "text": "\r", "unmodifiedText": "\r"}
        for t in ("keyDown", "char", "keyUp"):
            await self.send("Input.dispatchKeyEvent", dict(base, type=t))
            await asyncio.sleep(0.03)

    async def shot(self, path):
        mid = await self.send("Page.captureScreenshot", {"format": "png"})
        self._shots[mid] = path


async def run(url, shot_path, name, win=None, dsf=1, pointer="mouse"):
    assert_port_free()
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

            if win:
                # dsf 从档位表来,不再在这里写第二遍 —— 两处数字曾经各改各的,
                # 而对不上的后果是坐标静静地偏掉,点到别的控件上。
                await page.send("Emulation.setDeviceMetricsOverride", {
                    "width": win[0], "height": win[1],
                    "deviceScaleFactor": dsf, "mobile": True})
                # 特意不开 Emulation.setTouchEmulationEnabled。实测(A/B/C/D/E 五组
                # 对照)一开它,name 就打不进去、Enter 也没反应,登录卡死在 viewport 记录
                # 之后 —— 跟视口尺寸无关(单独开它、不带 metrics override 照样卡)。
                #
                # 机制不是「Chrome 吞事件」,是**焦点换了地方**:
                # export_presets.cfg 里 html/experimental_virtual_keyboard=true,
                # 而 Godot Web 的 FEATURE_VIRTUAL_KEYBOARD 是按运行时触屏探测
                # ('ontouchstart' in window)开关的 —— setTouchEmulationEnabled
                # 正好把它打开(setDeviceMetricsOverride{mobile:true} 不会)。
                # LineEdit.virtual_keyboard_enabled 默认 true,于是 grab_focus()
                # 时 Godot 会新建并聚焦一个贴在 canvas 旁边的隐藏 DOM <input>
                # 来接软键盘输入,打在 canvas 上的键事件自然进不去。
                #
                # ⚠️ 推论:**真机上的文字输入走的就是这条 DOM 覆盖层路径,
                # 这个测试完全没覆盖到。** 软键盘相关的行为只能真机验。

            await page.send("Page.navigate", {"url": f"{url}/?player={name}"})
            await asyncio.sleep(10)          # 38 MB wasm,给足加载时间

            # ⚠️ 不用像素坐标。Login.gd 里 name_edit 开局就 grab_focus(),
            # 软键盘的回车会触发 text_submitted —— 布局怎么改都不影响这里。
            await page.type(name)
            await asyncio.sleep(1)
            await page.press_enter()
            await asyncio.sleep(12)
            if shot_path:
                await page.shot(shot_path)
                await asyncio.sleep(1)

            # ---- ① 从房间列表点进**别人**的房间。
            # 这一步和「点建房」不是一条路:那边点的是 Button,这边点的是
            # ItemList 的一行,2026-08-28 的 bug 只在这边现形。
            try:
                guest = guest_room(name)
            except Exception as e:
                # Nakama 没起来这一步就会炸。别让它掀掉整轮 —— 后面的断言
                # 会以「没进大厅」的形式一起报出来,比一个 traceback 好读。
                guest = ""
                page.logs.append(f"SMOKE 另一个玩家建不出房:{e}")
            await asyncio.sleep(6)     # 等大厅那 3 秒一次的轮询把它捞进列表
            # ⚠️ guest 为空时**不能**去找行:room_row_css 的匹配是子串,
            # 空串命中每一行,会点到一个随机房间上去。
            row = room_row_css(page.logs, dsf, guest) if guest else None
            if row is None:
                page.logs.append(f"SMOKE 房间列表里没有「{guest}」这一行")
            else:
                await page.point(*row, kind=pointer)
                await asyncio.sleep(8)
                if shot_path:
                    await page.shot(shot_path.replace(".png", "_joined.png"))
                    await asyncio.sleep(1)

            # ---- ② 点「退出」回大厅。顺带盖住「退了还能不能再来一次」——
            # 这条路上曾经有过 bug(见 create_room_async 的注释)。
            back = rect_css(page.logs, dsf, r"退出按钮 (\d+),(\d+) (\d+)x(\d+)")
            if back is None:
                page.logs.append("SMOKE 没能定位退出按钮(压根没进到房间里?)")
            else:
                await page.point(*back, kind=pointer)
                await asyncio.sleep(6)

            # ---- ③ 自己建一个房。房名留空,服务端会起「<名字>的房间」,
            # check() 靠这个名字确认房间页拿到的是**这个**房间的状态。
            target = rect_css(page.logs, dsf, r"建房按钮 (\d+),(\d+) (\d+)x(\d+)")
            if target is None:
                page.logs.append("SMOKE 没能定位建房按钮(缺 [layout] 日志)")
            else:
                await page.point(*target, kind=pointer)
                await asyncio.sleep(8)
                if shot_path:
                    await page.shot(shot_path.replace(".png", "_room.png"))
                    await asyncio.sleep(1)
            pump.cancel()
            return page.logs
    finally:
        chrome.kill()
        # 两个档位顺序跑、共用固定的调试端口,kill 之后要真的等它退出,
        # 否则下一个档位可能绑不上 9333,报一个完全看不懂的错。
        try:
            chrome.wait(timeout=5)
        except Exception:
            pass
        shutil.rmtree(profile, ignore_errors=True)


def check(logs, name, mobile=False):
    """判定:进没进大厅、进没进房间。

    断言分两类,刻意分开:
      - **记录类**走 probe.records() —— 客户端主动上报的结构化事实。
      - **痕迹类**还是在原始日志里找子串 —— 引擎和网络栈自己打的东西
        (list_rooms 请求、gzip 解压失败、HTTPRequest failed),
        它们不归 Probe 管,也不该归。
    """
    blob = "\n".join(logs)
    recs = probe.records(logs)
    problems = []

    # ---- 痕迹类 ----
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

    # ---- 记录类 ----
    # 自己必须出现在「在线」里。channel.presences 不含自己,自己是靠一条单独的
    # presence 事件来的 —— 那条事件和 join 的 await 有竞争,曾经时灵时不灵。
    if not any(r.get("count", 0) >= 1 for r in probe.of_kind(recs, "lobby_online")):
        problems.append("大厅「在线」列表里没有自己"
                        " —— join_lobby_async 是不是又把 self_presence 丢了?")

    if probe.last_of(recs, "config") is None:
        problems.append("客户端没发 config 记录:服务器地址没推导出来")

    # 手机档位专属:逻辑视口必须是手机尺寸,不能是 1280。
    # 桌面档位下 1024 宽是正常的,所以只在手机档位查。
    if mobile:
        vp = probe.last_of(recs, "viewport")
        if vp is None:
            problems.append("没收到 viewport 记录,量不出 UI 尺寸")
        elif vp["vp_w"] > MOBILE_VIEWPORT_MAX:
            problems.append(
                f"逻辑视口宽 {vp['vp_w']},超过 {MOBILE_VIEWPORT_MAX}"
                f" —— 基准分辨率还是桌面的,手机上内容会被缩得点不到")

    # 房间页必须真的拿到进房那一刻的 ROOM_STATE。缺这条不是「没点到按钮」,
    # 更可能是那条状态又被丢了 —— 房间页会停在写死的「房间」+ 空花名册,
    # 用户看到的就是「进不了房间」。
    rooms = probe.of_kind(recs, "room_state")
    guest = "别人的房" + name
    if not rooms:
        problems.append("没收到 room_state:一个房间都没进去,"
                        "或者进房的 ROOM_STATE 又被丢了")
        return problems

    # ① 第一个进的必须是从**列表里点进去**的那个别人的房间。
    if guest not in rooms[0]["name"]:
        problems.append(
            f"第一个进的房间是「{rooms[0]['name']}」,不是从列表里点进的「{guest}」"
            f" —— 点房间行进不去了?(手机档位上这条最容易断,见模块文档)")
    # ③ 最后停在自己建的房间里 —— 中间还夹着一次「退出回大厅」。
    last = rooms[-1]
    if name not in last["name"]:
        problems.append(
            f"最后停在「{last['name']}」而不是自己建的房 ——"
            f" 退出回大厅、或者回来之后再建房这一步断了")
    if last["players"] != 1:
        problems.append(f"自己建的房里显示 {last['players']} 人,应该是 1 人(花名册没拿到?)")
    if last["phase"] != "waiting":
        problems.append(f"自己建的房 phase={last['phase']},刚建的房应该是 waiting")

    return problems


def main():
    url = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else None
    server = None

    if url is None:
        if not os.path.isdir(os.path.join(ROOT, "build", "web")):
            sys.exit("没有 build/web/ —— 先跑 tools/build_web.sh")
        server = subprocess.Popen(
            [sys.executable, os.path.join(ROOT, "tools", "serve_web.py"), "8080"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        url = "http://localhost:8080"
        time.sleep(2)

    failed = []
    try:
        for tier in TIERS:
            shot = os.path.join(
                tempfile.gettempdir(),
                f"web_smoke_{'mobile' if tier['win'] else 'desktop'}.png")
            name = NAME_BASE + tier["tag"]
            print(f"\n=== {tier['name']} ===")
            logs = asyncio.run(run(url, shot, name, tier["win"], tier["dsf"],
                                   tier["pointer"]))
            problems = check(logs, name, mobile=bool(tier["win"]))
            print(f"  截图:{shot}")
            print(f"        {shot.replace('.png', '_joined.png')}")
            print(f"        {shot.replace('.png', '_room.png')}")
            if problems:
                failed.append(tier["name"])
                print(f"  ✗ {tier['name']} 失败:")
                for p in problems:
                    print(f"      - {p}")
                print("    控制台最后 20 行:")
                for line in logs[-20:]:
                    print("      " + line[:180])
            else:
                print(f"  ✓ {tier['name']} 通过")
    finally:
        if server:
            server.terminate()

    if failed:
        print("\n✗ Web 冒烟失败:" + "、".join(failed))
        return 1
    print("\n✓ Web 冒烟通过:桌面(鼠标) + 手机竖屏(触屏),"
          "登录 → 大厅 → 点进别人的房间 → 退出 → 自己建房 都走通")
    return 0


if __name__ == "__main__":
    sys.exit(main())
