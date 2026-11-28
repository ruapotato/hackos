#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
"""hm9p.py -- reach a Hamnix Micro device's files from a PC over its console
serial line, with 9P2000.  Python standard library only.

    hm9p.py --tty /dev/ttyUSB0 ls /dev
    hm9p.py --tty /dev/ttyUSB0 cat /proc/version
    hm9p.py --tty /dev/ttyUSB0 write /dev/gpio/47 1        (text + newline)
    hm9p.py --tty /dev/ttyUSB0 put local.txt /tmp/remote.txt
    hm9p.py --tty /dev/ttyUSB0 get /tmp/remote.txt local.txt
    hm9p.py --tty /dev/ttyUSB0 rm /tmp/remote.txt
    hm9p.py --tty /dev/ttyUSB0 mkdir /tmp/d
    hm9p.py --tty /dev/ttyUSB0 stat /bin/hamsh

The device must be at its shell prompt.  The tool types `exportfs
/dev/console` there, which turns the console line into a 9P connection
(user/progs/exportfs.ad, docs/9p.md), does what was asked, and ends the
session with four zero bytes, after which the shell has its console back.
Several commands can be given in one session, separated by a lone `--`.

--root DIR     export DIR of the device instead of /
--baud N       line speed for --tty (115200)
--cmd 'PROG ARGS...'   instead of --tty: start PROG and talk to its standard
               input and output (an emulator whose serial port is on stdio)
--tcp HOST:PORT        instead of --tty: a TCP socket that carries the serial
               line (an emulator's, or a serial-to-network bridge)
--no-start     exportfs is already serving (do not type the command)

As a module: Session(transport) gives a 9P client (class Client) after
start(); tests/9p/host_test.py uses it.
"""
import os
import select
import struct
import subprocess
import sys
import time

TVERSION, TATTACH, RERROR, TWALK, TOPEN, TCREATE, TREAD, TWRITE, TCLUNK, TREMOVE, TSTAT = \
    100, 104, 107, 110, 112, 114, 116, 118, 120, 122, 124
NOFID = 0xFFFFFFFF
DMDIR = 0x80000000
BANNER = b"until four zero bytes arrive"
ENDED = b"the console is a console again"


class P9Error(Exception):
    pass


class Transport:
    """Bytes both ways with a timeout: a tty, or a child process's stdio."""

    def __init__(self, rfd, wfd, proc=None):
        self.rfd, self.wfd, self.proc = rfd, wfd, proc
        self.pending = b""
        self.log = bytearray()          # everything received, for diagnosis

    @classmethod
    def tty(cls, path, baud=115200):
        import termios
        fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
        a = termios.tcgetattr(fd)
        speed = getattr(termios, "B%d" % baud)
        a[0] = 0                                        # iflag: no translation, no XON/XOFF
        a[1] = 0                                        # oflag
        a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        a[3] = 0                                        # lflag: raw
        a[4] = a[5] = speed
        a[6][termios.VMIN] = 1
        a[6][termios.VTIME] = 0
        termios.tcsetattr(fd, termios.TCSANOW, a)
        return cls(fd, fd)

    @classmethod
    def tcp(cls, hostport):
        import socket
        host, port = hostport.rsplit(":", 1)
        for _ in range(200):                            # an emulator may still be starting
            try:
                sk = socket.create_connection((host, int(port)), timeout=5)
                break
            except OSError:
                time.sleep(0.25)
        else:
            raise P9Error("cannot connect to %s" % hostport)
        sk.setblocking(True)
        t = cls(sk.fileno(), sk.fileno())
        t.sock = sk                                     # keeps the descriptor open
        return t

    @classmethod
    def command(cls, argv):
        p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, bufsize=0)
        return cls(p.stdout.fileno(), p.stdin.fileno(), p)

    def write(self, data):
        while data:
            n = os.write(self.wfd, data)
            data = data[n:]

    def _fill(self, timeout):
        r, _, _ = select.select([self.rfd], [], [], timeout)
        if not r:
            return False
        d = os.read(self.rfd, 4096)
        if not d:
            raise P9Error("the line was closed")
        self.pending += d
        self.log += d
        return True

    def read_exact(self, n, timeout=10.0):
        end = time.monotonic() + timeout
        while len(self.pending) < n:
            left = end - time.monotonic()
            if left <= 0 or not self._fill(left):
                raise P9Error("timeout: wanted %d bytes, have %d" % (n, len(self.pending)))
        d, self.pending = self.pending[:n], self.pending[n:]
        return d

    def read_until(self, marker, timeout=20.0):
        end = time.monotonic() + timeout
        while marker not in self.pending:
            left = end - time.monotonic()
            if left <= 0 or not self._fill(left):
                raise P9Error("timeout waiting for %r; last received: %r" % (marker, bytes(self.pending[-200:])))
        i = self.pending.index(marker) + len(marker)
        d, self.pending = self.pending[:i], self.pending[i:]
        return d

    def close(self):
        if self.proc is not None:
            try:
                self.proc.stdin.close()
            except OSError:
                pass
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        elif hasattr(self, "sock"):
            self.sock.close()
        else:
            os.close(self.rfd)


