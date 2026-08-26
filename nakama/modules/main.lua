-- Nakama 启动时执行一次。所有 RPC 注册都放这里。
local nk    = require("nakama")
local lobby = require("lobby_rpc")

nk.register_rpc(lobby.create_room, "create_room")
nk.register_rpc(lobby.list_rooms,  "list_rooms")
nk.register_rpc(lobby.list_games,  "list_games")

nk.logger_info("family-lobby modules loaded")
