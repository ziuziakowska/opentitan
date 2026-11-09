// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * The application compartment of the CHERIoT RTOS smoke test.
 *
 * Two threads, `main_thread` and `helper_thread`, take turns by yielding (the
 * scheduler is round-robin), each writing three characters to UART0. Then
 * `main_thread` calls into the `callee` compartment through the switcher and
 * prints `PASS!` if everything happened as expected, `FAIL!` otherwise.
 * Expected output: `ABABAB`, then `PASS!`.
 */

#include <stdint.h>

#include "sw/device/lib/base/cheriot_compartment.h"

// The compartment `callee` exports this.
int OT_CHERIOT_COMPARTMENT("callee") add_one(int x);

// UART0's registers (hw/ip/uart): STATUS at 0x14 (bit 0 is TXFULL), WDATA at
// 0x1c.
struct Uart {
  uint32_t unused0[5];
  uint32_t status;
  uint32_t rdata;
  uint32_t wdata;
};

#define UART_STATUS_TXFULL 1u

// Hand control to the scheduler, which resumes the next thread that has not
// finished. The switcher resumes this thread after the `ecall`.
static void yield(void) { __asm__ volatile("ecall" ::: "memory"); }

static void put(volatile struct Uart *uart, char c) {
  while (uart->status & UART_STATUS_TXFULL) {
  }
  uart->wdata = (unsigned char)c;
}

static void puts_(volatile struct Uart *uart, const char *s) {
  for (; *s; ++s) {
    put(uart, *s);
  }
}

// Both threads are in this compartment, so they share its globals.
static volatile int helper_done;

int OT_CHERIOT_COMPARTMENT("app") multiply(int x) {
    return x * 2;
}

void OT_CHERIOT_COMPARTMENT("app") main_thread(void) {
  volatile struct Uart *uart = OT_CHERIOT_MMIO(struct Uart, uart);
  for (int i = 0; i < 3; ++i) {
    put(uart, 'A');
    yield();
  }
  // Wait for the other thread to finish: the scheduler resumes it in turn.
  while (!helper_done) {
    yield();
  }
  put(uart, (char)add_one(41));
  if (add_one(41) == (41 * 2) + 1) {
    puts_(uart, "PASS!\r\n");
  } else {
    puts_(uart, "FAIL!\r\n");
  }
}

void OT_CHERIOT_COMPARTMENT("app") helper_thread(void) {
  volatile struct Uart *uart = OT_CHERIOT_MMIO(struct Uart, uart);
  for (int i = 0; i < 3; ++i) {
    put(uart, 'B');
    yield();
  }
  helper_done = 1;
}
