#!/usr/bin/env python3
"""端到端:**真客户端**的断线自愈 —— 半开连接被探活发现、强制重连、自动回房。

用法:  python3 tools/e2e_client_reconnect.py
前置:  cd nakama && docker compose up -d;本机有 godot(或 GODOT=/path 指定)

**为什么要有这一层:**
「手机玩着玩着不动了」的最坏形态是**半开连接**:Wi-Fi 切 4G、蜂窝网 NAT 超时
之后,客户端的 socket 看起来还连着(get_ready_state() = OPEN),发出去的全进
黑洞,服务端早就把人从房间移走了 —— 桌面打了 5 轮,手机还停在「等待」
(2026-08-28 用户实报)。这条路层 1–6 一层都跑不到:e2e_match/e2e_edge 是
Python 客户端,web_smoke 不掐网,桌面真玩拔网线是 close 不是黑洞。

做法:起一个可**冻结**的 TCP 代理(冻结 = 双向不再转发但 TCP 不断),让
headless Godot 跑真的 ServerConnection(tests/NetProbe.tscn)连代理进房,
然后冻结代理,断言:
  1. 客户端在限时内自己发现连接死了(ping 探活)→ 判死(probe_timeout)
  2. 解冻后自己重连 → socket_connected
  3. 自己回到房间 → room_state(不需要用户做任何事)

**判死里程碑用决策记录 net/probe_timeout,不用 SDK 的 socket_closed:**
判死后客户端立刻重连,而代理这时还冻着 —— 这次重连要等 10s 连接超时
(REQUEST_TIMEOUT_SEC)才放弃,SDK 的 closed 信号跟着才发。拿 socket_closed
当「发现」,测到的 ~29.5s 里有一半是重连死网络,预算模型(12+3+5=20s)怎么都
对不上。probe_timeout 是客户端真正「判死」的那一刻,和用户体感一致。
"""
import os
import select
import socket
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# 客户端诊断记录的解析。NetProbe 走的是产品代码同一条 Probe 通道,
# 所以这里不再自己写一套 [probe] 正则 —— 语法和解析各只有一份。
import probe

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROXY_PORT = 7397
UPSTREAM = ("127.0.0.1", int(os.environ.get("NAKAMA_PORT", "7350")))

GODOT_CANDIDATES = [
    os.environ.get("GODOT", ""),
    "/Applications/Godot.app/Contents/MacOS/Godot",
    "godot",
]

# 客户端应在这么多秒内**判死**半开连接(巡检 3s + 静默阈值 12s + ping 超时 5s + 余量)。
# ⚠️ 里程碑是「判死决策」net/probe_timeout,不是 SDK 的 socket_closed:
# 判死后客户端会立刻重连,而代理此时还冻着 —— 这次重连要等 10s 连接超时
# (REQUEST_TIMEOUT_SEC)才放弃并触发 closed 信号。拿 socket_closed 当里程碑,
# 测到的 29.5s 里有一半是「重连死网络」的超时,预算模型(20s)怎么都对不上。
DETECT_DEADLINE = 30.0
# 解冻后应在这么多秒内回到房间。预算:判死时那次重连还在飞,要等它 10s 超时
# 落地 + 最多 3s 巡检周期才会发起下一次重连 + 实际连上(1~2s)+ 重新进房。
RECOVER_DEADLINE = 25.0


class FreezableProxy(threading.Thread):
    """TCP 代理。frozen=True 时既不转发已建连接的数据(黑洞,不 close),
    也不给新连接接上游 —— 完整复刻「网络没了但 TCP 谁都没断」。"""

    def __init__(self):
        super().__init__(daemon=True)
        self.frozen = False
        self._lis = socket.create_server(("127.0.0.1", PROXY_PORT))
        self._lis.settimeout(0.5)
        self._stop = False

    def run(self):
        while not self._stop:
            try:
                cli, _ = self._lis.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            if self.frozen:
                # 断网时新握手连不上:直接晾着(不回包),客户端会超时。
                threading.Thread(target=self._blackhole, args=(cli,), daemon=True).start()
                continue
            try:
                up = socket.create_connection(UPSTREAM)
            except OSError:
                cli.close()
                continue
            threading.Thread(target=self._pump, args=(cli, up), daemon=True).start()

    def _blackhole(self, sock):
        try:
            while not self._stop:
                time.sleep(0.5)
        finally:
            sock.close()

    def _pump(self, cli, up):
        """cli = 客户端侧,up = 上游(Nakama)侧。

        ⚠️ 冻结期间上游把连接关了(它 ping 不到客户端,会主动断)——这个死讯
        **不能**传给客户端:真实的半开(NAT 表项没了)里,客户端的 TCP 会一直
        挂着,谁也不会给它发 FIN。第一版代理在这里偷懒直接双向 close,于是
        客户端「免费」拿到了 closed 事件,探活被关掉测试照样绿 —— 门禁形同虚设
        (故障注入抓出来的)。上游死掉的隧道从此永久黑洞,解冻也不恢复:
        现实里旧连接也不会因为网络恢复而复活,只能靠客户端自己探活换新连接。
        """
        broken = False   # 上游在冻结期间死了:隧道永久黑洞
        try:
            while not self._stop:
                r, _, _ = select.select([cli, up], [], [], 0.25)
                for s in r:
                    try:
                        data = s.recv(65536)
                    except OSError:
                        data = b""
                    if s is up:
                        if not data:
                            if self.frozen or broken:
                                broken = True
                                r = []        # 上游 socket 之后不再 select
                                break
                            return            # 正常状态:上游关了就照实传染
                        if not (self.frozen or broken):
                            cli.sendall(data)
                    else:
                        if not data:
                            return            # 客户端自己关了,随它
                        if not (self.frozen or broken):
                            up.sendall(data)
                if broken:
                    self._hold(cli)           # 挂住客户端侧直到测试结束
                    return
        except OSError:
            pass
        finally:
            cli.close()
            up.close()

    def _hold(self, cli):
        """半开:只读不答,永不 close —— 客户端的 TCP 看起来一直活着。"""
        while not self._stop:
            r, _, _ = select.select([cli], [], [], 0.5)
            if r:
                try:
                    if not cli.recv(65536):
                        return                # 客户端主动关了才算完
                except OSError:
                    return

    def stop(self):
        self._stop = True
        self._lis.close()


