import unittest, asyncdispatch, options, strutils, os
import redis

proc getClient(): Redis =
  redis.open(getEnv("REDIS_HOST", "localhost"), Port(parseInt(getEnv("REDIS_PORT", "6379"))))

proc getAsyncClient(): Future[AsyncRedis] {.async.} =
  await redis.openAsync(getEnv("REDIS_HOST", "localhost"), Port(parseInt(getEnv("REDIS_PORT", "6379"))))

proc redisVersion(r: Redis): tuple[major, minor: int] =
  for line in r.info().splitLines():
    if line.strip().startsWith("redis_version:"):
      let parts = line.strip().split(':')[1].strip().split('.')
      let maj = if parts.len > 0: (try: parseInt(parts[0]) except ValueError: 0) else: 0
      let min = if parts.len > 1: (try: parseInt(parts[1]) except ValueError: 0) else: 0
      return (maj, min)
  return (0, 0)

template xfailBefore(r: Redis, minMajor, minMinor: int, body: untyped) =
  let v = redisVersion(r)
  let ok = if v.major != minMajor: v.major > minMajor else: v.minor >= minMinor
  if ok:
    body
  else:
    expect RedisError:
      body

suite "Redis Modern Hash and Sorted Set Verbs (Sync)":
  let r = getClient()
  discard r.flushdb()

  test "hSet multi-pair and hDel multi-field":
    discard r.del(@["test:hash:multi"])
    let added = r.hSet("test:hash:multi", [("f1", "v1"), ("f2", "v2"), ("f3", "v3")])
    check added == 3
    check r.hGet("test:hash:multi", "f1") == "v1"
    check r.hGet("test:hash:multi", "f2") == "v2"
    check r.hGet("test:hash:multi", "f3") == "v3"

    let removed = r.hDel("test:hash:multi", @["f1", "f2"])
    check removed == 2
    check r.hExists("test:hash:multi", "f1") == false
    check r.hExists("test:hash:multi", "f3") == true

  test "hStrLen":
    discard r.del(@["test:hash:strlen"])
    discard r.hSet("test:hash:strlen", "msg", "hello world")
    check r.hStrLen("test:hash:strlen", "msg") == 11

  test "hRandField (Redis 6.2+)":
    discard r.del(@["test:hash:rand"])
    discard r.hSet("test:hash:rand", [("a", "1"), ("b", "2"), ("c", "3")])
    r.xfailBefore(6, 2):
      let fields = r.hRandField("test:hash:rand", 2)
      check fields.len == 2
      for f in fields:
        check f in ["a", "b", "c"]

  test "zpopmin and zpopmax (Redis 5.0+)":
    discard r.del(@["test:zset:pop"])
    discard r.zadd("test:zset:pop", 10, "one")
    discard r.zadd("test:zset:pop", 20, "two")
    discard r.zadd("test:zset:pop", 30, "three")

    let minPop = r.zpopmin("test:zset:pop", 1)
    check minPop.len == 1
    check minPop[0].member == "one"
    check minPop[0].score == 10.0

    let maxPop = r.zpopmax("test:zset:pop", 1)
    check maxPop.len == 1
    check maxPop[0].member == "three"
    check maxPop[0].score == 30.0

  test "bzpopmin and bzpopmax (Redis 5.0+)":
    discard r.del(@["test:zset:bpop"])
    discard r.zadd("test:zset:bpop", 100, "hundred")
    let popped = r.bzpopmin(@["test:zset:bpop"], 1)
    check popped.isSome
    let (key, mem, sc) = popped.get()
    check key == "test:zset:bpop"
    check mem == "hundred"
    check sc == 100.0

  test "zmscore (Redis 6.2+)":
    discard r.del(@["test:zset:mscore"])
    discard r.zadd("test:zset:mscore", 15, "alpha")
    discard r.zadd("test:zset:mscore", 25, "beta")
    r.xfailBefore(6, 2):
      let scores = r.zmscore("test:zset:mscore", @["alpha", "nonexistent", "beta"])
      check scores.len == 3
      check scores[0] == some(15.0)
      check scores[1].isNone
      check scores[2] == some(25.0)

  test "zrandmember (Redis 6.2+)":
    discard r.del(@["test:zset:rand"])
    discard r.zadd("test:zset:rand", 1, "m1")
    discard r.zadd("test:zset:rand", 2, "m2")
    r.xfailBefore(6, 2):
      let randm = r.zrandmember("test:zset:rand", 1)
      check randm.len == 1
      check randm[0] in ["m1", "m2"]

  test "zdiff, zdiffstore, zinter, zunion (Redis 6.2+)":
    discard r.del(@["test:zset:z1", "test:zset:z2", "test:zset:diffout"])
    discard r.zadd("test:zset:z1", 1, "a")
    discard r.zadd("test:zset:z1", 2, "b")
    discard r.zadd("test:zset:z2", 2, "b")
    discard r.zadd("test:zset:z2", 3, "c")

    r.xfailBefore(6, 2):
      let diff = r.zdiff(@["test:zset:z1", "test:zset:z2"])
      check diff == @["a"]

      let diffCount = r.zdiffstore("test:zset:diffout", @["test:zset:z1", "test:zset:z2"])
      check diffCount == 1

      let inter = r.zinter(@["test:zset:z1", "test:zset:z2"])
      check inter == @["b"]

      let unionRes = r.zunion(@["test:zset:z1", "test:zset:z2"])
      check unionRes.len == 3

  test "zrem multi-member":
    discard r.del(@["test:zset:rem"])
    discard r.zadd("test:zset:rem", 1, "a")
    discard r.zadd("test:zset:rem", 2, "b")
    discard r.zadd("test:zset:rem", 3, "c")
    check r.zrem("test:zset:rem", @["a", "b"]) == 2
    check r.zcard("test:zset:rem") == 1

  r.quit()

