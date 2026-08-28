#!/usr/bin/env python3
"""端到端边界场景:走神代出 / 中途掉线 / 房间列表状态流转 / 掉线重连观战。

对应计划 Task 13 的 Step 4、5、6 —— 原本要人肉开多窗口点,这里全自动。
场景 4(2026-08-28 补)对应「桌面打了 5 轮,手机还在等待」:对局中掉线的人
要能回到房间观战,局终后正常再战,而不是被「游戏已开始」锁在门外。
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


async def scenario_rejoin():
    print()
    print("=" * 60)
    print("场景 4:对局中掉线的人重连回房")
    print("  期望:能进(观战席),看得到局终,局终后能再准备 —— 不是被锁在门外")
    print("=" * 60)
    clients, mid = await setup(3, "edge-rj")
    by_uid = {c.user_id: c for c in clients}
    await drain_until(clients[0], GAME_STARTED)
    begin = await drain_until(clients[0], ROUND_BEGIN)
    victim = clients[-1]
    print(f"  开局 {len(begin['alive'])} 人,第 1 轮全员平局后 {victim.tag} 掉线")
    for c in clients:                       # 全出石头:平局,局面稳住
        await c.op(THROW, {"hand": 0})
    await drain_until(clients[0], ROUND_RESULT)
    await victim.ws.close()

    # 掉线者缺席地打两轮(平局拖着)
    rounds = 0
    while rounds < 2:
        code, p = await asyncio.wait_for(clients[0].inbox.get(), 15)
        if code == ROUND_BEGIN:
            rounds += 1
            for uid in p["alive"]:
                if by_uid.get(uid) is not victim:
                    await by_uid[uid].op(THROW, {"hand": 0})
            await drain_until(clients[0], ROUND_RESULT)

    print(f"  {victim.tag} 带新 socket 重连进房…")
    back = Client(victim.tag, victim.token, victim.user_id)
    await back.connect(mid)
    await back.join()

    # 重连者应收到:ROOM_STATE(花名册含自己)→ GAME_STARTED → 回合快照
    got, deadline = {}, 8
    try:
        while len(got) < 3:
            code, p = await asyncio.wait_for(back.inbox.get(), deadline)
            if code in (ROOM_STATE, GAME_STARTED, ROUND_BEGIN) and code not in got:
                got[code] = p
    except asyncio.TimeoutError:
        pass
    in_roster = ROOM_STATE in got and any(
        pl["id"] == victim.user_id for pl in got[ROOM_STATE]["players"])
    snap = got.get(ROUND_BEGIN)
    spectating = snap is not None and victim.user_id not in snap["alive"]
    print(f"  回到花名册     : {'✓' if in_roster else '✗'}")
    print(f"  收到游戏现场   : {'✓ GAME_STARTED + 第 %d 轮快照' % snap['round'] if snap else '✗'}")
    print(f"  以观战身份     : {'✓ 不在 alive 里' if spectating else '✗ 竟然还在对局里'}")

    # 分出胜负:a 布 b 石头 → 局终,重连者也要看得到
    over = None
    for _ in range(20):
        code, p = await asyncio.wait_for(clients[0].inbox.get(), 15)
        if code == ROUND_BEGIN:
            for uid, h in zip(p["alive"], [1, 0]):
                if by_uid.get(uid) is not victim:
                    await by_uid[uid].op(THROW, {"hand": h})
        elif code == GAME_OVER:
            over = p
            break
    saw_over = False
    try:
        while True:
            code, p = await asyncio.wait_for(back.inbox.get(), 8)
            if code == GAME_OVER:
                saw_over = True
                break
    except asyncio.TimeoutError:
        pass
    print(f"  观战到局终     : {'✓' if saw_over else '✗ 没收到 GAME_OVER'}")

    # 局终后正常再准备(下一局自动参加的前提)
    await back.op(READY, {"ready": True})
    ready_ok = False
    try:
        while True:
            code, p = await asyncio.wait_for(back.inbox.get(), 8)
            if code == ROOM_STATE:
                for pl in p["players"]:
                    if pl["id"] == victim.user_id and pl["ready"]:
                        ready_ok = True
                if ready_ok:
                    break
    except asyncio.TimeoutError:
        pass
    print(f"  局终后能再战   : {'✓ ready 生效' if ready_ok else '✗'}")

    ok = in_roster and snap is not None and spectating and over is not None         and saw_over and ready_ok
    print(f"  结论           : {'✓ 掉线的人回得来、看得到、下局能打' if ok else '✗ 不符预期'}")
    for c in clients[:-1]:
        await c.ws.close()
    await back.ws.close()
    return ok


async def main():
    results = [await scenario_afk(), await scenario_disconnect(),
               await scenario_roomlist(), await scenario_rejoin()]
    print()
    print("=" * 60)
    names = ["走神代出", "中途掉线", "房间列表状态", "掉线重连观战"]
    for n, r in zip(names, results):
        print(f"  {n:<14} {'✓ 通过' if r else '✗ 失败'}")
    print("=" * 60)
    return 0 if all(results) else 1


sys.exit(asyncio.run(main()))
