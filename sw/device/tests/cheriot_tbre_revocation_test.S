// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "sw/device/lib/base/multibits_asm.h"
#include "hw/top/cheriot_regs.h" // Generated.
#include "hw/top/rv_core_ibex_regs.h"  // Generated.
#include "hw/top/sram_ctrl_regs.h" // Generated.
#include "hw/top/top_memory.h" // Generated.

#define DV_STATUS_IN_TEST 0x4354
#define DV_STATUS_PASSED 0x900d
#define DV_STATUS_FAILED 0xbaad

  .section .crt, "ax", @progbits
  .balign 4
  .globl _ottf_start
  .type _ottf_start, @function
_ottf_start:
.L_cheriot_header:
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
.L_cheriot_start: // In CHERIoT Mode now.
  cspecialr a0, mtdc
  li        a1, TOP_RV_CORE_IBEX_CFG_BASE_ADDR
  csetaddr  ca1, ca0, a1
  li        a2, DV_STATUS_IN_TEST
  sw        a2, RV_CORE_IBEX_DV_SIM_WINDOW_REG_OFFSET(a1)

  li        a1, TOP_SRAM_CTRL_META_REGS_BASE_ADDR
  csetaddr  ca1, ca0, a1
  li        a2, (1 << SRAM_CTRL_CTRL_INIT_BIT)
  sw        a2, SRAM_CTRL_CTRL_REG_OFFSET(a1)
.L_sram_init:
  lw        a2, SRAM_CTRL_STATUS_REG_OFFSET(a1)
  andi      a2, a2, (1 << SRAM_CTRL_STATUS_INIT_DONE_BIT)
  beqz      a2, .L_sram_init

  // Test.
  // Set up 2 regions of SRAM: A, B
  // A: Valid capabilities that point into B.
  // B: Arbitrary data.

#define REGION_SIZE (8 * 128)
// 1 revocation bit per 8 Bytes = 256 Bytes per 32-bit register -> >> 6.
#define REGION_REVOCATON_SHIFT 6
  cspecialr a0, mtdc
  lui       a1, %hi(_data_start)
  addi      a1, a1, %lo(_data_start)
  csetaddr  ca0, ca0, a1
  li        a2, REGION_SIZE
  add       a1, a1, a2
  csetaddr  ca1, ca0, a1
  // ca0 (A): [ .data, .data + REGION_SIZE)
  // ca1 (B): [ .data + REGION_SIZE, .data + (2 * REGION_SIZE))
.L_init_loop:
  // Loop that initialises regions A and B.
  // ca0 and ca1 sweep through their REGION_SIZE-sized regions.
  // ct0 stores a capability to write to region A, which points into
  // region B, at the same offset in both regions.
  // The capability stored in region B is the null capability.
  beqz a2, .L_init_loop_done
  csetaddr      ct0, ca0, a1
  csetboundsimm ct0, ct0, 8
  sc            ct0, 0(ca0)
  sc            czero, 0(ca1)
  // Increment and loop again.
  cincoffsetimm ca0, ca0, 8
  cincoffsetimm ca1, ca1, 8
  addi          a2, a2, -8
  j .L_init_loop
.L_init_loop_done:
  // Re-materialise.
  cspecialr a0, mtdc
  lui       a1, %hi(_data_start)
  addi      a1, a1, %lo(_data_start)
  csetaddr  ca0, ca0, a1
  li        a2, REGION_SIZE
  add       a1, a1, a2
  csetaddr  ca1, ca0, a1

.L_tag_check_loop:
  // Check that all tags are set in region A, and no tags are set in region B.
  beqz a2, .L_tag_check_loop_done
  lc   ct0, 0(ca0)
  lc   ct1, 0(ca1)
  cgettag t0, t0
  cgettag t1, t1
  beqz t0, .L_failure
  bnez t1, .L_failure
  // Increment and loop again.
  cincoffsetimm ca0, ca0, 8
  cincoffsetimm ca1, ca1, 8
  addi a2, a2, -8
  j .L_tag_check_loop
