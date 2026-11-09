# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

load("//sw/device/cheriot_rtos:defs.bzl", "cheriot_compartment", "cheriot_rtos_test")

package(default_visibility = ["//visibility:public"])

cheriot_compartment(
    name = "app",
    srcs = ["app.c"],
    deps = ["//sw/device/lib/base:cheriot_compartment"],
)

cheriot_compartment(
    name = "callee",
    srcs = ["callee.c"],
    deps = ["//sw/device/lib/base:cheriot_compartment"],
)

# Two threads in `app` take turns, then one calls `callee` through the switcher
# and reports. See `app.c`.
cheriot_rtos_test(
    name = "smoketest",
    compartments = [
        ":app",
        ":callee",
    ],
    # UART0, as `top_earlgrey.h` has it.
    devices = {"uart": [
        "0x40000000",
        "0x40000040",
    ]},
    threads = [
        {
            "compartment": "app",
            "entry": "main_thread",
            "priority": 1,
            "stack_size": 1024,
            "trusted_stack_frames": 4,
        },
        {
            "compartment": "app",
            "entry": "helper_thread",
            "priority": 1,
            "stack_size": 1024,
            "trusted_stack_frames": 4,
        },
    ],
)