suite "Redis Cursor Scanning & Native Iterators (Sync)":
  let r = getClient()
  discard r.flushdb()

  test "scan iterator yields all matching keys":
    for i in 1..25:
      r.setk("test:scan:k" & $i, "val" & $i)
    
    var collected: seq[string] = @[]
    for k in r.scan(pattern = "test:scan:k*", count = 5):
      collected.add(k)
    
    check collected.len == 25
    for i in 1..25:
      check ("test:scan:k" & $i) in collected

  test "hscan iterator yields all hash fields":
    var pairs: seq[(string, string)] = @[]
    for i in 1..20:
      pairs.add(("field" & $i, "val" & $i))
    discard r.hSet("test:hscan:hash", pairs)

    var count = 0
    for (f, v) in r.hscan("test:hscan:hash", count = 5):
      check v == "val" & f.substr(5)
      count.inc
    check count == 20

  test "sscan iterator yields all set members":
    var members: seq[string] = @[]
    for i in 1..20:
      members.add("member" & $i)
    discard r.sadd("test:sscan:set", members)

    var count = 0
    for m in r.sscan("test:sscan:set", count = 5):
      check m in members
      count.inc
    check count == 20

  test "zscan iterator yields all sorted set entries":
    for i in 1..20:
      discard r.zadd("test:zscan:zset", i, "entry" & $i)

    var count = 0
    for (m, s) in r.zscan("test:zscan:zset", count = 5):
      check m.startsWith("entry")
      check s > 0.0
      count.inc
    check count == 20
  test "hscan, sscan, and zscan raise RedisResponseError on WRONGTYPE":
    discard r.del(@["test:wrongtype:str"])
    r.setk("test:wrongtype:str", "just_a_string")
    expect RedisResponseError:
      discard r.hscan("test:wrongtype:str", 0)
    expect RedisResponseError:
      discard r.sscan("test:wrongtype:str", 0)
    expect RedisResponseError:
      discard r.zscan("test:wrongtype:str", 0)

  test "hPairs handles empty string key correctly":
    discard r.del(@["test:hash:emptykey"])
    discard r.hSet("test:hash:emptykey", "", "empty_val")
    discard r.hSet("test:hash:emptykey", "normal", "normal_val")
    var pairs: seq[(string, string)] = @[]
    for p in r.hPairs("test:hash:emptykey"):
      pairs.add(p)
    check pairs.len == 2
    var foundEmpty = false
    var foundNormal = false
    for (k, v) in pairs:
      if k == "" and v == "empty_val": foundEmpty = true
      if k == "normal" and v == "normal_val": foundNormal = true
    check foundEmpty == true
    check foundNormal == true

  r.quit()

suite "Redis Scanning & Collectors (Async)":
  proc mainAsync() {.async.} =
    let r = await getAsyncClient()
    discard await r.flushdb()

    # Async scanAll
    for i in 1..20:
      await r.setk("test:async:scan:k" & $i, "v" & $i)
    let keys = await r.scanAll("test:async:scan:k*", count = 5)
    check keys.len == 20

    # Async hscanAll
    var hpairs: seq[(string, string)] = @[]
    for i in 1..15:
      hpairs.add(("f" & $i, "v" & $i))
    discard await r.hSet("test:async:hscan", hpairs)
    let hres = await r.hscanAll("test:async:hscan", count = 5)
    check hres.len == 15

    # Async sscanAll
    var smembers: seq[string] = @[]
    for i in 1..15:
      smembers.add("m" & $i)
    discard await r.sadd("test:async:sscan", smembers)
    let sres = await r.sscanAll("test:async:sscan", count = 5)
    check sres.len == 15

    # Async zscanAll
    for i in 1..15:
      discard await r.zadd("test:async:zscan", i, "e" & $i)
    let zres = await r.zscanAll("test:async:zscan", count = 5)
    check zres.len == 15

    # Async hPairs with empty key
    discard await r.del(@["test:async:emptykey"])
    discard await r.hSet("test:async:emptykey", "", "empty_val")
    discard await r.hSet("test:async:emptykey", "normal", "normal_val")
    let asyncPairs = await r.hPairs("test:async:emptykey")
    check asyncPairs.len == 2

    await r.quit()

  waitFor mainAsync()
