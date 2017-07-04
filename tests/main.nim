import redis, unittest

suite "redis tests":
  let r = redis.open("localhost")

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

  # TODO: Ideally tests for all other procedures, will add these in the future

  # delete all keys in the DB at the end of the tests
  discard r.flushdb()
  r.quit()
