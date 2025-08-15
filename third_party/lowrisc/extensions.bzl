# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

def _lowrisc_repos():
    VERSION = "test-2025-08-15-v2"
    http_archive(
        name = "lowrisc_rv32imcb_toolchain",
        url = "https://github.com/jwnrt/lowrisc-toolchains/releases/download/{v}/lowrisc-toolchain-rv32imcb-x86_64-{v}.tar.xz".format(v = VERSION),
        sha256 = "11a63c08de028bebe6d3546979bb024d5b95dba3362fcdfab4d7172fe3b12e20",
        strip_prefix = "lowrisc-toolchain-rv32imcb-x86_64-{}".format(VERSION),
        build_file = ":BUILD.lowrisc_rv32imcb_toolchain.bazel",
    )

lowrisc_rv32imcb_toolchain = module_extension(
    implementation = lambda _: _lowrisc_repos(),
)
