/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* Forced into every C translation unit of HackOS (clang -include).
 *
 * Adder code (Hamnix sources in particular) defines and calls functions named
 * memcpy and memset with the ADDER calling convention: every argument is a
 * 64-bit slot.  A C function of the same name cannot exist next to them, and
 * a C caller that bound to the Adder one would pass its arguments in the
 * wrong registers and corrupt memory (this happened in milestone 1).
 *
 * So C code in this image never refers to the bare C library names.  This
 * header renames them to the hackos_c_* implementations in lib/cshim/libc.c.
 * Calls the compiler generates by itself use the __aeabi_* names on this
 * target, which have their own entry points.  tests/check_c_link.sh fails the
 * build if a C object still references a bare name.                        */
#ifndef HACKOS_LIBC_RENAME_H
#define HACKOS_LIBC_RENAME_H
#define memcpy   hackos_c_memcpy
#define memmove  hackos_c_memmove
#define memset   hackos_c_memset
#define memcmp   hackos_c_memcmp
#define strlen   hackos_c_strlen
#define strcmp   hackos_c_strcmp
#define strncmp  hackos_c_strncmp
#define strncpy  hackos_c_strncpy
#define abs      hackos_c_abs
#endif
