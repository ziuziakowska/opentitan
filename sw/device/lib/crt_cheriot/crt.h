// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#ifndef OPENTITAN_SW_DEVICE_LIB_CRT_CHERIOT_CRT_H_
#define OPENTITAN_SW_DEVICE_LIB_CRT_CHERIOT_CRT_H_

/**
 * @file
 * @brief Interface of the minimal CHERIoT C runtime (`crt.S`).
 *
 * The CRT enters `main()` with `cgp` bounded to `.data`+`.bss`, a PCC bounded
 * to code+rodata, and `csp` bounded to the stack. Everything else (MMIO,
 * memories outside the globals) must be reached through a capability derived
 * from `_infinite_memory_cap`.
 */

#ifdef __cplusplus
extern "C" {
#endif  // __cplusplus

/**
 * The memory (read/write) root capability, published by the CRT before
 * `main()` is called. Derive narrower capabilities from it; do not hand it out.
 */
extern void *_infinite_memory_cap;

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  // OPENTITAN_SW_DEVICE_LIB_CRT_CHERIOT_CRT_H_
