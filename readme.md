# redis [![CircleCI](https://circleci.com/gh/nim-lang/redis.svg?style=svg)](https://circleci.com/gh/nim-lang/redis)

A redis client for Nim.

## Installation

Add the following to your `.nimble` file:

```
# Dependencies

requires "redis >= 0.2.0"
```

Or, to install globally to your Nimble cache run the following command:

```
nimble install redis
```

## Usage

```nim
import redis, asyncdispatch

## Open a connection to Redis running on localhost on the default port (6379)
let redisClient = openAsync()

## Set the key `nim_redis:test` to the value `Hello, World`
await redisClient.setk("nim_redis:test", "Hello, World")

## Get the value of the key `nim_redis:test`
let value = await redisClient.get("nim_redis:test")

assert(value == "Hello, World")
```

There is also a synchronous version of the client, that can be created using the `open()` procedure rather than `openAsync()`.

## License

Copyright (C) 2015, 2017 Dominik Picheta. All rights reserved.
