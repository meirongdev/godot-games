#!/usr/bin/env python3
"""端到端回归测试:真实账号 + 真实 WebSocket,打完一整局猜拳。

不需要 Godot,不需要 GUI。验证的是服务端游戏循环的全链路:
设备认证 → create_room RPC → match_join → ready/start → 出拳 → 淘汰 → 局终。

用法:  python3 tools/e2e_match.py [玩家数] [强制平局轮数]
       强制平局用来验证「连续平局倒计时递减」在真实服务器上生效。
前置:  cd nakama && docker compose up -d
"""
import asyncio, json, base64, urllib.request, sys, os, websockets

# 默认打本地 compose;设环境变量即可打任何部署,不用改源码:
#   NAKAMA_HOST=nakama.example.com NAKAMA_PORT=443 NAKAMA_TLS=1 \
#   NAKAMA_KEY=<server_key> python3 tools/e2e_match.py 3
HOST = os.environ.get("NAKAMA_HOST", "127.0.0.1")
PORT = int(os.environ.get("NAKAMA_PORT", "7350"))
KEY  = os.environ.get("NAKAMA_KEY", "family-lobby-2026")
_TLS = os.environ.get("NAKAMA_TLS", "") not in ("", "0", "false")
HTTP_SCHEME = "https" if _TLS else "http"
WS_SCHEME   = "wss"   if _TLS else "ws"
HAND = {0: "石头", 1: "布", 2: "剪刀"}
READY, START, ROOM_STATE, GAME_STARTED, GAME_OVER = 1, 2, 10, 11, 12
THROW, ROUND_BEGIN, ROUND_RESULT = 20, 30, 31


def _post(url, body, headers):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers)
    return json.load(urllib.request.urlopen(req))


def auth(device_id):
    basic = base64.b64encode(f"{KEY}:".encode()).decode()
    tok = _post(f"{HTTP_SCHEME}://{HOST}:{PORT}/v2/account/authenticate/device?create=true",
                {"id": device_id},
                {"Content-Type": "application/json",
                 "Authorization": "Basic " + basic})["token"]
    # user_id 就在 JWT 载荷里,省一次请求
    pad = tok.split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(pad + "=" * (-len(pad) % 4)))
    return tok, claims["uid"]


def rpc(token, name, payload):
    out = _post(f"{HTTP_SCHEME}://{HOST}:{PORT}/v2/rpc/{name}", json.dumps(payload),
                {"Content-Type": "application/json",
                 "Authorization": f"Bearer {token}"})
    return json.loads(out["payload"])


class Client:
    def __init__(self, tag, token, user_id):
        self.tag, self.token, self.user_id = tag, token, user_id
        self.cid, self.inbox = 0, asyncio.Queue()

    async def connect(self, match_id):
        self.match_id = match_id
        self.ws = await websockets.connect(
            f"{WS_SCHEME}://{HOST}:{PORT}/ws?lang=en&status=true&format=json&token={self.token}")
        asyncio.create_task(self._pump())

    async def _pump(self):
        try:
            async for raw in self.ws:
                m = json.loads(raw)
                if "match_data" in m:
                    d = m["match_data"]
                    await self.inbox.put((
                        int(d.get("op_code", 0)),
                        json.loads(base64.b64decode(d.get("data") or "e30=").decode())))
        except Exception:
            pass

    async def _send(self, obj):
        self.cid += 1
        obj["cid"] = str(self.cid)
        await self.ws.send(json.dumps(obj))

    async def join(self):
        await self._send({"match_join": {"match_id": self.match_id}})

    async def op(self, code, data=None):
        await self._send({"match_data_send": {
            "match_id": self.match_id, "op_code": str(code),
            "data": base64.b64encode(json.dumps(data or {}).encode()).decode()}})

    async def next(self, timeout=15):
        return await asyncio.wait_for(self.inbox.get(), timeout)


def choose(alive_count, force_draw=False):
    """构造出拳。force_draw 时三种手势都出(服务端判平局),否则只出两种。"""
    if alive_count < 2:
        return []
    if force_draw and alive_count >= 3:
        # 三种手势都出现 → 服务端判平局,用来验证倒计时加速
        return [i % 3 for i in range(alive_count)]
    half = max(1, alive_count // 2)
    return [0] * half + [2] * (alive_count - half)


async def run(n, force_draws=0):
    print(f"=== 1. {n} 个设备账号认证 ===")
    clients = []
    for i in range(n):
        tag = chr(ord("a") + i)
        tok, uid = auth(f"e2e-device-{tag}-0123456789")
        clients.append(Client(tag, tok, uid))
        print(f"  {tag}  user_id={uid[:8]}…")
    by_uid = {c.user_id: c for c in clients}

    print("\n=== 2. create_room RPC ===")
    room = rpc(clients[0].token, "create_room", {"game": "rps", "name": "e2e"})
    print(f"  match_id={room['match_id'][:8]}…  name={room['name']}")

    print(f"\n=== 3. {n} 人加入对局 ===")
    for c in clients:
        await c.connect(room["match_id"])
        await c.join()
    await asyncio.sleep(1.5)

    print("\n=== 4. 全员准备 → 房主开局 ===")
    for c in clients:
        await c.op(READY, {"ready": True})
    await asyncio.sleep(1.0)
    await clients[0].op(START)

    print("\n=== 5. 对局 ===")
    winner, guard, countdowns = None, 0, []
    while winner is None and guard < 40:
        guard += 1
        code, p = await clients[0].next()

        if code == GAME_STARTED:
            print(f"  GAME_STARTED  settings={p['settings']}")

        elif code == ROUND_BEGIN:
            alive, secs = p["alive"], p["seconds"]
            countdowns.append(secs)
            streak = p.get("draw_streak", 0)
            note = f"  ← 连续平局 ×{streak},加速" if streak else ""
            print(f"\n  第 {p['round']} 轮 · 存活 {len(alive)} · 倒计时 {secs}s{note}")
            plan = choose(len(alive), force_draw=(p["round"] <= force_draws))
            for uid, hand in zip(alive, plan):
                await by_uid[uid].op(THROW, {"hand": hand})

        elif code == ROUND_RESULT:
            shown = "  ".join(f"{by_uid[u].tag}:{HAND[h]}" for u, h in p["hands"].items())
            print(f"    {shown}")
            if p["draw"]:
                print(f"    平局(连续 {p['draw_streak']} 次)")
            else:
                elim = ", ".join(by_uid[u].tag for u in p["eliminated"])
                print(f"    {HAND[p['winner']]} 胜 → 晋级 {len(p['advanced'])}"
                      + (f",淘汰 {elim}" if elim else ""))

        elif code == GAME_OVER:
            winner = p["results"][0] if p["results"] else None
            print(f"\n  🏆 GAME_OVER  胜者 = {winner['name'] if winner else '(无)'}")

    for c in clients:
        await c.ws.close()

    ok = winner is not None
    print("\n=== 结果 ===")
    print(f"  局终            : {'✓' if ok else '✗ 未在 40 条消息内结束'}")
    print(f"  各轮倒计时       : {countdowns}")
    accel = any(b < a for a, b in zip(countdowns, countdowns[1:]))
    print(f"  平局加速生效     : {'✓ 观察到倒计时缩短' if accel else '— 本次未出现连续平局'}")
    return 0 if ok else 1


if __name__ == "__main__":
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    draws = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    sys.exit(asyncio.run(run(n, draws)))
