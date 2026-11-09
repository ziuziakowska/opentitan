// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * The compartment that `app` calls: it exists so that the test makes a call
 * through the compartment switcher.
 */

#include "sw/device/lib/base/cheriot_compartment.h"

int OT_CHERIOT_COMPARTMENT("app") multiply(int x);

int OT_CHERIOT_COMPARTMENT("callee") add_one(int x) { return multiply(x) + 1; }
