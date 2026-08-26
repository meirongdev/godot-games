# 部署契约:本仓库 ↔ 部署仓库(homelab)

本文档定义两个仓库之间的**全部**交互面。原则:

> **本仓库交付版本化的 OCI 镜像和这份契约;部署仓库拥有一切环境事实。**
> 镜像之外不允许任何东西跨仓库 —— 不共享 YAML 片段,不互相引用文件路径。

最后核对:2026-08-27。

---

## 1. 职责切分

| 关注点 | godot-games(本仓库) | homelab(部署仓库) |
|---|---|---|
| 游戏源码 / Lua 规则 / 测试 | ✅ | — |
| 制品构建与发布(CI → ghcr) | ✅ | — |
| 制品的运行时要求(本文档) | ✅ 声明 | 按声明落实 |
| **部署哪个版本**(tag 钉选) | — | ✅ 换 tag 即发版 |
| K8s 清单(Deployment/Service/Route/…) | — | ✅ |
| 命名空间 / 域名 / 网关 / DNS / TLS | — | ✅ |
| server key | ✅ 值定在 `NakamaConfig.SERVER_KEY`(它跟着 web 制品公开发布,见 §3.4) | 按这个值配 `--socket.server_key` |
| 资源限额 / 安全上下文 / 集群策略合规 | — | ✅ |
| Nakama 服务器实例(版本、运维、备份、监控) | 声明兼容要求 | ✅ 拥有实例 |
| 本地开发环境(docker-compose / serve_web.py) | ✅ | — |

判别法:**跟着游戏一起变的进本仓库;跟着基础设施一起变的进 homelab。**

### 历史包袱说明

本仓库曾经内置过 `k8s/` 清单目录和 ConfigMap 生成器(2026-08-26 前),它们把
homelab 的 namespace、gateway 名、域名硬编码进了游戏仓库,且靠「拷贝片段到对面
仓库」集成。已整体废弃,由下述镜像契约取代。不要恢复那套东西。

---

## 2. 制品

两个镜像,都由 CI 在 push 到 main 时自动构建推送,tag 规则相同:
`:latest`(仅供手工 `docker pull`)+ `:<git short-sha>`(**部署用这个**)。

### 2.1 `ghcr.io/meirongdev/godot-games-nakama-modules`

| | |
|---|---|
| 内容 | `/modules/**.lua` —— Nakama 服务端模块,目录结构与 `nakama/modules/` 一致 |
| 基底 | busybox(**刻意的**:消费方式需要容器里有 `cp`) |
| 体积 | ~4 MB |
| 构建 | `.github/workflows/nakama-modules-image.yml`,**推送前先跑全部 busted 单测** |
| 触发 | `nakama/modules/**` 或 `images/nakama-modules/**` 变化 |

### 2.2 `ghcr.io/meirongdev/godot-games-web`

| | |
|---|---|
| 内容 | Godot Web 导出 + nginx(unprivileged),含预压 gzip(wasm 39.5MB → 10.1MB) |
| 构建 | `.github/workflows/web-image.yml`,CI 内下载 Godot 4.7.2 + 导出模板,然后**调 `tools/build_web.sh`**(和本地同一条导出路径) |
| 门禁 | 场景节点路径检查 + 制品自检(不含测试脚手架、不含任何环境地址)。不过就不推 |
| 触发 | `godot/**`、`images/web/**`、`tools/build_web.sh` 变化 |

### 2.3 两个镜像都必须匿名可拉

ghcr 的包**默认是 private**,而部署侧没有 imagePullSecret,只能匿名拉。
两个 workflow 在推完之后都会用匿名 token 取一次 manifest,不是 200 就让
构建失败,并在日志里给出改可见性的 URL。

> 2026-08-26 就是漏在这里:两个包都成功推上去了,但都是 private,
> 集群 403,homelab 卡住。首次发布仍然需要人去 ghcr 的 package settings
> 里点一次 Public —— 现在漏了会红,不会静默。

---

## 3. 集成契约

### 3.1 模块镜像的消费方式

模块镜像不跑服务,由 Nakama Deployment 的 initContainer 把文件拷进
`<data_dir>/modules`(Nakama 默认 `data_dir=/nakama/data`)。通用模式,
不含任何环境信息:

```yaml
initContainers:
  - name: copy-game-modules
    image: ghcr.io/meirongdev/godot-games-nakama-modules:<short-sha>
    command: ["sh", "-c", "cp -r /modules/. /nakama-modules/"]
    volumeMounts:
      - { name: game-modules, mountPath: /nakama-modules }
containers:
  - name: nakama
    volumeMounts:
      - { name: game-modules, mountPath: /nakama/data/modules, readOnly: true }
volumes:
  - { name: game-modules, emptyDir: {} }
```

**为什么是镜像 + initContainer,而不是 ConfigMap(旧方案):**

1. **换 tag 就是完整发版。** pod template 变化 → Deployment 自动滚动。Nakama 只在
   进程启动时加载 Lua,旧方案 ConfigMap 更新后必须人肉 `rollout restart`,这个
   步骤忘了就是「改了没生效」,现在不存在了。
2. **没有 1MiB 上限。** M4 成语接龙的 1.12MB 词库索引直接进镜像,机制不用换。
3. **目录结构原样保留。** ConfigMap 的 key 不能含 `/`,旧方案要把 `games/rps.lua`
   拍平成 key 再用 `items[].path` 还原,加一个文件要同步两处。

### 3.2 Nakama 运行时要求

| 要求 | 值 | 为什么 |
|---|---|---|
| Nakama 版本 | 3.40.x(3.x 大概率兼容,只在 3.40.0 上验证过) | 模块用的都是稳定 Lua API |
| `runtime.lua_min_count` / `lua_max_count` | 建议 **1 / 4** | 每个 Lua VM 都加载全部模块。现在 17KB 无所谓;M4 的 1.12MB 词库 × 默认 48 VM ≈ 400MB,会顶穿常见的内存限额。⚠️ 两个必须**成对**给:`min` 默认 16,Nakama 校验 `min <= max`,只调 max 直接启动失败 |
| 客户端端口 | Service 上 7350(HTTP API + WebSocket 同端口);7349 gRPC 不需要 | ⚠️ 浏览器**不直连**这个端口 —— 走 §3.3.1 的同源路由。7350 也不在 Cloudflare 的可代理端口白名单里,直连在这套基础设施上连不通 |
| CORS | 无需配置 | 走 §3.3.1 的同源路由后本来就不跨源。(Nakama 3.40.0 对 `/v2/*` 和 WS 升级也自带 `Access-Control-Allow-Origin: *`,实测) |
| 模块加载验证 | 启动日志见 §4.2 | 少挂 = 游戏完全不可用,不是降级 |

### 3.3 web 镜像的运行要求

| | 值 |
|---|---|
| 监听 | **8080**(unprivileged nginx,不是 80) |
| 健康检查 | `GET /healthz` → 200(readiness/liveness 都可用) |
| 进程身份 | uid/gid 101,兼容 `runAsNonRoot: true` + `runAsUser: 101`;`readOnlyRootFilesystem` 需为 false(nginx 写 /tmp) |
| 状态 | 无。全部游戏状态在 Nakama;这个 pod 挂了只是页面打不开,不影响进行中的对局 |
| 资源 | 静态文件服务,10m/32Mi 请求级别就够 |
| 架构 | linux/amd64 + linux/arm64 |

#### 3.3.1 必须的路由:Nakama 挂在同一个域名下

**这不是可选项,不加游戏就打不开。** Web 客户端从页面自身的地址推导 Nakama
地址(`godot/src/autoload/NakamaConfig.gd`),所以部署侧必须在 web 服务那个
域名上加两条路由:

| 路径 | 去处 | 备注 |
|---|---|---|
| `/v2/*` | Nakama Service `:7350` | HTTP API(设备认证、RPC) |
| `/ws` | Nakama Service `:7350` | WebSocket,**必须允许 Upgrade**,读超时要够长 |
| 其余全部 | web 镜像 `:8080` | 静态站点 |

路径来自 Nakama SDK 本身,不是我们选的:`NakamaAPI.gd` 的 `urlpath` 全是
`/v2/…`,socket 是 `NakamaSocket.gd:318` 的 `/ws?…`。

**为什么是同源,而不是让客户端直连 nakama 域名:**

1. **镜像里零环境事实。** 不需要 ConfigMap、不需要环境变量、换环境不需要重新
   构建 —— 契约「本仓库交付镜像,部署仓库拥有环境」的原则原样成立。
