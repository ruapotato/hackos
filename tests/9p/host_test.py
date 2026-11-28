#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
"""host_test.py (--cmd 'EMULATOR ARGS...' | --tcp HOST:PORT) HELLO [--halt]

The device's own tree, exported over its console serial line, used from the
host: starts `exportfs /dev/console` at the shell of a running Hamnix Micro
(an emulator on stdio, or on a TCP socket) and checks, as a 9P2000 client
(tools/hm9p.py, Python standard library only): the root directory, /proc,
/dev, a file written in pieces and read back, every byte value both ways
(the console must pass Ctrl-C, XON/XOFF, CR and LF untouched), a binary
compared with the build's (HELLO = the build's user/hello), create, mkdir,
remove, an error string, and that the shell has its console back afterwards.
Prints one "[9p-host] ok:" or "FAIL:" line per check; exit status = failures.
"""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
import hm9p  # noqa: E402

fails = 0
checks = 0


def check(cond, msg):
    global fails, checks
    checks += 1
    print(("[9p-host] ok: " if cond else "[9p-host] FAIL: ") + msg, flush=True)
    if not cond:
        fails += 1


def main(argv):
    if len(argv) < 3 or argv[0] not in ("--cmd", "--tcp"):
        raise SystemExit(__doc__)
    hello = open(argv[2], "rb").read()
    tr = hm9p.Transport.command(argv[1].split()) if argv[0] == "--cmd" else hm9p.Transport.tcp(argv[1])
    halt = "--halt" in argv[3:]
    try:
        tr.read_until(b"hamsh$ ", 90)
        time.sleep(0.5)
        s = hm9p.Session(tr)
        t0 = time.monotonic()
        c = s.start("/")
        check(True, "`exportfs /dev/console` typed at the shell: Tversion and Tattach answered, msize %d" % c.msize)
        names = sorted(e["name"] for e in c.ls("/"))
        check(all(n in names for n in ("bin", "dev", "proc", "tmp", "srv", "fd")),
              "the root directory lists bin dev proc tmp srv fd (%s)" % " ".join(names))
        v = c.read("/proc/version").decode()
        check(v.startswith("Hamnix Micro "), "/proc/version: %s" % v.strip())
        dev = [e["name"] for e in c.ls("/dev")]
        check("console" in dev and "gpio" in dev and "consctl" in dev, "/dev lists the drivers' files (%s)" % " ".join(dev))
        ns = c.read("/proc/self/ns").decode()
        check("bind '#c' /dev" in ns, "/proc/self/ns read from the host is the server's namespace (%d lines)" % ns.count("\n"))
        blob = bytes((i * 7 + 3) & 255 for i in range(1000))
        c.write("/tmp/h9", blob)
        check(c.read("/tmp/h9") == blob, "1000 bytes written in %d-byte requests and read back" % (c.msize - 24))
        check(c.stat("/tmp/h9")["length"] == 1000, "Tstat gives its length")
        every = bytes(range(256)) * 2
        c.write("/tmp/h9b", every)
        check(c.read("/tmp/h9b") == every, "every byte value twice, both ways: Ctrl-C, XON, XOFF, CR, LF and NUL pass the console untouched")
        got = c.read("/bin/hello")
        check(got == hello, "/bin/hello read through 9P is the build's file (%d bytes)" % len(hello))
        c.mkdir("/tmp/hd")
        c.write("/tmp/hd/inner", b"inside\n")
        e = {x["name"]: x for x in c.ls("/tmp")}
        check("hd" in e and e["hd"]["dir"] and e["h9"]["length"] == 1000, "mkdir; the directory listing has it, and the file with its length")
        check(c.read("/tmp/hd/inner") == b"inside\n", "a file created in the new directory")
        c.remove("/tmp/hd/inner")
        c.remove("/tmp/hd")
        c.remove("/tmp/h9")
        c.remove("/tmp/h9b")
        left = [x["name"] for x in c.ls("/tmp")]
        check("hd" not in left and "h9" not in left and "h9b" not in left, "Tremove: file, then directory")
        try:
            c.read("/tmp/no-such-file")
            check(False, "a missing file is an error")
        except hm9p.P9Error as ex:
            check("does not exist" in str(ex), "a missing file is refused (%s)" % ex)
        gp = [x["name"] for x in c.ls("/dev/gpio")]
        pin = "blue" if "blue" in gp else "2"
        c.write("/dev/gpio/" + pin, b"1\n")
        one = c.read("/dev/gpio/" + pin)
        c.write("/dev/gpio/" + pin, b"0\n")
        zero = c.read("/dev/gpio/" + pin)
        check(one == b"1\n" and zero == b"0\n", "a pin switched from the host: /dev/gpio/%s written 1 then 0, read back each time" % pin)
        dt = time.monotonic() - t0
        s.end()
        check(True, "four zero bytes end the session (%d requests in %.1f s)" % (c.calls, dt))
        tr.write(b"echo shell-is-back | wc\r")
        tr.read_until(b"1 1 14", 20)
        check(True, "the shell has its console back: a pipeline typed afterwards runs")
        if halt:
            tr.write(b"halt 0\r")
            tr.read_until(b"exit status 0", 20)
    except hm9p.P9Error as ex:
        check(False, "the session broke: %s" % ex)
        sys.stderr.write(repr(bytes(tr.log[-600:])) + "\n")
    finally:
        if tr.proc is not None:
            tr.proc.kill()
        tr.close()
    print("[9p-host] %d checks, %d failed" % (checks, fails))
    return fails


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
