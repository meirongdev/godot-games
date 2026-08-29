#!/usr/bin/env python3
"""客户端诊断记录通道的解析器 —— 对面是 godot/src/net/Probe.gd。

**为什么是一个模块。**
这条通道本来就存在:客户端 print、Python 侧 regex。以前客户端那半是散在
4 个文件里的 7 个格式串,这半是 8 条各自为政的正则,两边都没有测试 ——
改一个格式串,层 1–6 全绿,而冒烟测试要么断言不到、要么按旧坐标点到别的
控件上去(那种假点击比测不到还糟)。现在语法只有一份,解析也只有一份。

**语法**:每条一行 `[probe] {json}`,必带 `k`。字段以 Probe.KINDS 为准。

**契约怎么验**(这是本文件存在的另一半理由):

    godot --headless --path godot --script res://tests/check_probe.gd \
      | python3 tools/probe.py --verify

check_probe.gd 会把 Probe.KINDS **本身**当成一条 schema 记录发出来,再发
每种记录的一个样本。--verify 拿 schema 校验样本,并检查下面 NEEDS 里
声明的字段确实还在 —— 所以这里没有第二份 schema,只有一份「我用到了谁」。
tools/build_web.sh 每次导出前都跑它。
"""
import json
import sys

TAG = "[probe] "

# 本文件的解析函数实际读到的字段。**不是** schema 的副本 —— 是依赖声明。
# 有人在 Probe.KINDS 里改了字段名,--verify 会在这里红。
NEEDS = {
    "viewport": ["win_w", "vp_w"],
    "target": ["name", "x", "y", "w", "h"],
    "room_rows": ["rows"],
}

# room_rows 里每一行用到的字段(rows 是数组,单独声明)。
ROW_NEEDS = ["x", "y", "w", "h", "text"]


def records(lines):
    """把控制台行解析成记录列表。不是 [probe] 的行直接跳过 ——
    引擎横幅、push_error、网络日志都混在同一个流里。"""
    out = []
    for line in lines:
        i = line.find(TAG)
        if i < 0:
            continue
        try:
            rec = json.loads(line[i + len(TAG):])
        except ValueError:
            continue
        if isinstance(rec, dict) and "k" in rec:
            out.append(rec)
    return out


def of_kind(recs, kind):
    return [r for r in recs if r.get("k") == kind]


def last_of(recs, kind):
    hits = of_kind(recs, kind)
    return hits[-1] if hits else None


def css_scale(recs, dsf):
    """逻辑坐标 → CSS 像素的换算系数。

    CDP 的输入坐标是 CSS 像素,而客户端报的窗口尺寸是物理像素,所以除一次
    deviceScaleFactor。**换算只在这里做一次** —— 以前 _css_per_logical /
    rect_css / room_row_css 各推一遍,dsf 还在 web_smoke.py 里写了两处
    (档位表一处、CDP override 一处),改一处不改另一处就会静静地点偏。
    """
    vp = last_of(recs, "viewport")
    if vp is None or not vp.get("vp_w"):
        return None
    return (vp["win_w"] / dsf) / vp["vp_w"]


def _center_css(rect, k):
    return ((rect["x"] + rect["w"] / 2) * k, (rect["y"] + rect["h"] / 2) * k)


def target_css(recs, dsf, name):
    """名为 name 的靶子的中心,CSS 像素。取最后一次上报的坐标。

    刻意不按 .tscn 反算布局:那种算法每改一次布局就悄悄失准,而客户端会把
    控件的实际矩形报出来(逻辑坐标),这里只做一次单位换算。
    """
    k = css_scale(recs, dsf)
    hits = [r for r in of_kind(recs, "target") if r.get("name") == name]
    return None if k is None or not hits else _center_css(hits[-1], k)


def room_row_css(recs, dsf, want):
    """房间列表里房名含 want 的那一行的中心,CSS 像素。

    ⚠️ 必须按房名挑,不能按行号。列表里混着别人建的房、以及上几次冒烟跑完
    还没被自动关闭的空房间 —— 第一行基本上不是自己要点的那个。

    只看**最后一条** room_rows:客户端每 3 秒重排一次列表,内容变了才重发,
    所以最后一条就是当前状态。房间不在当前列表里就返回 None —— 以前是在
    历史行里找最后一次命中,那会拿到一个已经过期的坐标去点。
    """
    k = css_scale(recs, dsf)
    rec = last_of(recs, "room_rows")
    if k is None or rec is None:
        return None
    for row in rec.get("rows", []):
        if want and want in row.get("text", ""):
            return _center_css(row, k)
    return None


def verify(recs):
    """跨语言契约校验。返回问题列表,空 = 通过。"""
    problems = []
    schema_rec = last_of(recs, "schema")
    if schema_rec is None:
        return ["没收到 schema 记录 —— check_probe.gd 没跑起来?"]
    schema = schema_rec.get("kinds", {})
    if not schema:
        return ["schema 记录里没有 kinds"]

    # ① 每种声明的记录都要有样本,且样本带齐必备字段。
    for kind, fields in schema.items():
        samples = of_kind(recs, kind)
        if not samples:
            problems.append(f"schema 声明了 {kind},但流里一条样本都没有")
            continue
        for f in fields:
            if f not in samples[-1]:
                problems.append(f"{kind} 的样本缺字段 {f}")

    # ② 解析器用到的字段必须还在 schema 里。这是 Probe.KINDS 改名的警报。
    for kind, fields in NEEDS.items():
        if kind not in schema:
            problems.append(f"probe.py 依赖记录类型 {kind},schema 里没有了")
            continue
        for f in fields:
            if f not in schema[kind]:
                problems.append(
                    f"probe.py 读 {kind}.{f},但 Probe.KINDS 里已经没有这个字段")

    # ③ room_rows 的行内字段没进 schema(rows 是数组),单独按样本验。
    sample = last_of(recs, "room_rows")
    if sample is not None:
        rows = sample.get("rows") or []
        if not rows:
            problems.append("room_rows 的样本里 rows 是空的,验不到行内字段")
        else:
            for f in ROW_NEEDS:
                if f not in rows[0]:
                    problems.append(f"probe.py 读 room_rows.rows[].{f},样本里没有")

    return problems


def main():
    if "--verify" not in sys.argv:
        sys.exit(__doc__)
    recs = records(sys.stdin.read().splitlines())
    problems = verify(recs)
    if problems:
        print("✗ Probe 契约不一致:")
        for p in problems:
            print("   -", p)
        return 1
    kinds = sorted({r["k"] for r in recs if r["k"] != "schema"})
    print(f"✓ Probe 契约一致:{len(kinds)} 种记录 —— " + "、".join(kinds))
    return 0


if __name__ == "__main__":
    sys.exit(main())
