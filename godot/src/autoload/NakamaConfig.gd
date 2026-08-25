class_name NakamaConfig
extends RefCounted

const PATH := "res://nakama.cfg"

var host := "127.0.0.1"
var port := 7350
var scheme := "http"
var server_key := "family-lobby-2026"
## 同机联调用:附加到设备 ID 后面,让多个实例登进不同账号
var device_suffix := ""

static func load_or_default() -> NakamaConfig:
	var cfg := NakamaConfig.new()
	var file := ConfigFile.new()
	if file.load(PATH) == OK:
		cfg.host       = file.get_value("nakama", "host", cfg.host)
		cfg.port       = file.get_value("nakama", "port", cfg.port)
		cfg.scheme     = file.get_value("nakama", "scheme", cfg.scheme)
		cfg.server_key = file.get_value("nakama", "server_key", cfg.server_key)

	# 同机开多个客户端联调时用:
	#   godot --path godot -- --nakama-host=192.168.1.50
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--nakama-host="):
			cfg.host = arg.split("=", true, 1)[1]
		# 设备认证按机器 ID,同机多实例会撞成同一个账号。
		#   godot --path godot -- --device-suffix=2
		elif arg.begins_with("--device-suffix="):
			cfg.device_suffix = arg.split("=", true, 1)[1]

	# Web 导出拿不到命令行参数,改从 URL 查询串读:
	#   index.html?player=a&host=192.168.1.50
	# 浏览器所有标签页共享 user://(IndexedDB),设备 ID 会撞成同一个,
	# 所以想在多个标签里当不同玩家,必须带 ?player=
	var web_player := _web_query("player")
	if not web_player.is_empty():
		cfg.device_suffix = web_player
	var web_host := _web_query("host")
	if not web_host.is_empty():
		cfg.host = web_host

	return cfg


## 读一个 URL 查询参数。非 Web 平台一律返回空串。
static func _web_query(key: String) -> String:
	if not OS.has_feature("web"):
		return ""
	# 用 Engine.get_singleton 而不是直接写 JavaScriptBridge,
	# 后者在非 Web 构建里不是注册单例,直接引用会编译失败。
	if not Engine.has_singleton("JavaScriptBridge"):
		return ""
	var bridge := Engine.get_singleton("JavaScriptBridge")
	var raw = bridge.eval("window.location.search", true)
	if not (raw is String) or raw.is_empty():
		return ""
	var query: String = raw
	for part in query.trim_prefix("?").split("&"):
		var pair: PackedStringArray = (part as String).split("=", true, 1)
		if pair.size() == 2 and pair[0] == key:
			return pair[1].uri_decode()
	return ""
