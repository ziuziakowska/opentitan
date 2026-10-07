// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "hw/top/rv_core_ibex_regs.h"  // Generated.
#include "hw/top/top_memory.h" // Generated.
#include "hw/top/uart_regs.h"  // Generated.

#define cheri_address_get(x) __builtin_cheri_address_get(x)
#define cheri_address_set(x, y) __builtin_cheri_address_set((x), (y))
#define cheri_bounds_set(x, y) __builtin_cheri_bounds_set((x), (y))
#define cheri_bounds_set_exact(x, y) __builtin_cheri_bounds_set_exact((x), (y))

#define TOP_UART0_BASE_ADDR 0x40000000

extern void *__capability _infinite_memory_cap;

volatile void * __capability something(void) {
    volatile void *__capability uart = cheri_address_set(_infinite_memory_cap, TOP_UART0_BASE_ADDR);
    return uart;
}

int main(void) {
    volatile void *__capability uart = something();
    *(volatile unsigned long *)(uart + UART_WDATA_REG_OFFSET) = '!';
    
    return 5;
}
