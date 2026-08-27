extends SceneTree
## 场景节点路径检查。
##
## 为什么需要它:.gd 里的 $VBox/Hands/RockButton 这类路径是硬编码的,
## .tscn 改了节点名不会有任何编译错误 —— 解析检查(--editor)照样全绿,
## 只会在运行时炸。这是唯一能提前抓住它的检查。
##
## 用法:
##   godot --headless --path godot --script res://tests/check_scenes.gd
##
## 已知噪音:--script 模式下 autoload 未挂载,加载场景时会打印
## "Identifier not found: ServerConnection" 的 SCRIPT ERROR。不影响
## 节点路径解析(节点树不依赖脚本编译成功),以 FAILURES 行和退出码为准。
##
## 加新场景、或在 .gd 里新引用节点时,把路径补进 CHECKS。

const CHECKS := {
	"res://src/lobby/Login.tscn": [
		"Margin/Row/Col/NameEdit", "Margin/Row/Col/EnterButton",
		"Margin/Row/Col/Status",
	],
	"res://src/lobby/Lobby.tscn": [
		"HBox/Left/OnlineList", "HBox/Left/ChatLog", "HBox/Left/ChatEdit",
		"HBox/Right/RoomList", "HBox/Right/RefreshButton",
		"HBox/Right/CreateBox/GameOption", "HBox/Right/CreateBox/RoomNameEdit",
		"HBox/Right/CreateBox/CreateButton", "HBox/Right/Status",
	],
	"res://src/room/Room.tscn": [
		"VBox/Header/RoomTitle", "VBox/Header/LeaveButton",
		"VBox/Body/PlayerPanel/PlayerList", "VBox/Body/PlayerPanel/ReadyButton",
		"VBox/Body/PlayerPanel/StartButton", "VBox/Body/GameSlot", "VBox/Status",
	],
	"res://src/games/rps/RpsGame.tscn": [
		"VBox/RoundLabel", "VBox/Countdown", "VBox/Hands",
		"VBox/Hands/RockButton", "VBox/Hands/PaperButton",
		"VBox/Hands/ScissorButton", "VBox/WaitLabel", "VBox/Result", "VBox/Spectator",
	],
}


func _init() -> void:
	var failed := 0
	var checked := 0
	for path in CHECKS:
		var packed: PackedScene = load(path)
		if packed == null:
			print("LOAD FAIL: ", path)
			failed += 1
			continue
		var root := packed.instantiate()
		for np in CHECKS[path]:
			checked += 1
			if root.get_node_or_null(np) == null:
				print("MISSING: ", path.get_file(), " -> ", np)
				failed += 1
		root.free()
	print("checked %d paths across %d scenes, FAILURES: %d" % [checked, CHECKS.size(), failed])
	quit(1 if failed > 0 else 0)
