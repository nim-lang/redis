import redis, unittest, asyncdispatch, os, strutils

proc getClient(): Redis =
  redis.open(getEnv("REDIS_HOST", "localhost"), Port(parseInt(getEnv("REDIS_PORT", "6379"))))

proc getAsyncClient(): Future[AsyncRedis] {.async.} =
  await redis.openAsync(getEnv("REDIS_HOST", "localhost"), Port(parseInt(getEnv("REDIS_PORT", "6379"))))

suite "Redis rawCommand execution (Sync)":
  let r = getClient()
  discard r.flushdb()

  test "rawCommand ping":
    let res = r.rawCommand("PING")
    check res.kind == vkStatus
    check res.strVal == "PONG"
    check res == "PONG"

  test "rawCommand set and get":
    let setRes = r.rawCommand("SET", "test:raw:key", "value123")
    check setRes.kind == vkStatus
    check setRes.strVal == "OK"

    let getRes = r.rawCommand("GET", "test:raw:key")
    check getRes.kind == vkString
    check getRes.strVal == "value123"
    check getRes == "value123"

  test "rawCommand incr and del":
    let incrRes = r.rawCommand("INCR", "test:raw:num")
    check incrRes.kind == vkInteger
    check incrRes.intVal == 1
    check incrRes == 1

    let delRes = r.rawCommand("DEL", "test:raw:key", "test:raw:num")
    check delRes.kind == vkInteger
    check delRes.intVal == 2

  test "rawCommand multi-bulk array":
    r.setk("test:raw:a", "1")
    r.setk("test:raw:b", "2")
    let mgetRes = r.rawCommand("MGET", "test:raw:a", "test:raw:b", "test:raw:c")
    check mgetRes.kind == vkList
    check mgetRes.len == 3
    check mgetRes[0] == "1"
    check mgetRes[1] == "2"
    check mgetRes[2].kind == vkNil

  test "rawCommand seq overload":
    let args: seq[string] = @["test:raw:seq", "hello_seq"]
    let res = r.rawCommand("SET", args)
    check res.strVal == "OK"
    check r.get("test:raw:seq") == "hello_seq"

  discard r.flushdb()
  r.quit()

suite "Redis rawCommand execution (Async)":
  proc runAsyncTests() {.async.} =
    let r = await getAsyncClient()
    discard await r.flushdb()

    let pingRes = await r.rawCommand("PING")
    check pingRes.strVal == "PONG"

    let setRes = await r.rawCommand("SET", "test:async:raw", "val_async")
    check setRes.strVal == "OK"

    let getRes = await r.rawCommand("GET", "test:async:raw")
    check getRes.strVal == "val_async"

    let incrRes = await r.rawCommand("INCR", @["test:async:seq_num"])
    check incrRes.intVal == 1

    discard await r.flushdb()
    await r.quit()

  waitFor runAsyncTests()
