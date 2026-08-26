#!/usr/bin/env python3
"""端到端边界场景:走神代出 / 中途掉线 / 房间列表状态流转。

对应计划 Task 13 的 Step 4、5、6 —— 原本要人肉开多窗口点,这里全自动。
用法:  python3 tools/e2e_edge.py
前置:  cd nakama && docker compose up -d
"""
import asyncio, json, sys, urllib.request
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from e2e_match import auth, rpc, Client, HAND, READY, START, THROW, \
    ROUND_BEGIN, ROUND_RESULT, GAME_OVER, GAME_STARTED, ROOM_STATE


async def setup(n, tag_prefix):
    clients = []
    for i in range(n):
        tag = chr(ord("a") + i)
        tok, uid = auth(f"{tag_prefix}-{tag}-0123456789")
        clients.append(Client(tag, tok, uid))
    room = rpc(clients[0].token, "create_room", {"game": "rps", "name": "edge"})
    for c in clients:
        await c.connect(room["match_id"])
        await c.join()
    await asyncio.sleep(1.5)
    for c in clients:
        await c.op(READY, {"ready": True})
    await asyncio.sleep(1.0)
    await clients[0].op(START)
    return clients, room["match_id"]


async def drain_until(c, want, timeout=15):
    while True:
        code, p = await asyncio.wait_for(c.inbox.get(), timeout)
        if code == want:
            return p


async def scenario_afk():
    print("=" * 60)
    print("场景 1:走神代出(afk_random 默认开)")
    print("  期望:不出拳的人被系统随机代出,不因走神直接淘汰")
    print("=" * 60)
    clients, _ = await setup(3, "edge-afk")
    by_uid = {c.user_id: c for c in clients}
    await drain_until(clients[0], GAME_STARTED)
    begin = await drain_until(clients[0], ROUND_BEGIN)
    alive = begin["alive"]
    silent = alive[-1]
    print(f"  存活 {len(alive)} 人,让 {by_uid[silent].tag} 完全不出拳")
    for uid in alive[:-1]:
        await by_uid[uid].op(THROW, {"hand": 0})     # 其余全出石头
    print(f"  其余出石头,等倒计时 {begin['seconds']}s 走完…")
    res = await drain_until(clients[0], ROUND_RESULT)
    afk = [by_uid[u].tag for u in res["afk"]]
    elim = [by_uid[u].tag for u in res["eliminated"]]
    got_hand = by_uid[silent].user_id in res["hands"]
    print(f"  服务端标记走神 : {afk}")
    print(f"  是否被代出手势 : {'✓ ' + HAND[res['hands'][silent]] if got_hand else '✗ 没有'}")
    print(f"  本轮淘汰       : {elim or '(无)'}")
    ok = afk == [by_uid[silent].tag] and got_hand
    print(f"  结论           : {'✓ 走神被标记并代出手势(之后胜负随机,不豁免淘汰)' if ok else '✗ 不符预期'}")
    for c in clients:
        await c.ws.close()
    return ok


async def scenario_disconnect():
    print()
    print("=" * 60)
    print("场景 2:对局中途掉线")
    print("  期望:剩下的人继续正常推进,不卡死,能打到局终")
    print("=" * 60)
    clients, _ = await setup(3, "edge-dc")
    by_uid = {c.user_id: c for c in clients}
    await drain_until(clients[0], GAME_STARTED)
    begin = await drain_until(clients[0], ROUND_BEGIN)
    victim = clients[-1]
    print(f"  开局 {len(begin['alive'])} 人,直接切断 {victim.tag} 的连接")
    await victim.ws.close()
    await asyncio.sleep(1.0)

    winner, guard = None, 0
    while winner is None and guard < 30:
        guard += 1
        code, p = await asyncio.wait_for(clients[0].inbox.get(), 15)
        if code == ROUND_BEGIN:
            alive = p["alive"]
            print(f"  第 {p['round']} 轮 · 存活 {len(alive)}"
                  f" ({', '.join(by_uid[u].tag for u in alive)})")
            plan = [0] * max(1, len(alive) // 2) + [2] * (len(alive) - max(1, len(alive) // 2))
            for uid, h in zip(alive, plan):
                if uid in by_uid and by_uid[uid] is not victim:
                    await by_uid[uid].op(THROW, {"hand": h})
        elif code == GAME_OVER:
            winner = p["results"][0] if p["results"] else None
    ok = winner is not None
    print(f"  结论           : {'✓ 掉线后对局正常打完' if ok else '✗ 卡死或未结束'}")
    for c in clients[:-1]:
        await c.ws.close()
    return ok


async def scenario_roomlist():
    print()
    print("=" * 60)
    print("场景 3:房间列表状态流转")
    print("  期望:开局后 phase 变 playing,局终回 waiting")
    print("=" * 60)
    clients, mid = await setup(2, "edge-rl")
    by_uid = {c.user_id: c for c in clients}
    tok = clients[0].token

    def phase_of():
        for r in rpc(tok, "list_rooms", "")["rooms"]:
            if r["match_id"] == mid:
                return r["phase"], r["count"]
        return None, None

    await drain_until(clients[0], GAME_STARTED)
    await asyncio.sleep(2.0)
    ph1, n1 = phase_of()
    print(f"  开局后         : phase={ph1}  人数={n1}")

    winner, guard = None, 0
    while winner is None and guard < 30:
        guard += 1
        code, p = await asyncio.wait_for(clients[0].inbox.get(), 15)
        if code == ROUND_BEGIN:
            for uid, h in zip(p["alive"], [1, 0]):
                await by_uid[uid].op(THROW, {"hand": h})
        elif code == GAME_OVER:
            winner = True
    await asyncio.sleep(2.0)
    ph2, n2 = phase_of()
    print(f"  局终后         : phase={ph2}  人数={n2}")
    ok = ph1 == "playing" and ph2 == "waiting"
    print(f"  结论           : {'✓ 状态流转正确' if ok else '✗ 不符预期'}")
    for c in clients:
        await c.ws.close()
    return ok


async def main():
    results = [await scenario_afk(), await scenario_disconnect(), await scenario_roomlist()]
    print()
    print("=" * 60)
    names = ["走神代出", "中途掉线", "房间列表状态"]
    for n, r in zip(names, results):
        print(f"  {n:<14} {'✓ 通过' if r else '✗ 失败'}")
    print("=" * 60)
    return 0 if all(results) else 1


sys.exit(asyncio.run(main()))
