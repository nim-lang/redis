import redis, unittest, asyncdispatch, os, strutils

proc getClient(): Redis =
  redis.open(getEnv("REDIS_HOST", "localhost"), Port(parseInt(getEnv("REDIS_PORT", "6379"))))

proc getAsyncClient(): Future[AsyncRedis] {.async.} =
  await redis.openAsync(getEnv("REDIS_HOST", "localhost"), Port(parseInt(getEnv("REDIS_PORT", "6379"))))

template syncTests() =
  let r = getClient()
  discard r.flushdb()
  let keys = r.keys("*")
  doAssert keys.len == 0, "Don't want to mess up an existing DB."

  test "simple set and get":
    const expected = "Hello, World!"

    r.setk("redisTests:simpleSetAndGet", expected)
    let actual = r.get("redisTests:simpleSetAndGet")

    check actual == expected

  test "get returns values byte-for-byte":
    # Regression test for https://github.com/nim-lang/redis/issues/44:
    # bulk replies were passed through strip(), corrupting values with
    # leading/trailing whitespace. Bulk strings are binary safe, so
    # embedded CRLF and NUL bytes must survive the round trip too.
    const expected = " \t padded\r\nvalue\0 \n "

    r.setk("redisTests:whitespacePreserved", expected)
    let actual = r.get("redisTests:whitespacePreserved")

    check actual == expected

  test "increment key by one":
    const expected = 3

    r.setk("redisTests:incrementKeyByOne", "2")
    let actual = r.incr("redisTests:incrementKeyByOne")

    check actual == expected

  test "increment key by five":
    const expected = 10

    r.setk("redisTests:incrementKeyByFive", "5")
    let actual = r.incrBy("redisTests:incrementKeyByFive", 5)

    check actual == expected

  test "decrement key by one":
    const expected = 2

    r.setk("redisTest:decrementKeyByOne", "3")
    let actual = r.decr("redisTest:decrementKeyByOne")

    check actual == expected

  test "decrement key by three":
    const expected = 7

    r.setk("redisTest:decrementKeyByThree", "10")
    let actual = r.decrBy("redisTest:decrementKeyByThree", 3)

    check actual == expected

  test "append string to key":
    const expected = "hello world"

    r.setk("redisTest:appendStringToKey", "hello")
    let keyLength = r.append("redisTest:appendStringToKey", " world")

    check keyLength == len(expected)
    check r.get("redisTest:appendStringToKey") == expected

  test "check key exists":
    r.setk("redisTest:checkKeyExists", "foo")
    check r.exists("redisTest:checkKeyExists") == true

  test "delete key":
    r.setk("redisTest:deleteKey", "bar")
    check r.exists("redisTest:deleteKey") == true

    check r.del(@["redisTest:deleteKey"]) == 1
    check r.exists("redisTest:deleteKey") == false

  test "rename key":
    const expected = "42"

    r.setk("redisTest:renameKey", expected)
    discard r.rename("redisTest:renameKey", "redisTest:meaningOfLife")

    check r.exists("redisTest:renameKey") == false
    check r.get("redisTest:meaningOfLife") == expected

  test "get key length":
    const expected = 5

    r.setk("redisTest:getKeyLength", "hello")
    let actual = r.strlen("redisTest:getKeyLength")

    check actual == expected

  test "push entries to list":
    for i in 1..5:
      check r.lPush("redisTest:pushEntriesToList", $i) == i

    check r.llen("redisTest:pushEntriesToList") == 5

  test "pfcount supports single key and multiple keys":
    discard r.pfadd("redisTest:pfcount1", @["foo"])
    check r.pfcount("redisTest:pfcount1") == 1

    discard r.pfadd("redisTest:pfcount2", @["bar"])
    check r.pfcount(@["redisTest:pfcount1", "redisTest:pfcount2"]) == 2

  test "flushPipeline preserves values containing OK or QUEUED":
    # Regression test for https://github.com/nim-lang/redis/issues/48:
    # pipeline results were filtered with contains("OK")/contains("QUEUED"),
    # a substring match, so legitimate values were silently dropped and
    # later results shifted position.
    const
      lookupKey = "redisTests:pipeline:lookup"
      jobsKey = "redisTests:pipeline:jobs"
      plainKey = "redisTests:pipeline:plain"

    r.setk(lookupKey, "LOOKUP")
    r.setk(jobsKey, "QUEUED_JOBS")
    r.setk(plainKey, "plain")

    r.startPipelining()
    discard r.get(lookupKey)
    discard r.get(jobsKey)
    discard r.get(plainKey)
    let res = r.flushPipeline()

    check res == @["LOOKUP", "QUEUED_JOBS", "plain"]

  test "flushPipeline preserves values equal to OK or QUEUED":
    # Status acknowledgments are filtered by RESP reply type, so a data
    # reply whose text is exactly "OK" or "QUEUED" must survive.
    const
      okKey = "redisTests:pipeline:okval"
      queuedKey = "redisTests:pipeline:queuedval"

    r.setk(okKey, "OK")
    r.setk(queuedKey, "QUEUED")

    r.startPipelining()
    discard r.get(okKey)
    discard r.get(queuedKey)
    let res = r.flushPipeline()

    check res == @["OK", "QUEUED"]

  test "exec preserves values containing OK":
    const brokenKey = "redisTests:multi:broken"

    r.setk(brokenKey, "BROKEN")

    r.multi()
    discard r.get(brokenKey)
    let res = r.exec()

    check res == @["BROKEN"]

  test "exec preserves values equal to OK":
    const okKey = "redisTests:multi:okval"

    r.setk(okKey, "OK")

    r.multi()
    discard r.get(okKey)
    let res = r.exec()

    check res == @["OK"]

  test "multi-member sadd, srem, slrem":
    discard r.del(@["test:srem:multi"])
    discard r.sadd("test:srem:multi", @["a", "b", "c", "d"])
    check r.scard("test:srem:multi") == 4
    let rem1 = r.srem("test:srem:multi", @["a", "c"])
    check rem1 == 2
    check r.scard("test:srem:multi") == 2
    let rem2 = r.slrem("test:srem:multi", @["b", "d"])
    check rem2 == 2
    check r.scard("test:srem:multi") == 0

  test "flushPipelineValues and execValues positional integrity":
    discard r.del(@["test:pk1", "test:pk2", "test:pcount"])
    r.startPipelining()
    r.setk("test:pk1", "v1")
    discard r.get("test:pk1")
    discard r.incr("test:pcount")
    discard r.get("test:pk_nonexistent")
    let pVals = r.flushPipelineValues()
    check pVals.len == 4
    check pVals[0].kind == vkStatus and pVals[0].toStr == "OK"
    check pVals[1].kind == vkString and pVals[1].toStr == "v1"
    check pVals[2].kind == vkInteger and pVals[2].toInt == 1
    check pVals[3].kind == vkNil

    r.multi()
    r.setk("test:pk2", "v2")
    discard r.get("test:pk2")
    discard r.incr("test:pcount")
    let eVals = r.execValues()
    check eVals.len == 3
    check eVals[0].kind == vkStatus and eVals[0].toStr == "OK"
    check eVals[1].kind == vkString and eVals[1].toStr == "v2"
    check eVals[2].kind == vkInteger and eVals[2].toInt == 2

  # delete all keys in the DB at the end of the tests
  discard r.flushdb()
  r.quit()
