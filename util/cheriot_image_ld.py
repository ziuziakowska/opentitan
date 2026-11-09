#!/usr/bin/env python3
# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

"""Generates the firmware linker script for a CHERIoT RTOS image.

The CHERIoT RTOS builds its firmware linker script from three templates by
substituting, for each compartment and library, blocks that select the
component's sections by file name, and for each thread, its stacks and its entry
in the thread table. The RTOS does this in Lua inside its xmake build system
(`sdk/xmake.lua`, the `cheriot.firmware.ldscript.conf` rule); this is the same
substitution for the parts an image of ours needs, and nothing else.

The whole image runs from RAM. The RTOS's loader writes into its code at boot
(the capabilities of each component's import table, which is at the start of its
code, the export tables, and the sealing keys and scheduler entry in the
switcher, the scheduler and the token library), and the RTOS does not yet
support running its code in place. So the image is stored in NVM and its early
boot code copies all of it to RAM, then continues there. See
`rules/cheriot.bzl:cheriot_image` and `sw/device/cheriot_rtos/loader`.

The script has no `MEMORY` command. With one, lld puts the RTOS's sections,
which name no region, into the first region whose attributes match; so the
addresses come from OpenTitan's memory description instead (`memory_ld`), and
the result is a script with absolute addresses.

Usage: cheriot_image_ld.py CONFIG.json OUTPUT.ld

The config is a JSON object with:
  rocode_template, rwdata_template: paths of `firmware.{rocode,rwdata}.ldscript.in`
  threads: list of {compartment, entry, priority, stack_size, trusted_stack_frames}
  compartments, libraries: lists of {name, file}; `file` is the base name that the
      component's linked file has on the linker command line
  devices: list of {name, start, end} for the `__export_mem_<name>` symbols
  memory_ld: path of OpenTitan's memory description (`top_<top>_memory.ld`)
  rom_region, ram_region: names of the regions (or region aliases) in it that
      hold the stored image and that it runs in
  manifest_size: bytes the stored image leaves at the start of its region; the
      stored image's alignment must match its address in RAM, so keep this a
      multiple of the largest section alignment (1 KiB suffices)
  wrapper_template: path of a template that surrounds the image; it uses
      `@rom_origin@`, `@rom_size@`, `@rom_start@` (where the stored image
      begins, after the manifest), `@ram_origin@`, `@ram_size@` and `@image@`
"""

import json
import re
import sys


def parse_memory(path):
    """Returns ({region: (origin, length)}, {alias: region}) from a `.ld` file."""
    with open(path) as f:
        text = f.read()
    number = r"(0x[0-9a-fA-F]+|\d+)"
    regions = {
        m.group(1): (int(m.group(2), 0), int(m.group(3), 0))
        for m in re.finditer(
            r"(\w+)\s*\([rwxail!]*\)\s*:\s*ORIGIN\s*=\s*" + number + r"\s*,\s*LENGTH\s*=\s*" + number,
            text,
        )
    }
    aliases = dict(re.findall(r'REGION_ALIAS\("(\w+)"\s*,\s*(\w+)\)', text))
    reserved = re.search(r"_nvm_slot_reserved_bytes\s*=\s*(\d+)", text)
    return regions, aliases, int(reserved.group(1)) if reserved else 0


def region(regions, aliases, name):
    return regions[aliases.get(name, name)]


def substitute(template, values):
    """Replaces each `${name}` in `template` with `values[name]`."""
    return re.sub(r"\$\{(\w*)\}", lambda m: str(values[m.group(1)]), template)


# Declare space and start and end symbols for a thread's C stack.
THREAD_STACK = (
    "\n\t. = ALIGN(16);"
    "\n\t.thread_stack_${thread_id} : CAPALIGN"
    "\n\t{"
    "\n\t\t.thread_${thread_id}_stack_start = .;"
    "\n\t\t. += ${stack_size};"
    "\n\t\t.thread_${thread_id}_stack_end = .;"
    "\n\t}\n"
)

