# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

"""Rules for building the CHERIoT RTOS loader, switcher and compartments.

The RTOS linker scripts select their inputs by file name (for example
`*/boot.S.o` or `*/switcher/entry.S.o`), so these rules produce files with
exactly those names instead of Bazel's usual `_objs/...` names.
"""

load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")

def _compile(ctx, srcs, flags, defines, cxxopts = [], conlyopts = [], disabled_features = []):
    """Compiles each source on its own and returns the object files.

    Each source is compiled separately because Bazel would otherwise name the
    objects of `boot.S` and `boot.cc` identically.
    """
    cc_toolchain = find_cc_toolchain(ctx)
    features = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        # LTO would produce bitcode, which the RTOS linker scripts cannot place.
        unsupported_features = ctx.disabled_features + ["lto"] + disabled_features,
    )

    objects = []
    for i, src in enumerate(srcs):
        src_flags = list(flags)
        if src.extension in ["cc", "cpp"]:
            src_flags += cxxopts
        elif src.extension == "c":
            src_flags += conlyopts
        _, outputs = cc_common.compile(
            name = "{}_{}".format(ctx.label.name, i),
            actions = ctx.actions,
            feature_configuration = features,
            cc_toolchain = cc_toolchain,
            srcs = [src],
            # Not `private_hdrs`: that rejects files without a header extension
            # (such as `<type_traits>`), and these only need to be in the sandbox.
            additional_inputs = ctx.files.hdrs,
            compilation_contexts = [d[CcInfo].compilation_context for d in ctx.attr.deps],
            user_compile_flags = src_flags,
            defines = defines,
        )
        objects.append(outputs.objects[0])
    return objects

def _include_flags(ctx):
    flags = []
    for include in ctx.attr.includes:
        flags += ["-I", include]
    for include in ctx.attr.quote_includes:
        flags += ["-iquote", include]
    return flags + ctx.attr.copts

_COMPILE_ATTRS = {
    "srcs": attr.label_list(allow_files = True, doc = "Sources to compile."),
    "hdrs": attr.label_list(allow_files = True, doc = "Headers the sources include."),
    "deps": attr.label_list(
        providers = [CcInfo],
        doc = "Libraries whose headers the sources include (they are not linked).",
    ),
    "includes": attr.string_list(doc = "Directories for `-I`, relative to the workspace root."),
    "quote_includes": attr.string_list(doc = "Directories for `-iquote`, relative to the workspace root."),
    "defines": attr.string_list(doc = "Preprocessor definitions."),
    "copts": attr.string_list(doc = "Compiler options for every source."),
    "cxxopts": attr.string_list(doc = "Additional compiler options for C++ sources."),
}

def _cheriot_objects_impl(ctx):
    objects = []
    # The loader is built for speed, as the RTOS does: the toolchain's `minsize`
    # feature would put `-Oz` after the `-O3` in `copts`, which stops the
    # inlining that keeps the loader free of COMDAT groups (`ld.lld -r` cannot
    # re-link those).
    objs = _compile(
        ctx,
        ctx.files.srcs,
        _include_flags(ctx),
        ctx.attr.defines,
        ctx.attr.cxxopts,
        disabled_features = ["minsize"],
    )
    for obj, src in zip(objs, ctx.files.srcs):
        link = ctx.actions.declare_file("{}/{}.o".format(ctx.label.name, src.basename))
        ctx.actions.symlink(output = link, target_file = obj)
        objects.append(link)
    return [DefaultInfo(files = depset(objects))]

cheriot_objects = rule(
    implementation = _cheriot_objects_impl,
    doc = """Compiles sources to objects named `<name>/<source file name>.o`.""",
    attrs = _COMPILE_ATTRS,
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
)

def _cheriot_loader_impl(ctx):
    objects = ctx.files.objects
    out = ctx.actions.declare_file(ctx.label.name + ".loader.o")
    ctx.actions.run(
        executable = ctx.executable._lld,
        arguments = [
            "--relocatable",
            "--gc-sections",
            "--script=" + ctx.file.script.path,
            "-o",
            out.path,
        ] + [o.path for o in objects],
        inputs = objects + [ctx.file.script],
        outputs = [out],
        mnemonic = "CheriotLoaderLink",
        progress_message = "Linking CHERIoT loader %{output}",
    )
    return [DefaultInfo(files = depset([out]))]

_LLD = attr.label(
    default = "@lowrisc_cheriot_toolchain//:bin/ld.lld",
    allow_single_file = True,
    executable = True,
    cfg = "exec",
)

cheriot_loader = rule(
    implementation = _cheriot_loader_impl,
    doc = """Links the loader's objects into one relocatable object, `<name>.loader.o`.

The result is an input to the final image link, whose script finds the loader by
the `*.loader.o` name.""",
    attrs = {
        "objects": attr.label(
            mandatory = True,
            allow_files = True,
            doc = "A `cheriot_objects` target with `boot.S.o` and `boot.cc.o`.",
        ),
        "script": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The loader linker script (`loader.ldscript`).",
        ),
        "_lld": _LLD,
    },
)

