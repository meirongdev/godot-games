# 手机竖屏可玩 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Godot Web 版家庭游戏大厅在手机竖屏浏览器里可玩 —— 内容铺满屏幕、按钮点得到、大厅是单列。

**Architecture:** 根因是基准分辨率。`canvas_items` + `expand` 的缩放系数是 `min(窗口宽/基准宽, 窗口高/基准高)`,基准 1280×800 在 390 宽的手机上只能缩到 0.30。把基准改成竖屏方向的 **432×640**(= 16 边距 ×2 + 400 内容列),缩放就回到 ≈1.0。四个场景统一成 `MarginContainer → HBoxContainer(居中) → VBoxContainer(400 宽)`,大厅的左右两栏合成单列 + 分段切换。

**Tech Stack:** Godot 4.7.2(GDScript、`.tscn`)、Python 3(CDP 驱动无头 Chrome)、Nakama 3.40.0(本地 docker compose)

**Spec:** [`docs/superpowers/specs/2026-08-27-mobile-portrait-design.md`](../specs/2026-08-27-mobile-portrait-design.md)

---

## ⚠️ 与 spec 的三处偏差(实现期发现,Task 9 会同步回 spec)

| # | spec 原文 | 计划改为 | 为什么 |
|---|---|---|---|
| 1 | 基准 `400×640` | **`432×700`** | 宽 432 = 16 边距 ×2 + 400 内容列,算术正好对上:手机竖屏宽高比(0.45~0.56)都低于分界线 432/700=0.617,一律宽度受限,逻辑视口恒为 432 宽、内容列恒为 400。高 700 而非 640:基准高度**对手机毫无影响**(手机全程由宽度决定),只管平板/桌面 —— 640 会让 iPad 768×1024 缩放到 1.60(按钮 70pt+),700 压到 1.46 |
| 2 | 分段切换用 `TabContainer` | **三个 toggle `Button` + `ButtonGroup`** | `TabContainer` 的页签高度由主题 StyleBox 内边距决定,想做到 44pt 得自己写一套 StyleBox。页签是手机上的主导航,不能将就 |
| 3 | §6 触控尺寸收进 `family.tres` 主题 | **不做** | 实测现有 `custom_minimum_size` 已经全是 44–56 **逻辑**像素,一个不缺 —— 手机上点不到纯粹是被 0.30 缩放害的。基准一改就全部达标。而 Theme 没有 min-height 属性,要靠 StyleBox 内边距实现,等于重写一套外观,风险远大于收益 |

**偏差 3 需要打个补丁(Task 3 的 code review 算出来的)。** 原话「基准一改就全部达标」
只对 48/52 逻辑单位的控件成立,对 **44 的不成立**:

因为 432 已经**等于或大于**最宽的真机(430 CSS px),所有手机的缩放系数都 ≤ 1.0
(390 宽 → 0.903,360 宽 → 0.833),所以按 44 逻辑单位画的控件在真机上只有:

| 机型 | 缩放 | 44 单位 → 实际 | 48 单位 → 实际 | 52 单位 → 实际 |
|---|---|---|---|---|
| 430×932(Pro Max) | 0.995 | 43.8pt | 47.8pt | 51.8pt |
| 390×844(主流 iPhone) | 0.903 | **39.7pt** | 43.3pt | 46.9pt |
| 360×800(小 Android) | 0.833 | **36.7pt** | 40.0pt | 43.3pt |

44 在主流机上差 10%、在小屏上差 17%。所以本计划里**所有 44 都改成 48**
(Task 5 的三个页签、Task 6 的「离开」按钮)。48 在主流机上是 43.3pt,
基本贴住 44pt 这条线;要在 360 宽的机型上也严格 ≥44pt 得用 52,但那会让
次要控件和主 CTA 一样大,不值得 —— 48 已经远高于 WCAG 2.5.8 AA 的 24px 底线。

---

## 前置检查

- [ ] **Step 0: 确认环境就绪**

```bash
cd /Users/matthew/projects/meirongdev/godot-games
curl -s -o /dev/null -w 'nakama:%{http_code}\n' http://127.0.0.1:7350/healthcheck
git status --short
```

Expected: `nakama:200`,工作区干净。Nakama 不在就 `cd nakama && docker compose up -d`。

---

## Task 1: 登录页无坐标化(让冒烟测试不再依赖像素坐标)

冒烟测试现在靠 `--click 640,392` 点名字框。布局一改这些坐标全废。先让登录页支持「自动聚焦 + 回车提交」,冒烟测试就只需要打字和按回车,一个坐标都不用 —— 后面五个 Task 的验证才站得住。

顺带这两条本身就是手机上该有的行为:打开就能打字、软键盘的「完成」键能直接进去。

**Files:**
- Modify: `godot/src/lobby/Login.gd`
- Modify: `tools/web_smoke.py`

- [ ] **Step 1: 给 Login.gd 加自动聚焦、回车提交、布局日志**

把 `godot/src/lobby/Login.gd` 的 `_ready()` 整个替换成:

```gdscript
func _ready() -> void:
	enter_button.pressed.connect(_on_enter_pressed)
	# 手机上软键盘的「完成/换行」键要能直接进去,不用去够按钮。
	# 顺带让 tools/web_smoke.py 不再需要按钮的像素坐标。
	name_edit.text_submitted.connect(func(_text: String): _on_enter_pressed())
	name_edit.text = _load_name()
	# 打开就能打字。手机上这会顺带唤起软键盘 —— 第一屏就是让你输名字,合理。
	name_edit.grab_focus()
	status.text = ""

	# 给排查用:这台设备上 UI 实际多大。web_smoke.py 的手机档位靠这一行断言
	# 逻辑视口宽度 —— 基准分辨率不对的话,手机上一切都会被缩到 30%。
	# 见 docs/superpowers/specs/2026-08-27-mobile-portrait-design.md §3。
	var win := get_window().size
	var vp := get_viewport_rect().size
	print("[layout] 窗口 %dx%d → 逻辑视口 %dx%d(缩放 %.2f)" % [
		win.x, win.y, int(vp.x), int(vp.y), float(win.x) / vp.x])

	# 配置坏了就别等用户填完名字再告诉他 —— 一进门就说,而且把按钮关掉。
	if not ServerConnection.is_configured():
		status.text = "连不上服务器:%s" % ServerConnection.error_message
		enter_button.disabled = true
```

- [ ] **Step 2: 让冒烟测试改用打字 + 回车,不再点坐标**

在 `tools/web_smoke.py` 的 `Page` 类里,`type` 方法之后加一个 `press_enter`:

```python
    async def press_enter(self):
        base = {"key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13,
                "nativeVirtualKeyCode": 13, "text": "\r", "unmodifiedText": "\r"}
        for t in ("keyDown", "char", "keyUp"):
            await self.send("Input.dispatchKeyEvent", dict(base, type=t))
            await asyncio.sleep(0.03)
```

然后把 `run()` 里的登录动作替换掉。原来是:

```python
            await page.click(640, 392)        # 名字输入框
            await page.type(NAME)
            await asyncio.sleep(1)
            await page.click(640, 464)        # 「进入大厅」
            await asyncio.sleep(12)
```

改成:

```python
            # ⚠️ 不用像素坐标。Login.gd 里 name_edit 开局就 grab_focus(),
            # 软键盘的回车会触发 text_submitted —— 布局怎么改都不影响这里。
            await page.type(NAME)
            await asyncio.sleep(1)
            await page.press_enter()
            await asyncio.sleep(12)
```

