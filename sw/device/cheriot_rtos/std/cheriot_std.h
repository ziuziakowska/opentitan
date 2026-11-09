// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

/**
 * The few C++ standard library facilities that the CHERIoT RTOS loader and
 * switcher headers use, built on compiler intrinsics.
 *
 * Everything here is a compile-time utility: the loader links no C++ library
 * code. The standard headers `<type_traits>`, `<utility>`, `<limits>`,
 * `<concepts>`, `<compare>`, `<cstddef>`, `<cstdint>` and `<initializer_list>`
 * are provided by one-line wrappers that include this file, so that the
 * vendored sources compile unmodified without libc++.
 */

#include <stddef.h>
#include <stdint.h>

// `std::initializer_list` is a language feature: the compiler requires this
// exact layout in namespace `std`.
namespace std
{
	template<class T>
	class initializer_list
	{
		const T *begin_;
		size_t   size_;

		constexpr initializer_list(const T *b, size_t s) : begin_(b), size_(s) {}

		public:
		constexpr initializer_list() : begin_(nullptr), size_(0) {}
		constexpr size_t   size() const { return size_; }
		constexpr const T *begin() const { return begin_; }
		constexpr const T *end() const { return begin_ + size_; }
	};

	using nullptr_t = decltype(nullptr);
	using size_t    = ::size_t;
	using ptrdiff_t = decltype((char *)nullptr - (char *)nullptr);

	// --- <type_traits>
	template<class T, T V>
	struct integral_constant
	{
		static constexpr T value = V;
		constexpr operator T() const { return V; }
	};
	using true_type  = integral_constant<bool, true>;
	using false_type = integral_constant<bool, false>;

	template<class T> struct remove_const { using type = T; };
	template<class T> struct remove_const<const T> { using type = T; };
	template<class T> struct remove_volatile { using type = T; };
	template<class T> struct remove_volatile<volatile T> { using type = T; };
	template<class T> struct remove_reference { using type = T; };
	template<class T> struct remove_reference<T &> { using type = T; };
	template<class T> struct remove_reference<T &&> { using type = T; };
	template<class T> struct remove_pointer { using type = T; };
	template<class T> struct remove_pointer<T *> { using type = T; };
	template<class T> struct remove_pointer<T *const> { using type = T; };
	template<class T> struct remove_pointer<T *volatile> { using type = T; };
	template<class T> struct remove_pointer<T *const volatile> { using type = T; };
	template<class T> using remove_const_t     = typename remove_const<T>::type;
	template<class T> using remove_volatile_t  = typename remove_volatile<T>::type;
	template<class T> using remove_reference_t = typename remove_reference<T>::type;
	template<class T> using remove_pointer_t   = typename remove_pointer<T>::type;
	template<class T>
	using remove_cvref_t = remove_const_t<remove_volatile_t<remove_reference_t<T>>>;

	template<bool B, class T, class F> struct conditional { using type = T; };
	template<class T, class F> struct conditional<false, T, F> { using type = F; };
	template<bool B, class T, class F>
	using conditional_t = typename conditional<B, T, F>::type;

	template<bool B, class T = void> struct enable_if {};
	template<class T> struct enable_if<true, T> { using type = T; };
	template<bool B, class T = void>
	using enable_if_t = typename enable_if<B, T>::type;

	template<class A, class B> inline constexpr bool is_same_v = __is_same(A, B);
	template<class T> inline constexpr bool is_void_v = __is_same(remove_const_t<remove_volatile_t<T>>, void);
	template<class T> inline constexpr bool is_integral_v = __is_integral(T);
	template<class T> inline constexpr bool is_enum_v = __is_enum(T);
	template<class T> inline constexpr bool is_pointer_v = __is_pointer(T);
	template<class T> inline constexpr bool is_trivially_destructible_v = __is_trivially_destructible(T);
	template<class T> inline constexpr bool is_trivially_copy_constructible_v = __is_trivially_constructible(T, const T &);
	template<class T> inline constexpr bool has_unique_object_representations_v = __has_unique_object_representations(T);
	template<class From, class To> inline constexpr bool is_convertible_v = __is_convertible(From, To);
	template<class T> inline constexpr size_t extent_v = __array_extent(T, 0);

	template<class T> struct is_same_t_helper {};
	template<class T> T &&declval() noexcept;

	// --- <utility>
	template<class T>
	constexpr T &&forward(remove_reference_t<T> &t) noexcept { return static_cast<T &&>(t); }
	template<class T>
	constexpr T &&forward(remove_reference_t<T> &&t) noexcept { return static_cast<T &&>(t); }
	template<class T>
	constexpr remove_reference_t<T> &&move(T &&t) noexcept { return static_cast<remove_reference_t<T> &&>(t); }

	template<class T, T... Is> struct integer_sequence
	{
		using value_type = T;
		static constexpr size_t size() noexcept { return sizeof...(Is); }
	};
	template<size_t... Is> using index_sequence = integer_sequence<size_t, Is...>;
	template<size_t N>
	using make_index_sequence = __make_integer_seq<integer_sequence, size_t, N>;