# Declare space and start and end symbols for a thread's trusted stack.
THREAD_TRUSTED_STACK = (
    "\n\t. = ALIGN(8);"
    "\n\t.thread_trusted_stack_${thread_id} : CAPALIGN"
    "\n\t{"
    "\n\t\t.thread_${thread_id}_trusted_stack_start = .;"
    "\n\t\t. += __cheriot_switcher_trusted_stack_base_size;"
    "\n\t\t. += __cheriot_switcher_trusted_stack_frame_size * ${trusted_stack_frames};"
    "\n\t\t.thread_${thread_id}_trusted_stack_end = .;"
    "\n\t}\n"
)

# One `ThreadConfig` (sdk/core/loader/types.h).
THREAD_HEADER = (
    "\n\t\tSHORT(${priority});"
    "\n\t\tLONG(${mangled_entry_point});"
    "\n\t\tLONG(.thread_${thread_id}_stack_start);"
    "\n\t\tSHORT(.thread_${thread_id}_stack_end - .thread_${thread_id}_stack_start);"
    "\n\t\tLONG(.thread_${thread_id}_trusted_stack_start);"
    "\n\t\tSHORT(.thread_${thread_id}_trusted_stack_end - .thread_${thread_id}_trusted_stack_start);"
    "\n\n"
)

# Per-compartment blocks. Each substitutes `${compartment}` (its name) and
# `${obj}` (a glob for its linked file). The glob is not quoted: lld does not
# expand wildcards in a quoted file name.
COMPARTMENT_TEMPLATES = {
    # sdk/core/loader/types.h:/CompartmentHeader
    "compartment_headers": (
        '\n\t\tLONG(".${compartment}_code_start");'
        '\n\t\tSHORT((SIZEOF(.${compartment}_code) + 7) / 8);'
        '\n\t\tSHORT(".${compartment}_imports_end" - ".${compartment}_code_start");'
        '\n\t\tLONG(".${compartment}_export_table");'
        '\n\t\tSHORT(".${compartment}_export_table_end" - ".${compartment}_export_table");'
        '\n\t\tLONG(".${compartment}_globals");'
        '\n\t\tASSERT((SIZEOF(".${compartment}_globals") % 4) == 0, "${compartment}\'s globals oddly sized");'
        '\n\t\tASSERT(SIZEOF(".${compartment}_globals") < 0x40000, "${compartment}\'s globals are too large");'
        '\n\t\tSHORT(SIZEOF(".${compartment}_globals") / 4);'
        '\n\t\tSHORT(".${compartment}_bss_start" - ".${compartment}_globals");'
        '\n\t\tLONG(".${compartment}_cap_relocs_start");'
        '\n\t\tSHORT(".${compartment}_cap_relocs_end" - ".${compartment}_cap_relocs_start");'
        '\n\t\tLONG(".${compartment}_sealed_objects_start");'
        '\n\t\tSHORT(".${compartment}_sealed_objects_end" - ".${compartment}_sealed_objects_start");\n'
    ),
    "pcc_ld": (
        '\n\t".${compartment}_code" : CAPALIGN'
        "\n\t{"
        '\n\t\t".${compartment}_code_start" = .;'
        '\n\t\t${obj}(".compartment_import_table");'
        '\n\t\t".${compartment}_imports_end" = .;'
        '\n\t\t${obj}(.text);'
        '\n\t\t${obj}(.init_array);'
        '\n\t\t${obj}(.rodata);'
        "\n\t\t. = ALIGN(8);"
        "\n\t}\n"
    ),
    "gdc_ld": (
        '\n\t".${compartment}_globals" : CAPALIGN'
        "\n\t{"
        '\n\t\t".${compartment}_globals" = .;'
        '\n\t\t${obj}(.data);'
        '\n\t\t".${compartment}_bss_start" = .;'
        '\n\t\t${obj}(.bss)'
        "\n\t\t. = ALIGN(4);"
        "\n\t}\n"
    ),
    "compartment_exports": (
        '\n\t\t. = ALIGN(8); ".${compartment}_export_table" = .;'
        '\n\t\t${obj}(.compartment_export_table);'
        '\n\t\t".${compartment}_export_table_end" = .;\n'
    ),
    "cap_relocs": (
        '\n\t\t".${compartment}_cap_relocs_start" = .;'
        '\n\t\t${obj}(__cap_relocs);'
        '\n\t\t".${compartment}_cap_relocs_end" = .;'
    ),
    "sealed_objects": (
        '\n\t\t".${compartment}_sealed_objects_start" = .;'
        '\n\t\t${obj}(.sealed_objects);'
        '\n\t\t".${compartment}_sealed_objects_end" = .;'
    ),
}

