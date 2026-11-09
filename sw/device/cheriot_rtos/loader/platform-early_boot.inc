// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * What OpenTitan needs before the RTOS loader's C++ half can run (included by
 * `core/loader/boot.S`, after it has set up its stack).
 *
 * Registers, as the loader documents them: `ca4` holds the read/write root
 * capability, and `sp` and `a4`/`a5` must be preserved; `ra`, `a0` and `a1` are
 * free (so are the other temporaries). Nothing here may use the stack: the
 * copy below overwrites it.
 */

#include "hw/top/sram_ctrl_regs.h"  // Generated.
#include "hw/top/top_memory.h"      // Generated.
#include "sw/device/lib/base/multibits_asm.h"

#define CHERI_PERM_GLOBAL (1 << 0)
#define CHERI_PERM_LOAD (1 << 5)

  // 1. Allow instruction fetch from the main SRAM. The loader's C++ half, and
  // the data it consumes, are copied there below and erased when it is done, so
  // they must live (and run) in RAM; the SRAM controller blocks fetches from it
  // unless told otherwise.
  li        a0, TOP_SRAM_CTRL_MAIN_REGS_BASE_ADDR
  csetaddr  ca0, ca4, a0
  csetbounds ca0, ca0, 0x40
  li        a1, MULTIBIT_ASM_BOOL4_TRUE
  sw        a1, SRAM_CTRL_EXEC_REG_OFFSET(a0)

  // 2. Initialise the CHERIoT meta SRAM (the revocation bitmap and the validity
  // tags). Its controller reads back zero after `CTRL.INIT`, but the boot ROM
  // only initialises the main SRAM. Until then both hold garbage: stale tags,
  // and set revocation bits that make the load filter strip the tag from any
  // capability loaded from RAM.
  li        a0, TOP_SRAM_CTRL_META_REGS_BASE_ADDR
  csetaddr  ca0, ca4, a0
  csetbounds ca0, ca0, 0x40
  li        a1, ((1 << SRAM_CTRL_CTRL_RENEW_SCR_KEY_BIT) | (1 << SRAM_CTRL_CTRL_INIT_BIT))
  sw        a1, SRAM_CTRL_CTRL_REG_OFFSET(a0)
.L_meta_init_wait:
  lw        a1, SRAM_CTRL_STATUS_REG_OFFSET(a0)
  andi      a1, a1, (1 << SRAM_CTRL_STATUS_INIT_DONE_BIT)
  beqz      a1, .L_meta_init_wait

  // 3. Copy the whole image from NVM to RAM, and continue from the copy. The
  // loader writes into its code (see `util/cheriot_image_ld.py`), so the image
  // must run from RAM; it is entered in NVM, where it is stored, and until the
  // jump below only instructions that do not depend on where they are run from
  // may execute: none up to here uses a PC-relative address (addresses are
  // loaded with `la_abs`, which names where the image runs). Word copies only:
  // NVM has no tags, and a non-capability store also clears any stale tag at the
  // destination.
  la_abs    a1, __image_load_start
  la_abs    a2, __image_start
  la_abs    a3, __image_end
  sub       t0, a3, a2
  li        t1, (CHERI_PERM_LOAD | CHERI_PERM_GLOBAL)
  candperm  ca0, ca4, t1              // Source: read-only view of the root.
  csetaddr  ca0, ca0, a1
  csetbounds ca0, ca0, t0
  csetaddr  ct2, ca4, a2              // Destination.
  csetbounds ct2, ct2, t0
.L_image_copy:
  bgeu      t2, a3, .L_image_copied
  clw       t1, 0(ca0)
  csw       t1, 0(ct2)
  cincoffset ca0, ca0, 4
  cincoffset ct2, ct2, 4
  j         .L_image_copy
.L_image_copied:
  // The copy is code.
  fence.i
  // Jump to the next instruction, in the copy: take the current PCC, which
  // covers all of memory, and give it that instruction's address in RAM.
  auipcc    ct2, 0
  la_abs    t1, .L_in_ram
  csetaddr  ct2, ct2, t1
  cjr       ct2
.L_in_ram:
