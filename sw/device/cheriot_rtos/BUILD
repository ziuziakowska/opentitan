# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

load("//rules:linker.bzl", "ld_library")
load("//rules:cheriot.bzl", "cheriot_component", "cheriot_loader", "cheriot_objects")

package(default_visibility = ["//visibility:public"])

# The CHERIoT RTOS is used only as a loader and a compartment switcher. Their
# sources are vendored in `//sw/vendor:cheriot_rtos`; this
# package builds them.

_RTOS = "sw/vendor/cheriot_rtos/sdk"

# Everything a source of the loader or the switcher may include: the vendored
# headers, and the small replacements for the standard library and for the
# loader's debug output that live in this package.
_HDRS = [
    "//sw/vendor:cheriot_rtos",
    ":headers",
]

filegroup(
    name = "headers",
    srcs = glob([
        "loader/*",
        "std/*",
    ]),
)

_INCLUDES = [
    "sw/device/cheriot_rtos/std",
    _RTOS + "/include",
    _RTOS + "/include/platform/ibex",
    _RTOS + "/include/platform/generic-riscv",
]

_DEFINES = [
    "IBEX",
    "NDEBUG",
    "CHERIOT_NO_AMBIENT_MALLOC",
    "CHERIOT_AVOID_CAPRELOCS",
    "DEBUG_LOADER=false",
]

_COPTS = [
    # Third-party code: the vendored sources are not warning-clean under OpenTitan's flags.
    "-w",
    "-mrelax",
    "-Xclang",
    "-cheri-bounds=subobject-safe",
]

_CXXOPTS = [
    "-std=c++23",
    "-O3",
    "-fno-exceptions",
    "-fno-rtti",
    "-fno-asynchronous-unwind-tables",
    "-fno-c++-static-destructors",
]

cheriot_objects(
    name = "loader_objects",
    srcs = [
        "//sw/vendor:cheriot_rtos/sdk/core/loader/boot.S",
        "//sw/vendor:cheriot_rtos/sdk/core/loader/boot.cc",
    ],
    hdrs = _HDRS,
    copts = _COPTS,
    cxxopts = _CXXOPTS,
    defines = _DEFINES,
    # The platform hooks `boot.S` includes (`platform-early_boot*.inc`, found
    # with `<>`, hence `-I`), and the debug stub `boot.cc` includes (found with
    # `""`, hence `-iquote`), are in `loader/`. The hooks use the generated
    # register headers.
    includes = _INCLUDES + ["sw/device/cheriot_rtos/loader"],
    quote_includes = ["sw/device/cheriot_rtos/loader"],
    deps = [
        "//hw/top:rv_core_ibex_c_regs",
        "//hw/top:sram_ctrl_c_regs",
        "//hw/top:top_lib",
        "//sw/device/lib/base:multibits",
    ],
)

# `cheriot.loader.o`: the loader, linked so that the part that must survive
# boot is separate from the part that is erased once it has run.
cheriot_loader(
    name = "loader",
    objects = ":loader_objects",
    script = "//sw/vendor:cheriot_rtos/sdk/core/loader/loader.ldscript",
)

# `switcher/entry.S.o`. The final link script looks for exactly this path.
cheriot_objects(
    name = "switcher",
    srcs = ["//sw/vendor:cheriot_rtos/sdk/core/switcher/entry.S"],
    hdrs = _HDRS,
    copts = _COPTS,
    defines = _DEFINES,
    includes = _INCLUDES,
)

# The scheduler the loader and switcher need, written in C: see its header
# comment for what it does and does not do.
cheriot_component(
    name = "scheduler",
    srcs = ["scheduler/scheduler.c"],
    deps = ["//sw/device/lib/base:cheriot_compartment"],
    kind = "privileged_compartment",
)

# The token library. The loader writes sealing keys into it, so it is needed
# even though nothing here uses sealed objects.
cheriot_component(
    name = "token_library",
    srcs = ["//sw/vendor:cheriot_rtos/sdk/core/token_library/token_unseal.S"],
    hdrs = _HDRS,
    component_name = "token_library",
    includes = [_RTOS + "/include"],
    kind = "privileged_library",
)

exports_files(["image.ld.in"])

# The test rule gives the link its linker script through `cheriot_image` rather
# than through the execution environment, so the environment's script is
# replaced by an empty one.
ld_library(
    name = "no_script",
)
