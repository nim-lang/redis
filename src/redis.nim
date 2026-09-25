#
#
#            Nim's Runtime Library
#        (c) Copyright 2019 Dominik Picheta
#               and contributors
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## This module implements a redis client. It allows you to connect to a
## redis-server instance, send commands and receive replies.
##
## **Beware**: Most (if not all) functions that return a ``RedisString`` may
## return ``redisNil``.
##
## Example
## --------
##
## .. code-block::nim
##    import redis, asyncdispatch
##
##    proc main() {.async.} =
##      ## Open a connection to Redis running on localhost on the default port (6379)
##      let redisClient = await openAsync()
##
##      ## Set the key `nim_redis:test` to the value `Hello, World`
##      await redisClient.setk("nim_redis:test", "Hello, World")
##
##      ## Get the value of the key `nim_redis:test`
##      let value = await redisClient.get("nim_redis:test")
##
##      assert(value == "Hello, World")
##
##    waitFor main()

import std/net, asyncdispatch, asyncnet, os, strutils, parseutils, deques, options
import ./redis/values
export values

const
  redisNil* = "\0\0"

type
  Pipeline = ref object
    enabled: bool
    buffer: string
    expected: int ## number of replies expected if pipelined

  RedisBase[TSocket] = ref object of RootObj
    socket: TSocket
    connected: bool
    pipeline: Pipeline

  Redis* = ref object of RedisBase[net.Socket]
    ## A synchronous redis client.

  AsyncRedis* = ref object of RedisBase[asyncnet.AsyncSocket]
    ## An asynchronous redis client.
    currentCommand: Option[string]
    sendQueue: Deque[Future[void]]

  RedisStatus* = string
  RedisInteger* = BiggestInt
  RedisString* = string
    ## Bulk reply
  RedisList* = seq[RedisString]
    ## Multi-bulk reply
  RedisMessage* = object
    ## Pub/Sub
    channel*: string
    message*: string
  ReplyError* = object of IOError ## Invalid reply from redis
  RedisError* = object of IOError ## Error in redis

  RedisCursor* = ref object
    position*: BiggestInt

proc newPipeline(): Pipeline =
  new(result)
  result.buffer = ""
  result.enabled = false
  result.expected = 0

proc newCursor*(pos: BiggestInt = 0): RedisCursor =
  result = RedisCursor(
    position: pos
  )

proc `$`*(cursor: RedisCursor): string =
  result = $cursor.position

proc open*(host = "localhost", port = 6379.Port): Redis =
  ## Open a synchronous connection to a redis server.
  result = Redis(
    socket: newSocket(buffered = true),
    pipeline: newPipeline()
  )

  result.socket.connect(host, port)

proc openUnix*(path = "/var/run/redis/redis.sock"): Redis =
  ## Open a synchronous unix connection to a redis server.
  result = Redis(
    socket: newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP, buffered = false),
    pipeline: newPipeline()
  )

  result.socket.connectUnix(path)

proc openAsync*(host = "localhost", port = 6379.Port): Future[AsyncRedis] {.async.} =
  ## Open an asynchronous connection to a redis server.
  result = AsyncRedis(
    socket: newAsyncSocket(buffered = true),
    pipeline: newPipeline(),
    sendQueue: initDeque[Future[void]]()
  )

  await result.socket.connect(host, port)

proc openUnixAsync*(path = "/var/run/redis/redis.sock"): Future[AsyncRedis] {.async.} =
  ## Open an asynchronous unix connection to a redis server.
  result = AsyncRedis(
    socket: newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP, buffered = false),
    pipeline: newPipeline(),
    sendQueue: initDeque[Future[void]]()
  )

  await result.socket.connectUnix(path)

proc finaliseCommand(r: Redis | AsyncRedis) =
  when r is AsyncRedis:
    r.currentCommand = none(string)
    if r.sendQueue.len > 0:
      let fut = r.sendQueue.popFirst()
      fut.complete()

proc raiseReplyError(r: Redis | AsyncRedis, msg: string) =
  finaliseCommand(r)
  raise newException(ReplyError, msg)

proc raiseRedisError(r: Redis | AsyncRedis, msg: string) =
  finaliseCommand(r)
  raise newException(RedisError, msg)

proc managedSend(
  r: Redis | AsyncRedis, data: string
): Future[void] {.multisync.} =
  when r is Redis:
    r.socket.send(data)
  else:
    proc doSend() =
      r.currentCommand = some(data)
      asyncCheck r.socket.send(data)
    if r.currentCommand.isSome():
      # Queue this send.
      let sendFut = newFuture[void]("redis.managedSend")
      r.sendQueue.addLast(sendFut)
      await sendFut

    doSend()

proc managedRecv(
  r: Redis | AsyncRedis, size: int
): Future[string] {.multisync.} =
  result = newString(size)

  when r is Redis:
    if r.socket.recv(result, size) != size:
      raiseReplyError(r, "recv failed")
  else:
    let numReceived = await r.socket.recvInto(addr result[0], size)
    if numReceived != size:
      raiseReplyError(r, "recv failed")

proc managedRecvLine(r: Redis | AsyncRedis): Future[string] {.multisync.} =
  if r.pipeline.enabled:
    return ""

  when r is Redis:
    result = recvLine(r.socket)
  else:
    result = await recvLine(r.socket)

  # recvLine returns "" only when the peer closed the connection; an empty
  # protocol line would be returned as "\r\L". Raise here so callers can
  # treat an empty result as the pipelining dummy.
  if result.len == 0:
    raiseRedisError(r, "Server closed connection prematurely")

type
  RespKind = enum
    ## Internal RESP reply classification, used to filter pipeline
    ## results by type instead of by value. Not exported: the public API
    ## keeps returning flat strings.
    respStatus, respError, respInteger, respBulk, respNilBulk,
    respNilArray, respArray

  RespReply = object
    kind: RespKind
    value: string            # status/error/bulk text or rendered integer
    elements: seq[RespReply] # respArray only

proc readResp(r: Redis): RespReply {.gcsafe.}
proc readResp(r: AsyncRedis): Future[RespReply] {.gcsafe.}
proc readResp(r: Redis | AsyncRedis): Future[RespReply] {.multisync.} =
  ## Read one complete reply, classifying it by its RESP type marker so
  ## that status acknowledgments can be told apart from data replies
  ## that happen to carry the same text.
  let line = await r.managedRecvLine()
  if line.len == 0:
    raiseReplyError(r, "readResp called while pipelining is enabled")

  case line[0]
  of '+':
    result = RespReply(kind: respStatus, value: line.substr(1))
  of '-':
    # Keep the full error line, matching the message parseStatus raises.
    result = RespReply(kind: respError, value: strip(line))
  of ':':
    var num: BiggestInt
    if parseBiggestInt(line, num, 1) == 0:
      raiseReplyError(r, "Unable to parse integer.")
    result = RespReply(kind: respInteger, value: $num)
  of '$':
    let numBytes = parseInt(line.substr(1))
    if numBytes == -1:
      result = RespReply(kind: respNilBulk)
    else:
      var s = await r.managedRecv(numBytes + 2)
      s.setLen(numBytes)
      result = RespReply(kind: respBulk, value: s)
  of '*':
    let numElems = parseInt(line.substr(1))
    if numElems == -1:
      result = RespReply(kind: respNilArray)
    else:
      result = RespReply(kind: respArray, elements: @[])
      for _ in 1 .. numElems:
        when r is Redis:
          result.elements.add(r.readResp())
        else:
          result.elements.add(await r.readResp())
  else:
    raiseReplyError(r, "readResp failed on line: " & line)

proc appendData(r: Redis | AsyncRedis, reply: RespReply, into: var RedisList) =
  ## Flatten a reply into the legacy string list, dropping status
  ## acknowledgments by type. Mirrors the historical flattening: nested
  ## arrays are spliced into the parent, a nil bulk becomes redisNil, a
  ## nil array contributes nothing, and error replies raise.
  case reply.kind
  of respStatus: discard
  of respError: raiseRedisError(r, reply.value)
  of respInteger, respBulk: into.add(reply.value)
  of respNilBulk: into.add(redisNil)
  of respNilArray: discard
  of respArray:
    for element in reply.elements:
      appendData(r, element, into)

proc toRedisValue*(reply: RespReply): RedisValue =
  case reply.kind
  of respStatus:
    result = RedisValue(kind: vkStatus, strVal: reply.value)
  of respError:
    var msg = reply.value
    if msg.len > 0 and msg[0] == '-':
      msg = msg.substr(1).strip()
    raise newException(RedisError, msg)
  of respInteger:
    result = RedisValue(kind: vkInteger, intVal: parseBiggestInt(reply.value))
  of respBulk:
    result = RedisValue(kind: vkString, strVal: reply.value)
  of respNilBulk, respNilArray:
    result = RedisValue(kind: vkNil)
  of respArray:
    result = RedisValue(kind: vkList, listVal: @[])
    for elem in reply.elements:
      result.listVal.add(toRedisValue(elem))

proc readValue*(r: Redis | AsyncRedis): Future[RedisValue] {.multisync.} =
  if r.pipeline.enabled:
    return RedisValue(kind: vkStatus, strVal: "PIPELINED")
  let reply = await r.readResp()
  finaliseCommand(r)
  result = toRedisValue(reply)

proc raiseInvalidReply(r: Redis | AsyncRedis, expected, got: char) =
  raiseReplyError(r,
          "Expected '$1' at the beginning of a status reply got '$2'" %
          [$expected, $got])

proc raiseNoOK(r: Redis | AsyncRedis, status: string) =
  let pipelined = r.pipeline.enabled
  if pipelined and not (status == "QUEUED" or status == "PIPELINED"):
    raiseReplyError(r, "Expected \"QUEUED\" or \"PIPELINED\" got \"$1\"" % status)
  elif not pipelined and status != "OK":
    raiseReplyError(r, "Expected \"OK\" got \"$1\"" % status)

proc parseStatus(r: Redis | AsyncRedis, line: string = ""): RedisStatus =
  if r.pipeline.enabled:
    return "PIPELINED"

  if line == "":
    raiseRedisError(r, "Server closed connection prematurely")

  if line[0] == '-':
    raiseRedisError(r, strip(line))
  if line[0] != '+':
    raiseInvalidReply(r, '+', line[0])

  result = line.substr(1) # Strip '+'

proc readStatus(r: Redis | AsyncRedis): Future[RedisStatus] {.multisync.} =
  let line = await r.managedRecvLine()

  if line.len == 0:
    return "PIPELINED"

  result = r.parseStatus(line)
  finaliseCommand(r)

proc parseInteger(r: Redis | AsyncRedis, line: string = ""): RedisInteger =
  if r.pipeline.enabled:
    return -1

  #if line == "+QUEUED":  # inside of multi
  #  return -1

  if line == "":
    raiseRedisError(r, "Server closed connection prematurely")

  if line[0] == '-':
    raiseRedisError(r, strip(line))
  if line[0] != ':':
    raiseInvalidReply(r, ':', line[0])

  # Strip ':'
  if parseBiggestInt(line, result, 1) == 0:
    raiseReplyError(r, "Unable to parse integer.")

