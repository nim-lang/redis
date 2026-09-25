## Dynamic Redis value model for Lua scripting (eval), raw commands (rawCommand),
## and pipelined responses (flushPipelineValues).
import strutils

type
  RedisValueKind* = enum
    vkNil,
    vkStatus,
    vkInteger,
    vkString,
    vkList

  RedisValue* = object
    ## Algebraic data type representing a dynamic RESP value with scalar and composite variants.
    case kind*: RedisValueKind
    of vkNil: discard
    of vkStatus, vkString: strVal*: string
    of vkInteger: intVal*: BiggestInt
    of vkList: listVal*: seq[RedisValue]

proc `$`*(val: RedisValue): string =
  case val.kind
  of vkNil: result = "nil"
  of vkStatus, vkString: result = val.strVal
  of vkInteger: result = $val.intVal
  of vkList:
    result = "["
    for i, elem in val.listVal:
      if i > 0: result.add(", ")
      result.add($elem)
    result.add("]")

proc toInt*(val: RedisValue): BiggestInt =
  case val.kind
  of vkInteger: result = val.intVal
  of vkStatus, vkString: result = parseBiggestInt(val.strVal)
  of vkNil: result = 0.BiggestInt
  else: raise newException(ValueError, "Cannot convert Redis list to integer")

proc toStr*(val: RedisValue): string =
  case val.kind
  of vkStatus, vkString: result = val.strVal
  of vkInteger: result = $val.intVal
  of vkNil: result = ""
  else: result = $val

proc toSeq*(val: RedisValue): seq[RedisValue] =
  case val.kind
  of vkList: result = val.listVal
  of vkNil: result = @[]
  else: result = @[val]

proc len*(val: RedisValue): int =
  if val.kind == vkList: result = val.listVal.len
  elif val.kind == vkNil: result = 0
  else: result = 1

proc `[]`*(val: RedisValue, i: int): RedisValue =
  if val.kind == vkList: result = val.listVal[i]
  else: raise newException(IndexDefect, "RedisValue is not a list")

proc `==`*(a, b: RedisValue): bool =
  if a.kind != b.kind: return false
  case a.kind
  of vkNil: return true
  of vkStatus, vkString: return a.strVal == b.strVal
  of vkInteger: return a.intVal == b.intVal
  of vkList:
    if a.listVal.len != b.listVal.len: return false
    for i in 0 ..< a.listVal.len:
      if a.listVal[i] != b.listVal[i]: return false
    return true

proc `==`*(a: RedisValue, b: string): bool =
  case a.kind
  of vkStatus, vkString: result = (a.strVal == b)
  else: result = false

proc `==`*(a: string, b: RedisValue): bool = b == a

proc `==`*(a: RedisValue, b: BiggestInt): bool =
  case a.kind
  of vkInteger: result = (a.intVal == b)
  else: result = false

proc `==`*(a: BiggestInt, b: RedisValue): bool = b == a

proc `==`*(a: RedisValue, b: int): bool =
  case a.kind
  of vkInteger: result = (a.intVal == b.BiggestInt)
  else: result = false

proc `==`*(a: int, b: RedisValue): bool = b == a
