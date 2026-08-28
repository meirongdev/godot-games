# 本地测试

> 最近一轮完整执行记录:[test-reports/2026-08-26.md](test-reports/2026-08-26.md)

按速度分层。日常开发跑 1–3b(全自动,合计约 20 秒),动了玩法再跑 4,动了 UI 跑 5,
动了联机时序必跑 7b,发版前过一遍 6–7b。

## 前置

```bash
cd nakama && docker compose up -d     # 层 4 起需要;Nakama + Postgres
python3 -c "import websockets"        # 层 4 依赖;缺了就 python3 -m pip install websockets
```

> ⚠️ `websockets` 装在**当前 shell 解析到的那个 python3** 里。venv 切换后可能就没了,
> 报 `ModuleNotFoundError` 先查 `command -v python3`。

## 分层速查

| 层 | 命令 | 耗时 | 抓什么 |
|---|---|---|---|
| 1 Lua 单测 | `cd nakama && docker run --rm --platform linux/amd64 -v "$PWD:/work" -w /work imega/busted` | ~2s | 规则与房间逻辑(82 项;容器是 Lua 5.1,对齐 Nakama 的 GopherLua) |
| 2 GDScript 解析 | `godot --headless --editor --path godot --quit 2>&1 \| grep -icE "SCRIPT ERROR\|Parse Error"`(应为 0) | ~5s | 语法/类型错误 |
| 3 场景节点路径 | `godot --headless --path godot --script res://tests/check_scenes.gd` | ~3s | `.tscn` 节点名与 `.gd` 里 `$Path` 的错位(运行时才炸的那种) |
| 3b 字体覆盖 | `godot --headless --path godot --script res://tests/check_fonts.gd` | ~2s | 主题里的字体覆不覆盖 UI 用到的字。**Web 拿不到系统字体**,缺字就是豆腐块,而桌面版靠系统回退看不出来 |
| 4 端到端对局 | `python3 tools/e2e_match.py 3` · `python3 tools/e2e_match.py 5 4` · `python3 tools/e2e_edge.py` | ~15s | 真账号 + 真 WebSocket 打真 Nakama:完整对局、平局加速、走神代出、中途掉线、房间列表状态 |
| 5 场景截图 | 见下 | ~10s/景 | 布局灾难(缩成一团、区域被压成 0 高、控件隐形 —— 层 2/3 全都看不见) |
| 6 桌面多开真玩 | `godot --path godot -- --device-suffix=a &`(b、c 同理) | 人肉 | 客户端运行时逻辑与手感 |
| 7 Web 版(人肉) | `./tools/build_web.sh && python3 tools/serve_web.py` → `http://localhost:8080/?player=a` | ~1min | Web 特有问题(wasm、JS bridge、软键盘)+ **同源拓扑**:serve_web.py 把 `/v2/*` 和 `/ws` 反代到 Nakama,和线上路由一致(契约 §3.3.1) |
| 7b Web 冒烟(自动) | `python3 tools/web_smoke.py` | ~2min | 真 Chrome 里跑**桌面 + 手机竖屏**两档:登录 → 大厅 → **建房进房间**。断言 `[config]` / `[layout]` 逻辑视口 / `[lobby] 在线` / `[room]` 房名人数。**这是唯一会跑到 `ServerConnection` 联机时序的自动测试**(见坑 ⑧) |

层 4 还能打线上(部署验证,不改源码):

```bash
NAKAMA_HOST=<域名> NAKAMA_PORT=443 NAKAMA_TLS=1 NAKAMA_KEY=<server_key> \
  python3 tools/e2e_match.py 3
```

### 用「默认配置」的 Nakama 复现线上(见坑 ⑨)

`nakama/docker-compose.yml` 给的参数比线上宽松,会盖住一整类 bug。发版前至少
对一个**不带任何 session 参数**的 Nakama 跑一遍层 7b(在**仓库根目录**执行,
前提是 `cd nakama && docker compose up -d` 的本地栈在跑 —— 它复用同一个 Postgres):

```bash
docker run -d --name nak-default --network nakama_default -p 7360:7350 \
  -v "$PWD/nakama/modules:/nakama/data/modules" \
  --entrypoint /bin/sh registry.heroiclabs.com/heroiclabs/nakama:3.40.0 \
  -c '/nakama/nakama --database.address postgres:localdb@postgres:5432/nakama \
      --socket.server_key "family-lobby-2026" \
      --runtime.lua_min_count 1 --runtime.lua_max_count 4'

NAKAMA_PORT=7360 python3 tools/web_smoke.py     # serve_web.py 会把反代指过去
docker rm -f nak-default
```

## 改了什么 → 跑什么

| 改动 | 必跑 | 另加 |
|---|---|---|
| `nakama/modules/rules/*.lua` | 1 | 4 |
| `nakama/modules/`(适配层/RPC) | 1 + 4 | **先 `docker compose restart nakama`**(见坑 ②) |
| `godot/**.gd` | 2 + 3 | 6 |
| `godot/src/autoload/ServerConnection.gd`(或任何联机时序) | 2 + 3 + **7b** | 层 1–6 一条都覆盖不到这里,见坑 ⑧ |
| `godot/**.tscn` | 3 | 5(布局改动肉眼确认) |
| UI 文案加了新符号/emoji | 3b | 缺字就把它补进 `check_fonts.gd` 的 `MUST`,字体不够就跑 `tools/subset_fonts.sh` 重新生成 |
| `images/**` 或导出相关 | 7 | 部署契约验证:`docs/deployment-contract.md` §4 |
| `godot/export_presets.cfg` | 7 | 制品自检在 `tools/build_web.sh` 里,导出即跑 |

