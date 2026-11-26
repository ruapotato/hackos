/* SPDX-License-Identifier: AGPL-3.0-or-later */
/* Copyright (C) 2026 David Hamner */
/* HackOS minimal <stdlib.h> for third-party C code: no heap, no process. */
#ifndef HACKOS_CSHIM_STDLIB_H
#define HACKOS_CSHIM_STDLIB_H
#include <stddef.h>
int abs(int v);
#endif
