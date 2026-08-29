extends Control

const REFRESH_INTERVAL := 3.0   # Nakama 没有房间列表推送,只能轮询

@onready var online_list: ItemList = $Margin/Row/Col/Online/OnlineList
@onready var chat_log: RichTextLabel = $Margin/Row/Col/Chat/ChatLog
@onready var chat_edit: LineEdit = $Margin/Row/Col/Chat/ChatEdit
@onready var room_list: ItemList = $Margin/Row/Col/Rooms/RoomList
@onready var game_option: OptionButton = $Margin/Row/Col/CreateBox/GameOption
@onready var room_name_edit: LineEdit = $Margin/Row/Col/CreateBox/RoomNameEdit
@onready var create_button: Button = $Margin/Row/Col/CreateBox/CreateButton
@onready var status: Label = $Margin/Row/Col/Status

@onready var _panels := {
	"rooms":  $Margin/Row/Col/Rooms,
	"online": $Margin/Row/Col/Online,
	"chat":   $Margin/Row/Col/Chat,
}

var _rooms: Array = []
var _timer := 0.0
var _busy := false
## 历史补齐之前先攒着实时消息,免得新消息排到历史前面去。
var _history_loaded := false
var _pending_messages: Array = []
## 状态行上正挂着「列表刷不出来」。恢复之后要把它撤掉,不能一直挂在那儿。
var _showing_list_error := false
## 进房请求在飞。双击的第二下、或者手快连点两下,不该再发一次。
var _joining := false
## 房间行的坐标日志上次打的是什么 —— 一样就不重复打了(3 秒刷一次,会刷屏)。
var _last_row_log := ""


func _ready() -> void:
	ServerConnection.lobby_presence_changed.connect(_on_presence_changed)
	ServerConnection.lobby_message.connect(_on_message)
	create_button.pressed.connect(_on_create_pressed)
	chat_edit.text_submitted.connect(_on_chat_submitted)
	# ⚠️ 进房必须连 item_clicked(点一下),不能只连 item_activated(双击/回车)。
	# item_activated 要求输入事件带「双击」标记,而**手机浏览器上这个标记根本
	# 不存在**:Godot Web 的触屏回调只把(类型, 触点数, 坐标)传进引擎
	# (build/web/index.js 里的 _godot_js_input_touch_cb),
	# InputEventScreenTouch.double_tap 恒为 false;引擎的「触屏→鼠标」模拟又是
	# 直接抄这个字段的,于是手指怎么点都不会触发 item_activated ——
	# 这就是「手机上双击进不了房间」。
	# 桌面网页版一直是好的,因为**鼠标**的双击是 DisplayServer 按两次 mousedown
	# 的时间差自己算出来的,不依赖浏览器给标记。所以这个 bug 只在手机上现形。
	room_list.item_clicked.connect(_on_room_clicked)
	room_list.item_activated.connect(_on_room_activated)   # 桌面:双击/回车

	# 竖屏一屏放不下「房间/在线/聊天」三块,用分段切换。
	# 用三个 toggle Button 而不是 TabContainer:页签是手机上的主导航,
	# 必须够大(≥44),而 TabContainer 的页签高度由主题 StyleBox 的内边距
	# 决定,想做到 44 得自己写一套 StyleBox。Button 一个 custom_minimum_size
	# 就够了。互斥由 .tscn 里的 ButtonGroup 保证。
	$Margin/Row/Col/Segments/RoomsTab.pressed.connect(_show_segment.bind("rooms"))
	$Margin/Row/Col/Segments/OnlineTab.pressed.connect(_show_segment.bind("online"))
	$Margin/Row/Col/Segments/ChatTab.pressed.connect(_show_segment.bind("chat"))

	# 被房间页踢回来时,原因跟着 notice 走 —— 不然用户只看到自己莫名回到大厅。
	status.text = ServerConnection.notice
	ServerConnection.notice = ""

	await ServerConnection.join_lobby_async()
	await _load_history()
	await _load_games()
	_refresh_rooms()

	# 打一行给排查用,也给 tools/web_smoke.py 当点击靶子:建房按钮实际落在哪
	# (逻辑坐标)。布局一改这行自动跟着变,冒烟测试就不用自己按 .tscn 反算
	# 坐标 —— 那种算法每次调布局都会悄悄失准。
	await get_tree().process_frame
	Probe.target("create_button", create_button.get_global_rect())


func _show_segment(which: String) -> void:
	for key in _panels:
		_panels[key].visible = key == which


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= REFRESH_INTERVAL:
		_timer = 0.0
		_refresh_rooms()


func _on_presence_changed(users: Array) -> void:
	# 打一行给排查用:「在线」是空的还是没刷新,光看截图分不出来。
	# tools/web_smoke.py 也靠这一行断言自己进了在线列表。
	Probe.emit("lobby_online", {"count": users.size()})
	online_list.clear()
	var me := ServerConnection.get_user_id()
	users.sort_custom(func(a, b): return a["id"] == me)   # 自己排最前
	for u in users:
		var label: String = u["name"]
		if u["id"] == me:
			label += "(我)"
		online_list.add_item(label)


func _on_message(_sender_id: String, name: String, text: String) -> void:
	if not _history_loaded:
		_pending_messages.append([name, text])
		return
	_append_message(name, text)


func _append_message(name: String, text: String) -> void:
	chat_log.append_text("[b]%s[/b]: %s\n" % [name, text])


## 补大厅聊天的历史。频道本来就是带 persistence 加入的,消息一直存在服务端 ——
## 以前没人去取,所以每次从房间回到大厅、或者手机上刷一下页面,聊天记录就是空的。
func _load_history() -> void:
	for m in await ServerConnection.lobby_history_async():
		_append_message(m["name"], m["text"])
	_history_loaded = true
	for m in _pending_messages:
		_append_message(m[0], m[1])
	_pending_messages.clear()


