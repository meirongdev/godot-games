# 部署到 homelab k3s 并接入现有 Nakama

本文档说明如何把这个仓库部署到 `~/projects/homelab` 管理的 k3s 集群。
**本仓库只提供部署文件和说明,不直接修改 homelab 仓库** —— 需要在那边改的地方,
下面都给了确切的文件路径和代码片段。

对照时间:2026-08-26,针对 homelab 仓库当时的状态核对过。

---

## 0. 现状与缺口

集群里**已经有** Nakama:

| | |
|---|---|
| 清单 | `k8s/helm/manifests/personal-services/nakama.yaml` |
| 版本 | `docker.io/heroiclabs/nakama:3.40.0`(按 digest 钉死) |
| 客户端 API | `https://nakama.meirong.dev`(→ Service `nakama:7350`) |
| 管理控制台 | `https://nakama-console.meirong.dev` |
| 数据库 | 共享实例 `apps-pg.databases.svc` 的 `nakama` 库,**无 PVC** |
| 配置 | Vault `homelab/nakama` → ESO 渲染成整份 `config.yml`,挂成 Secret |

**缺口:那个 Nakama 没有挂任何模块目录。**

`config.yml` 里 `data_dir: "/nakama/data"`,但 Deployment 只在 `/etc/nakama` 挂了 config,
`/nakama/data/modules` 是空的。Nakama 从 `<data_dir>/modules` 递归加载 `.lua`,
没有模块就没有 `room` match handler、没有 `create_room` RPC —— **游戏完全跑不起来**。

所以部署 = 三件事:

1. 把本仓库的 Lua 模块送进那个 Nakama(§1)
2. 客户端指向 `nakama.meirong.dev` 并用对 server key(§2)
3. Web 版自托管(§3)

---

## 1. Lua 模块 → ConfigMap

### 1.1 为什么是 ConfigMap

模块合计 **17 KB**,远低于 ConfigMap 约 1 MiB 的上限。GitOps 原生,不需要额外镜像或 PVC。

> ⚠️ **这条路在 M4 会走到头。** 成语接龙的词库索引是 1.12 MB,超过 ConfigMap 上限。
> 到时候要么改成自建 Nakama 镜像把词库打进去,要么挂 PVC。现在不用管,但别忘了。

### 1.2 生成

```bash
cd ~/projects/meirongdev/godot-games
python3 tools/build_k8s_modules.py
```

产出 `k8s/nakama-modules-configmap.yaml` 和 `k8s/_volume-items.snippet`。

**不要手改生成物。** ConfigMap 的 key 不能含 `/`,所以 `games/rps.lua` 被拍平成
key `games_rps.lua`,再由 volume 的 `items[].path` 还原成子目录。这意味着加一个
Lua 文件要同时改 ConfigMap 和 volume items 两处 —— 脚本同时生成两边,免得漏。

### 1.3 装进 homelab

**a)** 把 `k8s/nakama-modules-configmap.yaml` 复制到
`homelab/k8s/helm/manifests/personal-services/nakama-modules.yaml`

**b)** 改 `homelab/k8s/helm/manifests/personal-services/nakama.yaml`,
在 `containers[0].volumeMounts` 里加:

```yaml
            - name: modules
              mountPath: /nakama/data/modules
              readOnly: true
```

**c)** 在同文件的 `volumes:` 下加(内容来自 `k8s/_volume-items.snippet`):

```yaml
        - name: modules
          configMap:
            name: nakama-modules
            items:
              - key: games_init.lua
                path: games/init.lua
              - key: games_rps.lua
                path: games/rps.lua
              - key: lobby_rpc.lua
                path: lobby_rpc.lua
              - key: main.lua
                path: main.lua
              - key: room.lua
                path: room.lua
              - key: rules_room_rules.lua
                path: rules/room_rules.lua
              - key: rules_rps_rules.lua
                path: rules/rps_rules.lua
```

**d)** 在 ExternalSecret 的 `config.yml` 模板里,`runtime:` 段补两行:

```yaml
          runtime:
            http_key: "{{ .runtime_http_key }}"
            # ☠️ Nakama 默认最多起 48 个 Lua VM,每个都会加载全部模块。
            #    现在模块只有 17 KB,48 份也无所谓;但 M4 的 1.12 MB 词库
            #    × 48 ≈ 400 MB,而这个 Deployment 的 limit 是 512Mi —— 会 OOM。
            #    家用规模 4 个 VM 绰绰有余。
            #    ⚠️ 两个都要给:lua_min_count 默认是 16,而 Nakama 校验 min <= max,
            #       只调 max 会让容器启动失败退出。
            lua_min_count: 1
            lua_max_count: 4
```

**e)** 推到 main。ArgoCD 3 分钟内自动同步。

### 1.4 模块改了之后必须重启

Deployment 挂的是 ConfigMap 卷,而 Nakama 只在**进程启动时**加载一次 Lua。
ConfigMap 更新后 pod 不会自己重启:

```bash
kubectl rollout restart deployment/nakama -n personal-services
```

ConfigMap 里有个 `godot-games/modules-sha` 注解记录内容指纹,可以用它判断是否需要重启。

### 1.5 验证

```bash
kubectl logs -n personal-services deploy/nakama | grep -E "Found runtime modules|Registered Lua runtime RPC"
```

应该看到七个模块和三个 RPC:

```
"msg":"Found runtime modules","count":7,"modules":["games/init.lua","games/rps.lua",
  "lobby_rpc.lua","main.lua","room.lua","rules/room_rules.lua","rules/rps_rules.lua"]
"msg":"Registered Lua runtime RPC function invocation","id":"create_room"
"msg":"Registered Lua runtime RPC function invocation","id":"list_rooms"
"msg":"Registered Lua runtime RPC function invocation","id":"list_games"
```

**看不到就是没挂上。** 另外确认没有 Lua 报错 —— match handler 少任何一个必需回调
(`match_init` / `match_join_attempt` / `match_join` / `match_leave` / `match_loop` /
`match_terminate` / `match_signal`),Nakama 会在启动时报错。

---

## 2. 客户端接入

### 2.1 取 server key

集群的 server key 在 Vault,**不是**本地开发用的 `family-lobby-2026`:

```bash
vault kv get -field=socket_server_key secret/homelab/nakama
```

> server key 本来就会被打进客户端二进制,不算真正的机密 —— 它的作用是防止随手扫端口,
> 不是防逆向。但它在你的 Vault 里,所以按 Vault 的规矩取。

### 2.2 本地客户端连生产 Nakama

改 `godot/nakama.cfg`(已在 `.gitignore`,不会进仓库):

```ini
[nakama]
host="nakama.meirong.dev"
port=443
scheme="https"
server_key="<上一步取到的值>"
```

`scheme="https"` 会让客户端自动把 socket 升级成 `wss://` —— `ServerConnection` 用的是
`Nakama.create_socket_from(client)`,scheme 是从 client 推导的,不用单独配。

验证连通(不用开 Godot):

```bash
curl -s -X POST "https://nakama.meirong.dev/v2/account/authenticate/device?create=true" \
  -H "Content-Type: application/json" -u "<server_key>:" \
  -d '{"id":"0123456789abcdef0123456789abcdef"}' | head -c 80
```

返回 `{"token":"eyJ...` 就通了。`401` 是 server key 不对。

### 2.3 端到端跑一局

`tools/e2e_match.py` 和 `tools/e2e_edge.py` 里的 `HOST/PORT/KEY` 是写死本地的,
改掉就能对生产跑:

```python
HOST, PORT, KEY = "nakama.meirong.dev", 443, "<server_key>"
```

还要把 `ws://` 改成 `wss://`、`http://` 改成 `https://`。

---

## 3. Web 版自托管

### 3.1 为什么要自建镜像

导出产物 38 MB(`index.wasm` 单文件 37.7 MB),比 ConfigMap 上限大 38 倍,只能走镜像。

集群的 Kyverno `restrict-image-registries` 白名单**已经包含 `ghcr.io/*`**,不需要改策略。

### 3.2 构建

`.github/workflows/web-image.yml` 会在 `godot/**` 或 `k8s/web/**` 变化时自动构建:
下 Godot 4.7.2 + 导出模板 → 导出 Web → 构建多架构镜像 → 推 ghcr。

