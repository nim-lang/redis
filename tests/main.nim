import redis, unittest, asyncdispatch

suite "redis tests":
  let r = redis.open("localhost")
  let keys = r.keys("*")
  doAssert keys.len == 0, "Don't want to mess up an existing DB."

  test "simple set and get":
    const expected = "Hello, World!"

    r.setk("redisTests:simpleSetAndGet", expected)
    let actual = r.get("redisTests:simpleSetAndGet")

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

  test "sorted sets":
    const expected = 1

    discard r.zadd("redisTest:myzset", 1, "one")
    discard r.zadd("redisTest:myzset", 2, "two")
    discard r.zadd("redisTest:myzset", 3, "three")

    assert r.zcard("redisTest:myzset") == 3

    assert r.zcount("redisTest:myzset", "-inf", "+inf") == 3
    assert r.zcount("redisTest:myzset", "(1", "3") == 2

    discard r.zadd("redisTest:myzset", 2, "four")
    discard r.zincrby("redisTest:myzset", 2, "four")
    assert r.zscore("redisTest:myzset", "four") == 4

    


    assert r.zrange("redisTest:myzset", 2, 3) == @["three", "four"]




  # TODO: Ideally tests for all other procedures, will add these in the future

  # delete all keys in the DB at the end of the tests
  discard r.flushdb()
  r.quit()

suite "redis async tests":
  let r = waitFor redis.openAsync("localhost")
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
      let sub = waitFor redis.openAsync("localhost")
      let pub = waitFor redis.openAsync("localhost")

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

    waitFor main()

  discard waitFor r.flushdb()
  waitFor r.quit()