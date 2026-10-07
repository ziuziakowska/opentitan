// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "sw/device/lib/base/multibits_asm.h"
#include "hw/top/rv_core_ibex_regs.h"  // Generated.
#include "hw/top/top_memory.h" // Generated.

  .section .crt, "ax", @progbits
  .balign 4
  .globl _ottf_start
  .type _ottf_start, @function
_ottf_start:
_cheriot_header:
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

_crt:
  // In CHERIoT Mode now.
  cspecialr s0, mtdc

  lui   a0, %hi(_data_start)
  addi  a0, a0, %lo(_data_start)
  lui   a1, %hi(_data_end)
  addi  a1, a1, %lo(_data_end)
  lui   a2, %hi(_data_init_start)
  addi  a2, a2, %lo(_data_init_start)

  sub a3, a1, a0
  csetaddr ca0, cs0, a0
  csetaddr ca2, cs0, a2
  csetbounds ca0, ca0, a3
  csetbounds ca2, ca2, a3

_copy_data:
  beq a0, a1, _copy_data_end
  lw a3, 0(a2)
  sw a3, 0(a0)
  cincoffsetimm ca0, ca0, 4
  cincoffsetimm ca2, ca2, 4
  j _copy_data
_copy_data_end:

  lui             a0, %hi(_stack_start)
  addi            a0, a0, %lo(_stack_start)
  lui             a1, %hi(_stack_size)
  addi            a1, a1, %lo(_stack_size)
  csetaddr        csp, cs0, a0
  csetboundsexact csp, csp, a1
  cincoffset      csp, csp, a1

  lui             a0, %hi(__global_pointer$)
  addi            a0, a0, %lo(__global_pointer$)
  csetaddr        cgp, cs0, a0

  lui       a0, %hi(_infinite_memory_cap)
  addi      a0, a0, %lo(_infinite_memory_cap)
  csetaddr  ca0, cs0, a0
  sc        cs0, 0(ca0)
  mv        s0, zero

  cjal main


loop:
  add x0, x0, x0
  j loop

.section .data
.align 3
.global _infinite_memory_cap
.type _infinite_memory_cap, @object
_infinite_memory_cap:
    .chericap 0
.size _infinite_memory_cap, . - _infinite_memory_cap
