# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 David Hamner
# BOARD=qemu-mps2 (the default): QEMU `-M mps2-an500`, the machine every test
# of `make test` runs on.  Nothing is patched for this board.
IMAGES := hackos monitor ktest selftest faulttest
