// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * A minimal cooperative scheduler for the CHERIoT RTOS loader and switcher.
 *
 * The loader and the switcher need a "scheduler" compartment that exports two
 * functions:
 *
 *   - `scheduler_entry`: called once by the loader, through the switcher, with
 *     a capability to an array of `ThreadLoaderInfo` (one per thread).
 *   - `exception_entry`: called by the switcher (with interrupts deferred) on
 *     every trap that is not handled inside a compartment: an explicit yield
 *     (`ecall`), a thread whose outermost compartment call has returned or
 *     faulted, or an interrupt. It is given the interrupted thread's sealed
 *     trusted stack and returns the sealed trusted stack to resume.
 *
 * The scheduler never looks inside a trusted stack: it stores and returns the
 * sealed pointers it is given, as the RTOS's own scheduler does.
 *
 * Policy: round-robin over the threads that have not exited, in the order the
 * loader listed them; priorities are ignored. With no thread left to run it
 * resumes the idle thread, which is the loader's boot thread (it waits for
 * interrupts). The number of threads is whatever the loader provides, up to
 * `CHERIOT_SCHEDULER_MAX_THREADS`.
 *
 * Interrupts and timers are not supported: this compartment has no access to
 * system registers or devices, so any interrupt is treated as a panic.
 *
 * The export names are mangled by the compiler from these signatures; the
 * loader refers to them (see the patch to `core/loader/boot.cc`).
 */

#include <stddef.h>
#include <stdint.h>

#include "sw/device/lib/base/cheriot_compartment.h"

#ifndef CHERIOT_SCHEDULER_MAX_THREADS
#define CHERIOT_SCHEDULER_MAX_THREADS 16
#endif

// `mcause` values the switcher passes on (sdk/include/priv/riscv.h).
#define MCAUSE_ECALL_MACHINE 11u
#define MCAUSE_THREAD_EXIT 24u

typedef void *__sealed_capability SealedTrustedStack;

// The loader's description of a thread (sdk/core/scheduler/loaderinfo.h). The
// name matters: it is part of `scheduler_entry`'s mangled export name.
struct ThreadLoaderInfo {
  // The thread's trusted stack, sealed by the loader.
  SealedTrustedStack trustedStack;
  // The thread's priority (unused here).
  uint16_t priority;
};

// No thread is running: the idle thread is.
#define NO_THREAD ((size_t)-1)

static SealedTrustedStack threads[CHERIOT_SCHEDULER_MAX_THREADS];
static uint8_t alive[CHERIOT_SCHEDULER_MAX_THREADS];
static size_t thread_count;
// Index of the running thread, or `NO_THREAD` for the idle thread.
static size_t current = NO_THREAD;
// The idle thread's trusted stack, saved when it is first interrupted.
static SealedTrustedStack idle;

// What went wrong, for a debugger to read.
volatile size_t panic_mcause, panic_mepc, panic_mtval;

__attribute__((noreturn)) static void panic(size_t mcause, size_t mepc,
                                            size_t mtval) {
  panic_mcause = mcause;
  panic_mepc = mepc;
  panic_mtval = mtval;
  for (;;) {
  }
}

[[cheriot::interrupt_state(disabled)]] int OT_CHERIOT_COMPARTMENT("scheduler")
    scheduler_entry(const struct ThreadLoaderInfo *info) {
  thread_count = __builtin_cheri_length_get(info) / sizeof(*info);
  if (thread_count > CHERIOT_SCHEDULER_MAX_THREADS) {
    panic(0, 0, thread_count);
  }
  for (size_t i = 0; i < thread_count; ++i) {
    threads[i] = info[i].trustedStack;
    alive[i] = 1;
  }
  return 0;
}

// The next thread that has not exited after the running one, or the idle
// thread.
static SealedTrustedStack schedule(void) {
  size_t last = current == NO_THREAD ? thread_count - 1 : current;
  for (size_t step = 1; step <= thread_count; ++step) {
    size_t candidate = (last + step) % thread_count;
    if (alive[candidate]) {
      current = candidate;
      return threads[candidate];
    }
  }
  current = NO_THREAD;
  return idle;
}

[[cheriot::interrupt_state(disabled)]] SealedTrustedStack
OT_CHERIOT_COMPARTMENT("scheduler")
    exception_entry(SealedTrustedStack interrupted, size_t mcause, size_t mepc,
                    size_t mtval) {
  switch (mcause) {
    case MCAUSE_ECALL_MACHINE:
      // A yield: remember where the interrupted thread was, and pick the next.
      if (current == NO_THREAD) {
        idle = interrupted;
      } else {
        threads[current] = interrupted;
      }
      return schedule();
    case MCAUSE_THREAD_EXIT:
      // The thread has finished: it is never run again, and its trusted stack
      // is not saved. If it was the last, the idle thread resumes.
      alive[current] = 0;
      return schedule();
    default:
      panic(mcause, mepc, mtval);
  }
}