- [ ] **Step 3: 重新导出并跑冒烟,确认无坐标化之后仍然通过**

```bash
cd /Users/matthew/projects/meirongdev/godot-games
tools/build_web.sh 2>&1 | tail -3
lsof -ti tcp:8080 | xargs -r kill -9 2>/dev/null; sleep 1
python3 tools/web_smoke.py 2>&1 | tail -3
```

Expected: `✓ Web 冒烟通过:登录 → 大厅走通`

如果失败:说明 `grab_focus()` 没生效或 `text_submitted` 没连上。先看控制台里有没有 `[layout]` 那一行(证明新代码进了制品),再看是不是 `NAME` 打进去了(截图在 `/tmp/web_smoke.png`)。

- [ ] **Step 4: 提交**

```bash
git add godot/src/lobby/Login.gd tools/web_smoke.py
git commit -m "$(cat <<'EOF'
refactor(smoke): 登录页自动聚焦 + 回车提交,冒烟测试不再依赖像素坐标

马上要重排整套布局,而冒烟测试是靠 --click 640,392 点名字框的 ——
坐标一废,后面每一步的验证都站不住。

让 name_edit 开局 grab_focus()、回车触发提交,冒烟测试就只需要打字和
按回车。这两条本身也是手机上该有的:打开就能打字、软键盘的完成键能进去。

顺带加一行 [layout] 日志,把「这台设备上 UI 实际多大」打出来 ——
下一步的手机档位断言就靠它。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: 加手机竖屏档位(这一步故意留红)

**Files:**
- Modify: `tools/web_smoke.py`

- [ ] **Step 1: 把 run/check 改成按档位跑**

`tools/web_smoke.py` 顶部把 `NAME` 那一段替换成档位表 —— **两个档位不能共用
同一个名字**:每个档位都是全新的 Chrome profile → IndexedDB 是空的 → Nakama
设备 ID 重新生成 → 新账号,而 Nakama 的 username 全局唯一,第二个档位会撞上
「Username is already in use」。

```python
# 名字每次都要换,而且两个档位之间也要不一样(理由见上)。
# Login.gd 限名字最长 12 个字,所以 5 位时间戳 + 1 位档位标记。
NAME_BASE = "smoke" + str(int(time.time()))[-5:]

# 两个档位都要过。手机档位是这次的重点,桌面档位防回归。
TIERS = [
    {"name": "桌面", "win": None, "tag": "d"},
    {"name": "手机竖屏", "win": (390, 844), "tag": "m"},
]

# 逻辑视口宽度的上限(手机档位)。基准分辨率不对时这里会是 1280,
# 内容被缩到 30%,按钮实际高约 18pt —— iOS 的最小点击目标是 44pt。
MOBILE_VIEWPORT_MAX = 480
```

`run()` 的签名加 `name` 和 `win` 两个参数:

```python
async def run(url, shot_path, name, win=None):
```

并把 `run()` 里原来用到模块级 `NAME` 的三处(`?player=`、`page.type`)都改成用
参数 `name`:

```python
            await page.send("Page.navigate", {"url": f"{url}/?player={name}"})
```

```python
            await page.type(name)
```

在 `pump = asyncio.create_task(page.pump())` 之后、`Page.navigate` 之前插入:

```python
            if win:
                await page.send("Emulation.setDeviceMetricsOverride", {
                    "width": win[0], "height": win[1],
                    "deviceScaleFactor": 3, "mobile": True})
                await page.send("Emulation.setTouchEmulationEnabled", {
                    "enabled": True, "maxTouchPoints": 5})
```

- [ ] **Step 2: check() 加逻辑视口断言**

在 `check()` 里,`if "[config]" not in blob:` 那一段**之前**插入:

```python
    # 手机档位专属:逻辑视口必须是手机尺寸,不能是 1280。
    # 桌面档位下 1024 宽是正常的,所以只在手机档位查。
    if mobile:
        m = re.search(r"逻辑视口 (\d+)x", blob)
        if not m:
            problems.append("没看到 [layout] 日志,量不出 UI 尺寸")
        elif int(m.group(1)) > MOBILE_VIEWPORT_MAX:
            problems.append(
                f"逻辑视口宽 {m.group(1)},超过 {MOBILE_VIEWPORT_MAX}"
                f" —— 基准分辨率还是桌面的,手机上内容会被缩得点不到")
```

并把 `check` 的签名改成:

```python
def check(logs, mobile=False):
```

- [ ] **Step 3: main() 改成循环两个档位**

把 `main()` 里那行 `shot = os.path.join(tempfile.gettempdir(), "web_smoke.png")`
删掉(现在每个档位自己算 `shot`),再把从 `try:` 到 `return 0` 整段替换成:

```python
    failed = []
    try:
        for tier in TIERS:
            shot = os.path.join(tempfile.gettempdir(),
                                "web_smoke_%s.png" % ("mobile" if tier["win"] else "desktop"))
            name = NAME_BASE + tier["tag"]
            print(f"\n=== {tier['name']} ===")
            logs = asyncio.run(run(url, shot, name, tier["win"]))
            problems = check(logs, mobile=bool(tier["win"]))
            print(f"  截图:{shot}")
            if problems:
                failed.append(tier["name"])
                print(f"  ✗ {tier['name']} 失败:")
                for p in problems:
                    print(f"      - {p}")
                print("    控制台最后 20 行:")
                for line in logs[-20:]:
                    print("      " + line[:180])
            else:
                print(f"  ✓ {tier['name']} 通过")
    finally:
        if server:
            server.terminate()

    if failed:
        print("\n✗ Web 冒烟失败:" + "、".join(failed))
        return 1
    print("\n✓ Web 冒烟通过:桌面 + 手机竖屏,登录 → 大厅都走通")
    return 0
```

- [ ] **Step 4: 跑一次,确认手机档位红、桌面档位绿**

```bash
cd /Users/matthew/projects/meirongdev/godot-games
lsof -ti tcp:8080 | xargs -r kill -9 2>/dev/null; sleep 1
python3 tools/web_smoke.py 2>&1 | tail -20
```

Expected:
```
=== 桌面 ===
  ✓ 桌面 通过
=== 手机竖屏 ===
  ✗ 手机竖屏 失败:
      - 逻辑视口宽 1280,超过 480 —— 基准分辨率还是桌面的,手机上内容会被缩得点不到
✗ Web 冒烟失败:手机竖屏
```

**这一步就是要红。** 红的内容正是 spec §3 的实测数字。

- [ ] **Step 5: 提交(红)**

```bash
git add tools/web_smoke.py
git commit -m "$(cat <<'EOF'
test(smoke): 加手机竖屏档位,断言逻辑视口宽度

这一次提交故意留红:手机档位报「逻辑视口宽 1280,超过 480」,
正是 spec §3 实测到的根因 —— 基准分辨率是桌面的,手机上内容被缩到 30%。
下一步改基准分辨率让它变绿。

CI 不跑 web_smoke(需要 Nakama + Chrome),所以 main 不会因此变红。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: 基准分辨率改成竖屏(让秤变绿)

**Files:**
- Modify: `godot/project.godot`

- [ ] **Step 1: 改基准分辨率**

把 `godot/project.godot` 的 `[display]` 段整段替换成:

