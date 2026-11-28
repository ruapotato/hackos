#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# Hamnix Micro link-time rule for mixing C and Adder.
#
# An Adder function takes every integer or pointer argument as a 64-bit slot;
# a C function does not.  The linker binds by name only, so a C call to an
# Adder-convention function (or the reverse) links without complaint and then
# passes its arguments in the wrong registers.  Milestone 1 hit exactly that
# with `memcpy`.  This script makes the three ways it can happen a build error:
#
#   R1  A symbol a C object needs must be defined by C, be a compiler helper
#       (__aeabi_*) defined in assembly, or be an Adder function exported with
#       `extern "C" def ...:`.  Anything else would be a C call into an
#       Adder-convention function.
#   R2  A symbol the Adder object needs that C defines must be declared
#       `extern "C" def ...` in Adder.  Otherwise Adder would call C with
#       64-bit slots.
#   R3  No C or assembly object may define a bare C library name
#       (memcpy, memset, strlen, ...): Adder code owns those names with its
#       own convention.  C code gets hmicro_c_* (lib/cshim).
#
# usage: check_c_link.sh <adder.ll> <adder.o> <asm.o>... -- <c.o>...
# The .ll is read for the compiler's `; ADDER_CABI_EXPORT/IMPORT name` lines.
# Prints one line per violation; exit status 1 if there is any.
set -u
NM="${NM:-llvm-nm}"
LL="$1"; AOBJ="$2"; shift 2
ASM=(); COBJ=(); seen=0
for a in "$@"; do
    if [ "$a" = "--" ]; then seen=1; continue; fi
    if [ $seen = 0 ]; then ASM+=("$a"); else COBJ+=("$a"); fi
done
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
defined() { "$NM" --defined-only -g "$@" 2>/dev/null | awk 'NF>=3{print $3}' | sort -u; }
undefined() { "$NM" -u "$@" 2>/dev/null | awk 'NF>=2 && $1=="U"{print $2}' | sort -u; }
sed -n 's/^; ADDER_CABI_EXPORT //p' "$LL" | sort -u > "$T/export"
sed -n 's/^; ADDER_CABI_IMPORT //p' "$LL" | sort -u > "$T/import"
defined "${COBJ[@]}" > "$T/cdef"
undefined "${COBJ[@]}" > "$T/cund"
defined "${ASM[@]}" > "$T/asmdef"
defined "$AOBJ" > "$T/adef"
undefined "$AOBJ" > "$T/aund"
bad=0
# R1
while read -r s; do
    [ -z "$s" ] && continue
    grep -qxF -- "$s" "$T/cdef" && continue
    grep -qxF -- "$s" "$T/export" && continue
    case "$s" in __aeabi_*) grep -qxF -- "$s" "$T/asmdef" && continue;; esac
    if grep -qxF -- "$s" "$T/adef"; then
        echo "R1: C code calls '$s', an Adder-convention function (export it with extern \"C\" or use the hmicro_c_ form)"
    else
        echo "R1: C code needs '$s', which nothing C-callable defines"
    fi
    bad=1
done < "$T/cund"
# R2
while read -r s; do
    [ -z "$s" ] && continue
    grep -qxF -- "$s" "$T/cdef" || continue
    grep -qxF -- "$s" "$T/import" && continue
    echo "R2: Adder code calls the C function '$s' without an extern \"C\" declaration"
    bad=1
done < "$T/aund"
# R3
for s in memcpy memmove memset memcmp strlen strcmp strncmp strcpy strncpy strcat strchr malloc free calloc realloc printf puts abort exit; do
    if grep -qxF -- "$s" "$T/cdef" || grep -qxF -- "$s" "$T/asmdef"; then
        echo "R3: a C or assembly object defines the bare C library name '$s'"
        bad=1
    fi
done
[ $bad = 0 ] && echo "ok: $(wc -l < "$T/cund") symbols needed by C, $(wc -l < "$T/export") Adder functions exported to C, $(wc -l < "$T/import") C functions imported by Adder"
exit $bad
