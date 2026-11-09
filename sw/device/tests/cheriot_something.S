// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Minimal CHERIoT C runtime: one PCC, one CGP, no loader/switcher.
 *
 * Boot flow:
 *   1. Switch the core from RV32 to CHERIoT mode (as `cheriot_smoketest.S`).
 *   2. Initialise the CHERIoT meta SRAM (revocation bitmap and tags).
 *   3. Derive `csp`, `cgp` and a bounded PCC from the
 *      memory root in `mtdc`.
 *   4. Copy `.data` from its NVM load address (LMA) to RAM (VMA), zero `.bss`.
 *   5. Publish the memory root in `_infinite_memory_cap` for C to derive MMIO
 *      capabilities from, clear the other roots, and call `main()`.
 *
 * Rules the linker script (`cheriot/ottf_common.ld`) must obey:
 *   - `.rodata` lives inside the executable output section, because lld makes
 *     a relocation PCC-relative iff its target's output section is executable,
 *     and `cgp`-relative otherwise.
 *   - `.data` and `.bss` live in ONE output section, because `cgp` is the
 *     midpoint of the output section containing the symbol being accessed.
 *   - Symbols used with `%cheriot_compartment_hi` must come from an input
 *     section, never from a linker script assignment.
 */

#include "sw/device/lib/base/multibits_asm.h"
#include "hw/top/rv_core_ibex_regs.h"  // Generated.
#include "hw/top/sram_ctrl_regs.h"     // Generated.
#include "hw/top/top_memory.h"         // Generated.
#include "hw/top/uart_regs.h"          // Generated.

// CHERIoT capability permission bits.
#define CHERI_PERM_GLOBAL      (1 << 0)
#define CHERI_PERM_STORE       (1 << 2)
#define CHERI_PERM_STORE_LOCAL (1 << 4)
#define CHERI_PERM_LOAD        (1 << 5)
#define CHERI_PERM_ACCESS_SYS  (1 << 7)

// Load the absolute (integer) address of a symbol.
.macro la_abs reg, symbol
  lui   \reg, %hi(\symbol)
  addi  \reg, \reg, %lo(\symbol)
.endm

// Print `s0` as eight hex digits through the UART capability in `t1`.
// Clobbers a0, a1, s0, s1.
.macro hex8
  addi s1, x0, 8
1:
  srli a0, s0, 28
  slli s0, s0, 4
  addi a1, x0, 10
  blt  a0, a1, 2f
  addi a0, a0, ('a' - 10 - '0')
2:
  addi a0, a0, '0'
  sw   a0, UART_WDATA_REG_OFFSET(t1)
  addi s1, s1, -1
  bnez s1, 1b
.endm

// -----------------------------------------------------------------------------

/**
 * Trap handler (installed in `mtcc` by the CRT).
 *
 * Prints `FAULT <mcause> <mtval> <mepc>\r\n` (matches the OTTF failure regex) and parks.
 * `mtdc` still holds the memory root (see the CRT); narrow a copy of it onto
 * the UART. `mtcc` carries the original PCC, so this runs with ASR and can
 * read `mtdc`.
 */
  .section .vectors, "ax", @progbits
  .balign 256
  .globl _trap_handler
  .type _trap_handler, @function
_trap_handler:
  cspecialr     ct1, mtdc
  lui           t2, %hi(TOP_UART0_BASE_ADDR)
  csetaddr      ct1, ct1, t2
  csetboundsimm ct1, ct1, 0x40

  addi t2, x0, 'F'
  sw   t2, UART_WDATA_REG_OFFSET(t1)
  addi t2, x0, 'A'
  sw   t2, UART_WDATA_REG_OFFSET(t1)
  addi t2, x0, 'U'
  sw   t2, UART_WDATA_REG_OFFSET(t1)
  addi t2, x0, 'L'
  sw   t2, UART_WDATA_REG_OFFSET(t1)
  addi t2, x0, 'T'
  sw   t2, UART_WDATA_REG_OFFSET(t1)
  addi t2, x0, ' '
  sw   t2, UART_WDATA_REG_OFFSET(t1)

  // `mcause`, `mtval` (CHERI cause / register index) and the faulting PC
  // (`mepcc`), each as eight hex digits, most significant first.
  csrr s0, mcause
  hex8
  addi t2, x0, ' '
  sw   t2, UART_WDATA_REG_OFFSET(t1)
  csrr s0, mtval
  hex8
  addi t2, x0, ' '
  sw   t2, UART_WDATA_REG_OFFSET(t1)
  cspecialr cs0, mepcc
  hex8

  addi t2, x0, '\r'
  sw   t2, UART_WDATA_REG_OFFSET(t1)
  addi t2, x0, '\n'
  sw   t2, UART_WDATA_REG_OFFSET(t1)
.L_trap_park:
  wfi
  j    .L_trap_park
  .size _trap_handler, . - _trap_handler