func _on_chat_submitted(text: String) -> void:
	var t := text.strip_edges()
	if t.is_empty():
		return
	chat_edit.clear()
	await ServerConnection.send_lobby_message_async(t)


func _load_games() -> void:
	game_option.clear()
	for g in await ServerConnection.list_games_async():
		var id: String = g["id"]
		game_option.add_item(OpCodes.GAME_LABELS.get(id, id))
		game_option.set_item_metadata(game_option.item_count - 1, id)


func _refresh_rooms() -> void:
	if _busy:
		return
	_busy = true
	# ⚠️ 房间列表是 HTTP 轮询,socket 死了它照样刷新 —— 页面看着一切正常,
	# 其实聊天、在线列表、进房、建房全废。所以断线要在这里主动修,
	# 不能等用户点了建房才发现。_busy 顺便保证了 3 秒最多试一次,不会打炮。
	if not ServerConnection.is_socket_connected():
		status.text = "和服务器断开了,正在重连…"
		status.text = "" if await ServerConnection.ensure_socket_async() == OK \
			else ServerConnection.error_message
	_rooms = await ServerConnection.list_rooms_async()
	_busy = false

	# ⚠️ 「拉不到列表」和「真的没有房间」必须分开显示。以前两种情况在界面上
	# 长得一模一样(都是「还没有房间 —— 建一个吧」),于是 token 过期导致的
	# RPC 401 完美伪装成「大家都还没建房」,谁也想不到去查登录状态 ——
	# 2026-08-27 那个「手机无法进入房间」就是靠这层伪装活下来的。
	var fetch_failed := not ServerConnection.error_message.is_empty()
	if fetch_failed:
		status.text = "房间列表刷不出来:%s" % ServerConnection.error_message
		_showing_list_error = true
	elif _showing_list_error:
		# 只撤自己贴的那句。别无条件清空 —— 那会把房间页带回来的 notice 也抹掉。
		status.text = ""
		_showing_list_error = false

	room_list.clear()
	if fetch_failed:
		room_list.add_item("⚠ 列表拉不到 —— 不是没有房间")
		room_list.set_item_disabled(0, true)
		room_list.set_item_selectable(0, false)
		return
	if _rooms.is_empty():
		room_list.add_item("还没有房间 —— 建一个吧")
		room_list.set_item_disabled(0, true)
		room_list.set_item_selectable(0, false)
		return
	for r in _rooms:
		var label := "%s · %s  (%d/%d)  房主 %s" % [
			OpCodes.GAME_LABELS.get(r["game"], r["game"]), r["name"],
			r["count"], r["max"], r["host_name"]]
		if r["phase"] != "waiting":
			label += "  [进行中]"
		room_list.add_item(label)
		# 进行中的房间不能加入,置灰
		room_list.set_item_disabled(room_list.item_count - 1, r["phase"] != "waiting")

	# 和建房按钮同理:把每一行房间的实际矩形打出来(逻辑坐标),给
	# tools/web_smoke.py 当点击靶子 —— 免得它自己按 .tscn 反算行高。
	# 只打**看得见**的行:滚出去的行坐标照样算得出来,点上去却会打到别的控件,
	# 那种假点击比测不到还糟。房间列表里混着别人建的房,所以带上行号和房名,
	# 测试按名字挑自己要点的那一行。
	await get_tree().process_frame
	var rows := []
	for i in room_list.item_count:
		var row := room_list.get_item_rect(i)
		if row.position.y + row.size.y > room_list.size.y:
			break
		rows.append({
			"i": i,
			"x": int(room_list.global_position.x + row.position.x),
			"y": int(room_list.global_position.y + row.position.y),
			"w": int(row.size.x), "h": int(row.size.y),
			"text": room_list.get_item_text(i),
		})
	# 整批发一条,于是「内容没变就不重发」还是一次字符串比较 ——
	# 和以前打一个 blob 是同一个道理,只是这回对面拿到的是数组。
	var blob := JSON.stringify(rows)
	if blob != _last_row_log:
		_last_row_log = blob
		Probe.emit("room_rows", {"rows": rows})


func _on_room_clicked(index: int, _at_position: Vector2, mouse_button: int) -> void:
	if mouse_button == MOUSE_BUTTON_LEFT:
		_on_room_activated(index)


func _on_room_activated(index: int) -> void:
	if index < 0 or index >= _rooms.size() or _joining:
		return
	if _rooms[index]["phase"] != "waiting":
		status.text = "这局已经开始了,进不去 —— 等他们打完"
		return
	# 手机上从点下去到场景切换可能要一两秒,没有这一行的话看着像没点着,
	# 用户会接着猛点(而那些点会被 _joining 挡掉,更像卡死)。
	status.text = "正在进房…"
	_joining = true
	var err := await ServerConnection.join_room_async(_rooms[index]["match_id"])
	_joining = false
	if err == OK:
		get_tree().change_scene_to_file("res://src/room/Room.tscn")
	else:
		status.text = "进房失败:%s" % ServerConnection.error_message


func _on_create_pressed() -> void:
	if game_option.selected < 0:
		return
	create_button.disabled = true
	status.text = ""
	var game_id: String = game_option.get_item_metadata(game_option.selected)
	var id := await ServerConnection.create_room_async(
		game_id, room_name_edit.text.strip_edges())
	create_button.disabled = false
	if not id.is_empty():
		get_tree().change_scene_to_file("res://src/room/Room.tscn")
	else:
		# 以前这里是完全静默的 —— 点「建房」没反应,用户不知道发生了什么。
		# 服务端的拒绝(限流、未知游戏)必须有出口。
		status.text = ServerConnection.error_message
