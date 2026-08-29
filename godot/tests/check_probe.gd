extends SceneTree
## Probe 通道的契约检查 —— 以前这条通道两边都没有测试。
##
## 为什么需要它:客户端发的记录和 tools/probe.py 解的记录,是同一份契约的
## 两半。以前那半是 7 个 print 格式串、这半是 8 条正则,改一边另一边不会响:
## 层 1–6 全绿,而冒烟测试要么断言不到、要么按旧坐标点到别的控件上去。
##
## 做两件事:
##   1. 进程内断言语法 —— sink 换得掉、一条一行、JSON 解得开、
##      中文原样、坐标是整数、样本字段与 Probe.KINDS 严格一致。
##   2. 把 KINDS 本身和每种记录的一个样本发到 stdout,交给 Python 侧校验。
##      跨语言的契约只有这么验:
##        godot --headless --path godot --script res://tests/check_probe.gd \
##          | python3 tools/probe.py --verify
##
## 用法(单跑,只看第 1 部分的结论):
##   godot --headless --path godot --script res://tests/check_probe.gd

## 每种记录的一个真实样本。类型要真:rows 是数组、count 是整数。
## 字段与 Probe.KINDS 的一致性由下面的检查强制,漏加一个字段就会红。
const SAMPLES := {
	"config":       {"scheme": "https", "host": "games.example", "port": 443},
	"viewport":     {"win_w": 1170, "win_h": 2532, "vp_w": 432, "vp_h": 700},
	"target":       {"name": "create_button", "x": 12, "y": 430, "w": 408, "h": 48},
	"room_rows":    {"rows": [
		{"i": 0, "x": 12, "y": 96, "w": 408, "h": 44,
		 "text": "石头剪刀布 · 客厅  (2/8)  房主 小明"}]},
	"lobby_online": {"count": 3},
	"room_state":   {"name": "客厅 · 小明的房", "game": "rps",
	                 "players": 1, "phase": "waiting"},
	"net":          {"event": "socket_connected"},
	"fatal":        {"at": "login", "error": "登录失效了"},
}

var _failed := 0
var _checked := 0


func _init() -> void:
	_check_grammar()
	_check_samples_cover_kinds()
	_check_cjk_roundtrip()
	_check_target_is_integer()
	_check_sink_restores()

	# ---- 第 2 部分:把契约和样本发出去,给 tools/probe.py --verify 读 ----
	Probe.sink = Callable()
	Probe.emit("schema", {"kinds": Probe.KINDS})
	for kind in SAMPLES:
		Probe.emit(kind, SAMPLES[kind])

	print("checked %d probe assertions across %d kinds, FAILURES: %d"
		% [_checked, Probe.KINDS.size(), _failed])
	quit(1 if _failed > 0 else 0)


func _fail(msg: String) -> void:
	_failed += 1
	print("PROBE FAIL: ", msg)


func _expect(cond: bool, msg: String) -> void:
	_checked += 1
	if not cond:
		_fail(msg)


## 收集器:把 sink 换成数组,这就是这个 seam 的第二个 adapter。
func _collect(body: Callable) -> Array:
	var got: Array = []
	Probe.sink = func(line: String): got.append(line)
	body.call()
	Probe.sink = Callable()
	return got


func _check_grammar() -> void:
	for kind in SAMPLES:
		var lines := _collect(func(): Probe.emit(kind, SAMPLES[kind]))
		_expect(lines.size() == 1, "%s 应该只发一条,实际 %d 条" % [kind, lines.size()])
		if lines.size() != 1:
			continue
		var line: String = lines[0]
		_expect(line.begins_with(Probe.TAG + " "),
			"%s 没有以 %s 开头:%s" % [kind, Probe.TAG, line])
		_expect(not line.contains("\n"), "%s 记录里带了换行,一条必须一行" % kind)
		var payload = JSON.parse_string(line.substr(Probe.TAG.length() + 1))
		_expect(payload is Dictionary, "%s 的载荷不是 JSON 对象:%s" % [kind, line])
		if not (payload is Dictionary):
			continue
		_expect(payload.get("k", "") == kind,
			"%s 的 k 字段是 %s" % [kind, payload.get("k", "<缺>")])
		for field in Probe.KINDS[kind]:
			_expect(payload.has(field), "%s 少了必备字段 %s" % [kind, field])


## KINDS 和 SAMPLES 必须一一对应 —— 两边都不许多、不许少。
## 加了记录类型忘了加样本,或者反过来,都在这里红。
func _check_samples_cover_kinds() -> void:
	for kind in Probe.KINDS:
		_expect(SAMPLES.has(kind), "KINDS 里有 %s,SAMPLES 里没有" % kind)
	for kind in SAMPLES:
		_expect(Probe.KINDS.has(kind), "SAMPLES 里有 %s,KINDS 里没有" % kind)
		if not Probe.KINDS.has(kind):
			continue
		# 样本不能只满足必备字段就算过:必备字段清单变了,样本要跟着变。
		for field in Probe.KINDS[kind]:
			_expect(SAMPLES[kind].has(field),
				"%s 的样本少了 KINDS 声明的字段 %s" % [kind, field])


## 中文必须原样过去。JSON.stringify 实测不转义 \u,而房名是用户随便起的 ——
## 这条要是断了,冒烟测试按房名挑行会全部落空。
func _check_cjk_roundtrip() -> void:
	var name := "客厅 · 小明的房(2/8)"
	var lines := _collect(func(): Probe.emit("room_state", {
		"name": name, "game": "rps", "players": 2, "phase": "waiting"}))
	if lines.is_empty():
		_fail("CJK 检查:没收到记录")
		return
	var line: String = lines[0]
	_expect(line.contains(name), "中文被转义了,控制台里就没法看:%s" % line)
	var payload = JSON.parse_string(line.substr(Probe.TAG.length() + 1))
	_expect(payload is Dictionary and payload["name"] == name,
		"中文没能原样解回来:%s" % line)


## 坐标必须是整数。浮点会带出 12.0 这种,Python 侧 int() 会炸。
func _check_target_is_integer() -> void:
	var lines := _collect(func():
		Probe.target("leave_button", Rect2(12.7, 430.2, 408.9, 48.4)))
	if lines.is_empty():
		_fail("target 检查:没收到记录")
		return
	var payload = JSON.parse_string(lines[0].substr(Probe.TAG.length() + 1))
	for field in ["x", "y", "w", "h"]:
		# 只要求「值是整数」,不锁 JSON 解出来的是 int 还是 float ——
		# 锁类型会在引擎换了解析实现时假报警。
		_expect(payload is Dictionary and payload[field] == floor(payload[field]),
			"target.%s 不是整数值:%s" % [field, lines[0]])
	_expect(not lines[0].contains(".7") and not lines[0].contains(".2"),
		"target 把浮点原样发出去了:%s" % lines[0])


## sink 是可换的 —— 这个 seam 有两个 adapter(stdout 与内存),
## 所以它是真的 seam,不是假设出来的。换完必须还原得回去。
func _check_sink_restores() -> void:
	var before := Probe.sink
	var got := _collect(func(): Probe.emit("net", {"event": "socket_closed"}))
	_expect(got.size() == 1, "换上 sink 之后没收到记录")
	_expect(not Probe.sink.is_valid(), "sink 没还原成默认(print)")
	Probe.sink = before
