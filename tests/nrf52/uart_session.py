#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# uart_session.py HOST:PORT SCRIPT OUT
#
# Types a shell session at HackOS's console through a TCP socket (Renode's
# server socket terminal on the emulated UARTE0) and records everything the
# console prints, as tests/imxrt/t41mem.sh does with QEMU's stdio.
# SCRIPT lines:
#   prompt TEXT      wait until TEXT has appeared (the first prompt)
#   sh CMD           type CMD, then `wc < /dev/null`, and wait for its
#                    "0 0 0" (the n-th one for the n-th sh): CMD is done
#   shn CMD          type CMD without waiting
#   raw HEX          send bytes (e.g. 03 = Ctrl-C)
#   keys TEXT        type TEXT, with \\x1b, \\r and the like as escapes
#   killbg           type `kill PID` with the PID of the last "[n] PID" the
#                    shell printed for a background job, and wait like sh
#   paste N TEXT     N lines of TEXT (%d = the line number) in ONE write to
#                    the socket: a pasted block, as fast as the emulated
#                    UART takes it
#   sleep SECONDS
#   end TEXT         wait (at most 120 s) until TEXT has appeared, then stop
# Exit status: 0 when every wait succeeded; the number of failed waits else.
import socket, sys, threading, time

host, port = sys.argv[1].rsplit(':', 1)
script = [l.rstrip('\n') for l in open(sys.argv[2]) if l.strip() and not l.startswith('#')]
out = open(sys.argv[3], 'wb')
buf = bytearray()
lock = threading.Lock()
done = False

for i in range(200):
    try:
        s = socket.create_connection((host, int(port)), timeout=5)
        break
    except OSError:
        time.sleep(0.25)
else:
    sys.exit("cannot connect to the emulated UART")
s.settimeout(0.2)


def reader():
    while not done:
        try:
            d = s.recv(4096)
        except socket.timeout:
            continue
        except OSError:
            return
        if not d:
            return
        with lock:
            buf.extend(d)
            out.write(d)
            out.flush()


threading.Thread(target=reader, daemon=True).start()


def count(text):
    with lock:
        return buf.count(text.encode())


def wait_for(text, n=1, limit=60.0):
    t0 = time.time()
    while count(text) < n:
        if time.time() - t0 > limit:
            return False
        time.sleep(0.05)
    return True


def send(text):
    # One byte at a time with a short gap: what a person (or picocom paste
    # with a character delay) does; the console must not depend on bursts.
    for ch in text.encode():
        s.sendall(bytes([ch]))
        time.sleep(0.002)


fails = 0
marks = 0
for line in script:
    op, _, arg = line.partition(' ')
    if op == 'prompt':
        if not wait_for(arg, 1, 120):
            print(f"uart_session: no '{arg}'", file=sys.stderr)
            fails += 1
            break
    elif op == 'sh':
        marks += 1
        send(arg + '\r')
        send('wc < /dev/null\r')
        if not wait_for('0 0 0', marks, 60):
            print(f"uart_session: no answer to command #{marks} ({arg})", file=sys.stderr)
            fails += 1
    elif op == 'shn':
        send(arg + '\r')
    elif op == 'killbg':
        # `kill PID` for the background job the shell announced last ("[1] PID")
        import re
        with lock:
            pids = re.findall(rb'\[\d+\] (\d+)\r?\n', bytes(buf))
        marks += 1
        send('kill %s\r' % (pids[-1].decode() if pids else '0'))
        send('wc < /dev/null\r')
        if not wait_for('0 0 0', marks, 60):
            print("uart_session: no answer to kill", file=sys.stderr)
            fails += 1
    elif op == 'keys':
        # keystrokes with Python escapes (\x1b, \r), typed one by one
        send(arg.encode().decode('unicode_escape'))
    elif op == 'paste':
        n, _, text = arg.partition(' ')
        s.sendall(''.join((text % i) + '\r' for i in range(1, int(n) + 1)).encode())
    elif op == 'raw':
        s.sendall(bytes.fromhex(arg))
    elif op == 'sleep':
        time.sleep(float(arg))
    elif op == 'end':
        if not wait_for(arg, 1, 120):
            print(f"uart_session: no '{arg}' at the end", file=sys.stderr)
            fails += 1
        time.sleep(0.5)
done = True
print(f"uart_session: {marks} commands sent, {fails} waits failed", file=sys.stderr)
sys.exit(fails)