def _s(b):
    return struct.pack("<H", len(b)) + b


class Client:
    """A 9P2000 client: one request at a time, tag 1."""

    def __init__(self, tr, msize=8192):
        self.tr = tr
        self.nextfid = 1
        self.calls = 0
        r = self._rpc(TVERSION, struct.pack("<I", msize) + _s(b"9P2000"), tag=0xFFFF)
        self.msize, = struct.unpack_from("<I", r, 0)
        vl, = struct.unpack_from("<H", r, 4)
        if r[6:6 + vl] != b"9P2000":
            raise P9Error("the server speaks %r" % r[6:6 + vl])
        self._rpc(TATTACH, struct.pack("<II", 0, NOFID) + _s(b"pc") + _s(b""))

    def _rpc(self, t, body, tag=1):
        msg = struct.pack("<IBH", 7 + len(body), t, tag) + body
        self.tr.write(msg)
        self.calls += 1
        size, rt, rtag = struct.unpack("<IBH", self.tr.read_exact(7))
        if size < 7 or size > 65536:
            raise P9Error("a reply of %d bytes: not 9P" % size)
        r = self.tr.read_exact(size - 7)
        if rt == RERROR:
            n, = struct.unpack_from("<H", r, 0)
            raise P9Error(r[2:2 + n].decode("utf-8", "replace"))
        if rt != t + 1 or rtag != tag:
            raise P9Error("reply type %d tag %d to request type %d" % (rt, rtag, t))
        return r

    def walk(self, path):
        """A new fid for `path`; returns (fid, qid type of the last element)."""
        names = [n.encode() for n in path.split("/") if n]
        fid = self.nextfid
        self.nextfid += 1
        r = self._rpc(TWALK, struct.pack("<IIH", 0, fid, len(names)) + b"".join(_s(n) for n in names))
        nq, = struct.unpack_from("<H", r, 0)
        if nq != len(names):
            raise P9Error("%s: file does not exist" % path)
        qt = 0x80 if nq == 0 else r[2 + 13 * (nq - 1)]
        return fid, qt

    def clunk(self, fid):
        self._rpc(TCLUNK, struct.pack("<I", fid))

    def _read_fid(self, fid):
        out = b""
        while True:
            r = self._rpc(TREAD, struct.pack("<IQI", fid, len(out), self.msize - 24))
            n, = struct.unpack_from("<I", r, 0)
            if n == 0:
                return out
            out += r[4:4 + n]

    def read(self, path):
        fid, qt = self.walk(path)
        try:
            self._rpc(TOPEN, struct.pack("<IB", fid, 0))
            return self._read_fid(fid)
        finally:
            self.clunk(fid)

    @staticmethod
    def _stat(b):
        """One stat record (after its size[2]) as a dict."""
        typ, dev, qt, qv, qp, mode, atime, mtime, length = struct.unpack_from("<HIBIQIIIQ", b, 0)
        nl, = struct.unpack_from("<H", b, 39)
        return {"name": b[41:41 + nl].decode("utf-8", "replace"), "mode": mode, "length": length,
                "qtype": qt, "qpath": qp, "dir": bool(mode & DMDIR)}

    def ls(self, path):
        """The stat records of a directory's entries."""
        data = self.read(path)
        out, o = [], 0
        while o + 2 <= len(data):
            sz, = struct.unpack_from("<H", data, o)
            out.append(self._stat(data[o + 2:o + 2 + sz]))
            o += 2 + sz
        return out

    def stat(self, path):
        fid, _ = self.walk(path)
        try:
            r = self._rpc(TSTAT, struct.pack("<I", fid))
            return self._stat(r[4:])
        finally:
            self.clunk(fid)

    def write(self, path, data, create=True):
        """Replace the contents of `path` (created if missing)."""
        try:
            fid, _ = self.walk(path)
            self._rpc(TOPEN, struct.pack("<IB", fid, 1 | 0x10))
        except P9Error:
            if not create:
                raise
            d, _, name = path.rstrip("/").rpartition("/")
            fid, _ = self.walk(d)
            self._rpc(TCREATE, struct.pack("<I", fid) + _s(name.encode()) + struct.pack("<IB", 0o644, 1))
        try:
            off = 0
            while off < len(data):
                chunk = data[off:off + self.msize - 24]
                r = self._rpc(TWRITE, struct.pack("<IQI", fid, off, len(chunk)) + chunk)
                n, = struct.unpack_from("<I", r, 0)
                if n == 0:
                    raise P9Error("%s: nothing written" % path)
                off += n
        finally:
            self.clunk(fid)

    def mkdir(self, path):
        d, _, name = path.rstrip("/").rpartition("/")
        fid, _ = self.walk(d)
        try:
            self._rpc(TCREATE, struct.pack("<I", fid) + _s(name.encode()) + struct.pack("<IB", DMDIR | 0o755, 0))
        finally:
            self.clunk(fid)

    def remove(self, path):
        fid, _ = self.walk(path)
        self._rpc(TREMOVE, struct.pack("<I", fid))


