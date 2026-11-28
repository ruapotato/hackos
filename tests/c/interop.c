/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* Hamnix Micro test: the C side of the Adder <-> C calling tests in
 * tests/kt_cinterop.ad.  Ordinary C, ordinary prototypes.                 */
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

struct hk_rec {                 /* mirrored by `class CRec` in Adder */
    uint8_t  tag;
    uint16_t len;
    uint32_t crc;
    uint64_t big;
    double   ratio;
    char     name[12];
};

/* every argument class in one call; the result mixes them so a wrong
 * register or a missing extension changes it */
double hk_c_mix(uint64_t a, int32_t b, double d, float f, uint8_t u8, int16_t s16)
{
    return (double)(a >> 32) + (double)b + d * (double)f + (double)u8 + (double)s16;
}

int64_t hk_c_wide(int8_t a, int16_t b, uint16_t c)
{
    return (int64_t)a * 1000000000000LL + (int64_t)b * 65536 + c;
}

int8_t hk_c_neg8(int32_t v) { return (int8_t)-abs(v); }
uint16_t hk_c_u16(uint32_t v) { return (uint16_t)(v + 1); }

/* C -> Adder through a function pointer handed over at run time */
uint32_t hk_c_apply(uint32_t (*fn)(uint32_t i, void *ctx), void *ctx, uint32_t n)
{
    uint32_t sum = 0;
    for (uint32_t i = 0; i < n; i++)
        sum += fn(i, ctx);
    return sum;
}

/* structures by pointer, and the C library through the shim */
uint32_t hk_c_fill(struct hk_rec *r, const char *name)
{
    memset(r, 0, sizeof *r);
    r->tag = 0xA7;
    r->len = (uint16_t)strlen(name);
    r->crc = 0xC0FFEE00u + r->len;
    r->big = 0x0123456789ABCDEFull;
    r->ratio = 0.375;
    strncpy(r->name, name, sizeof r->name - 1);
    return (uint32_t)sizeof *r;
}

uint32_t hk_c_check(const struct hk_rec *r)
{
    char want[12];
    memcpy(want, "from-adder", 11);
    return (r->tag == 0x5A) + 2 * (r->len == 4660) + 4 * (r->crc == 0xDEADBEEFu)
         + 8 * (r->big == 0xFEDCBA9876543210ull) + 16 * (r->ratio == -2.5)
         + 32 * (memcmp(r->name, want, 11) == 0) + 64 * (strcmp(r->name, want) == 0);
}
