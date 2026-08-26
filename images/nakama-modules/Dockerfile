# Nakama Lua 模块制品。只装文件,不跑服务 —— 部署侧用 initContainer
# 把 /modules 拷进 Nakama 的 <data_dir>/modules(默认 /nakama/data/modules)。
#
# 为什么用镜像而不是 ConfigMap(此前方案,已废弃):
#   1. 换版本 = 换 tag = pod template 变化 = Deployment 自动滚动。
#      Nakama 只在启动时加载 Lua,ConfigMap 更新后必须手工 rollout restart,
#      镜像方案把这个人肉步骤消灭掉了。
#   2. 没有 1MiB 上限 —— M4 的 1.12MB 成语索引可以直接进来,不用换机制。
#   3. 目录结构原样保留,不需要 ConfigMap 那套 key 拍平(games_rps.lua)
#      再用 items[].path 还原的 hack。
#
# 基底用 busybox 不用 scratch:initContainer 需要 `cp` 可执行。
FROM docker.io/library/busybox:1.37.0

COPY nakama/modules/ /modules/

# 构建期自检:核心文件必须在,免得构建上下文错了还推出去一个空镜像。
RUN test -f /modules/main.lua \
 && test -f /modules/room.lua \
 && test -f /modules/lobby_rpc.lua \
 && [ "$(find /modules/games /modules/rules -name '*.lua' | wc -l)" -ge 4 ] \
 || (echo "✗ 模块不完整,检查构建上下文是否为仓库根目录" && exit 1)
