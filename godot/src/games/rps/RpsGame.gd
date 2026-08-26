extends GameBase
## 石头剪刀布客户端。只负责显示和发送出拳,胜负一律由服务端裁定。

const HAND_ICON := { 0: "✊", 1: "✋", 2: "✌" }
const HAND_NAME := { 0: "石头", 1: "布", 2: "剪刀" }

@onready var round_label: Label = $VBox/RoundLabel
@onready var countdown: ProgressBar = $VBox/Countdown
@onready var hands_box: HBoxContainer = $VBox/Hands
@onready var wait_label: Label = $VBox/WaitLabel
@onready var result: RichTextLabel = $VBox/Result
@onready var spectator: Label = $VBox/Spectator

var _alive: Array = []
var _thrown := false
var _time_left := 0.0
var _round_seconds := 3.0


func _ready() -> void:
	$VBox/Hands/RockButton.pressed.connect(_throw.bind(OpCodes.ROCK))
	$VBox/Hands/PaperButton.pressed.connect(_throw.bind(OpCodes.PAPER))
	$VBox/Hands/ScissorButton.pressed.connect(_throw.bind(OpCodes.SCISSOR))
	countdown.min_value = 0.0
	countdown.max_value = 1.0


func game_started(_settings: Dictionary, _players: Array) -> void:
	result.clear()
	result.append_text("[i]准备…[/i]\n")


func handle_server(op_code: int, payload: Dictionary) -> void:
	match op_code:
		OpCodes.ROUND_BEGIN:    _on_round_begin(payload)
		OpCodes.ROUND_RESULT:   _on_round_result(payload)
		OpCodes.THROW_PROGRESS: _on_throw_progress(payload)


func game_ended(results: Array) -> void:
	_set_input_enabled(false)
	countdown.value = 0.0
	round_label.text = "本局结束"
	if not results.is_empty():
		result.append_text("\n[b]🏆 %s 获胜![/b]\n" % results[0]["name"])


# ---------------------------------------------------------------- 回合

func _on_round_begin(p: Dictionary) -> void:
	_alive = JsonSafe.arr(p, "alive")
	_thrown = false
	_round_seconds = float(p.get("seconds", 3.0))
	_time_left = _round_seconds

	var streak := int(p.get("draw_streak", 0))
	round_label.text = "第 %d 轮 · 剩 %d 人" % [int(p.get("round", 0)), _alive.size()]
	if streak > 0:
		round_label.text += "  (连续平局 ×%d,加速!)" % streak

	var i_am_alive := _alive.has(my_id)
	spectator.visible = not i_am_alive
	hands_box.visible = i_am_alive
	_set_input_enabled(i_am_alive)
	wait_label.text = ""
	# 连续平局加速时,倒计时条泛红提示节奏变了
	countdown.modulate = Color(1.0, 0.55, 0.45) if streak > 0 else Color.WHITE


func _on_throw_progress(p: Dictionary) -> void:
	var thrown := JsonSafe.arr(p, "thrown")
	var total := int(p.get("total", 0))
	var waiting := PackedStringArray()
	for uid in _alive:
		if not thrown.has(uid):
			waiting.append(name_of(str(uid)))
	if waiting.is_empty():
		wait_label.text = ""
	else:
		wait_label.text = "已出拳 %d/%d · 等:%s" % [thrown.size(), total, "、".join(waiting)]


func _on_round_result(p: Dictionary) -> void:
	wait_label.text = ""
	_set_input_enabled(false)
	_time_left = 0.0
	countdown.value = 0.0

	var hands := JsonSafe.dict(p, "hands")
	var line := ""
	for uid in hands.keys():
		line += "%s %s   " % [name_of(str(uid)), HAND_ICON.get(int(hands[uid]), "?")]
	result.append_text(line.strip_edges() + "\n")

	if p.get("draw", false):
		result.append_text("[color=gray]平局,重来[/color]\n\n")
		return

	var winner := int(p.get("winner", 0))
	result.append_text("[b]%s %s 胜[/b]\n" % [HAND_ICON[winner], HAND_NAME[winner]])

	var eliminated := JsonSafe.arr(p, "eliminated")
	if not eliminated.is_empty():
		var names := PackedStringArray()
		for uid in eliminated:
			names.append(name_of(str(uid)))
		result.append_text("[color=red]淘汰:%s[/color]\n" % ", ".join(names))

	var afk := JsonSafe.arr(p, "afk")
	if not afk.is_empty():
		var names := PackedStringArray()
		for uid in afk:
			names.append(name_of(str(uid)))
		result.append_text("[color=gray](%s 没出拳,系统代出)[/color]\n" % ", ".join(names))

	result.append_text("\n")


# ---------------------------------------------------------------- 输入

func _throw(hand: int) -> void:
	if _thrown:
		return
	_thrown = true
	_set_input_enabled(false)
	round_label.text += "  你出了 %s" % HAND_ICON[hand]
	send(OpCodes.THROW, {"hand": hand})


func _set_input_enabled(on: bool) -> void:
	for b in hands_box.get_children():
		if b is Button:
			b.disabled = not on


func _process(delta: float) -> void:
	if _time_left <= 0.0:
		return
	_time_left = max(0.0, _time_left - delta)
	countdown.value = _time_left / _round_seconds
