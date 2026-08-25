class_name JsonSafe
extends RefCounted
## 服务端 JSON 的防御性读取。
##
## Lua 分不清「空表」和「空数组」,`nk.json_encode({})` 产出的是 `{}` 而不是 `[]`。
## 于是服务端一个本该是数组的空字段,到客户端会解析成 Dictionary;直接赋给
## 静态 Array 类型的变量会抛:
##     Trying to assign value of type 'Dictionary' to a variable of type 'Array'
## 这个坑在本项目里已经踩过三次(list_rooms / list_games / ROUND_RESULT.afk),
## 所以统一收敛到这里。凡是从服务端读数组,一律走 arr()。


## 取出一个必定是 Array 的值。缺失、类型不对、或是 Lua 的空表 `{}`,都返回 []。
static func arr(source: Dictionary, key: String) -> Array:
	var value = source.get(key, [])
	return value if value is Array else []


## 同上,但用于取字典字段(Lua 空表在这里反而是对的)。
static func dict(source: Dictionary, key: String) -> Dictionary:
	var value = source.get(key, {})
	return value if value is Dictionary else {}
