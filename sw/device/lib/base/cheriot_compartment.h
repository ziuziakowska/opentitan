// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#ifndef OPENTITAN_SW_DEVICE_LIB_BASE_CHERIOT_COMPARTMENT_H_
#define OPENTITAN_SW_DEVICE_LIB_BASE_CHERIOT_COMPARTMENT_H_

/**
 * @file
 * @brief Declarations for CHERIoT compartments.
 *
 * Only the compiler's attributes are used here: nothing from the CHERIoT RTOS
 * is included, so that compartments are written against OpenTitan's own
 * headers. The RTOS's loader and switcher are what give these attributes
 * their meaning (see `//sw/device/cheriot_rtos`).
 */

/**
 * Declares or defines a function exported by the compartment `name`.
 *
 * Put it on the declaration other compartments include, and on the definition:
 *
 *     int OT_CHERIOT_COMPARTMENT("callee") add_one(int x);
 *
 * A call to a function declared with another compartment's name goes through
 * the compartment switcher; a definition with this compartment's name is
 * exported to the others. The name must match the compartment's target name.
 */
#define OT_CHERIOT_COMPARTMENT(name) __attribute__((cheri_compartment(name)))

/**
 * Evaluates to a `type *` to the device the image calls `name`.
 *
 * The compartment imports a read-write capability to the region that the
 * image's `devices` table gives for `name` (see `cheriot_rtos_test`). The
 * loader builds that capability at boot; it is not derived from any root at
 * run time. Only usable inside a function, not as a static initialiser.
 */
#define OT_CHERIOT_MMIO(type, name) OT_CHERIOT_MMIO_(type, name, __COUNTER__)

// Expands `__COUNTER__` first, so that each use declares its own symbol.
#define OT_CHERIOT_MMIO_(type, name, counter) \
  OT_CHERIOT_MMIO__(type, name, counter)

#define OT_CHERIOT_MMIO__(type, name, counter)                              \
  ({                                                                        \
    __attribute__((cheri_no_subobject_bounds)) __attribute__((cheriot_mmio( \
        #name, "RW"))) volatile extern char ot_cheriot_mmio_##counter;      \
    (type *)&ot_cheriot_mmio_##counter;                                     \
  })

#endif  // OPENTITAN_SW_DEVICE_LIB_BASE_CHERIOT_COMPARTMENT_H_
