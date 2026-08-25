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
	return cfg
