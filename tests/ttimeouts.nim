import unittest, asyncdispatch, asyncnet, os, strutils, times, net
import redis

proc getHost(): string = getEnv("REDIS_HOST", "localhost")
proc getPort(): Port = Port(parseInt(getEnv("REDIS_PORT", "6379")))

suite "Redis Timeouts and Socket Deadlines (Sync)":
  test "readTimeoutMs raises RedisTimeoutError on stalled blocking command":
    let r = redis.open(getHost(), getPort(), readTimeoutMs = 250)
    discard r.flushdb()

    let start = epochTime()
    expect RedisTimeoutError:
      # Server blocks for 5 seconds, but client readTimeoutMs is 250ms
      discard r.bLPop(@["test:nonexistent:queue"], timeout = 5)
    let elapsed = epochTime() - start

    # Should have timed out quickly (~250ms), far less than the 5s server wait
    check elapsed < 2.0
    check r.isConnected == false

  test "readTimeoutMs dynamically tunes socket deadlines":
    let r = redis.open(getHost(), getPort())
    discard r.flushdb()
    r.setk("test:dynamic:k", "hello")

    # Set aggressive read timeout directly on the public field
    r.readTimeoutMs = 200
    expect RedisTimeoutError:
      discard r.bLPop(@["test:dynamic:nonexistent"], timeout = 4)

    # Reconnect and restore indefinite timeout
    r.reconnect(getHost(), getPort())
    r.readTimeoutMs = -1
    check r.get("test:dynamic:k") == "hello"
    r.quit()

  test "withReadTimeout restores previous timeout even on error":
    let r = redis.open(getHost(), getPort(), readTimeoutMs = 5000)
    discard r.flushdb()

    expect RedisTimeoutError:
      withReadTimeout(r, 200):
        discard r.bLPop(@["test:dynamic:nonexistent2"], timeout = 4)

    # Verify original timeout was restored and socket closed on timeout
    check r.readTimeoutMs == 5000
    check r.isConnected == false

  test "connectTimeoutMs fails fast on unreachable endpoint":
    let start = epochTime()
    expect RedisTimeoutError:
      # 198.51.100.1 is RFC 5737 TEST-NET-2 (unroutable/blackhole)
      discard redis.open("198.51.100.1", 6379.Port, connectTimeoutMs = 250)
    let elapsed = epochTime() - start
    check elapsed < 2.0

suite "Redis Reconnect & State Retention (Sync)":
  test "manual reconnect restores client usability after socket close":
    let r = redis.open(getHost(), getPort())
    discard r.flushdb()
    r.setk("test:recon:k", "persisted")

    # Simulate dropped socket
    r.socket.close()

    r.reconnect(getHost(), getPort())
    check r.isConnected == true
    check r.get("test:recon:k") == "persisted"
    r.quit()

  test "reconnect selects database explicitly":
    let r = redis.open(getHost(), getPort(), db = 14)
    discard r.flushdb()
    r.setk("test:db14:k", "in_14")

    r.socket.close()
    r.reconnect(getHost(), getPort(), db = 14)

    check r.get("test:db14:k") == "in_14"
    r.quit()

  test "reconnect restores connection after manual close":
    let r = redis.open(getHost(), getPort())
    discard r.flushdb()
    r.setk("test:manual:k", "manual_val")

    r.socket.close()
    check r.isConnected == false
    r.reconnect(getHost(), getPort())
    check r.isConnected == true
    check r.get("test:manual:k") == "manual_val"
    r.quit()

suite "Redis Timeouts and Reconnect (Async)":
  test "Async readTimeoutMs raises RedisTimeoutError on stalled blocking command":
    proc runTest() {.async.} =
      let r = await redis.openAsync(getHost(), getPort(), readTimeoutMs = 250)
      discard await r.flushdb()

      let start = epochTime()
      var caught = false
      try:
        discard await r.bLPop(@["test:async:nonexistent"], timeout = 5)
      except RedisTimeoutError:
        caught = true
      let elapsed = epochTime() - start

      check caught == true
      check elapsed < 2.0
      check r.isConnected == false

    waitFor runTest()

  test "Async connectTimeoutMs fails fast on unreachable endpoint":
    proc runTest() {.async.} =
      let start = epochTime()
      var caught = false
      try:
        discard await redis.openAsync("198.51.100.1", 6379.Port, connectTimeoutMs = 250)
      except RedisTimeoutError:
        caught = true
      let elapsed = epochTime() - start

      check caught == true
      check elapsed < 2.0

    waitFor runTest()

  test "Async manual reconnect":
    proc runTest() {.async.} =
      let r = await redis.openAsync(getHost(), getPort())
      discard await r.flushdb()
      await r.setk("test:async:recon", "async_val")

      # Sever connection
      r.socket.close()
      check r.isConnected == false

      await r.reconnect(getHost(), getPort())
      check (await r.get("test:async:recon")) == "async_val"
      check r.isConnected == true
      await r.quit()

    waitFor runTest()

suite "Redis Error Hierarchy and Diagnostics":
  test "RedisTimeoutError inherits from RedisConnectionError and RedisError":
    let ex = newException(RedisTimeoutError, "timeout occurred")
    check ex of RedisTimeoutError
    check ex of RedisConnectionError
    check ex of RedisError
    check ex of IOError

  test "RedisResponseError captures parsed errorCode":
    let r = redis.open(getHost(), getPort())
    discard r.flushdb()
    r.setk("test:type:str", "simple_string")

    var caught = false
    try:
      # HGETALL on a string key will trigger WRONGTYPE
      discard r.hGetAll("test:type:str")
    except RedisResponseError as e:
      caught = true
      check e.errorCode == "WRONGTYPE"
      check e of RedisError
    check caught == true
    r.quit()

  test "Sync socket is closed on read timeout":
    let r = redis.open(getHost(), getPort(), readTimeoutMs = 150)
    expect RedisTimeoutError:
      discard r.bLPop(@["test:nonexistent:blocking"], timeout = 2)
    check r.socket.isSocketClosed() == true
    check r.isConnected == false

  test "reconnect with ACL credentials":
    let r = redis.open(getHost(), getPort())
    # If Redis supports ACLs (Redis 6+), create a temporary user and verify reconnect with ACL
    try:
      discard r.rawCommand("ACL", @["SETUSER", "testacl", "on", ">testpass", "~*", "&*", "+@all"])
      let rAcl = redis.open(getHost(), getPort(), username = "testacl", password = "testpass")
      check rAcl.isConnected == true

      # Sever and reconnect with explicit credentials
      rAcl.socket.close()
      check rAcl.isConnected == false
      rAcl.reconnect(getHost(), getPort(), username = "testacl", password = "testpass")
      check rAcl.isConnected == true
      check rAcl.ping() == "PONG"
      rAcl.quit()
      discard r.rawCommand("ACL", @["DELUSER", "testacl"])
    except CatchableError:
      discard
    r.quit()
