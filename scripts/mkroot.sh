#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# mkroot.sh OUT BOARD_DIR [PATCH...]
#
# Builds the source tree one board is compiled from.  The Adder compiler
# resolves `from a.b import x` as a/b.ad relative to its working directory and
# has no search path, so board selection is done by the tree it runs in:
#
#   OUT/<dir>/...   a symbolic link to every file of the firmware tree
#   OUT/board       a link to boards/BOARD_DIR (kernel code imports board.board)
#   OUT/<path>      for each PATCH = boards/BOARD_DIR/patches/<path>.patch: a
#                   real file, <path> with that patch applied (a per-board size
#                   configuration of copied code; the committed file is left
#                   as it is)
#
# Run from the firmware root.  OUT is removed and made again.
set -euo pipefail
out="$1"; board="$2"; shift 2
top="$(pwd)"
[ -d "boards/$board" ] || { echo "mkroot: no boards/$board" >&2; exit 1; }
rm -rf "$out"; mkdir -p "$out"
for d in arch boards demo drivers fs init kernel lib mm soc tests user; do
    [ -d "$d" ] && cp -rs "$top/$d" "$out/$d"
done
ln -s "$top/boards/$board" "$out/board"
for p in "$@"; do
    rel="${p#boards/$board/patches/}"; rel="${rel%.patch}"
    [ "$rel" != "$p" ] && [ -f "$rel" ] || { echo "mkroot: $p does not name a file under boards/$board/patches/" >&2; exit 1; }
    rm -f "$out/$rel"
    patch -s -o "$out/$rel" "$rel" "$p" || { echo "mkroot: $p does not apply to $rel" >&2; exit 1; }
done
touch "$out/.stamp"
