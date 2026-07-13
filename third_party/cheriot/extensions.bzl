# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

load("@bazel_tools//tools/build_defs/repo:local.bzl", "new_local_repository")

def _cheriot_repo():
    new_local_repository(
        name = "cheriot_toolchain",
        path = "/nix/store/c5swjfdl7av20ggwhk0x0mb887mxp84s-llvm-cheriot-20.0.0/",
        build_file = ":BUILD.cheriot_toolchain.bazel",
    )

cheriot_toolchain = module_extension(
    implementation = lambda _: _cheriot_repo(),
)
