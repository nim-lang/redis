# Package

version       = "0.2.0"
author        = "Dominik Picheta"
description   = "Official redis client for Nim"
license       = "MIT"

srcDir = "src"

# Dependencies

requires "nim >= 0.11.0"

task docs, "Build documentation":
    exec "nim doc --index:on -o:docs/redis.html src/redis.nim"