// -----------------------------------------------------------------------------

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
  // In CHERIoT Mode now. `mtdc` still holds the memory (RW) root; keep it in
  // cs0 until the end of the CRT.
  cspecialr cs0, mtdc

  // Initialise the CHERIoT meta SRAM (revocation bitmap and validity tags).
  // Its controller is configured to read back zero after `CTRL.INIT`, but the
  // ROM only does this for the main SRAM. Until then both hold garbage: stale
  // tags, and set revocation bits that make the load filter strip the tag from
  // any capability loaded from the stack.
  li        a1, TOP_SRAM_CTRL_META_REGS_BASE_ADDR
  csetaddr  ca1, cs0, a1
  csetbounds ca1, ca1, 0x40
  li        a2, ((1 << SRAM_CTRL_CTRL_RENEW_SCR_KEY_BIT) | (1 << SRAM_CTRL_CTRL_INIT_BIT))
  sw        a2, SRAM_CTRL_CTRL_REG_OFFSET(a1)
.L_meta_init_wait:
  lw        a2, SRAM_CTRL_STATUS_REG_OFFSET(a1)
  andi      a2, a2, (1 << SRAM_CTRL_STATUS_INIT_DONE_BIT)
  beqz      a2, .L_meta_init_wait

  // Trap vector, from the current (full) PCC so the handler keeps ASR.
1:
  auipcc    ct1, %cheriot_compartment_hi(_trap_handler)
  cincoffset ct1, ct1, %cheriot_compartment_lo_i(1b)
  cspecialw mtcc, ct1

  // csp: root without GL, bounded to the stack, pointing at its top.
  li        a5, ~CHERI_PERM_GLOBAL
  candperm  ca5, cs0, a5
  la_abs    a0, _stack_start
  la_abs    a1, _stack_size
  csetaddr  csp, ca5, a0
  csetbounds csp, csp, a1
  cincoffset csp, csp, a1

  // cgp: root without SL, bounded to the whole `.data`+`.bss` output section,
  // address at its MIDDLE (what lld assumes for every cgp-relative access).
  li        a5, ~CHERI_PERM_STORE_LOCAL
  candperm  ca5, cs0, a5
  la_abs    a0, _data_start
  la_abs    a1, _globals_size
  csetaddr  cgp, ca5, a0
  csetboundsexact cgp, cgp, a1
  srli      a1, a1, 1
  cincoffset cgp, cgp, a1

  // Copy initialised `.data` from NVM (LMA) to RAM (VMA), one word at a time.
  // Word copies only: NVM has no tags, and a non-capability store also clears
  // any stale tag at the destination. Skipped if `.data` is empty.
  la_abs    a3, _data_start
  la_abs    a5, _data_end
  bgeu      a3, a5, .L_copy_done
  csetaddr  ct0, cgp, a3                // dst, bounded to the globals
  li        a1, (CHERI_PERM_LOAD | CHERI_PERM_GLOBAL)
  candperm  ca1, cs0, a1                // src: read-only view of the root
  la_abs    a2, _data_init_start
  csetaddr  ca1, ca1, a2
  sub       a2, a5, a3
  csetbounds ca1, ca1, a2
.L_copy:
  clw       t1, 0(ca1)
  csw       t1, 0(ct0)
  cincoffset ca1, ca1, 4
  cincoffset ct0, ct0, 4
  bltu      t0, a5, .L_copy
.L_copy_done:

  // Zero `.bss` with capability-width stores (also clears stale tags).
  la_abs    a3, _bss_start
  la_abs    a5, _bss_end
  csetaddr  ct0, cgp, a3
.L_bss:
  bgeu      t0, a5, .L_bss_done
  csc       c0, 0(ct0)
  cincoffset ct0, ct0, 8
  j         .L_bss
.L_bss_done:

  // PCC for the application: [_text_start, _text_end) (code and rodata), ASR
  // dropped. `_ottf_start` is an input-section symbol, so auipcc is PCC-based.
1:
  auipcc    ca2, %cheriot_compartment_hi(_ottf_start)
  cincoffset ca2, ca2, %cheriot_compartment_lo_i(1b)
  la_abs    a0, _text_start
  la_abs    a1, _text_end
  sub       a1, a1, a0
  csetaddr  ca2, ca2, a0
  csetbounds ca2, ca2, a1
  li        a5, ~CHERI_PERM_ACCESS_SYS
  candperm  ca2, ca2, a5
  la_abs    a1, main
  csetaddr  ca2, ca2, a1

  // Publish the memory root for C: `main()` derives its MMIO capabilities
  // from `_infinite_memory_cap` (see `cheriot_main.c`). `mtdc` keeps the root
  // for the trap handler; `mscratchc` (sealing root) is cleared.
  la_abs    a0, _infinite_memory_cap
  csetaddr  ca0, cgp, a0
  csc       cs0, 0(ca0)
  li        s0, 0
  cspecialw mscratchc, cs0
  li        a0, 0
  li        a1, 0
  li        ra, 0
  li        tp, 0
  li        t0, 0
  li        t1, 0
  li        t2, 0
  li        s1, 0
  li        a3, 0
  li        a4, 0
  li        a5, 0
  cjalr     ca2                         // main()

.L_park:
  wfi
  j         .L_park
  .size _ottf_start, . - _ottf_start

// Capability slot holding the memory root, for C. Lives in `.bss` (inside the
// `cgp` region) and is written by the CRT after `.bss` has been zeroed.
  .section .bss._infinite_memory_cap, "aw", @nobits
  .p2align 3
  .globl _infinite_memory_cap
  .type _infinite_memory_cap, @object
_infinite_memory_cap:
  .zero 8
  .size _infinite_memory_cap, . - _infinite_memory_cap
