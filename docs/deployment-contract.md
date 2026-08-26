# 部署契约:本仓库 ↔ 部署仓库(homelab)

本文档定义两个仓库之间的**全部**交互面。原则:

> **本仓库交付版本化的 OCI 镜像和这份契约;部署仓库拥有一切环境事实。**
> 镜像之外不允许任何东西跨仓库 —— 不共享 YAML 片段,不互相引用文件路径。

最后核对:2026-08-26。

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
| 密钥(server key 等) | — | ✅(客户端配置消费它,不存它) |
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
| 构建 | `.github/workflows/web-image.yml`,CI 内下载 Godot 4.7.2 + 导出模板后现场导出 |
| 触发 | `godot/**`、`images/web/**`、`tools/build_web.sh` 变化 |

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
| 客户端端口 | 7350(HTTP API + WebSocket 同端口) | 客户端 SDK 只用这个;7349 gRPC 不需要 |
| CORS | 无需配置 | Nakama 对 `/v2/*` 和 WS 升级自带 `Access-Control-Allow-Origin: *`(3.40.0 实测),web 客户端跨源直连没问题 |
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

### 3.4 客户端行为(运维需要知道的)

- **`?player=<任意串>`**:浏览器所有标签共享 IndexedDB,设备 ID 会撞成同一个账号。
  多人同机(或一人多标签)必须带不同的 `player` 值。
- **`?host=<域名>`**:覆盖内置的 Nakama 地址,临时指向别的实例。
- **server key**:打进客户端配置(`godot/nakama.cfg`,gitignored)。它防的是端口
  扫描,不防逆向 —— 别当机密对待,但也别用默认值。
- 页面走 https 时客户端自动用 wss,无需单独配置。

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
"Found runtime modules","count":7,"modules":["games/init.lua","games/rps.lua",
  "lobby_rpc.lua","main.lua","room.lua","rules/room_rules.lua","rules/rps_rules.lua"]
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
```

---

## 5. 安全须知

**`create_room` 是开放 RPC。** 任何拿到 server key 的人(设备认证谁都能注册)都能
在部署的 Nakama 上创建 match。家庭规模可接受;要收紧的话,方向是在
`nakama/modules/lobby_rpc.lua` 里加限制(按 user_id 限流、校验 group 成员资格),
**属于本仓库的改动** —— 不要试图靠部署侧藏 server key 解决,藏不住。

---

## 6. 部署侧现状速记(信息指针,非契约)

> 这一节是唯一提及 homelab 内部结构的地方,只是省你查找时间,随时可能过时,
> **以 homelab 仓库为准**。

- Nakama 已部署:`k8s/helm/manifests/personal-services/nakama.yaml`,
  `nakama.meirong.dev`;**尚未挂模块**(§3.1 的 initContainer 就是要加的东西),
  `runtime.lua_*_count` 也未设(§3.2)。
- server key 在 Vault `homelab/nakama` 的 `socket_server_key`。
- web 服务是全新服务,homelab 有 `add-service` skill 走标准流程
  (manifest → HTTPRoute → homepage → Uptime Kuma);§3.3 的表就是给它的输入。
- 集群 Kyverno 禁 `:latest`(Enforce)且限制镜像仓库白名单 —— ghcr.io 已在白名单,
  用 `:<short-sha>` tag 天然合规。

---

## 7. M4(成语接龙)预告

词库索引 1.12MB **直接进模块镜像即可**,机制不变 —— 这正是放弃 ConfigMap 的原因
之一。唯一前置:部署侧必须已按 §3.2 设了 `lua_max_count`,否则 48 个 VM 各加载
一份词库会 OOM。