proc readInteger(r: Redis | AsyncRedis): Future[RedisInteger] {.multisync.} =
  let line = await r.managedRecvLine()
  if line.len == 0:
    return -1

  result = r.parseInteger(line)
  finaliseCommand(r)

proc readSingleString(
  r: Redis | AsyncRedis, line: string, allowMBNil: bool
): Future[Option[RedisString]] {.multisync.} =
  if r.pipeline.enabled:
    return

  # Error.
  if line[0] == '-':
    raiseRedisError(r, strip(line))

  # Some commands return a /bulk/ value or a /multi-bulk/ nil. Odd.
  if allowMBNil:
    if line == "*-1":
       return

  if line[0] != '$':
    raiseInvalidReply(r, '$', line[0])

  var numBytes = parseInt(line.substr(1))
  if numBytes == -1:
    return

  # Bulk strings are binary safe; drop only the trailing CRLF, never
  # whitespace belonging to the value itself.
  var s = await r.managedRecv(numBytes + 2)
  s.setLen(numBytes)
  result = some(s)

proc readSingleString(r: Redis | AsyncRedis): Future[RedisString] {.multisync.} =
  # TODO: Rename these style of procedures to `processSingleString`?
  let line = await r.managedRecvLine()
  if line.len == 0:
    return ""

  let res = await r.readSingleString(line, allowMBNil = false)
  result = res.get(redisNil)
  finaliseCommand(r)

proc readNext(r: Redis): RedisList {.gcsafe.}
proc readNext(r: AsyncRedis): Future[RedisList] {.gcsafe.}
proc readArrayLines(r: Redis | AsyncRedis, countLine: string): Future[RedisList] {.multisync.} =
  if countLine.len > 0 and countLine[0] == '-':
    raiseRedisError(r, strip(countLine))
  if countLine[0] != '*':
    raiseInvalidReply(r, '*', countLine[0])

  var numElems = parseInt(countLine.substr(1))
  result = @[]

  if numElems == -1:
    return result

  for i in 1..numElems:
    when r is Redis:
      var parsed = r.readNext()
    else:
      var parsed = await r.readNext()

    if parsed.len > 0:
      for item in parsed:
        result.add(item)

proc readArrayLines(r: Redis | AsyncRedis): Future[RedisList] {.multisync.} =
  let line = await r.managedRecvLine()
  if line.len == 0:
    return @[]

  result = await r.readArrayLines(line)

proc readBulkString(r: Redis | AsyncRedis, allowMBNil = false): Future[RedisString] {.multisync.} =
  let line = await r.managedRecvLine()
  if line.len == 0:
    return ""

  let res = await r.readSingleString(line, allowMBNil)
  result = res.get(redisNil)
  finaliseCommand(r)

proc readArray(r: Redis | AsyncRedis): Future[RedisList] {.multisync.} =
  let line = await r.managedRecvLine()
  if line.len == 0:
    return @[]

  result = await r.readArrayLines(line)
  finaliseCommand(r)

proc readNext(r: Redis | AsyncRedis): Future[RedisList] {.multisync.} =
  let line = await r.managedRecvLine()

  if line.len == 0:
    return @[]

  # TODO: This is no longer an expression due to
  # https://github.com/nim-lang/Nim/issues/8399
  var res: RedisList = @[]
  case line[0]
  of '+', '-': res = @[r.parseStatus(line)]
  of ':': res = @[$(r.parseInteger(line))]
  of '$':
    let x = await r.readSingleString(line, true)
    res = @[x.get(redisNil)]
  of '*':
    res = await r.readArrayLines(line)
  else:
    raiseReplyError(r, "readNext failed on line: " & line)

  r.pipeline.expected -= 1
  return res

proc flushPipeline*(r: Redis | AsyncRedis, wasMulti = false): Future[RedisList] {.multisync.} =
  ## Send buffered commands, clear buffer, return results
  if r.pipeline.buffer.len > 0:
    await r.socket.send(r.pipeline.buffer)
  r.pipeline.buffer = ""

  r.pipeline.enabled = false
  result = @[]

  var tot = r.pipeline.expected

  for i in 0..tot-1:
    # Read each reply in typed form and filter status acknowledgments by
    # their RESP type, so data replies whose text happens to be "OK" or
    # "QUEUED" are preserved.
    let reply = await r.readResp()
    appendData(r, reply, result)

  r.pipeline.expected = 0

proc flushPipelineValues*(r: Redis | AsyncRedis, wasMulti = false): Future[seq[RedisValue]] {.multisync.} =
  ## Send buffered commands, clear buffer, and return results as a sequence of RedisValue
  ## preserving 1:1 positional integrity with queued commands.
  if r.pipeline.buffer.len > 0:
    await r.socket.send(r.pipeline.buffer)
  r.pipeline.buffer = ""

  r.pipeline.enabled = false
  result = @[]

  var tot = r.pipeline.expected

  if wasMulti:
    var execReply: RespReply
    for i in 0 ..< tot:
      let reply = await r.readResp()
      if reply.kind == respError:
        raiseRedisError(r, reply.value)
      if i == tot - 1:
        execReply = reply
    r.pipeline.expected = 0
    if execReply.kind == respArray:
      for elem in execReply.elements:
        result.add(elem.toRedisValue())
    elif execReply.kind == respNilArray:
      discard
    elif execReply.kind != respError:
      result.add(execReply.toRedisValue())
  else:
    for i in 0 ..< tot:
      let reply = await r.readResp()
      result.add(reply.toRedisValue())
    r.pipeline.expected = 0

proc startPipelining*(r: Redis | AsyncRedis) =
  ## Enable command pipelining (reduces network roundtrips).
  ## Note that when enabled, you must call flushPipeline to actually send commands, except
  ## for multi/exec() which enable and flush the pipeline automatically.
  ## Commands return immediately with dummy values; actual results returned from
  ## flushPipeline() or exec()
  r.pipeline.expected = 0
  r.pipeline.enabled = true

proc sendCommand(r: Redis | AsyncRedis, cmd: string): Future[void] {.multisync.} =
  var request = "*1\c\L"
  request.add("$" & $cmd.len() & "\c\L")
  request.add(cmd & "\c\L")

  if r.pipeline.enabled:
    r.pipeline.buffer.add(request)
    r.pipeline.expected += 1
  else:
    await r.managedSend(request)

proc sendCommand(
  r: Redis | AsyncRedis, cmd: string, args: seq[string]
): Future[void] {.multisync.} =
  var request = "*" & $(1 + args.len()) & "\c\L"
  request.add("$" & $cmd.len() & "\c\L")
  request.add(cmd & "\c\L")
  for i in items(args):
    request.add("$" & $i.len() & "\c\L")
    request.add(i & "\c\L")

  if r.pipeline.enabled:
    r.pipeline.buffer.add(request)
    r.pipeline.expected += 1
  else:
    await r.managedSend(request)

proc sendCommand(
  r: Redis | AsyncRedis, cmd: string, arg1: string
): Future[void] {.multisync.} =
  var request = "*2\c\L"
  request.add("$" & $cmd.len() & "\c\L")
  request.add(cmd & "\c\L")
  request.add("$" & $arg1.len() & "\c\L")
  request.add(arg1 & "\c\L")

  if r.pipeline.enabled:
    r.pipeline.expected += 1
    r.pipeline.buffer.add(request)
  else:
    await r.managedSend(request)

proc sendCommand(r: Redis | AsyncRedis, cmd: string, arg1: string,
                 args: seq[string]): Future[void] {.multisync.} =
  var request = "*" & $(2 + args.len()) & "\c\L"
  request.add("$" & $cmd.len() & "\c\L")
  request.add(cmd & "\c\L")
  request.add("$" & $arg1.len() & "\c\L")
  request.add(arg1 & "\c\L")
  for i in items(args):
    request.add("$" & $i.len() & "\c\L")
    request.add(i & "\c\L")

  if r.pipeline.enabled:
    r.pipeline.expected += 1
    r.pipeline.buffer.add(request)
  else:
    await r.managedSend(request)

# Keys