```
[display]

; ⚠️ 基准分辨率是**竖屏方向**的,这不是笔误。
; canvas_items + expand 的缩放系数是 min(窗口宽/基准宽, 窗口高/基准高) ——
; **短边决定一切**。基准 1280×800 时,390 宽的手机只能缩到
; min(390/1280, 844/800) = 0.30,按钮实际高约 18pt(iOS 最小点击目标 44pt)。
;
; 432 = 16 边距 ×2 + 400 内容列。竖屏时宽度是限制项,逻辑视口恒为 432 宽,
; 内容列恒为 400 —— 算术正好对上,不需要 max-width 逻辑。
; 桌面 1280×800 时高度是限制项,缩放 1.25,逻辑视口 1024×640,400 的列居中。
; 详见 docs/superpowers/specs/2026-08-27-mobile-portrait-design.md §4。
window/size/viewport_width=432
window/size/viewport_height=640
window/stretch/mode="canvas_items"
window/stretch/aspect="expand"
```

- [ ] **Step 2: 重新导出并跑冒烟,确认两个档位都绿**

```bash
cd /Users/matthew/projects/meirongdev/godot-games
tools/build_web.sh 2>&1 | tail -3
lsof -ti tcp:8080 | xargs -r kill -9 2>/dev/null; sleep 1
python3 tools/web_smoke.py 2>&1 | tail -12
```

Expected: `✓ Web 冒烟通过:桌面 + 手机竖屏,登录 → 大厅都走通`,且手机档位的 `[layout]` 行显示 `逻辑视口 432x935` 左右。

- [ ] **Step 3: 看两张截图**

看 `/tmp/web_smoke_mobile.png` 和 `/tmp/web_smoke_desktop.png`。

Expected(手机):内容铺满宽度,按钮明显变大。**字号会偏大** —— 46 号标题是给 1280 基准调的,现在坐标系小了 3 倍,标题会占掉很大一块。这是预期的,Task 4–7 逐个场景收。

Expected(桌面):单列偏窄地居中,两侧留白 —— 但因为大厅还是两栏,桌面大厅这一版会挤。同样在 Task 5 收。

- [ ] **Step 4: 提交**

```bash
git add godot/project.godot
git commit -m "$(cat <<'EOF'
fix(ui): 基准分辨率改成竖屏 432×640 —— 手机上一切被缩到 30% 的根因

canvas_items + expand 的缩放系数是 min(窗口宽/基准宽, 窗口高/基准高),
短边决定一切。基准 1280×800 时 390 宽的手机只能缩到 0.30,
按钮实际高约 18pt(iOS 最小点击目标 44pt),登录页 65% 是空白。

432 = 16 边距 ×2 + 400 内容列。竖屏时逻辑视口恒为 432 宽,内容列恒为
400,算术正好对上。桌面 1280×800 缩放 1.25,逻辑视口 1024×640。

web_smoke.py 的手机档位由此变绿。各场景的字号还是按 1280 调的,偏大,
后续逐个场景收。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: 登录页适配新坐标系

**Files:**
- Modify: `godot/src/lobby/Login.tscn`
- Modify: `godot/src/lobby/Login.gd`(只改 `@onready` 路径)
- Modify: `godot/tests/check_scenes.gd`
- Modify: `godot/tests/ShotHarness.gd`

- [ ] **Step 1: 整份替换 Login.tscn**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://src/lobby/Login.gd" id="1_login"]

[node name="Login" type="Control"]
layout_mode = 3
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
script = ExtResource("1_login")

[node name="Margin" type="MarginContainer" parent="."]
layout_mode = 1
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
theme_override_constants/margin_left = 16
theme_override_constants/margin_top = 16
theme_override_constants/margin_right = 16
theme_override_constants/margin_bottom = 16

[node name="Row" type="HBoxContainer" parent="Margin"]
layout_mode = 2
alignment = 1

[node name="Col" type="VBoxContainer" parent="Margin/Row"]
custom_minimum_size = Vector2(400, 0)
layout_mode = 2
alignment = 1
theme_override_constants/separation = 14

[node name="Title" type="Label" parent="Margin/Row/Col"]
layout_mode = 2
theme_override_font_sizes/font_size = 30
text = "家庭游戏大厅"
horizontal_alignment = 1

[node name="Hint" type="Label" parent="Margin/Row/Col"]
modulate = Color(1, 1, 1, 0.55)
layout_mode = 2
text = "输入名字,家里人就能在大厅看到你"
horizontal_alignment = 1
autowrap_mode = 3

[node name="NameEdit" type="LineEdit" parent="Margin/Row/Col"]
custom_minimum_size = Vector2(0, 48)
layout_mode = 2
placeholder_text = "你的名字"
alignment = 1

[node name="EnterButton" type="Button" parent="Margin/Row/Col"]
custom_minimum_size = Vector2(0, 52)
layout_mode = 2
theme_override_font_sizes/font_size = 22
text = "进入大厅"

[node name="Status" type="Label" parent="Margin/Row/Col"]
modulate = Color(1, 0.75, 0.4, 1)
layout_mode = 2
horizontal_alignment = 1
autowrap_mode = 3
```

`Row` 用 `alignment = 1`(居中)负责水平居中,`Col` 用 `alignment = 1` 负责垂直居中 —— 替代原来的 `CenterContainer`。**为什么不用 `CenterContainer`:** 它会把子节点压到最小尺寸,竖直方向也压,后面的大厅/房间需要「水平居中 + 竖直铺满」,`CenterContainer` 做不到。四个场景用同一个 `Margin → Row → Col` 结构。

- [ ] **Step 2: 改 Login.gd 的三个 @onready 路径**

```gdscript
@onready var name_edit: LineEdit = $Margin/Row/Col/NameEdit
@onready var enter_button: Button = $Margin/Row/Col/EnterButton
@onready var status: Label = $Margin/Row/Col/Status
```

- [ ] **Step 3: 改 check_scenes.gd 里 Login 的路径**

```gdscript
	"res://src/lobby/Login.tscn": [
		"Margin/Row/Col/NameEdit", "Margin/Row/Col/EnterButton",
		"Margin/Row/Col/Status",
	],
```

- [ ] **Step 4: 改 ShotHarness.gd 里 Login 的路径**

```gdscript
func _login() -> void:
	var s: Control = load("res://src/lobby/Login.tscn").instantiate()
	add_child(s)
	s.get_node("Margin/Row/Col/NameEdit").text = "爸爸"
```

- [ ] **Step 5: 跑节点路径检查**

```bash
cd /Users/matthew/projects/meirongdev/godot-games
/Applications/Godot.app/Contents/MacOS/Godot --headless --path godot \
  --script res://tests/check_scenes.gd 2>&1 | grep -a "MISSING\|checked"
```

Expected: `checked 28 paths across 4 scenes, FAILURES: 0`(只改了 Login 的三条,其他场景还没动)

- [ ] **Step 6: 重新导出并跑冒烟 + 看截图**

```bash
tools/build_web.sh 2>&1 | tail -3
lsof -ti tcp:8080 | xargs -r kill -9 2>/dev/null; sleep 1
python3 tools/web_smoke.py 2>&1 | tail -12
```

Expected: 两个档位都通过。`/tmp/web_smoke_mobile.png` 里登录页铺满宽度、标题不再压屏。

- [ ] **Step 7: 提交**