2. **两个死结一起消掉。** 页面走 https 时直连 http 的 Nakama 会被浏览器按混合
   内容拦掉;而 7350 不在 Cloudflare 可代理端口白名单里,直连那个端口在这套
   基础设施上连不通。同源之后两个都不存在。
3. **不跨源就不依赖 CORS。**

本地 `tools/serve_web.py` 复现同一套路由(把 `/v2/*` 和 `/ws` 反代到
`127.0.0.1:7350`),所以本地测的拓扑和线上一致。这一点是刻意的:上一版本地
只发静态文件、线上却要跨源,才让「客户端连不上」一路飘到集群里才被发现。

### 3.4 客户端行为(运维需要知道的)

- **`?player=<任意串>`**:浏览器所有标签共享 IndexedDB,设备 ID 会撞成同一个账号。
  多人同机(或一人多标签)必须带不同的 `player` 值。
- **服务器地址不可配置,也不需要配置。** 一律等于页面自身的来源(§3.3.1)。
  `?host=` / `?port=` / `?scheme=` 只是联调临时覆盖,**不是部署手段**。
- **推导不出来时客户端直接停下**:登录页显示原因、按钮置灰,不会退回
  localhost 偷偷连一个错地址。
- **server key 打进制品,是公开的。** 值:`family-lobby-2026`
  (`godot/src/autoload/NakamaConfig.gd` 的 `SERVER_KEY`),部署侧
  `--socket.server_key` 必须一致,也与 `nakama/docker-compose.yml` 的本地值一致。
  按 §5 它不是机密,不为它设计藏法;防滥用靠 `create_room` 限流。
- **wss 跟着页面协议**:页面 https → 客户端 https + wss;http → http + ws。

> **两处旧说法已作废,别再照着做:**
> ① 「server key 打进 `godot/nakama.cfg`」—— 对 web 制品从来不成立:`.cfg`
> 是非资源文件,`export_filter="all_resources"` 不收它,那份配置进不了导出包。
> ② 「页面走 https 时自动用 wss」—— 旧实现看的是配置里的 `scheme`
> (`Nakama.gd:61-65`),而配置进不了制品,于是恒为 `ws://`。现在按页面协议推。

---

## 4. 验证

### 4.1 本地验证契约本身(不需要集群)

```bash
# 构建模块镜像 → 模拟 initContainer 拷贝 → 真实 Nakama 挂载启动
docker build -f images/nakama-modules/Dockerfile -t gg-mods:test .
docker volume create ggmods
docker run --rm -v ggmods:/nm gg-mods:test sh -c 'cp -r /modules/. /nm/'
docker run -d --name nak-test --network nakama_default \
  -v ggmods:/nakama/data/modules --entrypoint /bin/sh \
  registry.heroiclabs.com/heroiclabs/nakama:3.40.0 \
  -c '/nakama/nakama --database.address postgres:localdb@postgres:5432/nakama'
sleep 6 && docker logs nak-test 2>&1 | grep "Found runtime modules"
docker rm -f nak-test && docker volume rm ggmods
```

(前提:`cd nakama && docker compose up -d` 的本地栈在跑。2026-08-26 实测通过。)

### 4.2 部署后验证(homelab 侧执行)

启动日志必须出现,**缺任何一条都是部署失败**:

```
"Found runtime modules","count":8,"modules":["games/init.lua","games/rps.lua",
  "lobby_rpc.lua","main.lua","room.lua","rules/rate_limit.lua",
  "rules/room_rules.lua","rules/rps_rules.lua"]
"Registered Lua runtime RPC function invocation","id":"create_room"
"Registered Lua runtime RPC function invocation","id":"list_rooms"
"Registered Lua runtime RPC function invocation","id":"list_games"
```

然后从任意机器对线上打一整局(工具在本仓库,环境变量指向部署):

```bash
NAKAMA_HOST=<nakama 域名> NAKAMA_PORT=443 NAKAMA_TLS=1 NAKAMA_KEY=<server_key> \
  python3 tools/e2e_match.py 3        # 三人打满一局
NAKAMA_HOST=... NAKAMA_TLS=1 NAKAMA_KEY=... \
  python3 tools/e2e_edge.py           # 走神代出 / 中途掉线 / 房间列表状态
```

