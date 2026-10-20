// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "sw/device/lib/base/multibits_asm.h"
#include "hw/top/cheriot_mem_sys_regs.h" // Generated.
#include "hw/top/rv_core_ibex_regs.h" // Generated.
#include "hw/top/sram_ctrl_regs.h" // Generated.
#include "hw/top/top_memory.h" // Generated.
#include "hw/top/uart_regs.h" // Generated.

#if defined(DV_TEST_STATUS)
#define DV_STATUS_IN_TEST 0x4354
#define DV_STATUS_PASSED  0x900d
#define DV_STATUS_FAILED  0xbaad
#endif

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
  // In CHERIoT mode now.

#if defined(DV_TEST_STATUS)
  cspecialr a0, mtdc
  li        a1, TOP_RV_CORE_IBEX_CFG_BASE_ADDR
  csetaddr  ca1, ca0, a1
  li        a2, DV_STATUS_IN_TEST
  sw        a2, RV_CORE_IBEX_DV_SIM_WINDOW_REG_OFFSET(a1)
#endif

  j test

.macro test_crrl_cram_exponent exponent
  li   a1, 1
  li   a0, \exponent /* a0 = `exponent` */
  sll  a1, a1, a0    /* a1 = 2^`exponent` */
  addi a2, a1, -1    /* a2 = low `exponent` bits mask */
  not  a3, a2        /* a3 = negation of a2, 2^`exponent`-alignment mask */
  /**
   * This test checks properties of the `croundrepresentablelength` (CRRL)
   * and `crepresentablealignmentmask` (CRAM) instructions.
   *
   * Any length x >= 256 can be uniquely represented in the form
   * `x` = `k` * 2^`exponent` + f`, where
   * `k` is in [256, 512), and
   * `f` is in [0, 2^`exponent`), containing the value of the least-significant `exponent` bits.
   *
   * For this test, we're given an `exponent` and iterate `k`s in the range [256, 511).
   * We should observe:
   *
   * 1 does not divide 2^`exponent`, so x + 1 is misaligned to 2^`exponent`-bytes so,
   * CRRL(x) = x, but CRRL(x + 1) = x + 2^`exponent`.
   * => CRRL(x + 1) - CRRL(x) = 2^`exponent`.
   *
   * CRAM(x) has `exponent` trailing 0 bits, all other bits are set.
   * x + 1 <= x + 2^`exponent` <= 511 * 2^`exponent`,
   * => CRAM(x + 1) = CRAM(x).
   *
   * These alignment requirements increase between `k` = 511 with `f` = 0,
   * and `k` = 511 with `f` != 0 - these are tested for in the subsequent test.
   *
   * Capability bound alignment exponents are discontinuous after 14 - the next
   * exponent value after 14 is 24. This is handled in a subsequent test.
   */
  li   a4, 256
  li   a5, 511
1:
  sll                         t1, a4, a0 // t1 = x
  crepresentablealignmentmask tp, t1
  bne                         tp, a3, failure
  croundrepresentablelength   s0, t1 // s0 = CRRL(x)
  bne                         s0, t1, failure // expect that CRRL(x) = x
  and                         tp, s0, a2
  bnez                        tp, failure

  addi                        t1, t1, 1 // t1 = x + 1
  crepresentablealignmentmask tp, t1
  bne                         tp, a3, failure
  croundrepresentablelength   s1, t1 // s1 = CRRL(x + 1)
  and                         tp, s1, a2
  bnez                        tp, failure

  // expect CRRL(x + 1) - CRRL(x) = 2^`exponent`
  sub  s0, s1, s0
  bne  s0, a1, failure

  addi a4, a4, 1
  bne  a4, a5, 1b
.endm

.macro test_crrl_cram_exponent_crossover exponent
  li   a1, 1
  li   a0, \exponent // a0 = `exponent`
  sll  a1, a1, a0    // a1 = 2^`exponent`
  addi a2, a1, -1    // a2 = low `exponent` bits mask
  not  a3, a2        // a3 = negation of a2, 2^`exponent`-alignment mask
  /**
   * This test checks properties of CRRL and CRAM when crossing over
   * the maximum length for a given exponent value.
   *
   * Let x = 511 * 2^`exponent`, then
   * => CRRL(x) = x.
   * => CRRL(x + 1) = x + 2^`exponent`.
   *                = 511 * 2^`exponent` + 2^`exponent`.
   *                = 512 * 2^`exponent`.
   *                = 256 * 2^(`exponent` + 1) normalised.
   *
   * Since the exponent in CRRL has increased by 1 in the normalised form,
   * the alignment requirement of CRAM has also increased.
   * CRAM(x + 1) should have `exponent` + 1 trailing 0 bits, with all other bits set.
   * => CRAM(x + 1) = CRAM(x) << 1.
   */
  li                          t0, 511
  sll                         t0, t0, a0 // t0 = x
  crepresentablealignmentmask t1, t0
  bne                         t1, a3, failure
  addi                        t0, t0, 1 // t0 = x + 1
  crepresentablealignmentmask s0, t0 // s0 = CRAM(x + 1)
  // expect CRAM(x + 1) = CRAM(x) << 1
  sll t1, a3, 1
  bne s0, t1, failure
