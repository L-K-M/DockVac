#!/usr/bin/env python3
"""Test-only stand-in for ssh, exercising the real stdio transport and fixture daemon."""

import os
import json
import selectors
import shlex
import signal
import socket
import sys
import time
from pathlib import Path


def main():
    destination = sys.argv.index("--")
    mode = sys.argv[destination + 1]
    command = shlex.split(sys.argv[destination + 2])
    assert command[0:2] == ["docker", "--host"]
    path = command[2].removeprefix("unix://")
    if mode == "command-echo":
        Path(path + ".commands").write_text(json.dumps(command))
        return
    assert command[3:] == ["system", "dial-stdio"]

    if mode in ("bridge", "slow-bridge"):
        bridge = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        bridge.connect(path)
        selector = selectors.DefaultSelector()
        selector.register(0, selectors.EVENT_READ)
        selector.register(bridge, selectors.EVENT_READ)
        delayed = False
        while True:
            for key, _ in selector.select():
                if key.fileobj == 0:
                    data = os.read(0, 65536)
                    if not data:
                        selector.unregister(0)
                        bridge.shutdown(socket.SHUT_WR)
                        continue
                    if mode == "slow-bridge" and not delayed and data.startswith(b"DELETE "):
                        Path(path + ".deleting").touch()
                        time.sleep(0.5)
                        delayed = True
                    bridge.sendall(data)
                    continue
                data = bridge.recv(65536)
                if not data:
                    return
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()

    Path(path + ".pid").write_text(str(os.getpid()))
    if mode in ("fail", "exit-early"):
        sys.stderr.write("Permission denied (publickey).\n")
        sys.exit(255)
    if mode == "hang":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(60)
        return

    request = sys.stdin.buffer.read()
    Path(path + ".request").write_bytes(request)
    if mode == "malformed":
        response = b"garbage\r\n\r\n"
    elif mode == "truncated":
        response = b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nOK"
    elif mode == "close-delimited":
        response = b"HTTP/1.1 200 OK\r\n\r\nOK"
    else:
        response = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nOK\r\n0\r\n\r\n"
    if mode == "stderr-flood":
        sys.stderr.buffer.write(b"banner\n" * 100000)
        sys.stderr.buffer.flush()
    sys.stdout.buffer.write(response)
    sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