## 层 5:截图怎么拍

Godot 的 Movie Maker 模式能无窗口渲染帧:

```bash
godot --path godot --write-movie /tmp/shots/f.png --quit-after 10
```

文档用的「有内容」截图(对局中、满员大厅)由 `python3 tools/take_screenshots.py`
生成 —— 它用 `godot/tests/ShotHarness.gd` 给场景喂真实格式的服务端 payload。

产出 `/tmp/shots/f00000009.png`(取最后一帧)。默认拍主场景(Login);拍别的场景,
临时把 `godot/project.godot` 的 `run/main_scene` 指过去,拍完改回来。

## 九个坑

1. **层 2 的 `--editor` 不能省。** 没有它,Godot 在加载任何脚本**之前**就退出了——
   正确代码和语法错误代码输出逐字节相同,检查等于没做(故障注入验证过)。
2. **改 Lua 后必须 `docker compose restart nakama`。** compose 挂的是目录卷,
   但 Nakama 只在进程启动时加载模块——不重启就是「改了没生效」。
3. **busted 的 platform WARNING 是正常输出。** 镜像是 amd64,Apple Silicon 上走模拟,
   实测单次 ~2ms,不是错误。
4. **桌面多开必须 `--device-suffix`,Web 多标签必须 `?player=`。** 设备认证按机器 ID
   (桌面共享 `user://`,浏览器共享 IndexedDB),不带后缀全部登进同一个账号,
   被服务端当成同一个人重连,多人根本测不起来。
5. **层 3 的 `Identifier not found: ServerConnection` 是已知噪音。** `--script` 模式
   下 autoload 未挂载;节点路径解析不受影响,以 `FAILURES` 行和退出码为准。
6. **文档截图和桌面真玩都抓不到字体问题。** `tools/take_screenshots.py` 和层 6
   跑的都是桌面 Godot,有操作系统字体回退;**Web 导出没有**。整套中文字体缺失
   就这么活到了发版前(2026-08-27):截图全正常,网页上满屏豆腐块。两个字体子集
   的 `.import` 现在都关掉了 `allow_system_fallback`,让桌面复现 Web 的行为。
7. **grep 导出制品里的字符串,永远是假阴性。** `export_presets.cfg` 是
   `script_export_mode=2`(二进制 token + 压缩),GDScript 的字符串字面量不以明文
   存在 —— `grep 127.0.0.1` / `grep family-lobby-2026` 在 `.pck`/`.wasm`/`.js` 里
   都是 0 命中,**不论客户端是对是错**(2026-08-27 实测)。想验客户端连哪儿,
   只能把它跑起来看请求。可以 grep 的是 pck 的路径表(`res://…`)。
8. **层 1–6 完全覆盖不到客户端的联机时序。** 层 1 只跑服务端 Lua;层 4 用的是
   `tools/e2e_match.py` 里**自己写的 Python 客户端**,一行 `ServerConnection.gd`
   都不执行;层 2/3 只看语法和节点路径;层 5/6 是渲染和人肉。于是「进房那一刻
   服务端广播的 ROOM_STATE 被客户端丢掉」这种 bug 能穿过全部 7 层活到线上
   (2026-08-27:房间页停在写死的「房间」+ 空花名册,长得和「进房失败」一模
   一样)。层 7b 现在会一路点进房间并断言 `[room]`,**动了联机时序就必须跑它**。
9. **本地 compose 的参数比线上宽松,会盖住 bug。** `--session.token_expiry_sec 7200`
   是本地为了顺手加的,而 Nakama 的默认值是 **60 秒** —— 契约 §3.2 以前没要求
   部署侧设这个参数,于是线上就是默认值。后果:登录一分钟后所有 RPC 401,大厅
   房间列表变空、建不出房,而聊天和在线列表照常(那两个走 socket)。本地的
   7200 秒把它盖得严严实实:同一份客户端,打 compose 一切正常,打默认配置的
   Nakama 一分钟后就废。**发版前用上面那段「默认配置的 Nakama」跑一遍层 7b。**

## 这些层各自是怎么来的

每一层都对应一个真踩过的坑:层 2 的 `--editor` 来自一条从未生效过的假检查;层 3 来自
「节点路径错位只在运行时炸」;层 4 抓过 3 个单测全绿但跨端契约错位的 bug(Lua 空表
编码成 `{}`、`draw_streak` 发错消息);层 5 来自「布局全对但小成一团没法用」。
层 7b 的「一路点进房间」来自 2026-08-27 的两个线上 bug:客户端丢掉进房第一条
ROOM_STATE(全 7 层都看不见),以及 token 60 秒过期后大厅静默失效(只在**线上的
参数**下才出现)。
**单测全绿 ≠ 能用**,所以才要一层层叠 —— 而且测试环境的参数要和线上一致,
否则叠得再多也一样漏。