```bash
git add godot/src/lobby/Login.tscn godot/src/lobby/Login.gd \
        godot/tests/check_scenes.gd godot/tests/ShotHarness.gd
git commit -m "$(cat <<'EOF'
feat(ui): 登录页改成 Margin→Row→Col 单列,字号收到新坐标系

统一的居中结构:Row(HBox, alignment=1) 管水平居中,Col(VBox, alignment=1)
管垂直居中。不用 CenterContainer —— 它会把子节点竖直方向也压到最小尺寸,
后面的大厅/房间需要「水平居中 + 竖直铺满」,它做不到。

标题 46 → 30,输入框/按钮最小高 56 → 48/52:基准从 1280 变 432 之后
坐标系小了 3 倍,原来的字号会占掉整屏。

顺带修掉一个现存问题:原来 Center/Box 的 custom_minimum_size 是 440,
比 432 宽的逻辑视口还宽,手机上边缘会被切掉一点。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

> 最后那段是执行期补的:Task 3 的 code review 发现 `Center/Box` 的 440 已经
> 超过 432 的逻辑视口,正好被这一步的整份替换顺手修掉,值得记在 commit 里。

---

## 骨架的两条规则(Task 4 的 code review 从 Godot 引擎源码确认)

`Margin → Row → Col` 已在 Task 4 落地并逐条验证过,Tasks 5–6 照抄。两条必须
带着走的规则:

1. **别给 `Col` 加带 EXPAND 的 `size_flags_horizontal`。**
   `custom_minimum_size.x = 400` 是**下限,不是上限**。`box_container.cpp` 里
   「居中」和「400 不被拉宽」用的是同一份 leftover space —— 子节点一 expand
   就把 leftover 全吃掉,居中和限宽同时失效。手机上看不出来(432−32 正好
   等于 400,leftover 本来就是 0),到桌面才炸。

2. **凡是显示「自己控制不了的文字」的 Label,`autowrap_mode` 必须是 3
   (`AUTOWRAP_WORD_SMART`),不能是 2(`AUTOWRAP_WORD`)。**
   2 只在词间软换行,**不会**强行拆开一个超长的不可断 token;3 会。
   `Status` 直接吃 `NakamaException.message` 和 `_rpc_error()` 兜底透出的
   原始错误码 —— 一旦里面有 URL 或下划线连起来的长标识符,Label 的最小宽度
   就超过 400,`Col` 的最小宽度跟着涨,而这条链上没有任何 `clip_contents`,
   项目里也没有 `ScrollContainer` —— 直接横向溢出到屏幕外。
   所以本计划里所有 `autowrap_mode` 一律写 3。

另外确认过的两件事(可以放心依赖):`alignment = 1` 在 `HBoxContainer` 和
`VBoxContainer` 上都是 CENTER;`Col` 默认在交叉轴(高度)上是 FILL,所以它
真的铺满高度,Tasks 5–6 的 `size_flags_vertical = 3` 子节点能正常拿到剩余高度。

---

## Task 5: 大厅重排成单列 + 分段切换

**Files:**
- Modify: `godot/src/lobby/Lobby.tscn`
- Modify: `godot/src/lobby/Lobby.gd`
- Modify: `godot/tests/check_scenes.gd`
- Modify: `godot/tests/ShotHarness.gd`

- [ ] **Step 1: 整份替换 Lobby.tscn**

```
[gd_scene load_steps=4 format=3]

[ext_resource type="Script" path="res://src/lobby/Lobby.gd" id="1_lobby"]

[sub_resource type="StyleBoxFlat" id="panel"]
bg_color = Color(0.16, 0.16, 0.16, 1)
corner_radius_top_left = 4
corner_radius_top_right = 4
corner_radius_bottom_right = 4
corner_radius_bottom_left = 4
content_margin_left = 12.0
content_margin_top = 10.0
content_margin_right = 12.0
content_margin_bottom = 10.0

[sub_resource type="ButtonGroup" id="segments"]

[node name="Lobby" type="Control"]
layout_mode = 3
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
script = ExtResource("1_lobby")

[node name="Margin" type="MarginContainer" parent="."]
layout_mode = 1
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
theme_override_constants/margin_left = 16
theme_override_constants/margin_top = 16
theme_override_constants/margin_right = 16
theme_override_constants/margin_bottom = 16

[node name="Row" type="HBoxContainer" parent="Margin"]
layout_mode = 2
alignment = 1

[node name="Col" type="VBoxContainer" parent="Margin/Row"]
custom_minimum_size = Vector2(400, 0)
layout_mode = 2
theme_override_constants/separation = 10

[node name="Title" type="Label" parent="Margin/Row/Col"]
layout_mode = 2
theme_override_font_sizes/font_size = 24
text = "家庭游戏大厅"
horizontal_alignment = 1

[node name="Segments" type="HBoxContainer" parent="Margin/Row/Col"]
layout_mode = 2
theme_override_constants/separation = 8

[node name="RoomsTab" type="Button" parent="Margin/Row/Col/Segments"]
custom_minimum_size = Vector2(0, 48)
layout_mode = 2
size_flags_horizontal = 3
toggle_mode = true
button_pressed = true
button_group = SubResource("segments")
text = "房间"

[node name="OnlineTab" type="Button" parent="Margin/Row/Col/Segments"]
custom_minimum_size = Vector2(0, 48)
layout_mode = 2
size_flags_horizontal = 3
toggle_mode = true
button_group = SubResource("segments")
text = "在线"

[node name="ChatTab" type="Button" parent="Margin/Row/Col/Segments"]
custom_minimum_size = Vector2(0, 48)
layout_mode = 2
size_flags_horizontal = 3
toggle_mode = true
button_group = SubResource("segments")
text = "聊天"

[node name="Rooms" type="VBoxContainer" parent="Margin/Row/Col"]
layout_mode = 2
size_flags_vertical = 3

[node name="RoomList" type="ItemList" parent="Margin/Row/Col/Rooms"]
layout_mode = 2
size_flags_vertical = 3
theme_override_font_sizes/font_size = 18

[node name="Online" type="VBoxContainer" parent="Margin/Row/Col"]
visible = false
layout_mode = 2
size_flags_vertical = 3

[node name="OnlineList" type="ItemList" parent="Margin/Row/Col/Online"]
layout_mode = 2
size_flags_vertical = 3
theme_override_font_sizes/font_size = 18

[node name="Chat" type="VBoxContainer" parent="Margin/Row/Col"]
visible = false
layout_mode = 2
size_flags_vertical = 3
theme_override_constants/separation = 8

[node name="ChatLog" type="RichTextLabel" parent="Margin/Row/Col/Chat"]
layout_mode = 2
size_flags_vertical = 3
theme_override_font_sizes/normal_font_size = 18
theme_override_styles/normal = SubResource("panel")
bbcode_enabled = true
scroll_following = true

[node name="ChatEdit" type="LineEdit" parent="Margin/Row/Col/Chat"]
custom_minimum_size = Vector2(0, 48)
layout_mode = 2
placeholder_text = "说点什么…"

[node name="CreateBox" type="VBoxContainer" parent="Margin/Row/Col"]
layout_mode = 2
theme_override_constants/separation = 8

[node name="GameOption" type="OptionButton" parent="Margin/Row/Col/CreateBox"]
custom_minimum_size = Vector2(0, 48)
layout_mode = 2

[node name="RoomNameEdit" type="LineEdit" parent="Margin/Row/Col/CreateBox"]
custom_minimum_size = Vector2(0, 48)
layout_mode = 2
placeholder_text = "房间名(留空自动起)"

[node name="CreateButton" type="Button" parent="Margin/Row/Col/CreateBox"]
custom_minimum_size = Vector2(0, 52)
layout_mode = 2
theme_override_font_sizes/font_size = 22
text = "建房"

[node name="Status" type="Label" parent="Margin/Row/Col"]
layout_mode = 2
theme_override_colors/font_color = Color(1, 0.63, 0.36, 1)
theme_override_font_sizes/font_size = 15
autowrap_mode = 3
```

三个面板是 `Col` 的兄弟节点,同一时刻只有一个 `visible`,可见的那个吃掉剩余高度。`CreateBox` **始终可见** —— 建房是主操作,不该藏在页签后面。

- [ ] **Step 2: 改 Lobby.gd 的 @onready 和分段逻辑**

把 `godot/src/lobby/Lobby.gd` 从第 5 行的 `@onready` 块到 `_ready()` 结束整段替换成:

```gdscript
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


func _ready() -> void:
	ServerConnection.lobby_presence_changed.connect(_on_presence_changed)
	ServerConnection.lobby_message.connect(_on_message)
	create_button.pressed.connect(_on_create_pressed)
	chat_edit.text_submitted.connect(_on_chat_submitted)
	room_list.item_activated.connect(_on_room_activated)

	# 竖屏一屏放不下「房间/在线/聊天」三块,用分段切换。
	# 用三个 toggle Button 而不是 TabContainer:页签是手机上的主导航,
	# 必须够大(≥44),而 TabContainer 的页签高度由主题 StyleBox 的内边距
	# 决定,想做到 44 得自己写一套 StyleBox。Button 一个 custom_minimum_size
	# 就够了。互斥由 .tscn 里的 ButtonGroup 保证。
	$Margin/Row/Col/Segments/RoomsTab.pressed.connect(_show_segment.bind("rooms"))
	$Margin/Row/Col/Segments/OnlineTab.pressed.connect(_show_segment.bind("online"))
	$Margin/Row/Col/Segments/ChatTab.pressed.connect(_show_segment.bind("chat"))

	status.text = ""

	await ServerConnection.join_lobby_async()
	await _load_games()
	_refresh_rooms()


func _show_segment(which: String) -> void:
	for key in _panels:
		_panels[key].visible = key == which
```

**注意:** 原来 `_ready()` 里的 `refresh_button.pressed.connect(_refresh_rooms)` 和对应的 `@onready var refresh_button` 一起删掉了 —— 列表本来每 3 秒自动轮询,竖屏下这个按钮纯占地方。

- [ ] **Step 3: 改 check_scenes.gd 里 Lobby 的路径**

```gdscript
	"res://src/lobby/Lobby.tscn": [
		"Margin/Row/Col/Segments/RoomsTab", "Margin/Row/Col/Segments/OnlineTab",
		"Margin/Row/Col/Segments/ChatTab",
		"Margin/Row/Col/Rooms/RoomList", "Margin/Row/Col/Online/OnlineList",
		"Margin/Row/Col/Chat/ChatLog", "Margin/Row/Col/Chat/ChatEdit",
		"Margin/Row/Col/CreateBox/GameOption",
		"Margin/Row/Col/CreateBox/RoomNameEdit",
		"Margin/Row/Col/CreateBox/CreateButton", "Margin/Row/Col/Status",
	],
```

- [ ] **Step 4: 改 ShotHarness.gd 里 Lobby 的房间列表路径**

把 `_lobby()` 里这一行:

```gdscript
	var room_list: ItemList = s.get_node("HBox/Right/RoomList")
```

改成:

```gdscript
	var room_list: ItemList = s.get_node("Margin/Row/Col/Rooms/RoomList")
```

- [ ] **Step 5: 跑节点路径检查**

```bash
cd /Users/matthew/projects/meirongdev/godot-games
/Applications/Godot.app/Contents/MacOS/Godot --headless --path godot \
  --script res://tests/check_scenes.gd 2>&1 | grep -a "MISSING\|checked"
```

Expected: `FAILURES: 0`。有 `MISSING` 就是 `.tscn` 的节点名和 CHECKS 对不上,照报错改。

- [ ] **Step 6: 重新导出,冒烟 + 肉眼看两个档位**

```bash
tools/build_web.sh 2>&1 | tail -3
lsof -ti tcp:8080 | xargs -r kill -9 2>/dev/null; sleep 1
python3 tools/web_smoke.py 2>&1 | tail -12
```

Expected: 两个档位都通过(冒烟断言里有 `[lobby] 在线 N 人`,分段切换不影响它)。

看 `/tmp/web_smoke_mobile.png`:标题、三个页签、房间列表、建房区自上而下一列;页签明显够大。
看 `/tmp/web_smoke_desktop.png`:同一列居中,两侧留白。

- [ ] **Step 7: 手动确认分段切换真的能切**

```bash
SP=/tmp/lobby-seg
mkdir -p $SP
lsof -ti tcp:8080 | xargs -r kill -9 2>/dev/null; sleep 1
nohup python3 tools/serve_web.py 8080 > $SP/serve.log 2>&1 &
sleep 2
```

然后用 Chrome MCP 或手工开 `http://localhost:8080/?player=seg1`,登录后点「在线」和「聊天」两个页签,确认面板真的切换、聊天能输入。

**⚠️ 用浏览器手工看的时候标签页必须在前台** —— Chrome 对隐藏标签不跑 `requestAnimationFrame`,Godot 主循环挂在 rAF 上,标签一隐藏引擎直接不转,看起来像卡死。

- [ ] **Step 8: 提交**

```bash
git add godot/src/lobby/Lobby.tscn godot/src/lobby/Lobby.gd \
        godot/tests/check_scenes.gd godot/tests/ShotHarness.gd
git commit -m "$(cat <<'EOF'
feat(ui): 大厅重排成单列 + 分段切换,竖屏能用了

左右两栏在 390 宽的手机上每栏不到 200,房间名和房主名都放不下。
合成一列,顶部三个页签切「房间/在线/聊天」,建房区始终可见 ——
它是主操作,不该藏在页签后面。

分段切换用三个 toggle Button + ButtonGroup,不用 TabContainer:
页签是手机上的主导航必须够大(≥44),而 TabContainer 的页签高度由主题
StyleBox 的内边距决定,想做到 44 得自己写一套 StyleBox。

顺带删掉「刷新」按钮:列表本来每 3 秒自动轮询,竖屏下它纯占地方。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: 房间页单列 + 横向玩家名单

**Files:**
- Modify: `godot/src/room/Room.tscn`
- Modify: `godot/src/room/RoomController.gd`
- Modify: `godot/tests/check_scenes.gd`

- [ ] **Step 1: 整份替换 Room.tscn**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://src/room/RoomController.gd" id="1_room"]

[node name="Room" type="Control"]
layout_mode = 3
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
script = ExtResource("1_room")

[node name="Margin" type="MarginContainer" parent="."]
layout_mode = 1
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
theme_override_constants/margin_left = 16
theme_override_constants/margin_top = 16
theme_override_constants/margin_right = 16
theme_override_constants/margin_bottom = 16

[node name="Row" type="HBoxContainer" parent="Margin"]
layout_mode = 2
alignment = 1

[node name="Col" type="VBoxContainer" parent="Margin/Row"]
custom_minimum_size = Vector2(400, 0)
layout_mode = 2
theme_override_constants/separation = 10

[node name="Header" type="HBoxContainer" parent="Margin/Row/Col"]
layout_mode = 2
theme_override_constants/separation = 8

[node name="RoomTitle" type="Label" parent="Margin/Row/Col/Header"]
layout_mode = 2
size_flags_horizontal = 3
size_flags_vertical = 4
theme_override_font_sizes/font_size = 20
text = "房间"
autowrap_mode = 3

[node name="LeaveButton" type="Button" parent="Margin/Row/Col/Header"]
custom_minimum_size = Vector2(72, 48)
layout_mode = 2
size_flags_vertical = 4
theme_override_font_sizes/font_size = 18
text = "离开"

[node name="PlayerStrip" type="Label" parent="Margin/Row/Col"]
layout_mode = 2
theme_override_font_sizes/font_size = 17
autowrap_mode = 3

[node name="GameSlot" type="Control" parent="Margin/Row/Col"]
layout_mode = 2
size_flags_horizontal = 3
size_flags_vertical = 3

[node name="Actions" type="HBoxContainer" parent="Margin/Row/Col"]
layout_mode = 2
theme_override_constants/separation = 8

[node name="ReadyButton" type="CheckButton" parent="Margin/Row/Col/Actions"]
custom_minimum_size = Vector2(0, 48)
layout_mode = 2
size_flags_horizontal = 3
theme_override_font_sizes/font_size = 20
text = "准备"

[node name="StartButton" type="Button" parent="Margin/Row/Col/Actions"]
custom_minimum_size = Vector2(0, 52)
layout_mode = 2
size_flags_horizontal = 3
theme_override_font_sizes/font_size = 22
text = "开始游戏"

[node name="Status" type="Label" parent="Margin/Row/Col"]
layout_mode = 2
theme_override_font_sizes/font_size = 18
horizontal_alignment = 1
autowrap_mode = 3
```

