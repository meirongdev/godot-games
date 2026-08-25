class_name OpCodes
extends RefCounted

## 与服务端手工同步。分段规则见 spec §8。
## 1-19 房间通用 / 20-39 石头剪刀布 / 40-59 成语接龙 / 60+ 预留

# --- 房间通用 ---
const READY        := 1    # C→S {ready: bool}
const START        := 2    # C→S {}          仅房主
const SETTINGS     := 3    # C→S {...}       仅房主
const ROOM_STATE   := 10   # S→C {phase, players[], host, settings}
const GAME_STARTED := 11   # S→C {game, settings}
const GAME_OVER    := 12   # S→C {results[]}
const ERROR        := 13   # S→C {msg}

# --- 石头剪刀布 ---
const THROW        := 20   # C→S {hand: 0|1|2}
const ROUND_BEGIN  := 30   # S→C {round, alive[], seconds, deadline_tick}
const ROUND_RESULT := 31   # S→C {hands{}, winner, draw, advanced[], eliminated[], afk[], draw_streak}

# 手势
const ROCK    := 0
const PAPER   := 1
const SCISSOR := 2
