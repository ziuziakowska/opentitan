// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * The very first instructions of the RTOS loader on OpenTitan (included by
 * `core/loader/boot.S`, before its first instruction).
 *
 * Whatever boots the image hands over with the core in RV32 mode, so these run
 * as RV32: they are assembled for CHERIoT, where loads and stores have the same
 * encodings, and compression and relaxation are off so that the encodings cannot
 * depend on assembler choices. Selecting and locking CHERIoT mode makes the next
 * instruction, the loader's first, execute as CHERIoT.
 */

#include "hw/top/rv_core_ibex_regs.h"  // Generated.
#include "hw/top/top_memory.h"         // Generated.
#include "sw/device/lib/base/multibits_asm.h"

  .option push
  .option norvc
  .option norelax

  li a0, TOP_RV_CORE_IBEX_CFG_BASE_ADDR
  li a1, MULTIBIT_ASM_BOOL4_TRUE
  sw a1, RV_CORE_IBEX_CHERIOT_ENA_REG_OFFSET(a0)
  sw a1, RV_CORE_IBEX_CHERIOT_LOCK_REG_OFFSET(a0)
  fence
  fence.i

  .option pop
