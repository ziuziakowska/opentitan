// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Minimal CHERIoT C runtime: one PCC, one CGP, no loader/switcher.
 *
 * The CHERIoT counterpart of `sw/device/lib/crt/crt.S`, but also provides the
 * `_ottf_start` entry point (there is no separate OTTF start file yet). See
 * `crt.h` for the interface exposed to C.
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
 *   - The `.data`+`.bss` output section must stay under ~4 KiB: beyond +/-2 KiB
 *     of its midpoint lld falls back to a GOT of capabilities that nothing
 *     initialises (the link still succeeds, the first access faults), and
 *     hand-written `%cheriot_compartment_hi`/`_lo_i` pairs get a wrong low part.
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
#define CHERI_PERM_EXECUTE     (1 << 8)

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

// Human parts below here so far.

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

.L_clear_bss:
  // ca0 = [`_bss_start`, `_bss_end`).
  la_abs     a0, _bss_start
  la_abs     a1, _bss_end
  csetaddr   ca0, cs0, a0
  sub        a2, a1, a0
  csetbounds ca0, ca0, a2
.L_bss_loop:
  bgeu       a0, a1, .L_clear_bss_done
  csc        c0, 0(ca0)
  cincoffset ca0, ca0, 8
  j          .L_bss_loop
.L_clear_bss_done:

.L_data_copy:
  // Copy `.data` from NVM (LMA) to RAM (VMA).
  // len = `_data_end` - `_data_start`.
  // ca0 = [`_data_start`, `_data_start` + len).
  // ca1 = [`_data_init_start`, `_data_init_start` + len).
  la_abs     a0, _data_start
  la_abs     a2, _data_end
  csetaddr   ca0, cs0, a0
  sub        a3, a2, a0
  csetbounds ca0, ca0, a3
  la_abs     a1, _data_init_start
  csetaddr   ca1, cs0, a1
  csetbounds ca1, ca1, a3
  li t0, ~CHERI_PERM_STORE
  candperm ca1, ca1, t0
  li t0, ~CHERI_PERM_LOAD
  candperm ca0, ca0, t0
.L_data_loop:
  bgeu       a0, a2, .L_data_copy_done
  lw         t0, 0(a1)
  sw         t0, 0(a0)
  cincoffset ca1, ca1, 4
  cincoffset ca0, ca0, 4
  j .L_data_loop
.L_data_copy_done:

.L_cap_relocs:
 // cs1 = [`_text_start`, `_text_end`).
  cspecialr cs1, mtcc
  la_abs t0, _text_start
  la_abs t1, _text_end
  sub    t1, t1, t0
  csetaddr cs1, cs1, t0
  csetbounds cs1, cs1, t1

  // Perform capability relocation.
  // ca0 = Pointer to the current `cap_reloc` entry
  //       in [`__cap_relocs_start`, `__cap_relocs_end`).
  //  a1 = `__cap_relocs_end`.
  la_abs     a0, __cap_relocs_start
  la_abs     a1, __cap_relocs_end
  sub        t0, a1, a0
  csetaddr   ca0, cs0, a0
  csetbounds a0, a0, t0
.L_cap_relocs_loop:
  bgeu a0, a1, .L_cap_relocs_done

  // struct cap_reloc {
  //    unsigned long cr_location;
  //    unsigned long cr_base;
  //    unsigned long cr_offset;
  //    unsigned long cr_length;
  //    unsigned long cr_flags;
  // }
  //
  // The capability to be written is built in ca2.

  lw   t0, (4 * 4)(a0) // t0 = `cr_flags`.
  li   t1, (1 << 31)
  and  t1, t0, t1
  bnez t1, .L_cap_reloc_executable
  // Fallthrough - Not an executable capability (RW/RO data).
.L_cap_reloc_data:
  // RW/RO data capability. Derive from data capability in cs0.
  lw t1, (1 * 4)(a0) // `cr_base`.
  csetaddr ca2, cs0, t1
  lw  t1, (3 * 4)(a0) // `cr_length`.
  csetbounds ca2, ca2, t1
  li   t1, ~CHERI_PERM_EXECUTE
  candperm ca2, ca2, t1

  li   t1, (1 << 30)
  and  t1, t0, t1
  bnez t1, .L_cap_reloc_data_ro
  // Fallthrough - RW data capability.
  j .L_cap_reloc_finish

.L_cap_reloc_data_ro:
  // RO data capability.
  li t1, ~CHERI_PERM_STORE
  candperm ca2, ca2, t1
  j .L_cap_reloc_finish

.L_cap_reloc_executable:
  // Executable capability. Derive from code capability in cs1.
  lw t1, (1 * 4)(a0) // `cr_base`.
  csetaddr ca2, cs1, t1
  li t1, ~CHERI_PERM_STORE
  candperm ca2, ca2, t1
  // Fallthrough

.L_cap_reloc_finish:
  lw t1, (2 * 4)(a0) // `cr_offset`.
  cincoffset ca2, ca2, t1

  // Write the capability to `cr_location`.
  lw            t0, (0 * 4)(a0)
  csetaddr      ct0, cs0, t0
  csetboundsimm ct0, ct0, 8
  sc            ca2, 0(ct0)

  // Next cap relocation entry.
  cincoffset ca0, ca0, (5 * 4)
  j .L_cap_relocs_loop
.L_cap_relocs_done:

.L_enter_main:
  // Store away root memory capability in `_infinite_memory_cap` for C code.
  la_abs a0, _infinite_memory_cap
  csetaddr ca0, cs0, a0
  sc cs0, 0(ca0)

  // Reset all registers apart from x2 (csp) and x3 (cgp).
  li   x1, 0
  li   x4, 0
  li   x5, 0
  li   x6, 0
  li   x7, 0
  li   x8, 0
  li   x9, 0
  li   x10, 0
  li   x11, 0
  li   x12, 0
  li   x13, 0
  li   x14, 0
  li   x15, 0
  cjal ra, main

.L_park:
  wfi
  j .L_park
  .size _ottf_start, . - _ottf_start

  .section .bss._infinite_memory_cap, "aw", @nobits
  .balign 8
  .globl _infinite_memory_cap
  .type _infinite_memory_cap, @object
_infinite_memory_cap:
  .zero 8
  .size _infinite_memory_cap, . - _infinite_memory_cap