玩家名单从竖着的 `ItemList` 换成一个 `autowrap` 的 `Label`(`PlayerStrip`)—— 竖屏里竖直空间全要留给游戏区,而家庭局最多 8 人,一两行就写完了。

- [ ] **Step 2: 改 RoomController.gd 的 @onready 路径**

把 `godot/src/room/RoomController.gd` 的 `@onready` 块整段替换成:

```gdscript
@onready var room_title: Label = $Margin/Row/Col/Header/RoomTitle
@onready var leave_button: Button = $Margin/Row/Col/Header/LeaveButton
@onready var player_strip: Label = $Margin/Row/Col/PlayerStrip
@onready var ready_button: CheckButton = $Margin/Row/Col/Actions/ReadyButton
@onready var start_button: Button = $Margin/Row/Col/Actions/StartButton
@onready var game_slot: Control = $Margin/Row/Col/GameSlot
@onready var status: Label = $Margin/Row/Col/Status
```

- [ ] **Step 3: 改名单渲染:ItemList → 一行文字**

在 `_apply_room_state()` 里,把这一段:

```gdscript
	var me := ServerConnection.get_user_id()
	player_list.clear()
	for p in _players:
		var line: String = p["name"]
		if p["id"] == me:
			line += "(我)"
		if p["id"] == _host:
			line += "  👑"
		line += "  ✓ 已准备" if p["ready"] else "  …"
		player_list.add_item(line)
```

替换成:

```gdscript
	var me := ServerConnection.get_user_id()
	# 竖屏里竖直空间全给游戏区,名单压成一行(最多 8 人,一两行写完)。
	# 房主的 👑 放在名字前面 —— 后面跟着 ✓,放后面会挤成一团认不出。
	var parts := PackedStringArray()
	for p in _players:
		var line: String = p["name"]
		if p["id"] == _host:
			line = "👑" + line
		if p["id"] == me:
			line += "(我)"
		if p["ready"]:
			line += " ✓"
		parts.append(line)
	player_strip.text = "   ".join(parts)
```

- [ ] **Step 4: 改 check_scenes.gd 里 Room 的路径**

```gdscript
	"res://src/room/Room.tscn": [
		"Margin/Row/Col/Header/RoomTitle", "Margin/Row/Col/Header/LeaveButton",
		"Margin/Row/Col/PlayerStrip", "Margin/Row/Col/Actions/ReadyButton",
		"Margin/Row/Col/Actions/StartButton", "Margin/Row/Col/GameSlot",
		"Margin/Row/Col/Status",
	],
```

- [ ] **Step 5: 跑节点路径检查**

```bash
cd /Users/matthew/projects/meirongdev/godot-games
/Applications/Godot.app/Contents/MacOS/Godot --headless --path godot \
  --script res://tests/check_scenes.gd 2>&1 | grep -a "MISSING\|checked"
```

Expected: `FAILURES: 0`

- [ ] **Step 6: 提交**

```bash
git add godot/src/room/Room.tscn godot/src/room/RoomController.gd \
        godot/tests/check_scenes.gd
git commit -m "$(cat <<'EOF'
feat(ui): 房间页改单列,玩家名单压成一行

竖屏里竖直空间全要留给游戏区,所以玩家名单从竖着的 ItemList 换成一个
autowrap 的 Label —— 家庭局最多 8 人,一两行就写完了。

准备/开始并排放在底部固定操作条里,两个都是 ≥48 高。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: 猜拳页手势按钮铺满宽度

`RpsGame.tscn` 被实例化进 `Room` 的 `GameSlot`,已经在 400 宽的列里 —— **不加 Margin/Row/Col 包装**,节点树保持不动(所以 `RpsGame.gd` 和 `check_scenes.gd` 都不用改),只调尺寸。

**Files:**
- Modify: `godot/src/games/rps/RpsGame.tscn`

- [ ] **Step 1: 改尺寸(五处)**

在 `godot/src/games/rps/RpsGame.tscn` 里逐项改:

`RoundLabel`:
```
custom_minimum_size = Vector2(0, 34)
theme_override_font_sizes/font_size = 20
```

`Countdown`:
```
custom_minimum_size = Vector2(0, 14)
```

`Hands`:
```
custom_minimum_size = Vector2(0, 118)
theme_override_constants/separation = 10
```

三个手势按钮(`RockButton` / `PaperButton` / `ScissorButton`)每个都改成:
```
custom_minimum_size = Vector2(0, 110)
size_flags_horizontal = 3
theme_override_font_sizes/font_size = 44
```

原来是固定 `Vector2(140, 140)`;改成宽度 `size_flags_horizontal = 3`(expand fill)让三个按钮**均分**整列宽度 —— 400 宽减去两个 10 的间距,每个约 126 宽,手指够大且不会溢出。

`Result`:
```
custom_minimum_size = Vector2(0, 120)
theme_override_font_sizes/normal_font_size = 17
```

`Spectator`:
```
custom_minimum_size = Vector2(0, 30)
theme_override_font_sizes/font_size = 18
```

`Hands` 的 `alignment = 1` 删掉 —— 按钮已经均分铺满,居中对齐没有意义了。

- [ ] **Step 2: 跑节点路径检查(应该零改动通过)**

```bash
cd /Users/matthew/projects/meirongdev/godot-games
/Applications/Godot.app/Contents/MacOS/Godot --headless --path godot \
  --script res://tests/check_scenes.gd 2>&1 | grep -a "MISSING\|checked"
```

Expected: `FAILURES: 0`(节点树没动)

- [ ] **Step 3: 提交**

```bash
git add godot/src/games/rps/RpsGame.tscn
git commit -m "$(cat <<'EOF'
feat(ui): 猜拳的三个手势按钮均分列宽

原来是固定 140×140,在 400 宽的单列里放不下三个。改成
size_flags_horizontal = 3 均分宽度,每个约 126 宽、110 高。

节点树没动,所以 RpsGame.gd 和 check_scenes.gd 都不用改。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: 打一整局验证 + 重新生成文档截图

前面每个 Task 只验证了「登录 → 大厅」。这一步真打一局,确认房间页和猜拳页在竖屏下能玩。

**Files:**
- Modify: `tools/take_screenshots.py`
- Modify: `docs/screenshots/login.png`, `lobby.png`, `room.png`, `rps.png`