CheriotComponentInfo = provider(
    doc = "A linked CHERIoT RTOS component, ready to be placed in an image.",
    fields = {
        "file": "The `.compartment` or `.library` file.",
        "component_name": "The compartment name (what other components import it as).",
        "kind": "One of the `kind` values of `cheriot_component`.",
    },
)

# What each kind of component is built as. See sdk/xmake.lua, the
# `cheriot.compartment`, `cheriot.privileged-compartment` and
# `cheriot.privileged-library` rules.
_KINDS = {
    "compartment": struct(extension = "compartment", privileged = False, named = True),
    "privileged_compartment": struct(extension = "compartment", privileged = True, named = True),
    "privileged_library": struct(extension = "library", privileged = True, named = False),
}

def _cheriot_component_impl(ctx):
    kind = _KINDS[ctx.attr.kind]
    name = ctx.attr.component_name or ctx.label.name

    flags = [
        # The RTOS ABI (not the bare-metal one the toolchain defaults to), and
        # its target, which the compiler needs to select compartment lowering.
        "-target",
        "riscv32-unknown-cheriotrtos",
        "-mabi=cheriot",
        "-mrelax",
        "-Xclang",
        "-cheri-bounds=subobject-safe",
        # Third-party code: not warning-clean under OpenTitan's flags.
        "-w",
    ]
    if kind.named:
        flags.append("-cheri-compartment=" + name)
    defines = ["NDEBUG", "CHERIOT_NO_AMBIENT_MALLOC"]
    if kind.privileged:
        defines.append("CHERIOT_AVOID_CAPRELOCS")

    objects = _compile(
        ctx,
        ctx.files.srcs,
        flags + _include_flags(ctx),
        ctx.attr.defines + defines,
        cxxopts = ctx.attr.cxxopts + ["-std=c++23", "-fno-exceptions", "-fno-rtti"],
        conlyopts = ["-std=c23"],
    )

    script = ctx.file._privileged_ld if kind.privileged else ctx.file._compartment_ld
    out = ctx.actions.declare_file("{}.{}".format(ctx.label.name, kind.extension))
    ctx.actions.run(
        executable = ctx.executable._lld,
        arguments = [
            "--script=" + script.path,
            "--compartment",
            "--gc-sections",
            "--relax",
            "-o",
            out.path,
        ] + [o.path for o in objects],
        inputs = objects + [script],
        outputs = [out],
        mnemonic = "CheriotComponentLink",
        progress_message = "Linking CHERIoT {} %{{output}}".format(ctx.attr.kind),
    )
    return [
        DefaultInfo(files = depset([out])),
        CheriotComponentInfo(file = out, component_name = name, kind = ctx.attr.kind),
    ]

_component_attrs = dict(_COMPILE_ATTRS)
_component_attrs.update({
    "kind": attr.string(
        mandatory = True,
        values = _KINDS.keys(),
        doc = """What the component is:

* `compartment`: an application compartment (code, globals, imports, exports).
* `privileged_compartment`: as above, with space for sealing keys; the scheduler.
* `privileged_library`: stateless code reached through sentries; the token library.""",
    ),
    "component_name": attr.string(
        doc = "The compartment name, as exports are named and imports refer to it. Defaults to the target name.",
    ),
    "_lld": _LLD,
    "_compartment_ld": attr.label(
        default = "//sw/vendor:cheriot_rtos/sdk/compartment.ldscript",
        allow_single_file = True,
    ),
    "_privileged_ld": attr.label(
        default = "//sw/vendor:cheriot_rtos/sdk/privileged-compartment.ldscript",
        allow_single_file = True,
    ),
})

cheriot_component = rule(
    implementation = _cheriot_component_impl,
    doc = """Compiles sources as one CHERIoT RTOS component and links it with `ld.lld --compartment`.

The result is a relocatable `.compartment` or `.library` file whose export and
import tables the image link and the loader resolve.""",
    attrs = _component_attrs,
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
)

def _symlink(ctx, name, target):
    link = ctx.actions.declare_file("{}/{}".format(ctx.label.name, name))
    ctx.actions.symlink(output = link, target_file = target)
    return link

