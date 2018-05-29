# This file demonstrates the issues that was reported in
# https://github.com/nim-lang/redis/issues/6

import asyncnet, asyncdispatch, strutils, strformat

proc echoClient(c: AsyncSocket) {.async.} =
  while true:
    var line = await c.recvLine()
    echo("Client: ", line)
    await c.send($line.len & "\c\l")
    await c.send(line & "\c\l")

proc echoServer() {.async.} =
  var server = newAsyncSocket()
  server.setSockOpt(OptReuseAddr, true)

  server.bindAddr(5312.Port)
  server.listen()

  while true:
    let c = await accept(server)
    asyncCheck echoClient(c)

proc command(client: AsyncSocket, text: string): Future[string] {.async.} =
  await client.send(text & "\c\l")

  let countStr = await client.recvLine()
  echo(fmt"{text}: count of {countStr}")
  let count = parseInt(countStr)
  result = newString(count+2)
  let len = await client.recvInto(addr result[0], count+2)
  doAssert len == count
  doAssert result == text
  echo("Recv: ", result)

proc main() {.async.} =
  asyncCheck echoServer()

  let client = newAsyncSocket()
  await client.connect("localhost", 5312.Port)

  for i in 0..50:
    asyncCheck command(client, "Foo" & $i)

asyncCheck main()

runForever()