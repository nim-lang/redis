import redis, unittest, asyncdispatch, os, strutils

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

suite "Redis Modern Verbs (Sync)":
  let r = getClient()
  discard r.flushdb()

  test "unlink deletes keys in background thread":
    r.setk("test:unlink:1", "val1")
    r.setk("test:unlink:2", "val2")
    r.setk("test:unlink:3", "val3")
    check r.exists("test:unlink:1") == true
    check r.unlink("test:unlink:1") == 1
    check r.exists("test:unlink:1") == false

    check r.unlink(@["test:unlink:2", "test:unlink:nonexistent"]) == 1
    check r.exists("test:unlink:2") == false

    # openArray array literal overload
    check r.unlink(["test:unlink:3", "test:unlink:nonexistent"]) == 1
    check r.exists("test:unlink:3") == false

  test "touch updates access time":
    r.setk("test:touch:1", "val1")
    check r.touch("test:touch:1") == 1
    check r.touch("test:touch:nonexistent") == 0
    check r.touch(@["test:touch:1", "test:touch:nonexistent"]) == 1
    # openArray array literal overload
    check r.touch(["test:touch:1", "test:touch:nonexistent"]) == 1

  test "copy copies key value (Redis 6.2+)":
    r.setk("test:copy:src", "copied_val")
    r.xfailBefore(6, 2):
      check r.copy("test:copy:src", "test:copy:dst") == true
      check r.get("test:copy:dst") == "copied_val"

  test "pexpire and pttl in milliseconds":
    r.setk("test:pexpire:1", "expiring")
    check r.pexpire("test:pexpire:1", 50000) == true
    let ttlMs = r.pttl("test:pexpire:1")
    check ttlMs > 0
    check ttlMs <= 50000

  test "expireTime and pexpireTime (Redis 7.0+)":
    r.setk("test:expiretime:1", "expiring_abs")
    discard r.expire("test:expiretime:1", 3600)
    r.xfailBefore(7, 0):
      let expSec = r.expireTime("test:expiretime:1")
      check expSec > 0
      let expMs = r.pexpireTime("test:expiretime:1")
      check expMs > 0

  test "keyType multisync":
    r.setk("test:type:str", "string_val")
    check r.keyType("test:type:str") == "string"

  test "getDel atomically gets and deletes (Redis 6.2+)":
    r.setk("test:getdel:1", "del_me")
    r.xfailBefore(6, 2):
      check r.getDel("test:getdel:1") == "del_me"
      check r.exists("test:getdel:1") == false

  test "getEx gets and sets expiration (Redis 6.2+)":
    r.setk("test:getex:1", "expire_me")
    r.xfailBefore(6, 2):
      check r.getEx("test:getex:1", seconds = 60) == "expire_me"
      check r.ttl("test:getex:1") > 0

  test "msetnx sets multiple keys only if none exist":
    let ok = r.msetnx([("test:msetnx:a", "1"), ("test:msetnx:b", "2")])
    check ok == true
    check r.get("test:msetnx:a") == "1"
    check r.get("test:msetnx:b") == "2"

    let fail = r.msetnx([("test:msetnx:a", "new1"), ("test:msetnx:c", "3")])
    check fail == false
    check r.exists("test:msetnx:c") == false

  test "incrByFloat increments floating point numbers":
    r.setk("test:float:1", "10.5")
    let newVal = r.incrByFloat("test:float:1", 2.25)
    check newVal > 12.74 and newVal < 12.76

  test "ping with custom message":
    check r.ping("custom ping payload") == "custom ping payload"

  test "hello handshake (Redis 6.0+)":
    r.xfailBefore(6, 0):
      let helloRes = r.hello(2)
      check helloRes.kind == vkList
      check helloRes.len > 0

  discard r.flushdb()
  r.quit()

suite "Redis Modern Verbs (Async)":
  proc runAsyncTests() {.async.} =
    let r = await getAsyncClient()
    discard await r.flushdb()

    # Async unlink
    await r.setk("test:async:unlink", "val")
    check (await r.unlink("test:async:unlink")) == 1
    await r.setk("test:async:unlink:arr", "val")
    check (await r.unlink(["test:async:unlink:arr"])) == 1

    # Async touch
    await r.setk("test:async:touch", "val")
    check (await r.touch("test:async:touch")) == 1
    await r.setk("test:async:touch:arr", "val")
    check (await r.touch(["test:async:touch:arr"])) == 1

    # Async keyType
    await r.setk("test:async:type", "val")
    check (await r.keyType("test:async:type")) == "string"

    # Async incrByFloat
    await r.setk("test:async:float", "5.0")
    let flt = await r.incrByFloat("test:async:float", 1.5)
    check flt > 6.4 and flt < 6.6

    # Async ping with message
    check (await r.ping("async pong")) == "async pong"

    discard await r.flushdb()
    await r.quit()

  waitFor runAsyncTests()
