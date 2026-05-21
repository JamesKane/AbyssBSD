#!/usr/bin/env python3
"""Drive the AbyssBSD FreeBSD VM's serial console.

`vm.sh` runs QEMU with the guest serial console on a TCP chardev socket
(127.0.0.1:4555 by default). This script connects to it and replays an
expect-style dialogue, so the console can be driven non-interactively for
provisioning and for debugging a kernel that will not come up far enough
for SSH.

Usage:
    console.py [--port N] [--timeout S] STEP [STEP ...]

Each STEP is `kind:value`:
    expect:REGEX    block until REGEX appears in the console stream
    send:TEXT       send TEXT followed by a carriage return
    sendraw:TEXT    send TEXT with no terminator
    sleep:SECONDS   read (and echo) the console for SECONDS

Everything received is echoed to stdout. Exit status is non-zero if an
`expect` step times out.
"""

import re
import socket
import sys
import time


def main() -> int:
    port = 4555
    timeout = 60.0
    steps = []

    args = sys.argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--port":
            port = int(args[i + 1]); i += 2
        elif a == "--timeout":
            timeout = float(args[i + 1]); i += 2
        else:
            steps.append(a); i += 1

    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    sock.setblocking(False)
    buf = ""

    def drain() -> None:
        nonlocal buf
        try:
            data = sock.recv(65536)
        except (BlockingIOError, InterruptedError):
            return
        if not data:
            return
        text = data.decode("utf-8", "replace")
        sys.stdout.write(text)
        sys.stdout.flush()
        buf += text

    for step in steps:
        kind, _, value = step.partition(":")
        if kind == "expect":
            rx = re.compile(value)
            deadline = time.time() + timeout
            while True:
                drain()
                if rx.search(buf):
                    buf = ""
                    break
                if time.time() > deadline:
                    sys.stderr.write(f"\n[console.py] timeout waiting for /{value}/\n")
                    return 1
                time.sleep(0.2)
        elif kind == "send":
            sock.sendall((value + "\r").encode())
            time.sleep(0.3)
        elif kind == "sendraw":
            sock.sendall(value.encode())
            time.sleep(0.3)
        elif kind == "sleep":
            end = time.time() + float(value)
            while time.time() < end:
                drain()
                time.sleep(0.2)
        else:
            sys.stderr.write(f"[console.py] unknown step: {step}\n")
            return 2

    end = time.time() + 1.0
    while time.time() < end:
        drain()
        time.sleep(0.1)
    sock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