def _cheriot_image_impl(ctx):
    scheduler = ctx.attr.scheduler[CheriotComponentInfo]
    token_library = ctx.attr.token_library[CheriotComponentInfo]
    compartments = [c[CheriotComponentInfo] for c in ctx.attr.compartments]
    libraries = [l[CheriotComponentInfo] for l in ctx.attr.libraries]

    # The RTOS's linker script templates look for these file names.
    scheduler_file = _symlink(ctx, ctx.label.name + ".scheduler.compartment", scheduler.file)
    token_library_file = _symlink(ctx, "cheriot.token_library.library", token_library.file)
    switcher_files = ctx.files.switcher
    files = [ctx.file.loader, scheduler_file, token_library_file] + switcher_files + \
            [c.file for c in compartments] + [l.file for l in libraries]

    memory = [f for f in ctx.attr.memory[DefaultInfo].files.to_list() if f.basename.endswith("_memory.ld")]
    if len(memory) != 1:
        fail("expected one `*_memory.ld` file in `memory`, found {}".format(len(memory)))

    config = ctx.actions.declare_file(ctx.label.name + ".json")
    script = ctx.actions.declare_file(ctx.label.name + "/cheriot_image.ld")
    ctx.actions.write(config, json.encode({
        "rocode_template": ctx.file._rocode_template.path,
        "rwdata_template": ctx.file._rwdata_template.path,
        "wrapper_template": ctx.file.wrapper.path,
        "memory_ld": memory[0].path,
        "rom_region": ctx.attr.rom_region,
        "ram_region": ctx.attr.ram_region,
        "manifest_size": ctx.attr.manifest_size,
        "threads": [json.decode(t) for t in ctx.attr.threads],
        "compartments": [{"name": c.component_name, "file": c.file.basename} for c in compartments],
        "libraries": [{"name": l.component_name, "file": l.file.basename} for l in libraries],
        "devices": [
            {"name": name, "start": bounds[0], "end": bounds[1]}
            for name, bounds in ctx.attr.devices.items()
        ],
    }))
    ctx.actions.run(
        executable = ctx.executable._generator,
        arguments = [config.path, script.path],
        inputs = [config, ctx.file._rocode_template, ctx.file._rwdata_template, ctx.file.wrapper, memory[0]],
        outputs = [script],
        mnemonic = "CheriotImageScript",
        progress_message = "Generating CHERIoT image linker script %{output}",
    )

    # What the final link needs, so that the OpenTitan binary rule, which does
    # the link, uses it: the script, and the files it selects by name. The
    # RTOS's scripts rely on sections that nothing references surviving, and
    # place the image themselves, so garbage collection is off and the segments
    # are not page aligned.
    flags = ["-Wl,-T," + script.path, "-Wl,-n", "-Wl,--relax", "-Wl,--no-gc-sections"]
    flags += [f.path for f in files]
    linking_context = cc_common.create_linking_context(
        linker_inputs = depset([cc_common.create_linker_input(
            owner = ctx.label,
            additional_inputs = depset(files + [script]),
            user_link_flags = depset(flags),
        )]),
    )
    return [
        DefaultInfo(files = depset([script])),
        CcInfo(linking_context = linking_context),
    ]

cheriot_image = rule(
    implementation = _cheriot_image_impl,
    doc = """Assembles the components of a CHERIoT RTOS image for the final link.

Generates the firmware linker script (see `util/cheriot_image_ld.py`) and provides,
as a `CcInfo`, the link flags and inputs that place the loader, the switcher, the
scheduler, the token library and the compartments with it. Depend on it from a
binary; the binary's own link then produces the ELF.""",
    attrs = {
        "loader": attr.label(mandatory = True, allow_single_file = True, doc = "The linked loader (`cheriot_loader`)."),
        "switcher": attr.label(mandatory = True, allow_files = True, doc = "The compiled switcher (`cheriot_objects`, named `switcher`)."),
        "scheduler": attr.label(mandatory = True, providers = [CheriotComponentInfo]),
        "token_library": attr.label(mandatory = True, providers = [CheriotComponentInfo]),
        "compartments": attr.label_list(providers = [CheriotComponentInfo]),
        "libraries": attr.label_list(providers = [CheriotComponentInfo]),
        "threads": attr.string_list(
            mandatory = True,
            doc = "One JSON object per thread: `compartment`, `entry`, `priority`, `stack_size`, `trusted_stack_frames`.",
        ),
        "devices": attr.string_list_dict(doc = "Device name to its `[start, end]` addresses, for `__export_mem_<name>`."),
        "memory": attr.label(mandatory = True, doc = "A target providing OpenTitan's `top_*_memory.ld`."),
        "rom_region": attr.string(default = "nvm", doc = "The memory region the image is stored in."),
        "ram_region": attr.string(default = "ram_main", doc = "The memory region the writable part runs in."),
        "manifest_size": attr.int(default = 0x400, doc = "Bytes the image leaves at the start of its region for the manifest."),
        "wrapper": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The template that surrounds the generated sections (`image.ld.in`).",
        ),
        "_generator": attr.label(
            default = "//util:cheriot_image_ld",
            executable = True,
            cfg = "exec",
        ),
        "_rocode_template": attr.label(
            default = "//sw/vendor:cheriot_rtos/sdk/firmware.rocode.ldscript.in",
            allow_single_file = True,
        ),
        "_rwdata_template": attr.label(
            default = "//sw/vendor:cheriot_rtos/sdk/firmware.rwdata.ldscript.in",
            allow_single_file = True,
        ),
    },
)
