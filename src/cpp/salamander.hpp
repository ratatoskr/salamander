// Salamander's ABI for C++20. Generated headers include this.
//
// A trait object is { data, table }. A table starts with a Header, then a function pointer per method.
// A null one is a method the table doesn't have, so the call gives zero, or Unsupported for a result.
// Callers enter a table's owner around each call. The generated methods do all this.
//
// What crosses is an aggregate with no constructors, so it's passed and returned like C's.
// Plain C++ like std::string_view, std::span and std::optional is converted at the call.

#ifndef SALAMANDER_HPP
#define SALAMANDER_HPP

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <new>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>
#include <vector>

// Calling conventions. The x86 ones are plain C anywhere else, and winapi is the Windows ABI wherever there is one.
#ifndef SAL_CDECL
#  if defined(_M_IX86) || defined(__i386__)
#    if defined(_MSC_VER) && !defined(__clang__)
#      define SAL_CDECL __cdecl
#      define SAL_STDCALL __stdcall
#      define SAL_THISCALL __thiscall
#      define SAL_FASTCALL __fastcall
#    else
#      define SAL_CDECL __attribute__((cdecl))
#      define SAL_STDCALL __attribute__((stdcall))
#      define SAL_THISCALL __attribute__((thiscall))
#      define SAL_FASTCALL __attribute__((fastcall))
#    endif
#    define SAL_WINAPI SAL_STDCALL
#  else
#    define SAL_CDECL
#    define SAL_STDCALL
#    define SAL_THISCALL
#    define SAL_FASTCALL
#    if (defined(__x86_64__) || defined(_M_X64)) && !defined(_WIN32)
#      define SAL_WINAPI __attribute__((ms_abi))
#    else
#      define SAL_WINAPI
#    endif
#  endif
#endif

// What a table calls catches anything C++ throws, since it can't cross
#if defined(__cpp_exceptions) || defined(_CPPUNWIND)
#  define SAL_TRY try {
#  define SAL_CATCH(...) } catch (...) { ::sal::threw(); return __VA_ARGS__; }
#else
#  define SAL_TRY {
#  define SAL_CATCH(...) }
#endif

namespace sal {

inline constexpr uint32_t abi_version = 1;

// Results return a code, with the value through a pointer at the end. 0 is success.
inline constexpr uint32_t ok = 0;
inline constexpr uint32_t cancelled = 0xFFFFFFFDu;
inline constexpr uint32_t unsupported = 0xFFFFFFFEu;
inline constexpr uint32_t gone = 0xFFFFFFFFu;

// Set in an owner's calls once it stops taking them
inline constexpr uint32_t closed = 0x80000000u;

// Gets what a C++ implementation threw, from inside the catch. The call gives zero, or Gone for a result.
inline void (*on_exception)() = nullptr;

inline void threw() {
    if (on_exception) on_exception();
}

// UTF-8, borrowed for the call
struct String {
    const char *ptr;
    uintptr_t len;

    static constexpr String of(std::string_view s) { return {s.data(), s.size()}; }
    constexpr std::string_view view() const { return len == 0 ? std::string_view{} : std::string_view{ptr, len}; }
    constexpr operator std::string_view() const { return view(); }
};

// Borrowed, like a span
template <class T>
struct Slice {
    const T *ptr;
    uintptr_t len;

    static constexpr Slice of(std::span<const T> s) { return {s.data(), s.size()}; }
    constexpr std::span<const T> view() const { return len == 0 ? std::span<const T>{} : std::span<const T>{ptr, len}; }
    constexpr const T *begin() const { return ptr; }
    constexpr const T *end() const { return ptr + len; }
    constexpr uintptr_t size() const { return len; }
    constexpr const T &operator[](uintptr_t i) const { return ptr[i]; }
};

// A value optional. Pointers and objects have their own null.
template <class T>
struct Opt {
    T value;
    bool some;

    static constexpr Opt of(const std::optional<T> &o) { return o ? Opt{*o, true} : Opt{}; }
    constexpr std::optional<T> get() const { return some ? std::optional<T>{value} : std::nullopt; }
    constexpr bool has_value() const { return some; }
};

// Any trait object. Each trait's object() and from_object() turn theirs into one and back.
struct Object {
    uintptr_t data;
    const void *table;