首次构建后把 ghcr 包 `meirongdev/godot-games-web` 的可见性设为 **Public**
(Packages → godot-games-web → Package settings → Change visibility),
否则集群拉取要 imagePullSecret。

### 3.3 装进 homelab

**a)** 复制这两个文件:

| 本仓库 | homelab |
|---|---|
| `k8s/web/deployment.yaml` | `k8s/helm/manifests/personal-services/family-lobby-web.yaml` |
| `k8s/web/route-family-lobby.yaml` | `k8s/helm/manifests/gateway/route-family-lobby.yaml` |

**b)** 把 `deployment.yaml` 里的 `REPLACE_WITH_SHORT_SHA` 换成 CI 输出的 short sha。

> ☠️ **不能用 `:latest`。** 集群的 Kyverno `disallow-latest-tag` 是
> `failureAction: Enforce`,带 `:latest` 的 Pod 会被**直接拒绝创建**。
> CI 推的 `:latest` 只供手工 `docker pull`。

**c)** 按 homelab 的 `add-service` skill 补两样(本仓库不含):
- homepage 条目(`cloud/oracle/manifests/homepage/homepage.yaml`)
- Uptime Kuma 监控(`cloud/oracle/manifests/uptime-kuma/provisioner.yaml`)

**d)** 推到 main。DNS 不用管 —— HTTPRoute 存在即 DNS 变更,external-dns 会建 CNAME。

### 3.4 玩

```
https://games.meirong.dev/?player=a
https://games.meirong.dev/?player=b
```

**`?player=` 不能省。** 浏览器所有标签共享 IndexedDB,设备 ID 会撞成同一个,
不带后缀的话多个标签会登进同一个 Nakama 账号,被服务端当成同一个人重连。

`?host=` 也支持,用来临时指向别的 Nakama 实例。

---

## 4. 安全上的取舍

部署前值得知道的:

**`create_room` 是开放 RPC。** 任何拿到 server key 的人(设备认证谁都能注册)
都能在 `nakama.meirong.dev` 上建 match。家庭规模无所谓,但这是新增的公网攻击面。
要收紧的话方向是在 `lobby_rpc.create_room` 里加限制(比如按 user_id 限流、
或校验用户属于某个 group),而不是靠藏 server key。

**Nakama 控制台已经是公网可达的管理面**,只有用户名/口令、没接 ZITADEL。
homelab 仓库把这条记为**有意接受**的残余风险(2026-08-25)。本次部署没有改变这一点,
但游戏上线后控制台里能看到的东西变多了(账号、房间、存储)。

---

## 5. 部署顺序

```
1. python3 tools/build_k8s_modules.py          生成 ConfigMap
2. 复制 ConfigMap + 改 nakama.yaml + 补 lua_min/max_count   → homelab
3. push → ArgoCD 同步 → rollout restart nakama
4. kubectl logs 确认七个模块 + 三个 RPC          ← 这一步过了,服务端就好了
5. 从 Vault 取 server key,配 godot/nakama.cfg
6. 本地 Godot 连生产,打一局验证                  ← 不需要 Web 托管就能玩
7. 跑 CI 构建 Web 镜像,设 ghcr 包为 Public
8. 复制 deployment + route,换 sha,push          → ArgoCD 同步
9. 开 https://games.meirong.dev/?player=a
```

**第 4 步和第 6 步之间可以停很久。** 服务端通了之后,家里人装个 Godot 就能玩,
Web 托管纯粹是为了「发个链接就能开」的便利,不是必需品。

---

## 6. 已知会在 M4 撞墙的两处

做成语接龙时这两条会同时爆:

| | 问题 | 出路 |
|---|---|---|
| ConfigMap 上限 | 词库索引 1.12 MB > 1 MiB | 自建 Nakama 镜像把词库打进去,或挂 PVC |
| Lua VM 内存 | 1.12 MB × VM 数,默认 48 个 ≈ 400 MB,limit 是 512Mi | §1.3(d) 的 `lua_max_count: 4` 已经预防了 |

第二条本次已经解决,第一条留到 M4。