# Libraries are almost identical to compartments, except that they have no
# globals and their export tables are placed with the library exports.
LIBRARY_TEMPLATES = dict(COMPARTMENT_TEMPLATES)
LIBRARY_TEMPLATES["compartment_headers"] = (
    '\n\t\tLONG(".${compartment}_code_start");'
    '\n\t\tSHORT((SIZEOF(.${compartment}_code) + 7) / 8);'
    '\n\t\tSHORT(".${compartment}_imports_end" - ".${compartment}_code_start");'
    '\n\t\tLONG(".${compartment}_export_table");'
    '\n\t\tSHORT(".${compartment}_export_table_end" - ".${compartment}_export_table");'
    "\n\t\tLONG(0);"
    "\n\t\tSHORT(0);"
    "\n\t\tSHORT(0);"
    '\n\t\tLONG(".${compartment}_cap_relocs_start");'
    '\n\t\tSHORT(".${compartment}_cap_relocs_end" - ".${compartment}_cap_relocs_start");'
    '\n\t\tLONG(".${compartment}_sealed_objects_start");'
    '\n\t\tSHORT(".${compartment}_sealed_objects_end" - ".${compartment}_sealed_objects_start");\n'
)
LIBRARY_TEMPLATES["gdc_ld"] = ""
LIBRARY_TEMPLATES["library_exports"] = LIBRARY_TEMPLATES.pop("compartment_exports")

# Statically allocated objects that components share. The loader requires the
# allocator's hazard pointers (two per thread) even without an allocator.
SHARED_OBJECT = (
    "\n\t\t. = ALIGN(MIN(${size}, 8));"
    "\n\t\t__cheriot_shared_object_section_${global} : CAPALIGN"
    "\n\t\t{"
    "\n\t\t\t__cheriot_shared_object_${global} = .;"
    "\n\t\t\t. += ${size};"
    "\n\t\t\t__cheriot_shared_object_${global}_end = .;"
    "\n\t\t}\n"
)

# Stacks must be smaller than this: the loader metadata cannot express more.
STACK_SIZE_LIMIT = 65280


def generate(config):
    threads = config["threads"]
    if not threads:
        raise SystemExit("an image needs at least one thread")

    # Per-thread values.
    for i, thread in enumerate(threads):
        thread["thread_id"] = i + 1
        entry = thread["entry"]
        # The compiler mangles an exported function's name as C++ does, also
        # for C: `__export_<compartment>__Z<length><name>v` for `void name(void)`.
        thread["mangled_entry_point"] = '"__export_%s__Z%d%sv"' % (
            thread["compartment"],
            len(entry),
            entry,
        )
        if thread["stack_size"] > STACK_SIZE_LIMIT:
            raise SystemExit(
                "thread %d: stacks over %d bytes are not supported by the switcher"
                % (i + 1, STACK_SIZE_LIMIT)
            )

    values = {
        key: ""
        for key in [
            "compartment_exports",
            "library_exports",
            "cap_relocs",
            "compartment_headers",
            "pcc_ld",
            "gdc_ld",
            "software_revoker_code",
            "software_revoker_globals",
            "software_revoker_header",
            "sealed_objects",
        ]
    }

    def add(components, templates):
        for component in components:
            for key, template in sorted(templates.items()):
                values[key] += substitute(
                    template,
                    {"obj": "*/" + component["file"], "compartment": component["name"]},
                )

    # Libraries come first, as in the RTOS's own image.
    add(config["libraries"], LIBRARY_TEMPLATES)
    add(config["compartments"], COMPARTMENT_TEMPLATES)

    values["shared_objects"] = "".join(
        substitute(SHARED_OBJECT, {"global": name, "size": size})
        for name, size in [
            ("allocator_epoch", 4),
            ("allocator_hazard_pointers", len(threads) * 8 * 2),
        ]
    )
    values["heap_start"] = "."
    values["thread_count"] = len(threads)
    values["library_count"] = len(config["libraries"])
    values["compartment_count"] = len(config["compartments"])
    values["thread_headers"] = "".join(substitute(THREAD_HEADER, t) for t in threads)
    values["thread_trusted_stacks"] = "".join(
        substitute(THREAD_TRUSTED_STACK, t) for t in threads
    )
    values["thread_stacks"] = "".join(substitute(THREAD_STACK, t) for t in threads)

    regions, aliases, reserved = parse_memory(config["memory_ld"])
    rom_origin, rom_length = region(regions, aliases, config["rom_region"])
    ram_origin, ram_size = region(regions, aliases, config["ram_region"])
    # The slot the image runs from is the first half of the NVM, less the bytes
    # reserved at the end of the slot (as the OTTF's linker scripts do).
    rom_size = rom_length // 2 - reserved

    def fill(template_path):
        with open(template_path) as f:
            template = f.read()
        return re.sub(r"@(.*?)@", lambda m: str(values[m.group(1)]), template)

    rocode = fill(config["rocode_template"])
    # The image is stored at `rom_start` and runs from RAM: say so on its first
    # section, and the rest follow it.
    first = ".loader_code_persistent : CAPALIGN"
    if first not in rocode:
        raise SystemExit("the rocode template no longer starts with " + first)
    rocode = rocode.replace(
        first,
        ".loader_code_persistent : AT(0x%x) CAPALIGN" % (rom_origin + config["manifest_size"]),
        1,
    )
    # ... and put the image in its own segment (which the sections after it
    # inherit).
    rocode, count = re.subn(
        r"(\.loader_code_persistent : AT\([^)]*\) CAPALIGN\s*\{[^}]*\})",
        r"\1 :rtos_image",
        rocode,
        count=1,
    )
    if count != 1:
        raise SystemExit("could not find the end of the loader's first section")
    rwdata = fill(config["rwdata_template"])


    devices = "".join(
        "__export_mem_{n} = {s};\n__export_mem_{n}_end = {e};\n".format(
            n=d["name"], s=d["start"], e=d["end"]
        )
        for d in config["devices"]
    )

    image = """\
/*
 * Generated by util/cheriot_image_ld.py: the firmware linker script for a CHERIoT
 * RTOS image. Do not edit.
 */

/*
 * The heap starts where the data the loader consumes begins, and the loader
 * zeroes it (which erases the loader). There is no allocator, so nothing but
 * that data needs to be in it: it ends just after the image's writable part.
 */
__export_mem_heap_end = ALIGN(__image_end, 64);
ASSERT(__export_mem_heap_end <= {ram_end}, "The RTOS image does not fit in RAM")

{devices}
SECTIONS
{{
	/* The image runs from RAM, and is stored in NVM from `__image_load_start`
	 * (its first section says so). Its first instruction is the loader's, and
	 * is where the image is entered. */
	. = {ram_start};
	__image_start = .;
{rocode}
{rwdata}
	/* Whole words: the early boot code copies the image word by word. */
	. = ALIGN(8);
	__image_end = .;
}}
__image_load_start = {rom_start};
""".format(
        ram_end="0x%x" % (ram_origin + ram_size),
        devices=devices,
        rom_start="0x%x" % (rom_origin + config["manifest_size"]),
        ram_start="0x%x" % ram_origin,
        rocode=rocode,
        rwdata=rwdata,
    )

    with open(config["wrapper_template"]) as f:
        wrapper = f.read()
    return re.sub(
        r"@(\w+)@",
        lambda m: {
            "rom_origin": "0x%x" % rom_origin,
            "rom_size": "0x%x" % rom_size,
            "ram_origin": "0x%x" % ram_origin,
            "ram_size": "0x%x" % ram_size,
            "rom_start": "0x%x" % (rom_origin + config["manifest_size"]),
            "image": image,
        }[m.group(1)],
        wrapper,
    )


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    with open(sys.argv[1]) as f:
        config = json.load(f)
    with open(sys.argv[2], "w") as f:
        f.write(generate(config))


if __name__ == "__main__":
    main()
