/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* Measurement fixture (not part of the firmware, never linked into it): the C
 * twin of tests/measure/cost.ad, compiled by the same clang for the same
 * target, as the yardstick for the cost of Adder's 64-bit value model. */
#include <stdint.h>

struct Item {
    uint32_t key;
    struct Item *next;
    uint8_t *data;
};

uint32_t ext_copy(uint8_t *dst, uint8_t *src, uint32_t n);
uint32_t ext5(uint8_t *a, uint8_t *b, uint8_t *c, uint8_t *d, uint32_t e);

struct Item *g_items;

uint32_t deref(uint32_t *p) { return p[0]; }

void store(uint32_t *p, uint32_t v) { p[0] = v; }

uint32_t call3(uint8_t *dst, uint8_t *src, uint32_t n) { return ext_copy(dst, src, n) + 1; }

uint32_t call5(uint8_t *a, uint8_t *b, uint8_t *c, uint8_t *d, uint32_t e) { return ext5(a, b, c, d, e); }

uint32_t sum_array(uint32_t *a, uint32_t n)
{
    uint32_t s = 0;
    for (uint32_t i = 0; i < n; i++)
        s += a[i];
    return s;
}

uint32_t list_sum(struct Item *head)
{
    uint32_t s = 0;
    for (struct Item *p = head; p; p = p->next)
        s += p->key;
    return s;
}

void bump_first(void) { g_items[0].key = g_items[0].key + 1; }

void copy_bytes(uint8_t *d, uint8_t *s, uint32_t n)
{
    for (uint32_t i = 0; i < n; i++)
        d[i] = s[i];
}

unsigned sizeof_item(void) { return sizeof(struct Item); }
