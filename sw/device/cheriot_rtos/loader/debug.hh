// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

/**
 * A no-output replacement for the CHERIoT RTOS loader's `debug.hh`.
 *
 * The upstream header formats loader log messages to a UART, which needs a
 * UART driver and a large part of the C++ standard library (`<array>`,
 * `<string_view>`). This keeps the interface the loader uses (`Debug::log`,
 * `Debug::Invariant`, `Debug::Assert`, `DebugLoader`) but never produces
 * output: `log` and `Assert` do nothing, and a failed `Invariant` traps.
 *
 * It is found through `-iquote` because the vendored copy of the loader does
 * not include `debug.hh`.
 */

#include <stddef.h>
#include <stdint.h>

namespace
{
	/// The loader is never built with debug output.
	static constexpr bool DebugLoader = false;

	struct Debug
	{
		/// Log a message: ignored.
		template<typename... Args>
		static void log(const char *, Args &&...)
		{
		}

		/// Check a condition that must always hold; trap if it does not.
		template<typename... Args>
		struct Invariant
		{
			__always_inline Invariant(bool condition, const char *, Args &&...)
			{
				if (!condition)
				{
					__builtin_trap();
				}
			}
		};

		/// Assertion that is only checked in debug builds: ignored.
		template<typename... Args>
		struct Assert
		{
			template<typename T>
			__always_inline Assert(T &&, const char *, Args &&...)
			{
			}
		};

		// Deduction guides, so that these can be used like functions.
		template<typename... Ts>
		Invariant(bool, const char *, Ts &&...) -> Invariant<Ts...>;

		template<typename T, typename... Ts>
		Assert(T &&, const char *, Ts &&...) -> Assert<Ts...>;
	};
} // namespace
