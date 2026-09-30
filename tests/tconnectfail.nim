# A failed connect in open() or openUnix() must not leave the socket
# open: no Redis object reaches the caller, so nobody else can close it.

import os, net, unittest, redis

proc openFds(): int =
  for _ in walkDir("/proc/self/fd"):
    inc result

suite "failed connect":
  when defined(linux):
    test "open does not leak a socket when the connect fails":
      let before = openFds()
      for _ in 1 .. 50:
        expect OSError:
          discard open("127.0.0.1", 1.Port)
      check openFds() == before

    test "openUnix does not leak a socket when the connect fails":
      let before = openFds()
      for _ in 1 .. 50:
        expect OSError:
          discard openUnix("/nonexistent/redis.sock")
      check openFds() == before