	// --- <concepts>
	template<class A, class B>
	concept same_as = __is_same(A, B) && __is_same(B, A);
	template<class From, class To>
	concept convertible_to = is_convertible_v<From, To> && requires { static_cast<To>(declval<From>()); };

	// --- <limits>
	template<class T> struct numeric_limits;
#define CHERIOT_STD_LIMITS(T, MIN, MAX)                                        \
	template<> struct numeric_limits<T>                                        \
	{                                                                          \
		static constexpr T min() { return MIN; }                               \
		static constexpr T max() { return MAX; }                               \
	}
	CHERIOT_STD_LIMITS(bool, false, true);
	CHERIOT_STD_LIMITS(signed char, -128, 127);
	CHERIOT_STD_LIMITS(unsigned char, 0, 0xff);
	CHERIOT_STD_LIMITS(short, -0x7fff - 1, 0x7fff);
	CHERIOT_STD_LIMITS(unsigned short, 0, 0xffff);
	CHERIOT_STD_LIMITS(int, -0x7fffffff - 1, 0x7fffffff);
	CHERIOT_STD_LIMITS(unsigned int, 0, 0xffffffffu);
	CHERIOT_STD_LIMITS(long, -0x7fffffffl - 1, 0x7fffffffl);
	CHERIOT_STD_LIMITS(unsigned long, 0, 0xfffffffful);
	CHERIOT_STD_LIMITS(long long, -0x7fffffffffffffffll - 1, 0x7fffffffffffffffll);
	CHERIOT_STD_LIMITS(unsigned long long, 0, 0xffffffffffffffffull);
#undef CHERIOT_STD_LIMITS

	/// Is the integer value `t` representable as an `R`?
	template<class R, class T>
	constexpr bool in_range(T t) noexcept
	{
		constexpr bool TSigned = T(-1) < T(0);
		constexpr bool RSigned = R(-1) < R(0);
		if constexpr (TSigned == RSigned)
		{
			return t >= numeric_limits<R>::min() && t <= numeric_limits<R>::max();
		}
		else if constexpr (TSigned)
		{
			return t >= 0 && static_cast<unsigned long long>(t) <=
			                   static_cast<unsigned long long>(numeric_limits<R>::max());
		}
		else
		{
			return static_cast<unsigned long long>(t) <=
			       static_cast<unsigned long long>(numeric_limits<R>::max());
		}
	}

	// --- <compare>
	class partial_ordering;
	class strong_ordering
	{
		signed char v_;
		constexpr explicit strong_ordering(signed char v) : v_(v) {}

		public:
		static const strong_ordering less, equal, equivalent, greater;
		constexpr operator partial_ordering() const;
		friend constexpr bool operator==(strong_ordering a, strong_ordering b) { return a.v_ == b.v_; }
		friend constexpr bool operator==(strong_ordering a, int) { return a.v_ == 0; }
		friend constexpr bool operator<(strong_ordering a, int) { return a.v_ < 0; }
		friend constexpr bool operator>(strong_ordering a, int) { return a.v_ > 0; }
		friend constexpr bool operator<=(strong_ordering a, int) { return a.v_ <= 0; }
		friend constexpr bool operator>=(strong_ordering a, int) { return a.v_ >= 0; }
	};
	inline constexpr strong_ordering strong_ordering::less(-1);
	inline constexpr strong_ordering strong_ordering::equal(0);
	inline constexpr strong_ordering strong_ordering::equivalent(0);
	inline constexpr strong_ordering strong_ordering::greater(1);

	class partial_ordering
	{
		signed char v_;
		constexpr explicit partial_ordering(signed char v) : v_(v) {}

		public:
		friend class strong_ordering;
		static const partial_ordering less, equivalent, greater, unordered;
		friend constexpr bool operator==(partial_ordering a, partial_ordering b) { return a.v_ == b.v_; }
		friend constexpr bool operator==(partial_ordering a, decltype(nullptr)) = delete;
		friend constexpr bool operator==(partial_ordering a, int) { return a.v_ == 0; }
		friend constexpr bool operator<(partial_ordering a, int) { return a.v_ == -1; }
		friend constexpr bool operator>(partial_ordering a, int) { return a.v_ == 1; }
		friend constexpr bool operator<=(partial_ordering a, int) { return a.v_ == -1 || a.v_ == 0; }
		friend constexpr bool operator>=(partial_ordering a, int) { return a.v_ == 1 || a.v_ == 0; }
	};
	inline constexpr partial_ordering partial_ordering::less(-1);
	inline constexpr partial_ordering partial_ordering::equivalent(0);
	inline constexpr partial_ordering partial_ordering::greater(1);
	inline constexpr partial_ordering partial_ordering::unordered(2);
	constexpr strong_ordering::operator partial_ordering() const
	{
		return partial_ordering(v_);
	}
} // namespace std
