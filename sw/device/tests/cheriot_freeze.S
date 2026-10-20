// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "sw/device/lib/base/multibits_asm.h"
#include "hw/top/cheriot_mem_sys_regs.h" // Generated.
#include "hw/top/rv_core_ibex_regs.h" // Generated.
#include "hw/top/sram_ctrl_regs.h" // Generated.
#include "hw/top/top_memory.h" // Generated.

#define DV_STATUS_IN_TEST 0x4354
#define DV_STATUS_PASSED  0x900d
#define DV_STATUS_FAILED  0xbaad

  .section .crt, "ax", @progbits
  .balign 4
  .globl _ottf_start
  .type _ottf_start, @function
_ottf_start:
  li   a0, TOP_SRAM_CTRL_META_REGS_BASE_ADDR
  li   a1, (1 << SRAM_CTRL_CTRL_INIT_BIT)
  sw   a1, SRAM_CTRL_CTRL_REG_OFFSET(a0)
meta_sram_init_loop:
  lw   a1, SRAM_CTRL_STATUS_REG_OFFSET(a0)
  andi a1, a1, (1 << SRAM_CTRL_STATUS_INIT_DONE_BIT)
  beqz a1, meta_sram_init_loop

  // Clear all registers before entering CHERIoT Mode.
  // Uses `.insn` directives because the CHERIoT Assembler
  // does not recognise registers x16-x31.
//.insn 0x00000093
//.insn 0x00000113
//.insn 0x00000193
//.insn 0x00000213
//.insn 0x00000293
//.insn 0x00000313
//.insn 0x00000393
//.insn 0x00000413
//.insn 0x00000493
//.insn 0x00000513
//.insn 0x00000593
//.insn 0x00000613
//.insn 0x00000693
//.insn 0x00000713
//.insn 0x00000793
//.insn 0x00000813
//.insn 0x00000893
//.insn 0x00000913
//.insn 0x00000993
//.insn 0x00000a13
//.insn 0x00000a93
//.insn 0x00000b13
//.insn 0x00000b93
//.insn 0x00000c13
//.insn 0x00000c93
//.insn 0x00000d13
//.insn 0x00000d93
//.insn 0x00000e13
//.insn 0x00000e93
//.insn 0x00000f13
//.insn 0x00000f93

cheriot_header:
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
cheriot_start:
  // Run with bazel run //sw/device/tests:cheriot_freeze_sim_verilator,
  // then inspect trace_core_00000000.log.

  // This instruction causes a freeze!
  crepresentablealignmentmask tp, t0

  // In CHERIoT mode now.
  cspecialr a0, mtdc
  li        a1, TOP_RV_CORE_IBEX_CFG_BASE_ADDR
  csetaddr  ca1, ca0, a1
  li        a2, DV_STATUS_IN_TEST
  sw        a2, RV_CORE_IBEX_DV_SIM_WINDOW_REG_OFFSET(a1)

  j success

success:
  cspecialr a0, mtdc
  li        a1, TOP_RV_CORE_IBEX_CFG_BASE_ADDR
  csetaddr  ca0, ca0, a1
  li        a1, DV_STATUS_PASSED
  sw        a1, RV_CORE_IBEX_DV_SIM_WINDOW_REG_OFFSET(a0)
  j park
failure:
  cspecialr a0, mtdc
  li        a1, TOP_RV_CORE_IBEX_CFG_BASE_ADDR
  csetaddr  ca0, ca0, a1
  li        a1, DV_STATUS_FAILED
  sw        a1, RV_CORE_IBEX_DV_SIM_WINDOW_REG_OFFSET(a0)
  j park
park:
  wfi
  j park
