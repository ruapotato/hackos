#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
"""hm9pd.py -- serve a directory of this PC to a Hamnix Micro device over a
serial line, with 9P2000.  Python standard library only.

    hm9pd.py --tty /dev/ttyUSB1 DIR          a serial port wired to the device
    hm9pd.py --unix PATH DIR                 a Unix socket (an emulator's port)
    hm9pd.py --tcp HOST:PORT DIR             a TCP socket

On the device, with that line as a device file (/dev/eia1 on the QEMU
boards; docs/9p.md):

    hamsh$ srv /dev/eia1 pc
    hamsh$ mount /srv/pc /n/pc
    hamsh$ ls /n/pc

One client, one request at a time, no authentication; files and directories
below DIR only (a name that would lead outside it does not exist).
--read-only refuses every change.  Runs until the line closes or Ctrl-C.
"""
import os
import stat as st
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hm9p  # noqa: E402

QTDIR = 0x80
DMDIR = 0x80000000


def _s(b):
    return struct.pack("<H", len(b)) + b


class Fid:
    def __init__(self, path):
        self.path = path
        self.f = None           # an open file object
        self.dirdata = None     # an open directory's stat records, read so far up to:
        self.dirnext = 0        # ... this record
        self.diroff = 0         # ... which is this offset


class Server:
    def __init__(self, tr, root, readonly=False, msize=8192):
        self.tr = tr
        self.root = os.path.realpath(root)
        self.readonly = readonly
        self.maxmsize = msize
        self.msize = msize
        self.fids = {}
        self.requests = 0

    # ---- names and stat records
    def _inside(self, path):
        rp = os.path.realpath(path)
        return rp == self.root or rp.startswith(self.root + os.sep)

    @staticmethod
    def _qid(s):
        return struct.pack("<BIQ", QTDIR if st.S_ISDIR(s.st_mode) else 0, int(s.st_mtime) & 0xFFFFFFFF, s.st_ino)

    def _stat(self, path):
        s = os.stat(path)
        name = b"/" if os.path.realpath(path) == self.root else os.path.basename(path).encode()
        mode = (s.st_mode & 0o777) | (DMDIR if st.S_ISDIR(s.st_mode) else 0)
        length = 0 if st.S_ISDIR(s.st_mode) else s.st_size
        body = struct.pack("<HI", 0, 0) + self._qid(s) + struct.pack("<IIIQ", mode, int(s.st_atime), int(s.st_mtime), length) \
            + _s(name) + _s(b"pc") + _s(b"pc") + _s(b"pc")
        return struct.pack("<H", len(body)) + body

    # ---- requests: each returns the reply's type and body, or raises
    def t_version(self, b):
        msize, = struct.unpack_from("<I", b, 0)
        self.msize = min(msize, self.maxmsize)
        for f in self.fids.values():
            if f.f:
                f.f.close()
        self.fids = {}
        return struct.pack("<I", self.msize) + _s(b"9P2000")

    def t_attach(self, b):
        fid, = struct.unpack_from("<I", b, 0)
        self.fids[fid] = Fid(self.root)
        return self._qid(os.stat(self.root))

    def t_walk(self, b):
        fid, newfid, n = struct.unpack_from("<IIH", b, 0)
        path = self.fids[fid].path
        o, qids = 10, []
        for _ in range(n):
            l, = struct.unpack_from("<H", b, o)
            name = b[o + 2:o + 2 + l].decode("utf-8", "replace")
            o += 2 + l
            if name == "..":
                nxt = path if path == self.root else os.path.dirname(path)
            elif "/" in name or name == "":
                nxt = None
            else:
                nxt = path if name == "." else os.path.join(path, name)
            if nxt is None or not os.path.lexists(nxt) or not self._inside(nxt):
                if not qids:
                    raise OSError("file does not exist")
                break
            path = nxt
            qids.append(self._qid(os.stat(path)))
        if len(qids) == n:
            self.fids[newfid] = Fid(path)
        return struct.pack("<H", len(qids)) + b"".join(qids)

    def _open(self, f, mode):
        if os.path.isdir(f.path):
            if mode & 3:
                raise OSError("is a directory")
            f.dirdata = []
        else:
            if (mode & 3 or mode & 0x10) and self.readonly:
                raise OSError("permission denied: read-only export")
            f.f = open(f.path, {0: "rb", 1: "r+b", 2: "r+b", 3: "rb"}[mode & 3])
            if mode & 0x10:
                f.f.truncate(0)

    def t_open(self, b):
        fid, mode = struct.unpack_from("<IB", b, 0)
        f = self.fids[fid]
        self._open(f, mode)
        return self._qid(os.stat(f.path)) + struct.pack("<I", self.msize - 24)

    def t_create(self, b):
        fid, l = struct.unpack_from("<IH", b, 0)
        name = b[6:6 + l].decode("utf-8", "replace")
        perm, mode = struct.unpack_from("<IB", b, 6 + l)
        f = self.fids[fid]
        if self.readonly:
            raise OSError("permission denied: read-only export")
        if "/" in name or name in ("", ".", ".."):
            raise OSError("bad name")
        path = os.path.join(f.path, name)
        if os.path.lexists(path):
            raise OSError("file exists")
        if perm & DMDIR:
            os.mkdir(path)
            f.path = path
            f.dirdata = []
        else:
            open(path, "xb").close()
            f.path = path
            f.f = open(path, "r+b")
        return self._qid(os.stat(path)) + struct.pack("<I", self.msize - 24)

    def t_read(self, b):
        fid, off, count = struct.unpack_from("<IQI", b, 0)
        f = self.fids[fid]
        count = min(count, self.msize - 24)
        if f.dirdata is not None:
            if off == 0:
                f.dirdata = [self._stat(os.path.join(f.path, n)) for n in sorted(os.listdir(f.path))
                             if os.path.exists(os.path.join(f.path, n))]
                f.diroff = 0
                f.dirnext = 0
            elif off != f.diroff:
                raise OSError("a directory is read from its start or from where the last read ended")
            out = b""
            while f.dirnext < len(f.dirdata) and len(out) + len(f.dirdata[f.dirnext]) <= count:
                out += f.dirdata[f.dirnext]
                f.dirnext += 1
            f.diroff += len(out)
            return struct.pack("<I", len(out)) + out
        if f.f is None:
            raise OSError("fid is not open")
        f.f.seek(off)
        data = f.f.read(count)
        return struct.pack("<I", len(data)) + data

    def t_write(self, b):
        fid, off, count = struct.unpack_from("<IQI", b, 0)
        f = self.fids[fid]
        if f.f is None or self.readonly:
            raise OSError("fid is not open for writing")
        f.f.seek(off)
        f.f.write(b[16:16 + count])
        f.f.flush()
        return struct.pack("<I", count)

    def t_clunk(self, b):
        fid, = struct.unpack_from("<I", b, 0)
        f = self.fids.pop(fid)
        if f.f:
            f.f.close()
        return b""

    def t_remove(self, b):
        fid, = struct.unpack_from("<I", b, 0)
        f = self.fids.pop(fid)
        if f.f:
            f.f.close()
        if self.readonly or f.path == self.root:
            raise OSError("permission denied")
        if os.path.isdir(f.path):
            os.rmdir(f.path)
        else:
            os.remove(f.path)
        return b""

    def t_stat(self, b):
        fid, = struct.unpack_from("<I", b, 0)
        s = self._stat(self.fids[fid].path)
        return struct.pack("<H", len(s)) + s

    def serve(self):
        """Until the line closes.  Returns the number of requests served."""
        table = {100: self.t_version, 104: self.t_attach, 110: self.t_walk, 112: self.t_open, 114: self.t_create,
                 116: self.t_read, 118: self.t_write, 120: self.t_clunk, 122: self.t_remove, 124: self.t_stat}
        while True:
            try:
                size, t, tag = struct.unpack("<IBH", self.tr.read_exact(7, 1e9))
                if size < 7 or size > 65536:
                    continue                    # noise on the line: look for the next header
                body = self.tr.read_exact(size - 7, 30)
            except hm9p.P9Error:
                return self.requests
            self.requests += 1
            try:
                if t == 108:
                    rt, rb = 109, b""           # Tflush: nothing is ever pending
                elif t in table:
                    rt, rb = t + 1, table[t](body)
                else:
                    raise OSError("not supported" if t in (102, 126) else "not a 9P2000 request")
            except KeyError:
                rt, rb = 107, _s(b"unknown fid")
            except FileExistsError:
                rt, rb = 107, _s(b"file exists")
            except FileNotFoundError:
                rt, rb = 107, _s(b"file does not exist")
            except PermissionError:
                rt, rb = 107, _s(b"permission denied")
            except (OSError, struct.error) as e:
                rt, rb = 107, _s(str(e.args[-1] if e.args else e).encode()[:120])
            self.tr.write(struct.pack("<IBH", 7 + len(rb), rt, tag) + rb)


def unix_transport(path):
    import socket
    import time
    for _ in range(200):
        try:
            sk = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sk.connect(path)
            break
        except OSError:
            sk.close()
            time.sleep(0.25)
    else:
        raise hm9p.P9Error("cannot connect to %s" % path)
    t = hm9p.Transport(sk.fileno(), sk.fileno())
    t.sock = sk
    return t


def main(argv):
    ro = "--read-only" in argv
    argv = [a for a in argv if a != "--read-only"]
    if len(argv) != 3 or argv[0] not in ("--tty", "--unix", "--tcp") or not os.path.isdir(argv[2]):
        raise SystemExit(__doc__)
    try:
        if argv[0] == "--tty":
            tr = hm9p.Transport.tty(argv[1])
        elif argv[0] == "--unix":
            tr = unix_transport(argv[1])
        else:
            tr = hm9p.Transport.tcp(argv[1])
    except (OSError, hm9p.P9Error) as e:
        raise SystemExit("hm9pd: %s" % e)
    srv = Server(tr, argv[2], ro)
    try:
        n = srv.serve()
    except KeyboardInterrupt:
        n = srv.requests
    sys.stderr.write("hm9pd: %d requests served\n" % n)
    tr.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