- [ ] **Step 1: 起陪练机器人,竖屏打一整局**

先写陪练脚本(它加入浏览器建的房、准备、出拳、打到局终):

```bash
cat > /tmp/bot.py <<'PYEOF'
import asyncio, json, base64, sys, time, urllib.request, websockets
KEY="family-lobby-2026"; HOST,PORT="127.0.0.1",7350
READY,START,GAME_STARTED,GAME_OVER,THROW,ROUND_BEGIN = 1,2,11,12,20,30
def _post(u,b,h):
    return json.load(urllib.request.urlopen(urllib.request.Request(
        u, data=json.dumps(b).encode(), headers=dict(h, **{"User-Agent":"bot"}))))
def auth(d):
    basic=base64.b64encode(f"{KEY}:".encode()).decode()
    return _post(f"http://{HOST}:{PORT}/v2/account/authenticate/device?create=true",
        {"id":d},{"Content-Type":"application/json","Authorization":"Basic "+basic})["token"]
def rpc(t,n,p):
    return json.loads(_post(f"http://{HOST}:{PORT}/v2/rpc/{n}", json.dumps(p),
        {"Content-Type":"application/json","Authorization":f"Bearer {t}"})["payload"])
async def main():
    tok=auth("bot-portrait-0123456789ab"); mid=None
    deadline=time.time()+60
    while time.time()<deadline:
        w=[r for r in rpc(tok,"list_rooms",{}).get("rooms",[]) if r.get("phase")=="waiting"]
        if w: mid=w[0]["match_id"]; print("[bot] 进房", mid[:8], flush=True); break
        await asyncio.sleep(1)
    if not mid: print("[bot] 等不到房间"); return
    ws=await websockets.connect(
        f"ws://{HOST}:{PORT}/ws?lang=en&status=true&format=json&token={tok}",
        user_agent_header="bot")
    cid=[0]
    async def send(o):
        cid[0]+=1; o["cid"]=str(cid[0]); await ws.send(json.dumps(o))
    async def op(c,d=None):
        await send({"match_data_send":{"match_id":mid,"op_code":str(c),
            "data":base64.b64encode(json.dumps(d or {}).encode()).decode()}})
    await send({"match_join":{"match_id":mid}}); await asyncio.sleep(1)
    await op(READY,{"ready":True}); print("[bot] 已准备", flush=True)
    while True:
        m=json.loads(await asyncio.wait_for(ws.recv(),timeout=60))
        if "match_data" not in m: continue
        d=m["match_data"]; code=int(d.get("op_code",0))
        body=json.loads(base64.b64decode(d.get("data") or "e30=").decode())
        if code==ROUND_BEGIN: await op(THROW,{"hand":0}); print("[bot] 出拳", flush=True)
        elif code==GAME_OVER:
            print("[bot] 局终", [r.get("name") for r in body.get("results",[])], flush=True); break
    await send({"match_leave":{"match_id":mid}}); await asyncio.sleep(0.5); await ws.close()
asyncio.run(main())
PYEOF
echo written
```

- [ ] **Step 2: 竖屏驱动:建房 → 准备 → 开局 → 打完 → 离开 → 再建房**

用 Chrome MCP(或等价的 CDP 脚本)在 **390×844 设备模拟 + 前台可见** 的标签页里操作。

⚠️ **不要照抄坐标 —— 每一步点之前先截一张图,按图上按钮的实际位置点。**
布局是这个计划刚改出来的,任何写死的坐标都可能是错的。下面给的是**预期位置**
(390×844 CSS 像素,缩放 0.9028),只用来对照「截图里按钮是不是大致在这儿」:

| 操作 | 预期位置(CSS px) | 怎么确认 |
|---|---|---|
| 名字输入 | 不需要坐标 | `grab_focus()` 已经聚焦,直接打字 + 回车 |
| 大厅「建房」 | 约 `(195, 780)` | 底部操作条最下面那个大按钮 |
| 房间「准备」 | 约 `(105, 800)` | 底部操作条左半 |
| 房间「开始游戏」 | 约 `(290, 800)` | 底部操作条右半 |
| 房间「离开」 | 约 `(360, 34)` | 右上角 |
| 猜拳三个手势 | 约 `y=?`,x 分别 `70 / 195 / 320` | 三个按钮均分列宽,y 看截图 |

流程:

1. 开 `http://localhost:8080/?player=port1`,等 10 秒加载,**截图**
2. 打字 `port1`,按回车 → 进大厅,**截图**
3. 按图点「建房」→ 进房间,**截图**
4. 按图点「准备」
5. 等陪练机器人加入并准备(`tail -f /tmp/bot.log` 等到 `[bot] 已准备`)
6. 按图点「开始游戏」
7. 等局终(约 15 秒),**截图** —— 这一张要能看清三个手势按钮和战报
8. 按图点「离开」→ 回大厅,**截图**

启动机器人和服务:

```bash
cd /Users/matthew/projects/meirongdev/godot-games
lsof -ti tcp:8080 | xargs -r kill -9 2>/dev/null; sleep 1
nohup python3 tools/serve_web.py 8080 > /tmp/serve.log 2>&1 &
sleep 2
nohup python3 /tmp/bot.py > /tmp/bot.log 2>&1 &
```

Expected:`/tmp/bot.log` 里依次出现 `[bot] 进房`、`[bot] 已准备`、`[bot] 出拳`、`[bot] 局终`。
浏览器里:三个手势按钮铺满宽度点得到、战报读得清、房名和玩家名单一行显示、局终后能离开并再建房。

**⚠️ 标签页必须前台可见**,理由同 Task 5 Step 7。

**软键盘遮挡这一条自动化验不出来。** CDP 的设备模拟不会真的弹出软键盘,
所以 spec §8 里那条「聊天输入框可能被软键盘挡住」只能在真手机上确认。
这一步之后请拿真机开一次 `https://<web 域名>/`,点聊天输入框看一眼 ——
挡住了再单独处理,不挡就把 spec §8 那一条划掉。

- [ ] **Step 3: 让截图工具能出竖屏图**

`tools/take_screenshots.py` 里 `--resolution 1280x800` 改成从环境变量取,默认竖屏:

```python
RES = os.environ.get("SHOT_RES", "432x866")
```

并把 subprocess 那一行的 `"--resolution", "1280x800"` 改成 `"--resolution", RES`。

顺带更新文件头的说明:

```python
"""生成文档截图:四个场景的「有内容」画面 → docs/screenshots/*.png

前置: cd nakama && docker compose up -d(harness 要真实登录拿 user_id)

分辨率默认 432x866(手机竖屏,基准分辨率 432×640 下的真实竖屏比例)。
要桌面比例:SHOT_RES=1280x800 python3 tools/take_screenshots.py

⚠️ 这个脚本跑的是**桌面** Godot。桌面有系统字体回退,Web 导出没有 ——
   所以截图看起来正常 ≠ Web 版正常。字体问题只有 tests/check_fonts.gd
   和真开一次网页能抓到(2026-08-27 就是这么漏掉整套中文字体的)。
原理: 临时把 main_scene 指向 tests/ShotHarness.tscn,movie 模式渲染,
      取最后一帧。SHOT 环境变量选场景。
"""
```

- [ ] **Step 4: 重新生成四张文档截图**

```bash
cd /Users/matthew/projects/meirongdev/godot-games
python3 tools/take_screenshots.py
git status --short docs/screenshots/
```

Expected: 四行 `login.png` / `lobby.png` / `room.png` / `rps.png` 各打印一个 KB 数,`git status` 显示四个文件被修改。

