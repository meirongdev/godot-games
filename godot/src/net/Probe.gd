class_name Probe
extends RefCounted
## 诊断记录通道:客户端把「测试要断言的事实」和「测试要点的靶子」发到这里。
##
## **这条通道本来就存在**,只是没人拥有它 —— 格式散在 4 个文件的 7 个
## print 格式串里,又在 Python 侧被 8 条正则重新描述一遍,两边都没有测试。
## 改一个格式串,层 1–6 照样全绿,而冒烟测试要么断言不到、要么按旧坐标
## 点到别的控件上 —— 那种假点击比测不到还糟。
##
## 语法:每条一行 `[probe] {json}`,必带 `k`(记录类型)。解析只有一份,
## 在 tools/probe.py。字段名以 KINDS 为准,check_probe.gd 会把 KINDS 本身
## 作为一条 schema 记录发出去,Python 侧据此校验 —— 两边不再各存一份。
##
## ⚠️ **制品里也输出,而且刻意不做开关。**
## 冒烟测试跑的是 `--export-release` 的制品(tools/build_web.sh 只有这一条
## 导出路径),那里 `OS.is_debug_build()` 和 `has_feature("debug")` 恒为 false ——
## 靠 debug 判据去关会直接把层 7b 打瞎。`?probe=1` 这类开关也不行:忘了带参数
## 的表现是「没看到 [room]」,和真回归一模一样,正是 2026-08-27 那个
## token 过期 bug 用过的伪装。
##
## 顺带:控制台里也是给人看的。JSON.stringify 输出的是原样 UTF-8
## (实测,不转义 \u),`[probe] {"k":"room_state","name":"客厅",...}` 直接可读。

const TAG := "[probe]"

## 记录类型 → 必备字段。**这是本通道的契约**,加字段先改这里。
## check_probe.gd 把它整个发给 Python 侧校验,所以 tools/probe.py 里
## 没有第二份 schema。
const KINDS := {
	"config":       ["scheme", "host", "port"],
	"viewport":     ["win_w", "win_h", "vp_w", "vp_h"],
	"target":       ["name", "x", "y", "w", "h"],
	"room_rows":    ["rows"],
	"lobby_online": ["count"],
	"room_state":   ["name", "game", "players", "phase"],
	"net":          ["event"],
	"fatal":        ["at", "error"],
}

## 记录往哪儿去。默认 print;测试把它换成一个数组收集器 —— 这个 seam 有
## 两个 adapter(stdout 与内存),所以它是真的,不是假设出来的。
static var sink := Callable()


## 发一条记录。fields 不能覆盖 k(merge 默认不覆写已有键)。
static func emit(kind: String, fields: Dictionary = {}) -> void:
	var rec := {"k": kind}
	rec.merge(fields)
	var line := "%s %s" % [TAG, JSON.stringify(rec)]
	if sink.is_valid():
		sink.call(line)
	else:
		print(line)


## 一个可点的靶子。坐标是**逻辑坐标**(引擎自己的坐标系)——
## 换算成浏览器的 CSS 像素要除 deviceScaleFactor,而那是 CDP 侧才知道的事,
## 所以换算归 tools/probe.py 管,这里只报客户端知道的东西。
static func target(name: String, r: Rect2, extra: Dictionary = {}) -> void:
	var f := {
		"name": name,
		"x": int(r.position.x), "y": int(r.position.y),
		"w": int(r.size.x), "h": int(r.size.y),
	}
	f.merge(extra)
	emit("target", f)