    explicit constexpr operator bool() const { return table != nullptr; }
};

struct MethodInfo {
    String name;
    uint64_t sig;
};

// What a table's methods are, so callers built against another version find theirs
struct Info {
    uint64_t hash;
    uint32_t abi;
    String name;
    const MethodInfo *methods;
    uintptr_t methods_len;
};

// calls counts calls in flight, with closed set once it stops taking them
struct Owner {
    uint32_t calls;
    String name;
};

struct Header {
    const Info *info;
    Owner *owner;
};

// False if the owner's closed. leave after each true. No owner always enters.
inline bool enter(Owner *owner) {
    if (!owner) return true;
    std::atomic_ref<uint32_t> calls(owner->calls);
    if (calls.fetch_add(1, std::memory_order_acq_rel) & closed) {
        calls.fetch_sub(1, std::memory_order_acq_rel);
        return false;
    }
    return true;
}

inline void leave(Owner *owner) {
    if (owner) std::atomic_ref<uint32_t>(owner->calls).fetch_sub(1, std::memory_order_acq_rel);
}

// The codes every result can give. Each error set has these too.
enum class Code : uint32_t { Cancelled = cancelled, Unsupported = unsupported, Gone = gone };

// A value, or an error's code. The value's zero when it failed.
template <class T, class E = Code>
class Result {
public:
    constexpr Result(T v) : code_(0), value_(std::move(v)) {}
    constexpr Result(E e) : code_(static_cast<uint32_t>(e)), value_{} {}
    static constexpr Result from_code(uint32_t code, T v = {}) { return code == 0 ? Result(std::move(v)) : Result(static_cast<E>(code)); }

    constexpr bool ok() const { return code_ == 0; }
    explicit constexpr operator bool() const { return ok(); }
    constexpr uint32_t code() const { return code_; }
    constexpr E error() const { return static_cast<E>(code_); }
    constexpr const T &value() const & { return value_; }
    constexpr T &value() & { return value_; }
    constexpr T value_or(T other) const { return ok() ? value_ : other; }
    constexpr const T &operator*() const & { return value_; }
    constexpr const T *operator->() const { return &value_; }

private:
    uint32_t code_;
    T value_;
};

template <class E>
class Result<void, E> {
public:
    constexpr Result() : code_(0) {}
    constexpr Result(E e) : code_(static_cast<uint32_t>(e)) {}
    static constexpr Result from_code(uint32_t code) { return code == 0 ? Result() : Result(static_cast<E>(code)); }

    constexpr bool ok() const { return code_ == 0; }
    explicit constexpr operator bool() const { return ok(); }
    constexpr uint32_t code() const { return code_; }
    constexpr E error() const { return static_cast<E>(code_); }

private:
    uint32_t code_;
};

// Finds code a schema declares, like a game's functions and globals
namespace declared {

// Where name is, like Player.heal, spawn, or Player for its vtable. 0 if it isn't there. The loader sets it.
inline uintptr_t (*locator)(std::string_view name) = nullptr;

// Told before a missing function would be called. Calling it can't do anything sensible, so it aborts after.
inline void (*on_missing)(std::string_view name) = nullptr;

inline uintptr_t address(std::string_view name) { return locator ? locator(name) : 0; }

[[noreturn]] inline void missing(std::string_view name) {
    if (on_missing) on_missing(name);
    std::abort();
}

// One name's address, kept once it's found
struct Site {
    std::string_view name;
    std::atomic<uintptr_t> at{0};

    uintptr_t get() {
        uintptr_t a = at.load(std::memory_order_acquire);
        if (a == 0) {
            a = address(name);
            at.store(a, std::memory_order_release);
        }
        return a;
    }
};

// Slot n of the vtable at the start of obj
inline uintptr_t slot(const void *obj, uintptr_t n) { return (*static_cast<const uintptr_t *const *>(obj))[n]; }

} // namespace declared

// Plain C++ as what crosses, and back. A temporary string or vector would be gone before it's used.
inline String lower(std::string_view s) { return String::of(s); }
String lower(std::string &&) = delete;
template <class T>
Slice<T> lower(std::span<const T> s) { return Slice<T>::of(s); }
template <class T>
Slice<T> lower(std::vector<T> &&) = delete;
template <class T>
constexpr T lower(T v) { return v; }
template <class P>
auto lower(const std::optional<P> &o) {
    using R = decltype(lower(*o));
    return o ? Opt<R>{lower(*o), true} : Opt<R>{};
}

inline std::string_view lift(String s) { return s.view(); }
template <class T>
std::span<const T> lift(Slice<T> s) { return s.view(); }
template <class T>
constexpr T lift(T v) { return v; }
template <class T>
auto lift(Opt<T> o) -> std::optional<decltype(lift(o.value))> {
    if (!o.some) return std::nullopt;
    return lift(o.value);
}

} // namespace sal

#endif
