/* Salamander's ABI for C. Generated headers include this.
 *
 * A trait object is { data, table }. A table starts with a sal_Header, then a function pointer per method.
 * A null one is a method the table doesn't have, so the call gives zero, or SAL_UNSUPPORTED for a result.
 * Before calling through a table with an owner, enter the owner, and leave after. A closed owner refuses,
 * and the call gives zero, or SAL_GONE for a result. The generated helpers do all this.
 *
 * Making a table in C only needs the methods there are:
 *     static const Freecam_table cam_table = { SAL_TABLE(Freecam), .setSpeed = cam_set_speed };  */

#ifndef SALAMANDER_H
#define SALAMANDER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define SAL_ABI_VERSION 1u

/* Results return a code, with the value through a pointer at the end. 0 is success. */
#define SAL_OK 0u
#define SAL_CANCELLED 0xFFFFFFFDu
#define SAL_UNSUPPORTED 0xFFFFFFFEu
#define SAL_GONE 0xFFFFFFFFu

/* Calling conventions. The x86 ones are plain C anywhere else, and winapi is the Windows ABI wherever there is one. */
#if defined(_M_IX86) || defined(__i386__)
#  if defined(_MSC_VER) && !defined(__clang__)
#    define SAL_CDECL __cdecl
#    define SAL_STDCALL __stdcall
#    define SAL_THISCALL __thiscall
#    define SAL_FASTCALL __fastcall
#  else
#    define SAL_CDECL __attribute__((cdecl))
#    define SAL_STDCALL __attribute__((stdcall))
#    define SAL_THISCALL __attribute__((thiscall))
#    define SAL_FASTCALL __attribute__((fastcall))
#  endif
#  define SAL_WINAPI SAL_STDCALL
#else
#  define SAL_CDECL
#  define SAL_STDCALL
#  define SAL_THISCALL
#  define SAL_FASTCALL
#  if (defined(__x86_64__) || defined(_M_X64)) && !defined(_WIN32)
#    define SAL_WINAPI __attribute__((ms_abi))
#  else
#    define SAL_WINAPI
#  endif
#endif

/* UTF-8, borrowed for the call. */
typedef struct sal_string {
    const char *ptr;
    uintptr_t len;
} sal_string;

#define SAL_STR(literal) ((sal_string){ (literal), sizeof(literal) - 1 })
/* The same for an initializer, like a static's, where MSVC doesn't take SAL_STR. */
#define SAL_STR_INIT(literal) { (literal), sizeof(literal) - 1 }

typedef struct sal_MethodInfo {
    sal_string name;
    uint64_t sig;
} sal_MethodInfo;

/* What a table's methods are, so callers built against another version find theirs. */
typedef struct sal_Info {
    uint64_t hash;
    uint32_t abi;
    sal_string name;
    struct {
        const sal_MethodInfo *ptr;
        uintptr_t len;
    } methods;
} sal_Info;

/* calls counts calls in flight, with SAL_CLOSED set once it stops taking them. */
typedef struct sal_Owner {
    uint32_t calls;
    sal_string name;
} sal_Owner;

#define SAL_CLOSED 0x80000000u

typedef struct sal_Header {
    const sal_Info *info;
    sal_Owner *owner;
} sal_Header;

/* Any trait object. Each trait's helpers turn theirs into one and back. */
typedef struct sal_object {
    uintptr_t data;
    const void *table;
} sal_object;

struct sal_TypeInfo;

/* A value with its sal_TypeInfo, borrowed for the call. A NULL type is none. */
typedef struct sal_any {
    const struct sal_TypeInfo *type;
    const void *value;
} sal_any;

/* A pointer to a T, like Vec3, as an any. */
#define SAL_ANY(T, value) ((sal_any){ &T##_sal_type, (const T *)(value) })
/* The any's value as a const T*, or NULL if it isn't a T, matched by hash. */
#define SAL_AS(T, any) ((any).type && (any).type->hash == T##_sal_type.hash ? (const T *)(any).value : NULL)

#if defined(__GNUC__) || defined(__clang__)
#define SAL_UNUSED __attribute__((unused))
#else
#define SAL_UNUSED
#endif

/* The start of a table's initializer, for one of trait T's. */
#define SAL_TABLE(T) .salamander_info = &sal_info_##T, .salamander_owner = NULL

#if defined(_MSC_VER) && !defined(__clang__)
#  include <intrin.h>
#  define SAL_ADD(p, n) ((uint32_t)_InterlockedExchangeAdd((volatile long *)(p), (long)(n)))
#else
#  define SAL_ADD(p, n) __atomic_fetch_add((p), (n), __ATOMIC_ACQ_REL)
#endif

/* False if the owner's closed. sal_leave after each true. No owner always enters. */
static inline bool sal_enter(sal_Owner *owner) {
    if (!owner) return true;
    if (SAL_ADD(&owner->calls, 1u) & SAL_CLOSED) {
        SAL_ADD(&owner->calls, (uint32_t)-1);
        return false;
    }
    return true;
}

static inline void sal_leave(sal_Owner *owner) {
    if (owner) SAL_ADD(&owner->calls, (uint32_t)-1);
}

#endif