proc del*(r: Redis | AsyncRedis, keys: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Delete a key or multiple keys
  await r.sendCommand("DEL", keys)
  result = await r.readInteger()

proc del*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Delete a single key
  await r.del(@[key])

proc del*(r: Redis, keys: openArray[string]): RedisInteger =
  ## Delete multiple keys
  var kSeq: seq[string] = @[]
  for k in keys: kSeq.add(k)
  result = r.del(kSeq)

proc del*(r: AsyncRedis, keys: openArray[string]): Future[RedisInteger] =
  ## Delete multiple keys asynchronously
  var kSeq: seq[string] = @[]
  for k in keys: kSeq.add(k)
  result = r.del(kSeq)

proc exists*(r: Redis | AsyncRedis, key: string): Future[bool] {.multisync.} =
  ## Determine if a key exists
  await r.sendCommand("EXISTS", @[key])
  result = (await r.readInteger()) == 1

proc expire*(r: Redis | AsyncRedis, key: string, seconds: int): Future[bool] {.multisync.} =
  ## Set a key's time to live in seconds. Returns `false` if the key could
  ## not be found or the timeout could not be set.
  await r.sendCommand("EXPIRE", key, @[$seconds])
  result = (await r.readInteger()) == 1

proc expireAt*(r: Redis | AsyncRedis, key: string, timestamp: int): Future[bool] {.multisync.} =
  ## Set the expiration for a key as a UNIX timestamp. Returns `false`
  ## if the key could not be found or the timeout could not be set.
  await r.sendCommand("EXPIREAT", key, @[$timestamp])
  result = (await r.readInteger()) == 1

proc keys*(r: Redis | AsyncRedis, pattern: string): Future[RedisList] {.multisync.} =
  ## Find all keys matching the given pattern
  await r.sendCommand("KEYS", pattern)
  result = await r.readArray()

proc scan*(r: Redis | AsyncRedis, cursor: RedisCursor): Future[RedisList] {.multisync.} =
  ## Find all keys matching the given pattern and yield it to client in portions
  ## using default Redis values for MATCH and COUNT parameters
  await r.sendCommand("SCAN", $cursor.position)
  let reply = await r.readArray()
  cursor.position = strutils.parseBiggestInt(reply[0])
  result = reply[1..high(reply)]

proc scan*(r: Redis | AsyncRedis, cursor: RedisCursor, pattern: string): Future[RedisList] {.multisync.} =
  ## Find all keys matching the given pattern and yield it to client in portions
  ## using cursor as a client query identifier. Using default Redis value for COUNT argument
  await r.sendCommand("SCAN", $cursor.position, @["MATCH", pattern])
  let reply = await r.readArray()
  cursor.position = strutils.parseBiggestInt(reply[0])
  result = reply[1..high(reply)]

proc scan*(r: Redis | AsyncRedis, cursor: RedisCursor, pattern: string, count: int): Future[RedisList] {.multisync.} =
  ## Find all keys matching the given pattern and yield it to client in portions
  ## using cursor as a client query identifier.
  await r.sendCommand("SCAN", $cursor.position, @["MATCH", pattern, "COUNT", $count])
  let reply = await r.readArray()
  cursor.position = strutils.parseBiggestInt(reply[0])
  result = reply[1..high(reply)]

proc move*(r: Redis | AsyncRedis, key: string, db: int): Future[bool] {.multisync.} =
  ## Move a key to another database. Returns `true` on a successful move.
  await r.sendCommand("MOVE", key, @[$db])
  result = (await r.readInteger()) == 1

proc persist*(r: Redis | AsyncRedis, key: string): Future[bool] {.multisync.} =
  ## Remove the expiration from a key.
  ## Returns `true` when the timeout was removed.
  await r.sendCommand("PERSIST", key)
  return (await r.readInteger()) == 1

proc randomKey*(r: Redis | AsyncRedis): Future[RedisString] {.multisync.} =
  ## Return a random key from the keyspace
  await r.sendCommand("RANDOMKEY")
  result = await r.readBulkString()

proc rename*(r: Redis | AsyncRedis, key, newkey: string): Future[RedisStatus] {.multisync.} =
  ## Rename a key.
  ##
  ## **WARNING:** Overwrites `newkey` if it exists!
  await r.sendCommand("RENAME", key, @[newkey])
  raiseNoOK(r, await r.readStatus())

proc renameNX*(r: Redis | AsyncRedis, key, newkey: string): Future[bool] {.multisync.} =
  ## Same as ``rename`` but doesn't continue if `newkey` exists.
  ## Returns `true` if key was renamed.
  await r.sendCommand("RENAMENX", key, @[newkey])
  result = (await r.readInteger()) == 1

proc ttl*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Get the time to live for a key
  await r.sendCommand("TTL", key)
  return await r.readInteger()

proc keyType*(r: Redis | AsyncRedis, key: string): Future[RedisStatus] {.multisync.} =
  ## Determine the type stored at key
  await r.sendCommand("TYPE", key)
  result = await r.readStatus()

proc unlink*(r: Redis | AsyncRedis, keys: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Delete a key or multiple keys asynchronously in a background thread.
  await r.sendCommand("UNLINK", keys)
  result = await r.readInteger()

proc unlink*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Delete a key asynchronously in a background thread.
  await r.sendCommand("UNLINK", @[key])
  result = await r.readInteger()

proc unlink*(r: Redis, keys: openArray[string]): RedisInteger =
  ## Delete multiple keys asynchronously in a background thread.
  var kSeq: seq[string] = @[]
  for k in keys: kSeq.add(k)
  result = r.unlink(kSeq)

proc unlink*(r: AsyncRedis, keys: openArray[string]): Future[RedisInteger] =
  ## Delete multiple keys asynchronously in a background thread.
  var kSeq: seq[string] = @[]
  for k in keys: kSeq.add(k)
  result = r.unlink(kSeq)

proc touch*(r: Redis | AsyncRedis, keys: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Alters the last access time of a key(s). Returns the number of keys that were touched.
  await r.sendCommand("TOUCH", keys)
  result = await r.readInteger()

proc touch*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Alters the last access time of a key. Returns 1 if key exists, 0 otherwise.
  await r.sendCommand("TOUCH", @[key])
  result = await r.readInteger()

proc touch*(r: Redis, keys: openArray[string]): RedisInteger =
  ## Alters the last access time of multiple keys. Returns the number of keys that were touched.
  var kSeq: seq[string] = @[]
  for k in keys: kSeq.add(k)
  result = r.touch(kSeq)

proc touch*(r: AsyncRedis, keys: openArray[string]): Future[RedisInteger] =
  ## Alters the last access time of multiple keys. Returns the number of keys that were touched.
  var kSeq: seq[string] = @[]
  for k in keys: kSeq.add(k)
  result = r.touch(kSeq)

proc copy*(r: Redis | AsyncRedis, src, dst: string, db: int = -1, replace: bool = false): Future[bool] {.multisync.} =
  ## Copy a key to another key. Returns true if the key was copied.
  var args: seq[string] = @[src, dst]
  if db >= 0:
    args.add("DB")
    args.add($db)
  if replace:
    args.add("REPLACE")
  await r.sendCommand("COPY", args)
  result = (await r.readInteger()) == 1

proc pexpire*(r: Redis | AsyncRedis, key: string, milliseconds: BiggestInt): Future[bool] {.multisync.} =
  ## Set a key's time to live in milliseconds.
  await r.sendCommand("PEXPIRE", key, @[$milliseconds])
  result = (await r.readInteger()) == 1

proc pexpireAt*(r: Redis | AsyncRedis, key: string, timestampMs: BiggestInt): Future[bool] {.multisync.} =
  ## Set the expiration for a key as a UNIX timestamp in milliseconds.
  await r.sendCommand("PEXPIREAT", key, @[$timestampMs])
  result = (await r.readInteger()) == 1

proc pttl*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Get the time to live for a key in milliseconds.
  await r.sendCommand("PTTL", @[key])
  result = await r.readInteger()

proc expireTime*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Get the expiration Unix timestamp for a key in seconds.
  await r.sendCommand("EXPIRETIME", @[key])
  result = await r.readInteger()

proc pexpireTime*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Get the expiration Unix timestamp for a key in milliseconds.
  await r.sendCommand("PEXPIRETIME", @[key])
  result = await r.readInteger()


# Strings

proc append*(r: Redis | AsyncRedis, key, value: string): Future[RedisInteger] {.multisync.} =
  ## Append a value to a key
  await r.sendCommand("APPEND", key, @[value])
  result = await r.readInteger()

proc decr*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Decrement the integer value of a key by one
  await r.sendCommand("DECR", key)
  result = await r.readInteger()

proc decrBy*(r: Redis | AsyncRedis, key: string, decrement: int): Future[RedisInteger] {.multisync.} =
  ## Decrement the integer value of a key by the given number
  await r.sendCommand("DECRBY", key, @[$decrement])
  result = await r.readInteger()

proc mget*(r: Redis | AsyncRedis, keys: seq[string]): Future[RedisList] {.multisync.} =
  ## Get the values of all given keys
  await r.sendCommand("MGET", keys)
  result = await r.readArray()

proc get*(r: Redis | AsyncRedis, key: string): Future[RedisString] {.multisync.} =
  ## Get the value of a key. Returns `redisNil` when `key` doesn't exist.
  await r.sendCommand("GET", key)
  result = await r.readBulkString()

#TODO: BITOP
proc getBit*(r: Redis | AsyncRedis, key: string, offset: int): Future[RedisInteger] {.multisync.} =
  ## Returns the bit value at offset in the string value stored at key
  await r.sendCommand("GETBIT", key, @[$offset])
  result = await r.readInteger()

proc bitCount*(r: Redis | AsyncRedis, key: string, limits: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Returns the number of set bits, optionally within limits
  await r.sendCommand("BITCOUNT", key, limits)
  result = await r.readInteger()

proc bitPos*(r: Redis | AsyncRedis, key: string, bit: int, limits: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Returns position of the first occurence of bit within limits
  var parameters = newSeqOfCap[string](len(limits) + 1)
  parameters.add($bit)
  parameters.add(limits)

  await r.sendCommand("BITPOS", key, parameters)
  result = await r.readInteger()

proc getRange*(r: Redis | AsyncRedis, key: string, start, stop: int): Future[RedisString] {.multisync.} =
  ## Get a substring of the string stored at a key
  await r.sendCommand("GETRANGE", key, @[$start, $stop])
  result = await r.readBulkString()

proc getSet*(r: Redis | AsyncRedis, key: string, value: string): Future[RedisString] {.multisync.} =
  ## Set the string value of a key and return its old value. Returns `redisNil`
  ## when key doesn't exist.
  await r.sendCommand("GETSET", key, @[value])
  result = await r.readBulkString()

proc incr*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Increment the integer value of a key by one.
  await r.sendCommand("INCR", key)
  result = await r.readInteger()

proc incrBy*(r: Redis | AsyncRedis, key: string, increment: int): Future[RedisInteger] {.multisync.} =
  ## Increment the integer value of a key by the given number
  await r.sendCommand("INCRBY", key, @[$increment])
  result = await r.readInteger()

#TODO incrbyfloat

proc msetk*(
  r: Redis | AsyncRedis,
  keyValues: seq[tuple[key, value: string]]
): Future[void] {.multisync.} =
  ## Set mupltiple keys to multplie values
  var args: seq[string] = @[]
  for key, value in items(keyValues):
    args.add(key)
    args.add(value)
  await r.sendCommand("MSET", args)
  raiseNoOK(r, await r.readStatus())

proc setk*(r: Redis | AsyncRedis, key, value: string): Future[void] {.multisync.} =
  ## Set the string value of a key.
  ##
  ## NOTE: This function had to be renamed due to a clash with the `set` type.
  await r.sendCommand("SET", key, @[value])
  raiseNoOK(r, await r.readStatus())

proc setNX*(r: Redis | AsyncRedis, key, value: string): Future[bool] {.multisync.} =
  ## Set the value of a key, only if the key does not exist. Returns `true`
  ## if the key was set.
  await r.sendCommand("SETNX", key, @[value])
  result = (await r.readInteger()) == 1

proc setBit*(r: Redis | AsyncRedis, key: string, offset: int,
             value: string): Future[RedisInteger] {.multisync.} =
  ## Sets or clears the bit at offset in the string value stored at key
  await r.sendCommand("SETBIT", key, @[$offset, value])
  result = await r.readInteger()

proc setEx*(r: Redis | AsyncRedis, key: string, seconds: int, value: string): Future[RedisStatus] {.multisync.} =
  ## Set the value and expiration of a key
  await r.sendCommand("SETEX", key, @[$seconds, value])
  raiseNoOK(r, await r.readStatus())

proc setRange*(r: Redis | AsyncRedis, key: string, offset: int,
               value: string): Future[RedisInteger] {.multisync.} =
  ## Overwrite part of a string at key starting at the specified offset
  await r.sendCommand("SETRANGE", key, @[$offset, value])
  result = await r.readInteger()

proc strlen*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Get the length of the value stored in a key. Returns 0 when key doesn't
  ## exist.
  await r.sendCommand("STRLEN", key)
  result = await r.readInteger()

proc getDel*(r: Redis | AsyncRedis, key: string): Future[RedisString] {.multisync.} =
  ## Get the value of a key and delete the key atomically.
  await r.sendCommand("GETDEL", key)
  result = await r.readBulkString()

proc getEx*(r: Redis | AsyncRedis, key: string, seconds: int = -1, pseconds: BiggestInt = -1, persist: bool = false): Future[RedisString] {.multisync.} =
  ## Get the value of a key and optionally set its expiration.
  var args: seq[string] = @[key]
  if persist:
    args.add("PERSIST")
  elif seconds >= 0:
    args.add("EX")
    args.add($seconds)
  elif pseconds >= 0:
    args.add("PX")
    args.add($pseconds)
  await r.sendCommand("GETEX", args)
  result = await r.readBulkString()

proc msetnx*(r: Redis | AsyncRedis, pairs: seq[(string, string)]): Future[bool] {.multisync.} =
  ## Set multiple keys to multiple values, only if none of the keys exist.
  var args: seq[string] = @[]
  for (k, v) in pairs:
    args.add(k)
    args.add(v)
  await r.sendCommand("MSETNX", args)
  result = (await r.readInteger()) == 1

proc msetnx*(r: Redis, pairs: openArray[(string, string)]): bool =
  var s = @pairs
  result = r.msetnx(s)

proc msetnx*(r: AsyncRedis, pairs: openArray[(string, string)]): Future[bool] =
  var s = @pairs
  result = r.msetnx(s)

proc incrByFloat*(r: Redis | AsyncRedis, key: string, increment: float): Future[float] {.multisync.} =
  ## Increment the float value of a key by the given amount.
  await r.sendCommand("INCRBYFLOAT", key, @[$increment])
  let res = await r.readBulkString()
  result = parseFloat(res)

# Hashes
proc hDel*(r: Redis | AsyncRedis, key, field: string): Future[bool] {.multisync.} =
  ## Delete a hash field at `key`. Returns `true` if the field was removed.
  await r.sendCommand("HDEL", key, @[field])
  result = (await r.readInteger()) == 1

proc hDel*(r: Redis | AsyncRedis, key: string, fields: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Delete one or more hash fields at `key`. Returns the number of fields removed.
  await r.sendCommand("HDEL", key, fields)
  result = await r.readInteger()

proc hExists*(r: Redis | AsyncRedis, key, field: string): Future[bool] {.multisync.} =
  ## Determine if a hash field exists.
  await r.sendCommand("HEXISTS", key, @[field])
  result = (await r.readInteger()) == 1

proc hGet*(r: Redis | AsyncRedis, key, field: string): Future[RedisString] {.multisync.} =
  ## Get the value of a hash field
  await r.sendCommand("HGET", key, @[field])
  result = await r.readBulkString()

proc hGetAll*(r: Redis | AsyncRedis, key: string): Future[RedisList] {.multisync.} =
  ## Get all the fields and values in a hash
  await r.sendCommand("HGETALL", key)
  result = await r.readArray()

proc hIncrBy*(r: Redis | AsyncRedis, key, field: string, incr: int): Future[RedisInteger] {.multisync.} =
  ## Increment the integer value of a hash field by the given number
  await r.sendCommand("HINCRBY", key, @[field, $incr])
  result = await r.readInteger()

proc hKeys*(r: Redis | AsyncRedis, key: string): Future[RedisList] {.multisync.} =
  ## Get all the fields in a hash
  await r.sendCommand("HKEYS", key)
  result = await r.readArray()

proc hLen*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Get the number of fields in a hash
  await r.sendCommand("HLEN", key)
  result = await r.readInteger()

proc hMGet*(r: Redis | AsyncRedis, key: string, fields: seq[string]): Future[RedisList] {.multisync.} =
  ## Get the values of all the given hash fields
  await r.sendCommand("HMGET", key, fields)
  result = await r.readArray()

proc hMSet*(r: Redis | AsyncRedis, key: string,
            fieldValues: seq[tuple[field, value: string]]): Future[void] {.multisync.} =
  ## Set multiple hash fields to multiple values
  var args = @[key]
  for field, value in items(fieldValues):
    args.add(field)
    args.add(value)
  await r.sendCommand("HMSET", args)
  raiseNoOK(r, await r.readStatus())

proc hSet*(r: Redis | AsyncRedis, key, field, value: string): Future[RedisInteger] {.multisync.} =
  ## Set the string value of a hash field
  await r.sendCommand("HSET", key, @[field, value])
  result = await r.readInteger()

proc hSetNX*(r: Redis | AsyncRedis, key, field, value: string): Future[RedisInteger] {.multisync.} =
  ## Set the value of a hash field, only if the field does **not** exist
  await r.sendCommand("HSETNX", key, @[field, value])
  result = await r.readInteger()

proc hVals*(r: Redis | AsyncRedis, key: string): Future[RedisList] {.multisync.} =
  ## Get all the values in a hash
  await r.sendCommand("HVALS", key)
  result = await r.readArray()

proc hSet*(r: Redis | AsyncRedis, key: string, pairs: seq[(string, string)]): Future[RedisInteger] {.multisync.} =
  ## Set multiple field-value pairs in a hash (Redis 4.0+)
  var args = newSeqOfCap[string](pairs.len * 2)
  for (f, v) in pairs:
    args.add(f)
    args.add(v)
  await r.sendCommand("HSET", key, args)
  result = await r.readInteger()

proc hSet*(r: Redis, key: string, pairs: openArray[(string, string)]): RedisInteger =
  var s = @pairs
  result = r.hSet(key, s)

proc hSet*(r: AsyncRedis, key: string, pairs: openArray[(string, string)]): Future[RedisInteger] =
  var s = @pairs
  result = r.hSet(key, s)

proc hRandField*(r: Redis | AsyncRedis, key: string, count: int = 1, withValues: bool = false): Future[seq[string]] {.multisync.} =
  ## Get one or multiple random fields from a hash (Redis 6.2+)
  var args: seq[string] = @[$count]
  if withValues:
    args.add("WITHVALUES")
  await r.sendCommand("HRANDFIELD", key, args)
  result = await r.readArray()

proc hStrLen*(r: Redis | AsyncRedis, key, field: string): Future[RedisInteger] {.multisync.} =
  ## Get the string length of the value of a hash field (Redis 3.2+)
  await r.sendCommand("HSTRLEN", key, @[field])
  result = await r.readInteger()


# Lists

proc bLPop*(r: Redis | AsyncRedis, keys: seq[string], timeout: int): Future[RedisList] {.multisync.} =
  ## Remove and get the *first* element in a list, or block until
  ## one is available
  var args = newSeqOfCap[string](len(keys) + 1)
  for i in items(keys):
    args.add(i)

  args.add($timeout)

  await r.sendCommand("BLPOP", args)
  result = await r.readArray()

proc bRPop*(r: Redis | AsyncRedis, keys: seq[string], timeout: int): Future[RedisList] {.multisync.} =
  ## Remove and get the *last* element in a list, or block until one
  ## is available.
  var args = newSeqOfCap[string](len(keys) + 1)
  for i in items(keys):
    args.add(i)

  args.add($timeout)

  await r.sendCommand("BRPOP", args)
  result = await r.readArray()

proc bRPopLPush*(r: Redis | AsyncRedis, source, destination: string,
                 timeout: int): Future[RedisString] {.multisync.} =
  ## Pop a value from a list, push it to another list and return it; or
  ## block until one is available.
  ##
  ## http://redis.io/commands/brpoplpush
  await r.sendCommand("BRPOPLPUSH", source, @[destination, $timeout])
  result = await r.readBulkString(true) # Multi-Bulk nil allowed.

proc lIndex*(r: Redis | AsyncRedis, key: string, index: int): Future[RedisString]  {.multisync.} =
  ## Get an element from a list by its index
  await r.sendCommand("LINDEX", key, @[$index])
  result = await r.readBulkString()

proc lInsert*(r: Redis | AsyncRedis, key: string, before: bool, pivot, value: string):
              Future[RedisInteger] {.multisync.} =
  ## Insert an element before or after another element in a list
  var pos = if before: "BEFORE" else: "AFTER"
  await r.sendCommand("LINSERT", key, @[pos, pivot, value])
  result = await r.readInteger()

proc lLen*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Get the length of a list
  await r.sendCommand("LLEN", key)
  result = await r.readInteger()

proc lPop*(r: Redis | AsyncRedis, key: string): Future[RedisString] {.multisync.} =
  ## Remove and get the first element in a list
  await r.sendCommand("LPOP", key)
  result = await r.readBulkString()

proc lPush*(r: Redis | AsyncRedis, key, value: string, create: bool = true): Future[RedisInteger] {.multisync.} =
  ## Prepend a value to a list. Returns the length of the list after the push.
  ## The ``create`` param specifies whether a list should be created if it
  ## doesn't exist at ``key``. More specifically if ``create`` is true, `LPUSH`
  ## will be used, otherwise `LPUSHX`.
  if create:
    await r.sendCommand("LPUSH", key, @[value])
  else:
    await r.sendCommand("LPUSHX", key, @[value])

  result = await r.readInteger()

proc lLPush*(r: Redis | AsyncRedis, key: string, values: seq[string], create: bool = true): Future[RedisInteger] {.multisync.} =
  ## Append a value to a list. Returns the length of the list after the push.
  ## The ``create`` param specifies whether a list should be created if it
  ## doesn't exist at ``key``. More specifically if ``create`` is true, `RPUSH`
  ## will be used, otherwise `RPUSHX`.
  if create:
    await r.sendCommand("LPUSH", key, values)
  else:
    await r.sendCommand("LPUSHX", key, values)

  result = await r.readInteger()

proc lRange*(r: Redis | AsyncRedis, key: string, start, stop: int): Future[RedisList] {.multisync.} =
  ## Get a range of elements from a list.
  await r.sendCommand("LRANGE", key, @[$start, $stop])
  result = await r.readArray()

proc lRem*(r: Redis | AsyncRedis, key: string, value: string, count: int = 0): Future[RedisInteger] {.multisync.} =
  ## Remove elements from a list. Returns the number of elements that have been
  ## removed.
  await r.sendCommand("LREM", key, @[$count, value])
  result = await r.readInteger()

proc lSet*(r: Redis | AsyncRedis, key: string, index: int, value: string): Future[void] {.multisync.} =
  ## Set the value of an element in a list by its index
  await r.sendCommand("LSET", key, @[$index, value])
  raiseNoOK(r, await r.readStatus())

proc lTrim*(r: Redis | AsyncRedis, key: string, start, stop: int): Future[void] {.multisync.}  =
  ## Trim a list to the specified range
  await r.sendCommand("LTRIM", key, @[$start, $stop])
  raiseNoOK(r, await r.readStatus())

proc rPop*(r: Redis | AsyncRedis, key: string): Future[RedisString] {.multisync.} =
  ## Remove and get the last element in a list
  await r.sendCommand("RPOP", key)
  result = await r.readBulkString()

proc rPopLPush*(r: Redis | AsyncRedis, source, destination: string): Future[RedisString] {.multisync.} =
  ## Remove the last element in a list, append it to another list and return it
  await r.sendCommand("RPOPLPUSH", source, @[destination])
  result = await r.readBulkString()

proc rPush*(r: Redis | AsyncRedis, key, value: string, create: bool = true): Future[RedisInteger] {.multisync.} =
  ## Append a value to a list. Returns the length of the list after the push.
  ## The ``create`` param specifies whether a list should be created if it
  ## doesn't exist at ``key``. More specifically if ``create`` is true, `RPUSH`
  ## will be used, otherwise `RPUSHX`.
  if create:
    await r.sendCommand("RPUSH", key, @[value])
  else:
    await r.sendCommand("RPUSHX", key, @[value])

  result = await r.readInteger()

proc rLPush*(r: Redis | AsyncRedis, key: string, values: seq[string], create: bool = true): Future[RedisInteger] {.multisync.} =
  ## Append a value to a list. Returns the length of the list after the push.
  ## The ``create`` param specifies whether a list should be created if it
  ## doesn't exist at ``key``. More specifically if ``create`` is true, `RPUSH`
  ## will be used, otherwise `RPUSHX`.
  if create:
    await r.sendCommand("RPUSH", key, values)
  else:
    await r.sendCommand("RPUSHX", key, values)

  result = await r.readInteger()

# Sets

proc sadd*(r: Redis | AsyncRedis, key: string, member: string): Future[RedisInteger] {.multisync.} =
  ## Add a member to a set
  await r.sendCommand("SADD", key, @[member])
  result = await r.readInteger()

proc sadd*(r: Redis | AsyncRedis, key: string, members: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Add one or multiple members to a set
  await r.sendCommand("SADD", key, members)
  result = await r.readInteger()

proc sladd*(r: Redis | AsyncRedis, key: string, members: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Add multiple members to a set
  await r.sendCommand("SADD", key, members)
  result = await r.readInteger()

proc scard*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Get the number of members in a set
  await r.sendCommand("SCARD", key)
  result = await r.readInteger()

proc sdiff*(r: Redis | AsyncRedis, keys: seq[string]): Future[RedisList] {.multisync.} =
  ## Subtract multiple sets
  await r.sendCommand("SDIFF", keys)
  result = await r.readArray()

proc sdiffstore*(r: Redis | AsyncRedis, destination: string,
                keys: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Subtract multiple sets and store the resulting set in a key
  await r.sendCommand("SDIFFSTORE", destination, keys)
  result = await r.readInteger()

proc sinter*(r: Redis | AsyncRedis, keys: seq[string]): Future[RedisList] {.multisync.} =
  ## Intersect multiple sets
  await r.sendCommand("SINTER", keys)
  result = await r.readArray()

proc sinterstore*(r: Redis | AsyncRedis, destination: string,
                 keys: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Intersect multiple sets and store the resulting set in a key
  await r.sendCommand("SINTERSTORE", destination, keys)
  result = await r.readInteger()

proc sismember*(r: Redis | AsyncRedis, key: string, member: string): Future[RedisInteger] {.multisync.} =
  ## Determine if a given value is a member of a set
  await r.sendCommand("SISMEMBER", key, @[member])
  result = await r.readInteger()

proc smembers*(r: Redis | AsyncRedis, key: string): Future[RedisList] {.multisync.} =
  ## Get all the members in a set
  await r.sendCommand("SMEMBERS", key)
  result = await r.readArray()

proc smove*(r: Redis | AsyncRedis, source: string, destination: string,
           member: string): Future[RedisInteger] {.multisync.} =
  ## Move a member from one set to another
  await r.sendCommand("SMOVE", source, @[destination, member])
  result = await r.readInteger()

proc spop*(r: Redis | AsyncRedis, key: string): Future[RedisString] {.multisync.} =
  ## Remove and return a random member from a set
  await r.sendCommand("SPOP", key)
  result = await r.readBulkString()

proc srandmember*(r: Redis | AsyncRedis, key: string): Future[RedisString] {.multisync.} =
  ## Get a random member from a set
  await r.sendCommand("SRANDMEMBER", key)
  result = await r.readBulkString()

proc srem*(r: Redis | AsyncRedis, key: string, member: string): Future[RedisInteger] {.multisync.} =
  ## Remove a member from a set
  await r.sendCommand("SREM", key, @[member])
  result = await r.readInteger()

proc srem*(r: Redis | AsyncRedis, key: string, members: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Remove one or multiple members from a set
  await r.sendCommand("SREM", key, members)
  result = await r.readInteger()

proc slrem*(r: Redis | AsyncRedis, key: string, members: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Remove multiple members from a set
  await r.sendCommand("SREM", key, members)
  result = await r.readInteger()

proc sunion*(r: Redis | AsyncRedis, keys: seq[string]): Future[RedisList] {.multisync.} =
  ## Add multiple sets
  await r.sendCommand("SUNION", keys)
  result = await r.readArray()

proc sunionstore*(r: Redis | AsyncRedis, destination: string,
                 key: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Add multiple sets and store the resulting set in a key
  await r.sendCommand("SUNIONSTORE", destination, key)
  result = await r.readInteger()

# Sorted sets

proc zadd*(r: Redis | AsyncRedis, key: string, score: int, member: string): Future[RedisInteger] {.multisync.} =
  ## Add a member to a sorted set, or update its score if it already exists
  await r.sendCommand("ZADD", key, @[$score, member])
  result = await r.readInteger()

proc zcard*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Get the number of members in a sorted set
  await r.sendCommand("ZCARD", key)
  result = await r.readInteger()

proc zcount*(r: Redis | AsyncRedis, key: string, min: string, max: string): Future[RedisInteger] {.multisync.} =
  ## Count the members in a sorted set with scores within the given values
  await r.sendCommand("ZCOUNT", key, @[min, max])
  result = await r.readInteger()

proc zincrby*(r: Redis | AsyncRedis, key: string, increment: string,
             member: string): Future[RedisString] {.multisync.}  =
  ## Increment the score of a member in a sorted set
  await r.sendCommand("ZINCRBY", key, @[increment, member])
  result = await r.readBulkString()

proc zinterstore*(r: Redis | AsyncRedis, destination: string, numkeys: string,
                 keys: seq[string], weights: seq[string] = @[],
                 aggregate: string = ""): Future[RedisInteger] {.multisync.} =
  ## Intersect multiple sorted sets and store the resulting sorted set in
  ## a new key
  let argsLen = 2 + len(keys) + (if len(weights) > 0: len(weights) + 1 else: 0) + (if len(aggregate) > 0: 1 + len(aggregate) else: 0)
  var args = newSeqofCap[string](argsLen)

  args.add(destination)
  args.add(numkeys)

  for i in items(keys):
    args.add(i)

  if weights.len != 0:
    args.add("WEIGHTS")
    for i in items(weights):
      args.add(i)

  if aggregate.len != 0:
    args.add("AGGREGATE")
    args.add(aggregate)

  await r.sendCommand("ZINTERSTORE", args)

  result = await r.readInteger()

proc zrange*(r: Redis | AsyncRedis, key: string, start: string, stop: string,
            withScores: bool = false): Future[RedisList] {.multisync.} =
  ## Return a range of members in a sorted set, by index
  if not withScores:
    await r.sendCommand("ZRANGE", key, @[start, stop])
  else:
    await r.sendCommand("ZRANGE", key, @[start, stop, "WITHSCORES"])

  result = await r.readArray()

proc zrangebyscore*(r: Redis | AsyncRedis, key: string, min: string, max: string,
                   withScores: bool = false, limit: bool = false,
                   limitOffset: int = 0, limitCount: int = 0): Future[RedisList] {.multisync.} =
  ## Return a range of members in a sorted set, by score
  var args = newSeqOfCap[string](3 + (if withScores: 1 else: 0) + (if limit: 3 else: 0))
  args.add(key)
  args.add(min)
  args.add(max)

  if withScores: args.add("WITHSCORES")
  if limit:
    args.add("LIMIT")
    args.add($limitOffset)
    args.add($limitCount)

  await r.sendCommand("ZRANGEBYSCORE", args)
  result = await r.readArray()

proc zrangebylex*(r: Redis | AsyncRedis, key: string, start: string, stop: string,
                  limit: bool = false, limitOffset: int = 0,
                  limitCount: int = 0): Future[RedisList] {.multisync.} =
  ## Return a range of members in a sorted set, ordered lexicographically
  var args = newSeqOfCap[string](3 + (if limit: 3 else: 0))
  args.add(key)
  args.add(start)
  args.add(stop)
  if limit:
    args.add("LIMIT")
    args.add($limitOffset)
    args.add($limitCount)

  await r.sendCommand("ZRANGEBYLEX", args)
  result = await r.readArray()

proc zrank*(r: Redis | AsyncRedis, key: string, member: string): Future[RedisString] {.multisync.} =
  ## Determine the index of a member in a sorted set
  await r.sendCommand("ZRANK", key, @[member])
  try:
    result = $(await r.readInteger())
  except ReplyError:
    result = redisNil

proc zrem*(r: Redis | AsyncRedis, key: string, member: string): Future[RedisInteger] {.multisync.} =
  ## Remove a member from a sorted set
  await r.sendCommand("ZREM", key, @[member])
  result = await r.readInteger()

proc zrem*(r: Redis | AsyncRedis, key: string, members: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Remove one or more members from a sorted set (Redis 2.4+)
  await r.sendCommand("ZREM", key, members)
  result = await r.readInteger()

proc zremrangebyrank*(r: Redis | AsyncRedis, key: string, start: string,
                     stop: string): Future[RedisInteger] {.multisync.} =
  ## Remove all members in a sorted set within the given indexes
  await r.sendCommand("ZREMRANGEBYRANK", key, @[start, stop])
  result = await r.readInteger()

proc zremrangebyscore*(r: Redis | AsyncRedis, key: string, min: string,
                      max: string): Future[RedisInteger] {.multisync.} =
  ## Remove all members in a sorted set within the given scores
  await r.sendCommand("ZREMRANGEBYSCORE", key, @[min, max])
  result = await r.readInteger()

proc zrevrange*(r: Redis | AsyncRedis, key: string, start: string, stop: string,
               withScores: bool = false): Future[RedisList] {.multisync.} =
  ## Return a range of members in a sorted set, by index,
  ## with scores ordered from high to low
  if withScores:
    await r.sendCommand("ZREVRANGE", key, @[start, stop, "WITHSCORES"])
  else:
    await r.sendCommand("ZREVRANGE", key, @[start, stop])

  result = await r.readArray()

proc zrevrangebyscore*(r: Redis | AsyncRedis, key: string, min: string, max: string,
                   withScores: bool = false, limit: bool = false,
                   limitOffset: int = 0, limitCount: int = 0): Future[RedisList] {.multisync.} =
  ## Return a range of members in a sorted set, by score, with
  ## scores ordered from high to low
  var args = newSeqOfCap[string](3 + (if withScores: 1 else: 0) + (if limit: 3 else: 0))
  args.add(key)
  args.add(min)
  args.add(max)

  if withScores: args.add("WITHSCORES")
  if limit:
    args.add("LIMIT")
    args.add($limitOffset)
    args.add($limitCount)

  await r.sendCommand("ZREVRANGEBYSCORE", args)
  result = await r.readArray()

proc zrevrank*(r: Redis | AsyncRedis, key: string, member: string): Future[RedisString] {.multisync.} =
  ## Determine the index of a member in a sorted set, with
  ## scores ordered from high to low
  await r.sendCommand("ZREVRANK", key, @[member])
  try:
    result = $(await r.readInteger())
  except ReplyError:
    result = redisNil

proc zscore*(r: Redis | AsyncRedis, key: string, member: string): Future[RedisString] {.multisync.} =
  ## Get the score associated with the given member in a sorted set
  await r.sendCommand("ZSCORE", key, @[member])
  result = await r.readBulkString()

proc zunionstore*(r: Redis | AsyncRedis, destination: string, numkeys: string,
                 keys: seq[string], weights: seq[string] = @[],
                 aggregate: string = ""): Future[RedisInteger] {.multisync.} =
  ## Add multiple sorted sets and store the resulting sorted set in a new key
  var args = newSeqOfCap[string](2 + len(keys) + (if len(weights) > 0: 1 + len(weights) else: 0) + (if len(aggregate) > 0: 1 + len(aggregate) else: 0))
  args.add(destination)
  args.add(numkeys)

  for i in items(keys):
    args.add(i)

  if weights.len != 0:
    args.add("WEIGHTS")
    for i in items(weights): args.add(i)

  if aggregate.len != 0:
    args.add("AGGREGATE")
    args.add(aggregate)

  await r.sendCommand("ZUNIONSTORE", args)

  result = await r.readInteger()

proc zmscore*(r: Redis | AsyncRedis, key: string, members: seq[string]): Future[seq[Option[float]]] {.multisync.} =
  ## Returns the scores associated with the specified members in a sorted set (Redis 6.2+)
  await r.sendCommand("ZMSCORE", key, members)
  let reply = await r.readResp()
  finaliseCommand(r)
  if reply.kind == respError:
    raiseRedisError(r, reply.value)
  result = @[]
  if reply.kind == respArray:
    for elem in reply.elements:
      if elem.kind == respNilBulk or elem.kind == respNilArray:
        result.add(none(float))
      else:
        result.add(some(parseFloat(elem.value)))

proc zpopmin*(r: Redis | AsyncRedis, key: string, count: int = 1): Future[seq[tuple[member: string, score: float]]] {.multisync.} =
  ## Remove and return members with the lowest scores in a sorted set (Redis 5.0+)
  await r.sendCommand("ZPOPMIN", key, @[$count])
  let reply = await r.readResp()
  finaliseCommand(r)
  if reply.kind == respError:
    raiseRedisError(r, reply.value)
  result = @[]
  if reply.kind == respArray:
    for i in countup(0, reply.elements.len - 1, 2):
      if i + 1 < reply.elements.len:
        result.add((reply.elements[i].value, parseFloat(reply.elements[i+1].value)))

proc zpopmax*(r: Redis | AsyncRedis, key: string, count: int = 1): Future[seq[tuple[member: string, score: float]]] {.multisync.} =
  ## Remove and return members with the highest scores in a sorted set (Redis 5.0+)
  await r.sendCommand("ZPOPMAX", key, @[$count])
  let reply = await r.readResp()
  finaliseCommand(r)
  if reply.kind == respError:
    raiseRedisError(r, reply.value)
  result = @[]
  if reply.kind == respArray:
    for i in countup(0, reply.elements.len - 1, 2):
      if i + 1 < reply.elements.len:
        result.add((reply.elements[i].value, parseFloat(reply.elements[i+1].value)))

proc bzpopmin*(r: Redis | AsyncRedis, keys: seq[string], timeout: int = 0): Future[Option[tuple[key, member: string, score: float]]] {.multisync.} =
  ## Blocking pop of member with lowest score across sorted sets (Redis 5.0+)
  var args = keys
  args.add($timeout)
  await r.sendCommand("BZPOPMIN", args)
  let reply = await r.readResp()
  finaliseCommand(r)
  if reply.kind == respError:
    raiseRedisError(r, reply.value)
  if reply.kind == respArray and reply.elements.len >= 3:
    result = some((reply.elements[0].value, reply.elements[1].value, parseFloat(reply.elements[2].value)))
  else:
    result = none(tuple[key, member: string, score: float])

proc bzpopmax*(r: Redis | AsyncRedis, keys: seq[string], timeout: int = 0): Future[Option[tuple[key, member: string, score: float]]] {.multisync.} =
  ## Blocking pop of member with highest score across sorted sets (Redis 5.0+)
  var args = keys
  args.add($timeout)
  await r.sendCommand("BZPOPMAX", args)
  let reply = await r.readResp()
  finaliseCommand(r)
  if reply.kind == respError:
    raiseRedisError(r, reply.value)
  if reply.kind == respArray and reply.elements.len >= 3:
    result = some((reply.elements[0].value, reply.elements[1].value, parseFloat(reply.elements[2].value)))
  else:
    result = none(tuple[key, member: string, score: float])

proc zrandmember*(r: Redis | AsyncRedis, key: string, count: int = 1): Future[seq[string]] {.multisync.} =
  ## Return random members from a sorted set (Redis 6.2+)
  await r.sendCommand("ZRANDMEMBER", key, @[$count])
  result = await r.readArray()

proc zdiff*(r: Redis | AsyncRedis, keys: seq[string], withScores: bool = false): Future[RedisList] {.multisync.} =
  ## Return the difference between multiple sorted sets (Redis 6.2+)
  var args: seq[string] = @[$keys.len]
  for k in keys: args.add(k)
  if withScores: args.add("WITHSCORES")
  await r.sendCommand("ZDIFF", args)
  result = await r.readArray()

proc zdiff*(r: Redis, keys: openArray[string], withScores: bool = false): RedisList =
  var kSeq: seq[string] = @[]
  for k in keys: kSeq.add(k)
  result = r.zdiff(kSeq, withScores)

proc zdiff*(r: AsyncRedis, keys: openArray[string], withScores: bool = false): Future[RedisList] =
  var kSeq: seq[string] = @[]
  for k in keys: kSeq.add(k)
  result = r.zdiff(kSeq, withScores)

proc zdiffstore*(r: Redis | AsyncRedis, destination: string, keys: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Store the difference between multiple sorted sets in a destination key (Redis 6.2+)
  var args: seq[string] = @[destination, $keys.len]
  for k in keys: args.add(k)
  await r.sendCommand("ZDIFFSTORE", args)
  result = await r.readInteger()

proc zdiffstore*(r: Redis, destination: string, keys: openArray[string]): RedisInteger =
  var kSeq: seq[string] = @[]
  for k in keys: kSeq.add(k)
  result = r.zdiffstore(destination, kSeq)

proc zdiffstore*(r: AsyncRedis, destination: string, keys: openArray[string]): Future[RedisInteger] =
  var kSeq: seq[string] = @[]
  for k in keys: kSeq.add(k)
  result = r.zdiffstore(destination, kSeq)

proc zinter*(r: Redis | AsyncRedis, keys: seq[string], withScores: bool = false): Future[RedisList] {.multisync.} =
  ## Return the intersection of multiple sorted sets (Redis 6.2+)
  var args: seq[string] = @[$keys.len]
  for k in keys: args.add(k)
  if withScores: args.add("WITHSCORES")
  await r.sendCommand("ZINTER", args)
  result = await r.readArray()

proc zinter*(r: Redis, keys: openArray[string], withScores: bool = false): RedisList =
  var kSeq: seq[string] = @[]
  for k in keys: kSeq.add(k)
  result = r.zinter(kSeq, withScores)

proc zinter*(r: AsyncRedis, keys: openArray[string], withScores: bool = false): Future[RedisList] =
  var kSeq: seq[string] = @[]
  for k in keys: kSeq.add(k)
  result = r.zinter(kSeq, withScores)

proc zunion*(r: Redis | AsyncRedis, keys: seq[string], withScores: bool = false): Future[RedisList] {.multisync.} =
  ## Return the union of multiple sorted sets (Redis 6.2+)
  var args: seq[string] = @[$keys.len]
  for k in keys: args.add(k)
  if withScores: args.add("WITHSCORES")
  await r.sendCommand("ZUNION", args)
  result = await r.readArray()

proc zunion*(r: Redis, keys: openArray[string], withScores: bool = false): RedisList =
  var kSeq: seq[string] = @[]
  for k in keys: kSeq.add(k)
  result = r.zunion(kSeq, withScores)

proc zunion*(r: AsyncRedis, keys: openArray[string], withScores: bool = false): Future[RedisList] =
  var kSeq: seq[string] = @[]
  for k in keys: kSeq.add(k)
  result = r.zunion(kSeq, withScores)

# HyperLogLog

proc pfadd*(r: Redis | AsyncRedis, key: string, elements: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Add variable number of elements into special 'HyperLogLog' set type
  await r.sendCommand("PFADD", key, elements)
  result = await r.readInteger()

proc pfcount*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Count approximate number of elements in 'HyperLogLog'
  await r.sendCommand("PFCOUNT", key)
  result = await r.readInteger()

proc pfcount*(r: Redis | AsyncRedis, keys: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Count approximate number of elements in 'HyperLogLog'
  await r.sendCommand("PFCOUNT", keys)
  result = await r.readInteger()

proc pfmerge*(r: Redis | AsyncRedis, destination: string, sources: seq[string]): Future[void] {.multisync.} =
  ## Merge several source HyperLogLog's into one specified by destKey
  await r.sendCommand("PFMERGE", destination, sources)
  raiseNoOK(r, await r.readStatus())

# Pub/Sub

# proc psubscribe*(r: Redis, pattern: openarray[string]): ???? =
#   ## Listen for messages published to channels matching the given patterns
#   r.socket.send("PSUBSCRIBE $#\c\L" % pattern)
#   return ???

proc publish*(r: Redis | AsyncRedis, channel: string, message: string): Future[RedisInteger] {.multisync.} =
  ## Post a message to a channel
  await r.sendCommand("PUBLISH", channel, @[message])
  result = await r.readInteger()

# proc punsubscribe*(r: Redis, [pattern: openarray[string], : string): ???? =
#   ## Stop listening for messages posted to channels matching the given patterns
#   r.socket.send("PUNSUBSCRIBE $# $#\c\L" % [[pattern.join(), ])
#   return ???

proc subscribe*(r: AsyncRedis, channel: string) {.async.} =
  ## Listen for messages published to the given channel
  await r.sendCommand("SUBSCRIBE", @[channel])
  let commandback = await r.readNext()
  finaliseCommand(r)

proc subscribe*(r: AsyncRedis, channels: seq[string]) {.async.} =
  ## Listen for messages published to the given channels
  await r.sendCommand("SUBSCRIBE", channels)
  for c in channels:
    let commandback = await r.readNext()
  finaliseCommand(r)

proc unsubscribe*(r: AsyncRedis, channel: string) {.async.} =
  ## Stop listening for messages posted to the given channel
  await r.sendCommand("UNSUBSCRIBE", @[channel])
  let commandback = await r.readNext()
  finaliseCommand(r)

proc unsubscribe*(r: AsyncRedis, channels: seq[string] = @[]) {.async.} =
  ## Stop listening for messages posted to the given channels (or all channels if empty)
  if channels.len == 0:
    await r.sendCommand("UNSUBSCRIBE")
    let commandback = await r.readNext()
    finaliseCommand(r)
  else:
    await r.sendCommand("UNSUBSCRIBE", channels)
    for c in channels:
      let commandback = await r.readNext()
    finaliseCommand(r)

proc nextMessage*(r: AsyncRedis): Future[RedisMessage] {.async.} =
  let msg = await r.readNext()
  assert msg[0] == "message"
  result = RedisMessage()
  result.channel = msg[1]
  result.message = msg[2]

# Transactions

proc discardMulti*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Discard all commands issued after MULTI
  await r.sendCommand("DISCARD")
  raiseNoOK(r, await r.readStatus())

proc exec*(r: Redis | AsyncRedis): Future[RedisList] {.multisync.} =
  ## Execute all commands issued after MULTI
  await r.sendCommand("EXEC")
  r.pipeline.enabled = false
  # Will reply with +OK for MULTI/EXEC and +QUEUED for every command
  # between, then with the results
  result = await r.flushPipeline(true)

proc execValues*(r: Redis | AsyncRedis): Future[seq[RedisValue]] {.multisync.} =
  ## Execute all commands issued after MULTI and return results as a sequence of RedisValue,
  ## preserving 1:1 positional integrity with the queued commands.
  await r.sendCommand("EXEC")
  r.pipeline.enabled = false
  result = await r.flushPipelineValues(true)

proc multi*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Mark the start of a transaction block
  r.startPipelining()
  await r.sendCommand("MULTI")
  raiseNoOK(r, await r.readStatus())

proc unwatch*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Forget about all watched keys
  await r.sendCommand("UNWATCH")
  raiseNoOK(r, await r.readStatus())

proc watch*(r: Redis | AsyncRedis, key: seq[string]): Future[void] {.multisync.} =
  ## Watch the given keys to determine execution of the MULTI/EXEC block
  await r.sendCommand("WATCH", key)
  raiseNoOK(r, await r.readStatus())

# Connection

proc auth*(r: Redis | AsyncRedis, password: string): Future[void] {.multisync.} =
  ## Authenticate to the server
  await r.sendCommand("AUTH", password)
  raiseNoOK(r, await r.readStatus())

proc auth*(r: Redis | AsyncRedis, username: string, password: string): Future[void] {.multisync.} =
  ## Authenticate to a server that uses Redis ACLs
  await r.sendCommand("AUTH", @[username, password])
  raiseNoOK(r, await r.readStatus())

proc echoServ*(r: Redis | AsyncRedis, message: string): Future[RedisString] {.multisync.} =
  ## Echo the given string
  await r.sendCommand("ECHO", message)
  result = await r.readBulkString()

proc ping*(r: Redis | AsyncRedis): Future[RedisStatus] {.multisync.} =
  ## Ping the server
  await r.sendCommand("PING")
  result = await r.readStatus()

proc ping*(r: Redis | AsyncRedis, message: string): Future[RedisString] {.multisync.} =
  ## Ping the server with a custom message. Returns the message.
  await r.sendCommand("PING", message)
  result = await r.readBulkString()

proc hello*(r: Redis | AsyncRedis, protover: int = 2): Future[RedisValue] {.multisync.} =
  ## Switch protocol or handshake with Redis 6+.
  await r.sendCommand("HELLO", @[$protover])
  result = await r.readValue()

proc close*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Close the connection
  r.socket.close()

proc quit*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Close the connection with using QUIT command
  ## Note: This command is regarded as deprecated since Redis version 7.2.0.
  await r.sendCommand("QUIT")
  raiseNoOK(r, await r.readStatus())
  r.socket.close()

proc select*(r: Redis | AsyncRedis, index: int): Future[RedisStatus] {.multisync.} =
  ## Change the selected database for the current connection
  await r.sendCommand("SELECT", $index)
  result = await r.readStatus()

# Server

proc bgrewriteaof*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Asynchronously rewrite the append-only file
  await r.sendCommand("BGREWRITEAOF")
  raiseNoOK(r, await r.readStatus())

proc bgsave*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Asynchronously save the dataset to disk
  await r.sendCommand("BGSAVE")
  raiseNoOK(r, await r.readStatus())

proc configGet*(r: Redis | AsyncRedis, parameter: string): Future[RedisList] {.multisync.} =
  ## Get the value of a configuration parameter
  await r.sendCommand("CONFIG", "GET", @[parameter])
  result = await r.readArray()

proc configSet*(r: Redis | AsyncRedis, parameter: string, value: string): Future[void] {.multisync.} =
  ## Set a configuration parameter to the given value
  await r.sendCommand("CONFIG", "SET", @[parameter, value])
  raiseNoOK(r, await r.readStatus())

proc configResetStat*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Reset the stats returned by INFO
  await r.sendCommand("CONFIG", "RESETSTAT")
  raiseNoOK(r, await r.readStatus())

proc dbsize*(r: Redis | AsyncRedis): Future[RedisInteger] {.multisync.} =
  ## Return the number of keys in the selected database
  await r.sendCommand("DBSIZE")
  result = await r.readInteger()

proc debugObject*(r: Redis | AsyncRedis, key: string): Future[RedisStatus] {.multisync.} =
  ## Get debugging information about a key
  await r.sendCommand("DEBUG", "OBJECT", @[key])
  result = await r.readStatus()

proc debugSegfault*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Make the server crash
  await r.sendCommand("DEBUG", "SEGFAULT")

proc flushall*(r: Redis | AsyncRedis): Future[RedisStatus] {.multisync.} =
  ## Remove all keys from all databases
  await r.sendCommand("FLUSHALL")
  raiseNoOK(r, await r.readStatus())

proc flushdb*(r: Redis | AsyncRedis): Future[RedisStatus] {.multisync.} =
  ## Remove all keys from the current database
  await r.sendCommand("FLUSHDB")
  raiseNoOK(r, await r.readStatus())

proc info*(r: Redis | AsyncRedis): Future[RedisString] {.multisync.} =
  ## Get information and statistics about the server
  await r.sendCommand("INFO")
  result = await r.readBulkString()

proc lastsave*(r: Redis | AsyncRedis): Future[RedisInteger] {.multisync.} =
  ## Get the UNIX time stamp of the last successful save to disk
  await r.sendCommand("LASTSAVE")
  result = await r.readInteger()

discard """
proc monitor*(r: Redis) =
  ## Listen for all requests received by the server in real time
  r.socket.send("MONITOR\c\L")
  raiseNoOK(r.readStatus(), r.pipeline.enabled)
"""

proc save*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Synchronously save the dataset to disk
  await r.sendCommand("SAVE")
  raiseNoOK(r, await r.readStatus())

proc shutdown*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Synchronously save the dataset to disk and then shut down the server
  await r.sendCommand("SHUTDOWN")

  when r is Redis:
    let s = recvLine(r.socket)
    if len(s) != 0:
      raiseRedisError(r, s)
  else:
    # Read the socket directly: an empty line (EOF) is the expected
    # outcome of SHUTDOWN, not an error.
    let s = await recvLine(r.socket)
    if len(s) != 0:
      raiseRedisError(r, s)
    finaliseCommand(r)

proc slaveof*(r: Redis | AsyncRedis, host: string, port: string): Future[void] {.multisync.} =
  ## Make the server a slave of another instance, or promote it as master
  await r.sendCommand("SLAVEOF", host, @[port])
  raiseNoOK(r, await r.readStatus())

iterator hPairs*(r: Redis, key: string): tuple[key, value: string] =
  ## Iterator for keys and values in a hash.
  let contents = r.hGetAll(key)
  for i in countup(0, contents.len - 1, 2):
    if i + 1 < contents.len:
      yield (contents[i], contents[i+1])

proc hPairs*(r: AsyncRedis, key: string): Future[seq[tuple[key, value: string]]] {.async.} =
  let contents = await r.hGetAll(key)
  result = @[]
  for i in countup(0, contents.len - 1, 2):
    if i + 1 < contents.len:
      result.add((contents[i], contents[i+1]))

# Scripting

proc eval*(r: Redis | AsyncRedis, script: string, keys: seq[string] = @[], args: seq[string] = @[]): Future[RedisValue] {.multisync.} =
  ## Execute a Lua script server-side using EVAL.
  var cmdArgs: seq[string] = @[script, $keys.len]
  for k in keys:
    cmdArgs.add(k)
  for a in args:
    cmdArgs.add(a)
  await r.sendCommand("EVAL", cmdArgs)
  result = await r.readValue()

proc evalSha*(r: Redis | AsyncRedis, sha: string, keys: seq[string] = @[], args: seq[string] = @[]): Future[RedisValue] {.multisync.} =
  ## Execute a cached Lua script server-side using its SHA1 digest via EVALSHA.
  var cmdArgs: seq[string] = @[sha, $keys.len]
  for k in keys:
    cmdArgs.add(k)
  for a in args:
    cmdArgs.add(a)
  await r.sendCommand("EVALSHA", cmdArgs)
  result = await r.readValue()

proc evalInt*(r: Redis | AsyncRedis, script: string, keys: seq[string] = @[], args: seq[string] = @[]): Future[BiggestInt] {.multisync.} =
  ## Convenience helper to execute a Lua script and return the result as an integer.
  let val = await r.eval(script, keys, args)
  result = val.toInt()

proc evalString*(r: Redis | AsyncRedis, script: string, keys: seq[string] = @[], args: seq[string] = @[]): Future[string] {.multisync.} =
  ## Convenience helper to execute a Lua script and return the result as a string.
  let val = await r.eval(script, keys, args)
  result = val.toStr()

proc evalList*(r: Redis | AsyncRedis, script: string, keys: seq[string] = @[], args: seq[string] = @[]): Future[seq[RedisValue]] {.multisync.} =
  ## Convenience helper to execute a Lua script and return the result as a list of RedisValues.
  let val = await r.eval(script, keys, args)
  result = val.toSeq()

proc scriptLoad*(r: Redis | AsyncRedis, script: string): Future[string] {.multisync.} =
  ## Load a script into the scripts cache without executing it. Returns the SHA1 digest.
  await r.sendCommand("SCRIPT", @["LOAD", script])
  result = await r.readBulkString()

proc scriptExists*(r: Redis | AsyncRedis, shas: seq[string]): Future[seq[bool]] {.multisync.} =
  ## Check existence of scripts in the script cache by their SHA1 digests.
  if shas.len == 0:
    return @[]
  var args: seq[string] = @["EXISTS"]
  for s in shas:
    args.add(s)
  await r.sendCommand("SCRIPT", args)
  let rawList = await r.readArray()
  result = @[]
  for item in rawList:
    result.add(item == "1")

proc scriptExists*(r: Redis, shas: openArray[string]): seq[bool] =
  ## Check existence of scripts in the script cache by their SHA1 digests.
  var sSeq: seq[string] = @[]
  for s in shas: sSeq.add(s)
  result = r.scriptExists(sSeq)

proc scriptExists*(r: AsyncRedis, shas: openArray[string]): Future[seq[bool]] =
  ## Check existence of scripts in the script cache by their SHA1 digests.
  var sSeq: seq[string] = @[]
  for s in shas: sSeq.add(s)
  result = r.scriptExists(sSeq)

proc scriptFlush*(r: Redis | AsyncRedis, async = false): Future[RedisStatus] {.multisync.} =
  ## Flush the Lua scripts cache.
  if async:
    await r.sendCommand("SCRIPT", @["FLUSH", "ASYNC"])
  else:
    await r.sendCommand("SCRIPT", @["FLUSH"])
  result = await r.readStatus()

proc scriptKill*(r: Redis | AsyncRedis): Future[RedisStatus] {.multisync.} =
  ## Kill the currently executing Lua script.
  await r.sendCommand("SCRIPT", @["KILL"])
  result = await r.readStatus()

# Raw command execution

proc rawCommand*(r: Redis | AsyncRedis, cmd: string, args: seq[string]): Future[RedisValue] {.multisync.} =
  ## Execute an arbitrary Redis command with arguments and return a dynamic RedisValue.
  await r.sendCommand(cmd, args)
  result = await r.readValue()

proc rawCommand*(r: Redis, cmd: string, args: varargs[string]): RedisValue =
  ## Execute an arbitrary Redis command with varargs arguments and return a dynamic RedisValue.
  var argSeq: seq[string] = @[]
  for a in args:
    argSeq.add(a)
  result = r.rawCommand(cmd, argSeq)

proc rawCommand*(r: AsyncRedis, cmd: string, args: varargs[string]): Future[RedisValue] =
  ## Execute an arbitrary Redis command with varargs arguments and return a dynamic RedisValue.
  var argSeq: seq[string] = @[]
  for a in args:
    argSeq.add(a)
  result = r.rawCommand(cmd, argSeq)

# Cursor Scanning & Iterators

proc scan*(r: Redis | AsyncRedis, cursor: int, pattern = "*", count = 10, keyType = ""): Future[tuple[cursor: int, keys: seq[string]]] {.multisync.} =
  ## Incrementally iterate the keys space using SCAN.
  var args: seq[string] = @[$cursor]
  if pattern != "*":
    args.add("MATCH")
    args.add(pattern)
  if count != 10:
    args.add("COUNT")
    args.add($count)
  if keyType.len > 0:
    args.add("TYPE")
    args.add(keyType)
  await r.sendCommand("SCAN", args)
  let reply = await r.readResp()
  if reply.kind == respError:
    raiseRedisError(r, reply.value)
  finaliseCommand(r)
  result.cursor = 0
  result.keys = @[]
  if reply.kind == respArray and reply.elements.len >= 2:
    result.cursor = parseInt(reply.elements[0].value)
    if reply.elements[1].kind == respArray:
      for e in reply.elements[1].elements:
        result.keys.add(e.value)

proc hscan*(r: Redis | AsyncRedis, key: string, cursor: int, pattern = "*", count = 10): Future[tuple[cursor: int, pairs: seq[tuple[field, value: string]]]] {.multisync.} =
  ## Incrementally iterate fields and values of a hash using HSCAN.
  var args: seq[string] = @[$cursor]
  if pattern != "*":
    args.add("MATCH")
    args.add(pattern)
  if count != 10:
    args.add("COUNT")
    args.add($count)
  await r.sendCommand("HSCAN", key, args)
  let reply = await r.readResp()
  if reply.kind == respError:
    raiseRedisError(r, reply.value)
  finaliseCommand(r)
  result.cursor = 0
  result.pairs = @[]
  if reply.kind == respArray and reply.elements.len >= 2:
    result.cursor = parseInt(reply.elements[0].value)
    if reply.elements[1].kind == respArray:
      let elems = reply.elements[1].elements
      for i in countup(0, elems.len - 1, 2):
        if i + 1 < elems.len:
          result.pairs.add((elems[i].value, elems[i+1].value))

proc sscan*(r: Redis | AsyncRedis, key: string, cursor: int, pattern = "*", count = 10): Future[tuple[cursor: int, members: seq[string]]] {.multisync.} =
  ## Incrementally iterate elements of a set using SSCAN.
  var args: seq[string] = @[$cursor]
  if pattern != "*":
    args.add("MATCH")
    args.add(pattern)
  if count != 10:
    args.add("COUNT")
    args.add($count)
  await r.sendCommand("SSCAN", key, args)
  let reply = await r.readResp()
  if reply.kind == respError:
    raiseRedisError(r, reply.value)
  finaliseCommand(r)
  result.cursor = 0
  result.members = @[]
  if reply.kind == respArray and reply.elements.len >= 2:
    result.cursor = parseInt(reply.elements[0].value)
    if reply.elements[1].kind == respArray:
      for e in reply.elements[1].elements:
        result.members.add(e.value)

proc zscan*(r: Redis | AsyncRedis, key: string, cursor: int, pattern = "*", count = 10): Future[tuple[cursor: int, entries: seq[tuple[member: string, score: float]]]] {.multisync.} =
  ## Incrementally iterate elements of a sorted set using ZSCAN.
  var args: seq[string] = @[$cursor]
  if pattern != "*":
    args.add("MATCH")
    args.add(pattern)
  if count != 10:
    args.add("COUNT")
    args.add($count)
  await r.sendCommand("ZSCAN", key, args)
  let reply = await r.readResp()
  if reply.kind == respError:
    raiseRedisError(r, reply.value)
  finaliseCommand(r)
  result.cursor = 0
  result.entries = @[]
  if reply.kind == respArray and reply.elements.len >= 2:
    result.cursor = parseInt(reply.elements[0].value)
    if reply.elements[1].kind == respArray:
      let elems = reply.elements[1].elements
      for i in countup(0, elems.len - 1, 2):
        if i + 1 < elems.len:
          result.entries.add((elems[i].value, parseFloat(elems[i+1].value)))

# Sync iterators
iterator scan*(r: Redis, pattern = "*", count = 10, keyType = ""): string =
  ## Synchronous iterator to yield keys one by one using SCAN.
  var cursor = 0
  var first = true
  while first or cursor != 0:
    first = false
    let batch = r.scan(cursor, pattern, count, keyType)
    cursor = batch.cursor
    for k in batch.keys:
      yield k

iterator hscan*(r: Redis, key: string, pattern = "*", count = 10): tuple[field, value: string] =
  ## Synchronous iterator to yield hash field-value pairs using HSCAN.
  var cursor = 0
  var first = true
  while first or cursor != 0:
    first = false
    let batch = r.hscan(key, cursor, pattern, count)
    cursor = batch.cursor
    for p in batch.pairs:
      yield p

iterator sscan*(r: Redis, key: string, pattern = "*", count = 10): string =
  ## Synchronous iterator to yield set members using SSCAN.
  var cursor = 0
  var first = true
  while first or cursor != 0:
    first = false
    let batch = r.sscan(key, cursor, pattern, count)
    cursor = batch.cursor
    for m in batch.members:
      yield m

iterator zscan*(r: Redis, key: string, pattern = "*", count = 10): tuple[member: string, score: float] =
  ## Synchronous iterator to yield sorted set member-score pairs using ZSCAN.
  var cursor = 0
  var first = true
  while first or cursor != 0:
    first = false
    let batch = r.zscan(key, cursor, pattern, count)
    cursor = batch.cursor
    for e in batch.entries:
      yield e

# Async collectors
proc scanAll*(r: AsyncRedis, pattern = "*", count = 100, keyType = ""): Future[seq[string]] {.async.} =
  ## Collect all matching keys using asynchronous SCAN pagination.
  ##
  ## **WARNING:** Buffers the entire matching keyspace into memory.
  ## For very large datasets, use cursor-based `scan(cursor)` pagination instead.
  var cursor = 0
  var first = true
  result = @[]
  while first or cursor != 0:
    first = false
    let batch = await r.scan(cursor, pattern, count, keyType)
    cursor = batch.cursor
    result.add(batch.keys)

proc hscanAll*(r: AsyncRedis, key: string, pattern = "*", count = 100): Future[seq[tuple[field, value: string]]] {.async.} =
  ## Collect all field-value pairs using asynchronous HSCAN pagination.
  ##
  ## **WARNING:** Buffers the entire hash into memory.
  ## For very large hashes, use cursor-based `hscan(key, cursor)` pagination instead.
  var cursor = 0
  var first = true
  result = @[]
  while first or cursor != 0:
    first = false
    let batch = await r.hscan(key, cursor, pattern, count)
    cursor = batch.cursor
    result.add(batch.pairs)

proc sscanAll*(r: AsyncRedis, key: string, pattern = "*", count = 100): Future[seq[string]] {.async.} =
  ## Collect all set members using asynchronous SSCAN pagination.
  ##
  ## **WARNING:** Buffers the entire set into memory.
  ## For very large sets, use cursor-based `sscan(key, cursor)` pagination instead.
  var cursor = 0
  var first = true
  result = @[]
  while first or cursor != 0:
    first = false
    let batch = await r.sscan(key, cursor, pattern, count)
    cursor = batch.cursor
    result.add(batch.members)

proc zscanAll*(r: AsyncRedis, key: string, pattern = "*", count = 100): Future[seq[tuple[member: string, score: float]]] {.async.} =
  ## Collect all sorted set member-score pairs using asynchronous ZSCAN pagination.
  ##
  ## **WARNING:** Buffers the entire sorted set into memory.
  ## For very large sets, use cursor-based `zscan(key, cursor)` pagination instead.
  var cursor = 0
  var first = true
  result = @[]
  while first or cursor != 0:
    first = false
    let batch = await r.zscan(key, cursor, pattern, count)
    cursor = batch.cursor
    result.add(batch.entries)

type
  SendMode = enum
    normal, pipelined, multiple

proc someTests(r: Redis | AsyncRedis, how: SendMode): Future[seq[string]] {.multisync.} =
  var list: seq[string] = @[]

  if how == pipelined:
    r.startPipelining()
  elif how == multiple:
    await r.multi()

  await r.setk("nim:test", "Testing something.")
  await r.setk("nim:utf8", "こんにちは")
  await r.setk("nim:esc", "\\ths ągt\\")
  await r.setk("nim:int", "1")
  list.add(await r.get("nim:esc"))
  list.add($(await r.incr("nim:int")))
  list.add(await r.get("nim:int"))
  list.add(await r.get("nim:utf8"))
  list.add($(await r.hSet("test1", "name", "A Test")))
  var res = await r.hGetAll("test1")
  for r in res:
    list.add(r)
  list.add(await r.get("invalid_key"))
  list.add($(await r.lPush("mylist","itema")))
  list.add($(await r.lPush("mylist","itemb")))
  await r.lTrim("mylist",0,1)
  var p = await r.lRange("mylist", 0, -1)

  for i in items(p):
    if i.len > 0:
      list.add(i)

  list.add(await r.debugObject("mylist"))

  await r.configSet("timeout", "299")
  var g = await r.configGet("timeout")
  for i in items(g):
    list.add(i)

  list.add(await r.echoServ("BLAH"))

  case how
  of normal:
    return list
  of pipelined:
    return await r.flushPipeline()
  of multiple:
    return await r.exec()

proc assertListsIdentical(listA, listB: seq[string]) =
  assert(listA.len == listB.len)
  var i = 0
  for item in listA:
    assert(item == listB[i])
    i = i + 1

when defined(testing) and not defined(testasync) and isMainModule:
  echo "Testing sync redis client"

  let r = open()

  # Test with no pipelining
  var listNormal = r.someTests(normal)

  # Test with pipelining enabled
  var listPipelined = r.someTests(pipelined)
  assertListsIdentical(listNormal, listPipelined)

  # Test with multi/exec() (automatic pipelining)
  var listMulti = r.someTests(multiple)
  assertListsIdentical(listNormal, listMulti)

  echo "Normal: ", listNormal
  echo "Pipelined: ", listPipelined
  echo "Multi: ", listMulti
elif defined(testing) and defined(testasync) and isMainModule:
  proc mainAsync(): Future[void] {.async.} =
    echo "Testing async redis client"

    let r = await openAsync()

    ## Set the key `nim_redis:test` to the value `Hello, World`
    await r.setk("nim_redis:test", "Hello, World")

    ## Get the value of the key `nim_redis:test`
    let value = await r.get("nim_redis:test")

    assert(value == "Hello, World")

    # Test with no pipelining
    var listNormal = await r.someTests(normal)

    # Test with pipelining enabled
    var listPipelined = await r.someTests(pipelined)
    assertListsIdentical(listNormal, listPipelined)

    # Test with multi/exec() (automatic pipelining)
    var listMulti = await r.someTests(multiple)
    assertListsIdentical(listNormal, listMulti)

    echo "Normal: ", listNormal
    echo "Pipelined: ", listPipelined
    echo "Multi: ", listMulti

  waitFor mainAsync()
