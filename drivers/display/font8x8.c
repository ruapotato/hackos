/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* Hamnix Micro -- the glyph table of the text screen (drivers/display/textcon.ad):
 * Daniel Hepper's public-domain font8x8 (third_party/font8x8), included
 * unmodified.  One function gives Adder code a glyph's eight rows (bit 0 of
 * each byte is the left-most pixel).  The table is a writable array in the
 * header, so it costs 1 KiB of RAM on a board that links this.             */
#include "font8x8_basic.h"

const unsigned char *hmicro_font8x8(unsigned int c)
{
    if (c > 127)
        c = '?';
    return (const unsigned char *)font8x8_basic[c];
}