def find_godot():
    import shutil
    for g in GODOT_CANDIDATES:
        if g and (os.path.exists(g) or shutil.which(g)):
            return g
    sys.exit("找不到 godot(用 GODOT=/path/to/godot 指定)")


def wait_for(lines, event, timeout, lock, start=0):
    """等 stdout 第 start 行**之后**出现 net/<event> 记录。返回耗时,超时 None。

    ⚠️ start 必须是「触发动作之前」快照的 len(lines)。从 0 扫会匹配到上一阶段
    的同名事件(第一次连接的 socket_connected、进房时的 room_state),
    把「什么都没发生」判成通过 —— 这个脚本自己就栽过。
    """
    t0 = time.time()
    seen = start
    while time.time() - t0 < timeout:
        with lock:
            chunk = lines[seen:]
            seen = len(lines)
        for rec in probe.records(chunk):
            if rec.get("k") == "net" and rec.get("event") == event:
                return time.time() - t0
        time.sleep(0.2)
    return None


def fatal_of(lines, lock):
    """客户端自己报的致命错误。有它就直接说是哪一步挂的,
    比让调用方去猜「没进房」强 —— 以前这条信息只在 stdout 里躺着。"""
    with lock:
        recs = probe.records(list(lines))
    hits = [r for r in recs if r.get("k") == "fatal"]
    return hits[-1] if hits else None


def main():
    proxy = FreezableProxy()
    proxy.start()

    proc = subprocess.Popen(
        [find_godot(), "--headless", "--path", os.path.join(ROOT, "godot"),
         "res://tests/NetProbe.tscn", "--",
         f"--nakama-port={PROXY_PORT}", "--device-suffix=netprobe"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    lines, lock = [], threading.Lock()

    def reader():
        for line in proc.stdout:
            line = line.rstrip()
            with lock:
                lines.append(line)
            if os.environ.get("VERBOSE") or line.startswith("[probe]") or line.startswith("[socket]"):
                print("   ", line[:170])

    threading.Thread(target=reader, daemon=True).start()

    failed = []
    try:
        print("== 1. 真客户端经代理登录进房 ==")
        if wait_for(lines, "room_joined", 30, lock) is None:
            bad = fatal_of(lines, lock)
            sys.exit(f"✗ 客户端在 {bad['at']} 这步挂了:{bad['error']}" if bad
                     else "✗ 客户端没能进房 —— 先检查 Nakama 起了没")

        print("\n== 2. 冻结代理(半开:黑洞但不断)==")
        with lock:
            cur = len(lines)
        proxy.frozen = True
        t = wait_for(lines, "probe_timeout", DETECT_DEADLINE, lock, cur)
        if t is None:
            failed.append(f"半开 {DETECT_DEADLINE:.0f} 秒内没被发现 —— 探活失效,"
                          "这就是「桌面打了 5 轮手机还在等待」")
        else:
            print(f"  ✓ {t:.1f}s 后客户端判死(probe_timeout,发现半开)")

        print("\n== 3. 解冻(网络恢复)==")
        with lock:
            cur = len(lines)
        proxy.frozen = False
        t = wait_for(lines, "socket_connected", RECOVER_DEADLINE, lock, cur)
        if t is None:
            failed.append("解冻后没有重连上")
        else:
            print(f"  ✓ {t:.1f}s 后重连成功")
        t = wait_for(lines, "room_state", RECOVER_DEADLINE, lock, cur)
        if t is None:
            with lock:
                lost = any(r.get("event") == "room_lost"
                           for r in probe.records(lines[cur:]))
            failed.append("重连后被判「回不去」(room_lost)" if lost
                          else "重连后没有自动回到房间(room_state 没出现)")
        else:
            print(f"  ✓ {t:.1f}s 后自动回到了房间(用户全程什么都不用做)")
    finally:
        proc.kill()
        proxy.stop()

    if failed:
        print("\n✗ 客户端断线自愈失败:")
        for f in failed:
            print("   -", f)
        return 1
    print("\n✓ 半开连接:发现 → 重连 → 回房,全自动")
    return 0


if __name__ == "__main__":
    sys.exit(main())