suite "redis tests":
  syncTests()

suite "redis async tests":
  let r = waitFor getAsyncClient()
  discard waitFor r.flushdb()
  let keys = waitFor r.keys("*")
  doAssert keys.len == 0, "Don't want to mess up an existing DB."

  test "issue #6":
    # See `tawaitorder` for a test that doesn't depend on Redis.
    const count = 5
    proc retr(key: string, expect: string) {.async.} =
      let val = await r.get(key)

      doAssert val == expect

    proc main(): Future[bool] {.async.} =
      for i in 0 ..< count:
        await r.setk("key" & $i, "value" & $i)

      var futures: seq[Future[void]] = @[]
      for i in 0 ..< count:
        futures.add retr("key" & $i, "value" & $i)

      for fut in futures:
        await fut

      return true

    check (waitFor main())

  test "pub/sub":

    proc main() {.async.} =
      let sub = waitFor getAsyncClient()
      let pub = waitFor getAsyncClient()

      let listerns = await pub.publish("channel1", "hi there")
      doAssert listerns == 0

      await sub.subscribe("channel1")
      # you should only call sub.nextMessage() from now on

      discard await pub.publish("channel1", "one")
      discard await pub.publish("channel1", "two")
      discard await pub.publish("channel1", "three")

      doAssert (await sub.nextMessage()).message == "one"
      doAssert (await sub.nextMessage()).message == "two"
      doAssert (await sub.nextMessage()).message == "three"
      await sub.unsubscribe("channel1")
      await sub.quit()
      await pub.quit()

    waitFor main()

  test "subscribe does not break subsequent commands or quit":
    proc testSubQuit() {.async.} =
      let sub = await getAsyncClient()
      await sub.subscribe("sub-channel")
      await sub.unsubscribe("sub-channel")
      await sub.quit()

      let sub2 = await getAsyncClient()
      await sub2.subscribe("sub-channel2")
      # quit immediately while subscribed without explicit unsubscribe
      await sub2.quit()

    waitFor testSubQuit()

  test "multi-member sadd, srem, slrem (async)":
    proc testSets() {.async.} =
      discard await r.del(@["test:async:set_multi"])
      check (await r.sadd("test:async:set_multi", @["x", "y", "z"])) == 3
      check (await r.scard("test:async:set_multi")) == 3
      check (await r.srem("test:async:set_multi", @["x", "y"])) == 2
      check (await r.scard("test:async:set_multi")) == 1
      check (await r.slrem("test:async:set_multi", @["z"])) == 1
      check (await r.scard("test:async:set_multi")) == 0

    waitFor testSets()

  test "flushPipelineValues and execValues positional integrity (async)":
    proc testPipelines() {.async.} =
      discard await r.del(@["test:async:pk1", "test:async:pk2", "test:async:pcount"])
      r.startPipelining()
      discard r.setk("test:async:pk1", "v1")
      discard r.get("test:async:pk1")
      discard r.incr("test:async:pcount")
      discard r.get("test:async:nonexistent")
      let pVals = await r.flushPipelineValues()
      check pVals.len == 4
      check pVals[0].kind == vkStatus and pVals[0].toStr == "OK"
      check pVals[1].kind == vkString and pVals[1].toStr == "v1"
      check pVals[2].kind == vkInteger and pVals[2].toInt == 1
      check pVals[3].kind == vkNil

      await r.multi()
      discard r.setk("test:async:pk2", "v2")
      discard r.get("test:async:pk2")
      discard r.incr("test:async:pcount")
      let eVals = await r.execValues()
      check eVals.len == 3
      check eVals[0].kind == vkStatus and eVals[0].toStr == "OK"
      check eVals[1].kind == vkString and eVals[1].toStr == "v2"
      check eVals[2].kind == vkInteger and eVals[2].toInt == 2

    waitFor testPipelines()
  discard waitFor r.flushdb()
  waitFor r.quit()


when compileOption("threads"):
  proc threadFunc() {.thread.} =
    suite "redis threaded tests":
      syncTests()

  var th: Thread[void]
  createThread(th, threadFunc)
  joinThread(th)