肉眼看一遍四张图:竖屏比例、中文正常、`✊ ✋ ✌` 画得出来。

- [ ] **Step 5: 提交**

```bash
git add tools/take_screenshots.py docs/screenshots/
git commit -m "$(cat <<'EOF'
docs: 文档截图改成手机竖屏比例

take_screenshots.py 的分辨率改成从 SHOT_RES 取,默认 432x866(竖屏)。
要桌面比例:SHOT_RES=1280x800。

四张截图重新生成 —— 布局已经是单列了,旧的两栏截图对不上代码。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: 全量回归 + 同步 spec + 发布

**Files:**
- Modify: `docs/superpowers/specs/2026-08-27-mobile-portrait-design.md`
- Modify: `docs/deployment-contract.md`

- [ ] **Step 1: 把三处偏差同步回 spec**

在 spec 里改这三处(内容见本计划开头的偏差表):

1. §4 标题下的 `起步值 **400×640**` → `**432×640**`,并把表格里的「内容列实际宽度」按 432 重算;补一句 `432 = 16 边距 ×2 + 400 内容列,竖屏时逻辑视口恒为 432 宽`。
2. §5.2 的 `分段切换用 **TabContainer**` 那一条 → 改成三个 toggle `Button` + `ButtonGroup`,理由是 `TabContainer` 的页签高度由主题 StyleBox 内边距决定,做不到 44pt。图注 `← TabContainer 的页签` → `← 三个 toggle Button`。
3. §6 整节 → 保留标题,内容改成「**不做**」并写明理由:实测现有 `custom_minimum_size` 已经全是 44–56 逻辑像素,基准分辨率一改就全部达标;Theme 没有 min-height 属性,要靠 StyleBox 内边距实现,等于重写一套外观。

4. §9 影响面表 → 删掉 `family.tres` 那一行,补上实现期才发现要改的四个文件:
   `godot/src/lobby/Login.gd`(自动聚焦 + 回车提交 + `[layout]` 日志)、
   `godot/tests/check_scenes.gd`(节点路径)、
   `godot/tests/ShotHarness.gd`(节点路径)、
   `tools/take_screenshots.py`(竖屏分辨率)。

顺带把状态行从 `设计已确认,待实施` 改成 `已实施(2026-08-27)`。

- [ ] **Step 2: 契约里记一句手机竖屏的验收**

在 `docs/deployment-contract.md` 的 §4.2.1 里,`python3 tools/web_smoke.py` 那个代码块下面补一句:

```markdown
它现在跑**两个档位**:桌面和手机竖屏(390×844 + 触摸模拟)。手机档位额外
断言逻辑视口宽度 ≤ 480 —— 基准分辨率要是被人改回桌面尺寸,这里会立刻红。
```

- [ ] **Step 3: 全量回归**

```bash
cd /Users/matthew/projects/meirongdev/godot-games

echo "=== 1. Lua 单测 ==="
(cd nakama && docker run --rm --platform linux/amd64 -v "$PWD:/work" -w /work imega/busted 2>&1 | tail -2)

echo "=== 2. 场景节点路径 ==="
/Applications/Godot.app/Contents/MacOS/Godot --headless --path godot \
  --script res://tests/check_scenes.gd 2>&1 | grep -a "MISSING\|checked"

echo "=== 3. 字体覆盖 ==="
/Applications/Godot.app/Contents/MacOS/Godot --headless --path godot \
  --script res://tests/check_fonts.gd 2>&1 | tail -2

echo "=== 4. 端到端(服务端全链路) ==="
NAKAMA_HOST=127.0.0.1 NAKAMA_PORT=7350 python3 tools/e2e_match.py 2 2>&1 | tail -4

echo "=== 5. 导出 + 制品自检 ==="
tools/build_web.sh 2>&1 | tail -3

echo "=== 6. Web 冒烟(桌面 + 手机) ==="
lsof -ti tcp:8080 | xargs -r kill -9 2>/dev/null; sleep 1
python3 tools/web_smoke.py 2>&1 | tail -12
```

Expected:
- Lua `82 successes / 0 failures`
- 场景路径 `FAILURES: 0`
- 字体检查通过
- e2e `局终 : ✓`
- 导出通过全部自检
- 冒烟 `✓ Web 冒烟通过:桌面 + 手机竖屏`

- [ ] **Step 4: 提交文档改动**

```bash
git add docs/superpowers/specs/2026-08-27-mobile-portrait-design.md \
        docs/deployment-contract.md
git commit -m "$(cat <<'EOF'
docs: spec 同步实现期的三处偏差 + 契约记一句手机档位

1. 基准 400×640 → 432×640(= 16 边距 ×2 + 400 内容列,算术正好对上)
2. 分段切换用三个 toggle Button 而不是 TabContainer —— TabContainer 的
   页签高度由主题 StyleBox 内边距决定,做不到 44pt
3. §6「触控尺寸收进主题」不做:实测现有 custom_minimum_size 已经全是
   44–56 逻辑像素,基准一改就全部达标;Theme 没有 min-height 属性,
   要靠 StyleBox 内边距实现,等于重写一套外观,风险大于收益

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: 推送并等 CI 出镜像**

```bash
cd /Users/matthew/projects/meirongdev/godot-games
git push origin main
sleep 12
RUN=$(gh run list --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch $RUN --exit-status 2>&1 | tail -4
```

Expected: CI 绿,最后一行 notice 打印新的 short-sha。

- [ ] **Step 6: 验证 CI 发布出来的镜像**

把 `<sha>` 换成上一步的 short-sha:

```bash
cd /Users/matthew/projects/meirongdev/godot-games
SHA=<sha>
docker pull -q ghcr.io/meirongdev/godot-games-web:$SHA
CID=$(docker run -d -p 18080:8080 ghcr.io/meirongdev/godot-games-web:$SHA); sleep 3
curl -s -o /dev/null -w '  /healthz : %{http_code}\n' http://localhost:18080/healthz
rm -rf build/web && mkdir -p build/web
docker cp "$CID:/usr/share/nginx/html/." build/web/ >/dev/null 2>&1
rm -f build/web/*.gz build/web/50x.html
docker rm -f "$CID" >/dev/null
lsof -ti tcp:8080 | xargs -r kill -9 2>/dev/null; sleep 1
python3 tools/web_smoke.py 2>&1 | tail -12
```

Expected: `/healthz : 200`,冒烟两个档位都通过 —— 也就是**发布出去的制品本身**在手机竖屏下可玩。

- [ ] **Step 7: 收尾清理**

```bash
lsof -ti tcp:8080 | xargs -r kill -9 2>/dev/null
pkill -f serve_web.py 2>/dev/null; pkill -f "remote-debugging-port" 2>/dev/null
pkill -f "bot.py" 2>/dev/null
rm -f /tmp/bot.py
git status --short
```

Expected: 工作区干净(`build/` 在 `.gitignore` 里)。

---

## 完成标准

- [ ] `tools/web_smoke.py` 两个档位都绿,手机档位的逻辑视口 ≤ 480
- [ ] 手机竖屏真机比例下:登录、大厅、房间、猜拳四页都能操作,打完一整局
- [ ] `check_scenes.gd` `FAILURES: 0`
- [ ] Lua 82/82、`e2e_match.py` 局终 ✓、字体检查通过
- [ ] 桌面档位没退化
- [ ] CI 发布的镜像本身通过两档位冒烟
- [ ] spec 状态改成「已实施」,三处偏差已同步
