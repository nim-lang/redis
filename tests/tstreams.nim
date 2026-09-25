import unittest, asyncdispatch, strutils, os
import redis

proc getClient(): Redis =
  redis.open(getEnv("REDIS_HOST", "localhost"), Port(parseInt(getEnv("REDIS_PORT", "6379"))))

proc getAsyncClient(): Future[AsyncRedis] {.async.} =
  await redis.openAsync(getEnv("REDIS_HOST", "localhost"), Port(parseInt(getEnv("REDIS_PORT", "6379"))))

suite "Redis Streams (Sync)":
  let r = getClient()
  discard r.flushdb()

  test "xadd with auto-generated id and xlen":
    discard r.del(@["test:stream:1"])
    let id1 = r.xadd("test:stream:1", [("sensor", "temp"), ("val", "21.5")])
    check id1.len > 0
    check '-' in id1

    let id2 = r.xadd("test:stream:1", [("sensor", "temp"), ("val", "22.0")])
    check id2.len > 0
    check id2 > id1

    let length = r.xlen("test:stream:1")
    check length == 2

  test "xadd with explicit id":
    discard r.del(@["test:stream:explicit"])
    let id = r.xadd("test:stream:explicit", "1000-0", [("msg", "first")])
    check id == "1000-0"
    let id2 = r.xadd("test:stream:explicit", "1000-1", [("msg", "second")])
    check id2 == "1000-1"
    check r.xlen("test:stream:explicit") == 2

  test "xrange, xrevrange and StreamEntry field helpers":
    discard r.del(@["test:stream:range"])
    discard r.xadd("test:stream:range", "1-0", [("k1", "v1"), ("k2", "v2")])
    discard r.xadd("test:stream:range", "2-0", [("k1", "v3"), ("k2", "v4")])
    discard r.xadd("test:stream:range", "3-0", [("k1", "v5"), ("k2", "v6")])

    let entries = r.xrange("test:stream:range", "-", "+")
    check entries.len == 3
    check entries[0].id == "1-0"
    check entries[0].hasField("k1")
    check "k1" in entries[0]
    check entries[0].getField("k1") == "v1"
    check entries[0]["k1"] == "v1"
    check entries[0].getField("k2") == "v2"
    check entries[0]["k2"] == "v2"
    check entries[0].hasField("nonexistent") == false
    check "nonexistent" notin entries[0]
    check entries[0].getField("nonexistent") == ""
    check entries[0]["nonexistent"] == ""

    check entries[2].id == "3-0"
    check entries[2].getField("k1") == "v5"

    # Count limit
    let limited = r.xrange("test:stream:range", "-", "+", count = 2)
    check limited.len == 2
    check limited[0].id == "1-0"
    check limited[1].id == "2-0"

    # Reverse range
    let rev = r.xrevrange("test:stream:range", "+", "-", count = 2)
    check rev.len == 2
    check rev[0].id == "3-0"
    check rev[1].id == "2-0"

  test "xtrim with maxLen":
    discard r.del(@["test:stream:trim"])
    for i in 1..10:
      discard r.xadd("test:stream:trim", [("seq", $i)])
    check r.xlen("test:stream:trim") == 10

    let trimmed = r.xtrim("test:stream:trim", 5)
    check trimmed == 5
    check r.xlen("test:stream:trim") == 5

  test "xdel specific ids":
    discard r.del(@["test:stream:del"])
    discard r.xadd("test:stream:del", "10-0", [("item", "a")])
    discard r.xadd("test:stream:del", "20-0", [("item", "b")])
    discard r.xadd("test:stream:del", "30-0", [("item", "c")])

    let deleted = r.xdel("test:stream:del", "20-0")
    check deleted == 1
    check r.xlen("test:stream:del") == 2

    let rangeAfter = r.xrange("test:stream:del", "-", "+")
    check rangeAfter.len == 2
    check rangeAfter[0].id == "10-0"
    check rangeAfter[1].id == "30-0"

  test "xread single and multi-stream":
    discard r.del(@["test:stream:read1", "test:stream:read2"])
    discard r.xadd("test:stream:read1", "1-0", [("src", "s1-e1")])
    discard r.xadd("test:stream:read1", "2-0", [("src", "s1-e2")])
    discard r.xadd("test:stream:read2", "1-0", [("src", "s2-e1")])

    # Single stream read
    let s1Entries = r.xread("test:stream:read1", "0", count = 10)
    check s1Entries.len == 2
    check s1Entries[0].id == "1-0"
    check s1Entries[0].getField("src") == "s1-e1"

    # Multi-stream read
    let results = r.xread([("test:stream:read1", "1-0"), ("test:stream:read2", "0")])
    check results.len == 2
    check results[0].stream == "test:stream:read1"
    check results[0].entries.len == 1
    check results[0].entries[0].id == "2-0"
    check results[1].stream == "test:stream:read2"
    check results[1].entries.len == 1
    check results[1].entries[0].id == "1-0"

  test "readStream synchronous iterator":
    discard r.del(@["test:stream:iter"])
    for i in 1..25:
      discard r.xadd("test:stream:iter", [("num", $i)])

    var collected: seq[string] = @[]
    for entry in r.readStream("test:stream:iter", count = 5):
      collected.add(entry.getField("num"))
    check collected.len == 25
    check collected[0] == "1"
    check collected[24] == "25"

  test "Consumer group lifecycle (xgroupCreate, xreadGroup, xack, xgroupDestroy)":
    discard r.del(@["test:stream:grp"])
    discard r.xadd("test:stream:grp", "1-0", [("task", "clean")])
    discard r.xadd("test:stream:grp", "2-0", [("task", "build")])

    # Create group
    let createStatus = r.xgroupCreate("test:stream:grp", "workers", "0")
    check createStatus == "OK"

    # Read as consumer 1
    let msgs = r.xreadGroup("workers", "c1", "test:stream:grp", id = ">", count = 1)
    check msgs.len == 1
    check msgs[0].id == "1-0"
    check msgs[0].getField("task") == "clean"

    # Ack message
    let acked = r.xack("test:stream:grp", "workers", "1-0")
    check acked == 1

    # Read remaining
    let msgs2 = r.xreadGroup("workers", "c1", "test:stream:grp", id = ">", count = 10)
    check msgs2.len == 1
    check msgs2[0].id == "2-0"
    check msgs2[0].getField("task") == "build"

    # Destroy group
    let destroyed = r.xgroupDestroy("test:stream:grp", "workers")
    check destroyed == 1

  r.quit()

