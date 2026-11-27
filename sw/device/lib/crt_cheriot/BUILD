# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

package(default_visibility = ["//visibility:public"])

# Minimal CHERIoT C runtime (entry point, trap handler, `.data`/`.bss` init).
# Must be linked with `//sw/device/lib/testing/test_framework/cheriot` linker
# scripts, whose layout it depends on.
cc_library(
    name = "crt",
    srcs = ["crt.S"],
    hdrs = ["crt.h"],
    target_compatible_with = ["//toolchain:isa_cheriot"],
    deps = [
        "//hw/top:rv_core_ibex_c_regs",
        "//hw/top:sram_ctrl_c_regs",
        "//hw/top:top_lib",
        "//hw/top:uart_c_regs",
        "//sw/device/lib/base:multibits",
    ],
    # `_ottf_start` is only referenced by the linker script's ENTRY().
    alwayslink = True,
)

# The `mem*` functions the compiler may call: `base:memory` plus `memmove`,
# which it lacks.
cc_library(
    name = "memory",
    srcs = ["memory.c"],
    target_compatible_with = ["//toolchain:isa_cheriot"],
    deps = ["//sw/device/lib/base:memory"],
)
