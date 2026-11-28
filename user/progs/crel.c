/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* Hamnix Micro -- a C program as a process, and the loader's relocation test.
 *
 * Adder programs address everything PC-relative and need no load-time
 * relocation.  C code with statically initialised pointers does: every
 * entry of the tables below is an R_ARM_RELATIVE that the loader must fix,
 * or the program reads the wrong memory.
 *
 * The run-time (user/rt/rt.ad) is Adder code, so its functions take 64-bit
 * argument slots; declared with 64-bit integer parameters they can be
 * called from C directly (AAPCS puts a 64-bit integer where Adder expects
 * it).  main() is called by the run-time with the same convention.       */
#include <stdint.h>

int64_t sys_write(int64_t fd, uint64_t buf, uint64_t count);

static int twice(int x) { return x * 2; }
static int thrice(int x) { return x * 3; }

static const char *const names[] = { "alpha", "beta", "gamma", "delta" };
static int (*const ops[])(int) = { twice, thrice };
static int value = 7;
static int *const pvalue = &value;
static const char *volatile late = "relocated";

static unsigned len(const char *s) { unsigned n = 0; while (s[n]) n++; return n; }
static void put(const char *s) { sys_write(1, (uint64_t)(uintptr_t)s, len(s)); }

int64_t main(int64_t argc, uint64_t argv)
{
    int r = 0;
    volatile int i0 = 0, i1 = 1, i2 = 2, i3 = 3;   /* keep the tables real */
    (void)argc; (void)argv;
    if (names[i0][0] == 'a' && names[i3][4] == 'a' && len(names[i2]) == 5) r |= 1;
    if (ops[i0](21) == 42 && ops[i1](14) == 42) r |= 2;
    *pvalue = *pvalue + 1;
    if (value == 8) r |= 4;
    put("crel: ");
    put(late);
    put(" pointers ok\n");
    return r;
}