class Session:
    """exportfs on the device's console, from its start to its end."""

    def __init__(self, tr):
        self.tr = tr
        self.client = None

    def start(self, root="/", type_command=True, timeout=20.0):
        if type_command:
            self.tr.write(b"exportfs /dev/console %s\r" % root.encode())
        self.tr.read_until(BANNER, timeout)
        self.tr.read_until(b"\n", timeout)
        self.client = Client(self.tr)
        return self.client

    def end(self, timeout=10.0):
        """Give the console back to the shell."""
        self.tr.write(b"\0\0\0\0")
        self.tr.read_until(ENDED, timeout)


def run_commands(c, words, out=sys.stdout):
    """The command-line commands, `--` between them."""
    cmds, cur = [], []
    for w in words:
        if w == "--":
            cmds.append(cur)
            cur = []
        else:
            cur.append(w)
    cmds.append(cur)
    for cmd in cmds:
        if not cmd:
            continue
        op, args = cmd[0], cmd[1:]
        if op == "ls":
            for e in c.ls(args[0] if args else "/"):
                out.write("%s %8d %s\n" % ("d" if e["dir"] else "-", e["length"], e["name"]))
        elif op == "cat":
            out.write(c.read(args[0]).decode("utf-8", "replace"))
        elif op == "write":
            c.write(args[0], (" ".join(args[1:]) + "\n").encode())
        elif op == "put":
            with open(args[0], "rb") as f:
                c.write(args[1], f.read())
        elif op == "get":
            with open(args[1], "wb") as f:
                f.write(c.read(args[0]))
        elif op == "rm":
            c.remove(args[0])
        elif op == "mkdir":
            c.mkdir(args[0])
        elif op == "stat":
            e = c.stat(args[0])
            out.write("%s mode %o length %d qid.path %#x%s\n" % (e["name"], e["mode"] & 0o777, e["length"], e["qpath"],
                                                              " directory" if e["dir"] else ""))
        else:
            raise SystemExit("hm9p: unknown command %r (ls cat write put get rm mkdir stat)" % op)


def main(argv):
    tty = cmd = tcp = None
    baud, root, start = 115200, "/", True
    i = 0
    while i < len(argv) and argv[i].startswith("--") and argv[i] != "--":
        if argv[i] == "--tty":
            tty = argv[i + 1]
            i += 2
        elif argv[i] == "--baud":
            baud = int(argv[i + 1])
            i += 2
        elif argv[i] == "--cmd":
            cmd = argv[i + 1].split()
            i += 2
        elif argv[i] == "--tcp":
            tcp = argv[i + 1]
            i += 2
        elif argv[i] == "--root":
            root = argv[i + 1]
            i += 2
        elif argv[i] == "--no-start":
            start = False
            i += 1
        else:
            raise SystemExit(__doc__)
    if [tty, cmd, tcp].count(None) != 2 or i >= len(argv):
        raise SystemExit(__doc__)
    try:
        tr = Transport.tty(tty, baud) if tty else Transport.command(cmd) if cmd else Transport.tcp(tcp)
    except (OSError, P9Error) as e:
        raise SystemExit("hm9p: %s" % e)
    s = Session(tr)
    rc = 0
    try:
        if cmd:
            tr.read_until(b"hamsh$ ", 60)
            time.sleep(0.5)             # the shell drops what is typed while it starts
        elif start:
            tr.write(b"\r")             # is a shell listening?
            tr.read_until(b"hamsh$ ", 5)
        c = s.start(root, start)
        try:
            run_commands(c, argv[i:])
        except P9Error as e:
            sys.stderr.write("hm9p: %s\n" % e)
            rc = 1
        s.end()
    except P9Error as e:
        sys.stderr.write("hm9p: %s\n" % e)
        rc = 2
    finally:
        tr.close()
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
