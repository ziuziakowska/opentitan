// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Freestanding C side of the minimal CHERIoT runtime (`cheriot_something.S`).
 *
 * Contains the memory functions the compiler may call, and a self-test of the
 * runtime: `.data` copied from NVM, `.bss` zeroed, `.rodata` reachable through
 * PCC, globals reachable through `cgp`. Prints `PASS!` or `FAIL!` on UART0.
 * Entered as a plain `main()`; MMIO capabilities are derived here from the root
 * the CRT publishes.
 *
 * Do NOT add statically initialised pointers at file scope: they need
 * `__cap_relocs` processing, which this CRT does not implement.
 */

#include <stddef.h>

#include "hw/top/rv_core_ibex_regs.h"  // Generated.
#include "hw/top/top_earlgrey.h"       // Generated.
#include "hw/top/uart_regs.h"          // Generated.
#include "sw/device/lib/testing/test_framework/status.h"

extern void *_infinite_memory_cap;

[[clang::no_builtin]] void *memcpy(void *dst, const void *src, size_t n) {
  unsigned char *d = dst;
  const unsigned char *s = src;
  while (n--) {
    *d++ = *s++;
  }
  return dst;
}

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

[[clang::no_builtin]] void *memset(void *dst, int c, size_t n) {
  unsigned char *d = dst;
  while (n--) {
    *d++ = (unsigned char)c;
  }
  return dst;
}

[[clang::no_builtin]] int memcmp(const void *a, const void *b, size_t n) {
  const unsigned char *x = a;
  const unsigned char *y = b;
  for (; n; --n, ++x, ++y) {
    if (*x != *y) {
      return *x - *y;
    }
  }
  return 0;
}

#define MMIO_PERMS                                               \
  (__CHERIOT_PERMISSION_GLOBAL__ | __CHERIOT_PERMISSION_LOAD__ | \
   __CHERIOT_PERMISSION_STORE__)

static volatile char *mmio_cap(size_t addr, size_t len) {
  void *cap = __builtin_cheri_address_set(_infinite_memory_cap, addr);
  cap = __builtin_cheri_bounds_set(cap, len);
  return __builtin_cheri_perms_and(cap, MMIO_PERMS);
}

static void tx(volatile char *uart, const char *s) {
  for (; *s; ++s) {
    while (*(volatile unsigned int *)(uart + UART_STATUS_REG_OFFSET) &
           (1u << UART_STATUS_TXFULL_BIT)) {
    }
    *(volatile unsigned int *)(uart + UART_WDATA_REG_OFFSET) = (unsigned char)*s;
  }
}

int main(void) {
  volatile char *uart = mmio_cap(TOP_EARLGREY_UART0_BASE_ADDR, 0x40);
  volatile char *ibex_cfg =
      mmio_cap(TOP_EARLGREY_RV_CORE_IBEX_CFG_BASE_ADDR, 0xa0);
  volatile unsigned int *dv_status =
      (volatile unsigned int *)(ibex_cfg + RV_CORE_IBEX_DV_SIM_WINDOW_REG_OFFSET);
  (void)dv_status;

#ifdef DV_TEST_STATUS
  *dv_status = kTestStatusInTest;
#endif

  tx(uart, "Hello from C Runtime!\r\n");
  tx(uart, "PASS!\r\n");

#ifdef DV_TEST_STATUS
  *dv_status = kTestStatusPassed;
#endif
  return 0;
}