.L_tag_check_loop_done:

  cspecialr a0, mtdc
  lui a1, %hi(TOP_CHERIOT_REVBM_BASE_ADDR)
  addi a1, a1, %lo(TOP_CHERIOT_REVBM_BASE_ADDR)
  li  a2, REGION_SIZE
  srai a2, a2, REGION_REVOCATON_SHIFT // words left to revoke
  add a1, a1, a2
  csetaddr ca0, ca0, a1
  // Revoke loop.
  li a3, -1
.L_revoke_loop:
  beqz a2, .L_revoke_loop_done
  sw   a3, 0(ca0)
  cincoffsetimm ca0, ca0, 4
  addi a2, a2, -4
  j .L_revoke_loop
.L_revoke_loop_done:

  // Re-materialise.
  cspecialr a0, mtdc
  lui       a1, %hi(_data_start)
  addi      a1, a1, %lo(_data_start)
  csetaddr  ca0, ca0, a1
  li        a2, REGION_SIZE
  add       a1, a1, a2
  csetaddr  ca1, ca0, a1

.L_tag_check_after_revoke_loop:
  // Check that all tags are set in region A, and no tags are set in region B.
  beqz a2, .L_tag_check_after_revoke_loop_done
  lc   ct0, 0(ca0)
  lc   ct1, 0(ca1)
  cgettag t0, t0
  cgettag t1, t1
  bnez t0, .L_failure
  bnez t1, .L_failure
  // Increment and loop again.
  cincoffsetimm ca0, ca0, 8
  cincoffsetimm ca1, ca1, 8
  addi a2, a2, -8
  j .L_tag_check_after_revoke_loop
.L_tag_check_after_revoke_loop_done:

  cspecialr a0, mtdc
  lui a1, %hi(TOP_CHERIOT_REVBM_BASE_ADDR)
  addi a1, a1, %lo(TOP_CHERIOT_REVBM_BASE_ADDR)
  li  a2, REGION_SIZE
  srai a2, a2, REGION_REVOCATON_SHIFT // words left to unrevoke
  add a1, a1, a2
  csetaddr ca0, ca0, a1
  // Un-revoke loop.
.L_unrevoke_loop:
  beqz a2, .L_unrevoke_loop_done
  sw   zero, 0(ca0)
  cincoffsetimm ca0, ca0, 4
  addi a2, a2, -4
  j .L_unrevoke_loop
.L_unrevoke_loop_done:

  // Re-materialise.
  cspecialr a0, mtdc
  lui       a1, %hi(_data_start)
  addi      a1, a1, %lo(_data_start)
  csetaddr  ca0, ca0, a1
  li        a2, REGION_SIZE
  add       a1, a1, a2
  csetaddr  ca1, ca0, a1

.L_tag_check_again_loop:
  // Check that no tags are set in either region.
  beqz a2, .L_tag_check_again_loop_done
  lc   ct0, 0(ca0)
  lc   ct1, 0(ca1)
  cgettag t0, t0
  cgettag t1, t1
  beqz t0, .L_failure
  bnez t1, .L_failure
  // Increment and loop again.
  cincoffsetimm ca0, ca0, 8
  cincoffsetimm ca1, ca1, 8
  addi a2, a2, -8
  j .L_tag_check_again_loop
.L_tag_check_again_loop_done:

  cspecialr a0, mtdc
  lui a1, %hi(TOP_CHERIOT_REVBM_BASE_ADDR)
  addi a1, a1, %lo(TOP_CHERIOT_REVBM_BASE_ADDR)
  li  a2, REGION_SIZE
  srai a2, a2, REGION_REVOCATON_SHIFT // words left to revoke
  add a1, a1, a2
  csetaddr ca0, ca0, a1
  // Revoke loop.
  li a3, -1
.L_revoke_again_loop:
  beqz a2, .L_revoke_again_loop_done
  sw   a3, 0(ca0)
  cincoffsetimm ca0, ca0, 4
  addi a2, a2, -4
  j .L_revoke_again_loop
