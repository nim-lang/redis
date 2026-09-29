# An error reply in a pipeline must not leave the replies after it on the
# connection. The in-process mock answers a pipeline of three commands
# with "+OK", an error and ":5", then answers the next command with a
# bulk string. Before the fix, the next command read ":5" as its reply.

import asyncnet, asyncdispatch, strutils, unittest, redis

const mockPort = 5315.Port

var mockServer: AsyncSocket

proc readRequest(c: AsyncSocket) {.async.} =
  let header = await c.recvLine()
  if header.len > 1 and header[0] == '*':
    for _ in 1 .. 2 * parseInt(header.substr(1)):
      discard await c.recvLine()

proc mockPipelineServer() {.async.} =
  mockServer = newAsyncSocket()
  mockServer.setSockOpt(OptReuseAddr, true)
  mockServer.bindAddr(mockPort)
  mockServer.listen()

  while not mockServer.isClosed():
    let c = try:
      await mockServer.accept()
    except CatchableError:
      break
    try:
      for _ in 1 .. 3:
        await c.readRequest()
      await c.send("+OK\r\n-ERR mock error\r\n:5\r\n")
      await c.readRequest()
      await c.send("$3\r\nfoo\r\n")
    except CatchableError:
      discard
    c.close()

suite "error reply in a pipeline":
  asyncCheck mockPipelineServer()

  test "the next command reads its own reply":
    proc run() {.async.} =
      let r = await openAsync("localhost", mockPort)
      r.startPipelining()
      await r.setk("a", "1")
      discard await r.incr("b")
      discard await r.incr("c")
      try:
        discard await r.flushPipeline()
        fail()
      except RedisError as e:
        check e.msg.startsWith("-ERR mock error")
      check (await r.get("d")) == "foo"
    waitFor run()
