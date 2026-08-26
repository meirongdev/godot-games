class_name NakamaConfig
extends RefCounted
## Nakama 连接配置。按运行环境分流,两条完全不同的来源:
##
## - **Web 制品**:从页面自身的地址推导(同源)。部署侧把 `/v2/*` 和 `/ws`
##   路由到 Nakama,客户端因此不需要知道任何环境事实 —— 镜像里零配置。
##   见 docs/deployment-contract.md §3.3。
## - **从源码跑**(编辑器 / `godot --path godot`):读 res://nakama.cfg。
##   ⚠️ 这个文件**进不了导出包** —— `.cfg` 是非资源文件,
##   `export_filter="all_resources"` 不收它。所以它只对源码运行有效,
##   对任何制品都无效。别指望用它给 Web 版配置地址。
##
## 两条路都能用参数临时覆盖(URL 查询串 / 命令行),只为联调,不是部署手段。

const PATH := "res://nakama.cfg"

## 本机默认值。**只对源码运行生效** —— Web 上推导不出来就 error,
## 绝不静默回退到 localhost:静默回退正是 2026-08-26「镜像进了集群才发现
## 客户端在拨 127.0.0.1」那个故障能飘那么远的唯一原因。
const LOCAL_HOST := "127.0.0.1"
const LOCAL_PORT := 7350
const LOCAL_SCHEME := "http"

## server key 跟着 Web 制品公开发布,任何人都能从页面里取出来。
## 按契约 §5 它不是机密,不为它设计藏法;防滥用的实际手段是
## lobby_rpc 的建房限流。这个值必须与部署侧 --socket.server_key 一致,
## 也与 nakama/docker-compose.yml 里的本地值一致。
const SERVER_KEY := "family-lobby-2026"

var host := LOCAL_HOST
var port := LOCAL_PORT
var scheme := LOCAL_SCHEME
var server_key := SERVER_KEY
## 同机联调用:附加到设备 ID 后面,让多个实例登进不同账号
var device_suffix := ""
## 非空 = 配置没能确定。此时**不要连接**,把这句话直接给用户看。
var error := ""


static func load_or_default() -> NakamaConfig:
	var cfg := NakamaConfig.new()
	if OS.has_feature("web"):
		cfg._from_page_origin()
	else:
		cfg._from_local_file()
	cfg._apply_overrides()
	return cfg


## Web:服务器就是本页面的来源。部署侧的路由负责把 /v2/* 和 /ws 送到 Nakama。
func _from_page_origin() -> void:
	if not Engine.has_singleton("JavaScriptBridge"):
		error = "浏览器里拿不到 JavaScriptBridge,无法确定服务器地址"
		return
	var proto := _js("window.location.protocol")   # "https:" / "http:"
	var hostname := _js("window.location.hostname")
	var page_port := _js("window.location.port")   # 默认端口时是空串
	if hostname.is_empty() or proto.is_empty():
		error = "读不到页面地址,无法推导服务器地址"
		return
	scheme = "https" if proto.begins_with("https") else "http"
	host = hostname
	if page_port.is_empty():
		# 页面用的是协议默认端口,URL 里就不带端口。
		port = 443 if scheme == "https" else 80
	else:
		port = page_port.to_int()
		if port <= 0:
			error = "页面端口读不成数字:%s" % page_port


## 源码运行:读 res://nakama.cfg,没有就用本机默认值。
func _from_local_file() -> void:
	var file := ConfigFile.new()
	if file.load(PATH) != OK:
		return
	host       = file.get_value("nakama", "host", host)
	port       = file.get_value("nakama", "port", port)
	scheme     = file.get_value("nakama", "scheme", scheme)
	server_key = file.get_value("nakama", "server_key", server_key)


## 联调覆盖项。**不会清掉 error** —— 推导失败说明环境本身有问题,
## 不该靠调试开关绕过去。
func _apply_overrides() -> void:
	if OS.has_feature("web"):
		# 浏览器所有标签页共享 user://(IndexedDB),设备 ID 会撞成同一个,
		# 想在多个标签里当不同玩家必须带 ?player=
		#   index.html?player=a&host=192.168.1.50&port=7350&scheme=http
		_set_if("player", func(v): device_suffix = v)
		_set_if("host",   func(v): host = v)
		_set_if("port",   func(v): port = v.to_int())
		_set_if("scheme", func(v): scheme = v)
		return

	# 同机开多个客户端联调:
	#   godot --path godot -- --nakama-host=192.168.1.50 --device-suffix=2
	for arg in OS.get_cmdline_user_args():
		var pair: PackedStringArray = arg.split("=", true, 1)
		if pair.size() != 2:
			continue
		match pair[0]:
			"--nakama-host":   host = pair[1]
			"--nakama-port":   port = pair[1].to_int()
			"--nakama-scheme": scheme = pair[1]
			# 设备认证按机器 ID,同机多实例会撞成同一个账号。
			"--device-suffix": device_suffix = pair[1]


func _set_if(key: String, apply: Callable) -> void:
	var v := _web_query(key)
	if not v.is_empty():
		apply.call(v)


## 求一个 window 表达式的字符串值。非 Web / 拿不到 bridge 时返回空串。
static func _js(expr: String) -> String:
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		return ""
	# 用 Engine.get_singleton 而不是直接写 JavaScriptBridge,
	# 后者在非 Web 构建里不是注册单例,直接引用会编译失败。
	var bridge := Engine.get_singleton("JavaScriptBridge")
	var raw = bridge.eval(expr, true)
	return raw if raw is String else ""


## 读一个 URL 查询参数。非 Web 平台一律返回空串。
static func _web_query(key: String) -> String:
	var query := _js("window.location.search")
	if query.is_empty():
		return ""
	for part in query.trim_prefix("?").split("&"):
		var pair: PackedStringArray = (part as String).split("=", true, 1)
		if pair.size() == 2 and pair[0] == key:
			return pair[1].uri_decode()
	return ""