.L_revoke_again_loop_done:

  // Now engage the TBRE.
  cspecialr a0, mtdc
  lui       a1, %hi(TOP_CHERIOT_REGS_BASE_ADDR)
  addi      a1, a1, %lo(TOP_CHERIOT_REGS_BASE_ADDR)
  csetaddr  ca1, ca0, a1
  lui       a2, %hi(_data_start)
  addi      a2, a2, %lo(_data_start)
  sw        a2, CHERIOT_TBRE_BASE_ADDR_REG_OFFSET(a1)
  li        a2, REGION_SIZE
  srai      a2, a2, 3
  sw        a2, CHERIOT_TBRE_NUM_CAPS_REG_OFFSET(a1)
  li        a2, (1 << CHERIOT_TBRE_START_START_BIT)
  sw        a2, CHERIOT_TBRE_START_REG_OFFSET(a1)
  // a2 persists as 1 - busy bit
.L_revocation_engine_poll:
  // Poll TBRE_STATUS every 32 instructions,
  // to not put additional pressure on the
  // LSU, which the TBRE re-uses.
  .rep (32 - 3)
  nop
  .endr
  lw        a3, CHERIOT_TBRE_STATUS_REG_OFFSET(a1)
  and       a3, a3, a2
  bnez      a3, .L_revocation_engine_poll
.L_revocation_engine_poll_done:
  lw        a3, CHERIOT_TBRE_STATUS_REG_OFFSET(a1)
  li        a2, ~(1 << CHERIOT_TBRE_STATUS_BUSY_BIT)
  andi      a3, a3, ~(1 << CHERIOT_TBRE_STATUS_BUSY_BIT)
  bnez      a3, .L_failure

  // Clear the revocation bitmap after it has ran.
  // Re-materialise
  cspecialr a0, mtdc
  lui a1, %hi(TOP_CHERIOT_REVBM_BASE_ADDR)
  addi a1, a1, %lo(TOP_CHERIOT_REVBM_BASE_ADDR)
  li  a2, REGION_SIZE
  srai a2, a2, REGION_REVOCATON_SHIFT // words left to check
  add a1, a1, a2
  csetaddr ca0, ca0, a1
  // Clear bitmap
.L_check_loop:
  beqz a2, .L_check_loop_done
  sw   zero, 0(ca0)
  cincoffsetimm ca0, ca0, 4
  addi a2, a2, -4
  j .L_check_loop
.L_check_loop_done:

  // Re-materialise.
  cspecialr a0, mtdc
  lui       a1, %hi(_data_start)
  addi      a1, a1, %lo(_data_start)
  csetaddr  ca0, ca0, a1
  li        a2, REGION_SIZE
  add       a1, a1, a2
  csetaddr  ca1, ca0, a1

.L_tag_check_after_revocation_engine_loop:
  // Check that no tags are set.
  beqz a2, .L_tag_check_after_revocation_engine_loop_done
  lc   ct0, 0(ca0)
  lc   ct1, 0(ca1)
  cgettag t0, t0
  cgettag t1, t1
  bnez t0, .L_failure
  bnez t1, .L_failure
  // Increment and loop again.
  cincoffsetimm ca0, ca0, 8
  cincoffsetimm ca1, ca1, 8
  addi a2, a2, -8
  j .L_tag_check_after_revocation_engine_loop
.L_tag_check_after_revocation_engine_loop_done:

  // Fallthrough, success
  j .L_success

.L_success:
  cspecialr a0, mtdc
  lui       a1, %hi(TOP_RV_CORE_IBEX_CFG_BASE_ADDR)
  addi      a1, a1, %lo(TOP_RV_CORE_IBEX_CFG_BASE_ADDR)
  csetaddr  ca0, ca0, a1
  li        a2, DV_STATUS_PASSED
  sw        a2, RV_CORE_IBEX_DV_SIM_WINDOW_REG_OFFSET(a0)
  j .L_park
.L_failure:
  cspecialr a0, mtdc
  lui       a1, %hi(TOP_RV_CORE_IBEX_CFG_BASE_ADDR)
  addi      a1, a1, %lo(TOP_RV_CORE_IBEX_CFG_BASE_ADDR)
  csetaddr  ca0, ca0, a1
  li        a2, DV_STATUS_FAILED
  sw        a2, RV_CORE_IBEX_DV_SIM_WINDOW_REG_OFFSET(a0)
  j .L_park
.L_park:
  wfi
  j .L_park