.endm

.macro test_crrl_cram_exponent_crossover_e14
  /**
    * Like the previous test but for `exponent` = 14. When the maximum
    * length for this is exceeded, `exponent` jumps to 24 instead of 15.
    *
    * Let x = 511 * 2^14, then
    * => CRRL(x) = x.
    * => CRRL(x + 1) = CRRL(x + 2^14).
    *                = CRRL(511 * 2^14 + 2^14).
    *                = CRRL(512 * 2^14)         >= 511 * 2^14.
    *                = 2^24.
    *
    * CRAM(x) should have 14 trailing 0 bits, with all other bits set.
    * CRAM(x + 1) should have 24 trailing 0 bits, with all other bits set.
    * => CRAM(x + 1) = 0xff000000.
    */
  li   a1, 1
  li   a0, 14
  sll  a1, a1, a0
  addi a2, a1, -1
  not  a3, a2

  li                          t0, 511
  sll                         t0, t0, a0 // t0 = x
  crepresentablealignmentmask t1, t0
  bne                         t1, a3, failure
  addi                        t0, t0, 1 // t0 = x + 1
  crepresentablealignmentmask s0, t0 // s0 = CRAM(x + 1)
  // expect that CRAM(x + 1) = 0xff000000.
  li  t1, 0xff000000
  bne t1, s0, failure


.endm

test:
  test_crrl_cram_exponent 0
  test_crrl_cram_exponent 1
  test_crrl_cram_exponent 2
  test_crrl_cram_exponent 3
  test_crrl_cram_exponent 4
  test_crrl_cram_exponent 5
  test_crrl_cram_exponent 6
  test_crrl_cram_exponent 7
  test_crrl_cram_exponent 8
  test_crrl_cram_exponent 9
  test_crrl_cram_exponent 10
  test_crrl_cram_exponent 11
  test_crrl_cram_exponent 12
  test_crrl_cram_exponent 13
  test_crrl_cram_exponent 14

  test_crrl_cram_exponent_crossover 0
  test_crrl_cram_exponent_crossover 1
  test_crrl_cram_exponent_crossover 2
  test_crrl_cram_exponent_crossover 3
  test_crrl_cram_exponent_crossover 4
  test_crrl_cram_exponent_crossover 5
  test_crrl_cram_exponent_crossover 6
  test_crrl_cram_exponent_crossover 7
  test_crrl_cram_exponent_crossover 8
  test_crrl_cram_exponent_crossover 9
  test_crrl_cram_exponent_crossover 10
  test_crrl_cram_exponent_crossover 11
  test_crrl_cram_exponent_crossover 12
  test_crrl_cram_exponent_crossover 13
  test_crrl_cram_exponent_crossover_e14

  j success

success:
  cspecialr a0, mtdc
  li        a1, TOP_UART0_BASE_ADDR
  csetaddr  ca0, ca0, a1
  li        a1, 'P'
  sw        a1, UART_WDATA_REG_OFFSET(a0)
  li        a1, 'A'
  sw        a1, UART_WDATA_REG_OFFSET(a0)
  li        a1, 'S'
  sw        a1, UART_WDATA_REG_OFFSET(a0)
  li        a1, 'S'
  sw        a1, UART_WDATA_REG_OFFSET(a0)
  li        a1, '!'
  sw        a1, UART_WDATA_REG_OFFSET(a0)
  li        a1, '\r'
  sw        a1, UART_WDATA_REG_OFFSET(a0)
  li        a1, '\n'
  sw        a1, UART_WDATA_REG_OFFSET(a0)
#if defined(DV_TEST_STATUS)
  li        a1, TOP_RV_CORE_IBEX_CFG_BASE_ADDR
  csetaddr  ca0, ca0, a1
  li        a1, DV_STATUS_PASSED
  sw        a1, RV_CORE_IBEX_DV_SIM_WINDOW_REG_OFFSET(a0)
#endif
  j park
failure:
  cspecialr a0, mtdc
  li        a1, TOP_UART0_BASE_ADDR
  csetaddr  ca0, ca0, a1
  li        a1, 'F'
  sw        a1, UART_WDATA_REG_OFFSET(a0)
  li        a1, 'A'
  sw        a1, UART_WDATA_REG_OFFSET(a0)
  li        a1, 'I'
  sw        a1, UART_WDATA_REG_OFFSET(a0)
  li        a1, 'L'
  sw        a1, UART_WDATA_REG_OFFSET(a0)
  li        a1, '!'
  sw        a1, UART_WDATA_REG_OFFSET(a0)
  li        a1, '\r'
  sw        a1, UART_WDATA_REG_OFFSET(a0)
  li        a1, '\n'
  sw        a1, UART_WDATA_REG_OFFSET(a0)
#if defined(DV_TEST_STATUS)
  li        a1, TOP_RV_CORE_IBEX_CFG_BASE_ADDR
  csetaddr  ca0, ca0, a1
  li        a1, DV_STATUS_FAILED
  sw        a1, RV_CORE_IBEX_DV_SIM_WINDOW_REG_OFFSET(a0)
#endif
  j park
park:
  wfi
  j park