suite "Redis Streams (Async)":
  proc mainAsync() {.async.} =
    let r = await getAsyncClient()
    discard await r.flushdb()

    # Async xadd, xlen, xrange
    discard await r.del(@["test:async:stream"])
    let id1 = await r.xadd("test:async:stream", [("foo", "bar")])
    check id1.len > 0
    let id2 = await r.xadd("test:async:stream", [("foo", "baz")])
    check id2.len > 0
    let streamLen = await r.xlen("test:async:stream")
    check streamLen == 2

    let rangeEntries = await r.xrange("test:async:stream", "-", "+")
    check rangeEntries.len == 2
    check rangeEntries[0].getField("foo") == "bar"
    check rangeEntries[1].getField("foo") == "baz"

    # Async readStreamAll collector
    for i in 3..15:
      discard await r.xadd("test:async:stream", [("idx", $i)])
    let allEntries = await r.readStreamAll("test:async:stream", count = 5)
    check allEntries.len == 15

    # Async consumer group
    let grpStatus = await r.xgroupCreate("test:async:stream", "asyncgrp", "0")
    check grpStatus == "OK"
    let groupMsgs = await r.xreadGroup("asyncgrp", "worker1", "test:async:stream", id = ">", count = 2)
    check groupMsgs.len == 2
    let ackCount = await r.xack("test:async:stream", "asyncgrp", @[groupMsgs[0].id, groupMsgs[1].id])
    check ackCount == 2

    let delGroup = await r.xgroupDestroy("test:async:stream", "asyncgrp")
    check delGroup == 1

    await r.quit()

  test "Async Redis Streams full lifecycle":
    waitFor mainAsync()
