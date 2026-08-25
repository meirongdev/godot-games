class_name GameBase
extends Control
## 所有游戏场景的基类。游戏场景不碰 Nakama,只通过 send_to_server 发消息。

## 由 RoomController 接到 ServerConnection.send()
signal send_to_server(op_code: int, data: Dictionary)

## 我的 user_id,由 RoomController 注入
var my_id := ""
## [{id, name, ready}] 的玩家数组
var players: Array = []


## 开局。settings 是房主定的那份。
func game_started(_settings: Dictionary, _players: Array) -> void:
	pass


## 收到本游戏 OpCode 段内的服务端消息。
func handle_server(_op_code: int, _payload: Dictionary) -> void:
	pass


## 局终。results 是 [{id, name, rank}]。
func game_ended(_results: Array) -> void:
	pass


## 便捷方法,给子类用。
func send(op_code: int, data: Dictionary = {}) -> void:
	send_to_server.emit(op_code, data)


## user_id -> 显示名。找不到就回退成 id 前 6 位。
func name_of(uid: String) -> String:
	for p in players:
		if p["id"] == uid:
			return p["name"]
	return uid.substr(0, 6)
