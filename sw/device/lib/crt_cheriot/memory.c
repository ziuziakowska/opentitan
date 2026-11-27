// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * `memmove`, which the compiler may emit calls to but
 * `//sw/device/lib/base:memory` (providing `memcpy`, `memset`, `memcmp`, ...)
 * does not define.
 *
 * Copies bytes, so it does NOT preserve capability tags.
 */

#include <stddef.h>

[[clang::no_builtin]] void *memmove(void *dst, const void *src, size_t n) {
  unsigned char *d = dst;
  const unsigned char *s = src;
  if (d < s) {
    while (n--) {
      *d++ = *s++;
    }
  } else {
    // Copy backwards so an overlapping tail is read before it is overwritten.
    d += n;
    s += n;
    while (n--) {
      *--d = *--s;
    }
  }
  return dst;
}
