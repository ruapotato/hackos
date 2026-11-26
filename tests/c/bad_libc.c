/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* NEGATIVE test input for tests/check_c_link.sh: never linked into an image.
 * Compiled WITHOUT the rename header, so it refers to the bare `memcpy` (the
 * Adder-convention function in this image) and to an Adder kernel function,
 * and it defines a bare C library name.  The check must reject all three.  */
#include <stddef.h>
void *memcpy(void *dst, const void *src, size_t n);
unsigned long long kmalloc(unsigned long long size);
size_t strlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }
void *bad_copy(void *dst, const void *src, size_t n)
{
    (void)kmalloc(n);
    return memcpy(dst, src, n);
}
