# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

"""Macros for building and testing firmware on the CHERIoT RTOS loader and switcher."""

load("//rules:cheriot.bzl", "cheriot_component", "cheriot_image")
load("//rules/opentitan:defs.bzl", "CHERIOT_PLATFORM", "opentitan_test")

def cheriot_compartment(name, srcs, **kwargs):
    """An application compartment, in C.

    Args:
      name: The target name, and by default the compartment's name: the name
        other compartments' declarations of its exported functions use
        (`OT_CHERIOT_COMPARTMENT("name")`).
      srcs: The sources of the compartment.
      **kwargs: Passed to `cheriot_component`.
    """
    cheriot_component(
        name = name,
        srcs = srcs,
        kind = "compartment",
        **kwargs
    )

def cheriot_rtos_test(name, compartments, threads, devices = {}, exec_env = None, **kwargs):
    """A firmware test, built on the CHERIoT RTOS loader and switcher.

    The image consists of the RTOS's loader and switcher, the C scheduler in
    `//sw/device/cheriot_rtos:scheduler`, the token library the loader needs, and
    the given compartments. The test passes when the firmware prints a line
    starting with `PASS`.

    Args:
      name: The test name.
      compartments: `cheriot_compartment` targets to include.
      threads: The threads to start, in scheduling order: a list of dicts with the
        keys `compartment`, `entry` (the name of a `void entry(void)` that the
        compartment exports), `priority`, `stack_size` and `trusted_stack_frames`
        (how deeply the thread may call across compartments, plus one).
      devices: The MMIO regions the compartments import with `OT_CHERIOT_MMIO`:
        each name maps to the `[start, end]` addresses of the device.
      exec_env: The execution environments to run in; the Verilator simulation
        by default.
      **kwargs: Passed to `opentitan_test`.
    """
    cheriot_image(
        name = name + "_image",
        testonly = True,
        loader = "//sw/device/cheriot_rtos:loader",
        switcher = "//sw/device/cheriot_rtos:switcher",
        scheduler = "//sw/device/cheriot_rtos:scheduler",
        token_library = "//sw/device/cheriot_rtos:token_library",
        compartments = compartments,
        threads = [json.encode(t) for t in threads],
        devices = devices,
        memory = "//hw/top:top_ld",
        wrapper = "//sw/device/cheriot_rtos:image.ld.in",
    )
    opentitan_test(
        name = name,
        # The image holds all the code; the binary only needs the manifest.
        deps = [
            ":" + name + "_image",
            "//sw/device:info_sections",
            "//sw/device/silicon_creator/lib:manifest_def",
        ],
        linker_script = "//sw/device/cheriot_rtos:no_script",
        platform = CHERIOT_PLATFORM,
        exec_env = exec_env or {"//hw/top_earlgrey:sim_verilator": None},
        **kwargs
    )
