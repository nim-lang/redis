# An error reply must not leave the replies after it on the connection,
# also when the pipeline returns RedisValue results. Each in-process mock
# answers one pipeline with an error before the last reply, then answers
# the next command with a bulk string. Before the fix, the next command
# read a reply that belonged to the pipeline.

import asyncnet, asyncdispatch, strutils, unittest, redis

const
  valuesPort = 5316.Port
  execPort = 5317.Port

var mockServers: seq[AsyncSocket]

proc readRequest(c: AsyncSocket) {.async.} =
  let header = await c.recvLine()
  if header.len > 1 and header[0] == '*':
    for _ in 1 .. 2 * parseInt(header.substr(1)):
      discard await c.recvLine()

proc mockServer(port: Port, requests: int, answer: string) {.async.} =
  let server = newAsyncSocket()
  mockServers.add(server)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(port)
  server.listen()

  while not server.isClosed():
    let c = try:
      await server.accept()
    except CatchableError:
      break
    try:
      for _ in 1 .. requests:
        await c.readRequest()
      await c.send(answer)
      await c.readRequest()
      await c.send("$3\r\nfoo\r\n")
    except CatchableError:
      discard
    c.close()

suite "error reply in a RedisValue pipeline":
  asyncCheck mockServer(valuesPort, 3, "+OK\r\n-ERR mock error\r\n:5\r\n")
  asyncCheck mockServer(execPort, 4,
    "+OK\r\n+QUEUED\r\n-ERR mock error\r\n-EXECABORT mock abort\r\n")

  test "flushPipelineValues: the next command reads its own reply":
    proc run() {.async.} =
      let r = await openAsync("localhost", valuesPort)
      r.startPipelining()
      await r.setk("a", "1")
      discard await r.incr("b")
      discard await r.incr("c")
      try:
        discard await r.flushPipelineValues()
        fail()
      except RedisError as e:
        check e.msg.startsWith("ERR mock error")
      check (await r.get("d")) == "foo"
    waitFor run()

  test "execValues: the next command reads its own reply":
    proc run() {.async.} =
      let r = await openAsync("localhost", execPort)
      await r.multi()
      await r.setk("a", "1")
      discard await r.incr("b")
      try:
        discard await r.execValues()
        fail()
      except RedisError as e:
        check e.msg.startsWith("-ERR mock error")
      check (await r.get("d")) == "foo"
    waitFor run()
