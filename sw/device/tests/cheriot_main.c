// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Smoke test of the minimal CHERIoT runtime (`sw/device/lib/crt_cheriot`):
 * reaching `main()` and printing `PASS!` on UART0 shows the CRT set up PCC,
 * `cgp` and the stack. Entered as a plain `main()`; MMIO capabilities are
 * derived here from the root the CRT publishes.
 *
 * TODO: actually check `.data` initialisation, `.bss` zeroing and `.rodata`
 * access, and report `FAIL!` otherwise.
 *
 * Do NOT add statically initialised pointers at file scope: they need
 * `__cap_relocs` processing, which this CRT does not implement.
 */

#include <stddef.h>

#include "hw/top/rv_core_ibex_regs.h"  // Generated.
#include "hw/top/top_earlgrey.h"       // Generated.
#include "hw/top/uart_regs.h"          // Generated.
#include "sw/device/lib/crt_cheriot/crt.h"
#include "sw/device/lib/testing/test_framework/status.h"

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
  volatile char *uart = mmio_cap(TOP_EARLGREY_UART0_BASE_ADDR, TOP_EARLGREY_UART0_SIZE_BYTES);
  volatile char *ibex_cfg =
      mmio_cap(TOP_EARLGREY_RV_CORE_IBEX_CFG_BASE_ADDR, TOP_EARLGREY_RV_CORE_IBEX_CFG_SIZE_BYTES);
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