### 4.3 web 镜像验证

```bash
docker run -d -p 18080:8080 ghcr.io/meirongdev/godot-games-web:<sha>
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:18080/healthz          # 200
curl -sI http://localhost:18080/index.wasm | grep -i content-type               # application/wasm
curl -sI -H "Accept-Encoding: gzip" http://localhost:18080/index.wasm \
  | grep -i content-length                                                       # ~10MB,不是 39.5MB

# 制品里不该有环境地址,也不该有测试脚手架(CI 的 build_web.sh 已断言这两条)
docker cp <container>:/usr/share/nginx/html/index.pck /tmp/index.pck
strings -a /tmp/index.pck | grep -c 'nakama.cfg'    # 0
strings -a /tmp/index.pck | grep -c 'res://tests/'  # 0
```

⚠️ **不要靠 grep 制品里的 IP / server key 来判断客户端行为。** 导出用的是
`script_export_mode=2`(二进制 token + 压缩),GDScript 的字符串字面量不以
明文存在制品里 —— `grep 127.0.0.1` 和 `grep family-lobby-2026` 在
`.pck` / `.wasm` / `.js` 里**都是 0 命中,不论客户端是对是错**(2026-08-27 实测)。
拿它当"客户端没问题"的证据会得到假阴性。

真要验客户端连得上,唯一可靠的办法是把它跑起来看请求打到了哪儿:

```bash
# 本地等价验证:serve_web.py 复现线上的同源路由
./tools/build_web.sh && python3 tools/serve_web.py 8099 &
curl -s -X POST 'http://127.0.0.1:8099/v2/account/authenticate/device?create=true' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Basic $(printf 'family-lobby-2026:' | base64)" \
  -d '{"id":"11111111-1111-4111-8111-111111111111"}'      # 应返回 token
```

线上则是开页面,看浏览器 network 面板里
`/v2/account/authenticate/device` 和 `/ws` 的状态码。

---

## 5. 安全须知

**`create_room` 是开放 RPC。** 设备认证谁都能注册,而 server key 跟着 web 制品
公开发布 —— 所以「拿到 key 的人」就是「任何人」。**不要试图靠部署侧藏 server key
解决,藏不住。**

已有的防线(本仓库,`nakama/modules/lobby_rpc.lua`):

- **建房限流**:每个 `user_id` 每 60 秒最多 5 次,超了返回
  `{"error":"rate_limited","retry_after":<秒>}`。纯函数在
  `nakama/modules/rules/rate_limit.lua`,单测覆盖。
  ⚠️ 状态在 Lua VM 内存里,每 VM 一份 —— 按 §3.2 的 `lua_max_count=4`,
  最坏实际上限是 4×。家庭规模够用;要精确得挪到 `nk.storage`。

还没做、需要时的方向:校验 group 成员资格(只让家庭 group 的人建房)。

---

## 6. 部署侧现状速记(信息指针,非契约)

> 这一节是唯一提及 homelab 内部结构的地方,只是省你查找时间,随时可能过时,
> **以 homelab 仓库为准**。

- Nakama 已部署:`k8s/helm/manifests/personal-services/nakama.yaml`,
  `nakama.meirong.dev`;**尚未挂模块**(§3.1 的 initContainer 就是要加的东西),
  `runtime.lua_*_count` 也未设(§3.2)。
- server key 在 Vault `homelab/nakama` 的 `socket_server_key` —— 需要**改成
  `family-lobby-2026`**(§3.4:它跟着 web 制品公开发布,随机值只是安慰剂)。
- web 服务是全新服务,homelab 有 `add-service` skill 走标准流程
  (manifest → HTTPRoute → homepage → Uptime Kuma);§3.3 的表是它的输入,
  **§3.3.1 那两条路由是硬要求** —— 少了页面能打开但进不去游戏。
- 集群 Kyverno 禁 `:latest`(Enforce)且限制镜像仓库白名单 —— ghcr.io 已在白名单,
  用 `:<short-sha>` tag 天然合规。

---

## 7. M4(成语接龙)预告

词库索引 1.12MB **直接进模块镜像即可**,机制不变 —— 这正是放弃 ConfigMap 的原因
之一。唯一前置:部署侧必须已按 §3.2 设了 `lua_max_count`,否则 48 个 VM 各加载
一份词库会 OOM。
