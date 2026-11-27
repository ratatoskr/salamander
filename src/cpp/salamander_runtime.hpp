// What C++ plugins use over the runtime's own traits: the host, kept objects and promises.

#ifndef SALAMANDER_RUNTIME_HPP
#define SALAMANDER_RUNTIME_HPP

#include <coroutine>
#include <mutex>
#include <unordered_set>

#include "salamander_core.hpp"

namespace sal {

// The host this plugin uses, and the owner guarding what keep makes. Set by init.
struct Runtime {
    static inline Host host{};
    static inline Owner *owner = nullptr;
};

namespace detail {

// Each kept object has what destroys it this far before it, so the host's release needn't know its type
inline constexpr uintptr_t kept_offset = alignof(std::max_align_t);
using Destroy = void (*)(uintptr_t data);
static_assert(sizeof(Destroy) <= kept_offset);

// What keep made, since the owner can guard other objects too, which aren't the host's to destroy
struct KeptSet {
    std::mutex lock;
    std::unordered_set<uintptr_t> data;
};

inline KeptSet &kept() {
    static KeptSet k;
    return k;
}

inline void destroyKept(uintptr_t data) {
    {
        std::lock_guard<std::mutex> g(kept().lock);
        if (kept().data.erase(data) == 0) return;
    }
    (*reinterpret_cast<Destroy *>(data - kept_offset))(data);
}

} // namespace detail

// What a plugin does first, with its host and the owner guarding what keep makes, like its loader's.
// False out of memory.
inline bool init(Host host, Owner *owner) {
    Runtime::host = host;
    Runtime::owner = owner;
    if (!owner) return false;
    static auto hook = [](uintptr_t data) { detail::destroyKept(data); };
    return host.releasable(owner, Release::of(hook));
}

// The same with an owner of its own called name. False if the host had none.
inline bool init(Host host, std::string_view name) { return init(host, host.owner(name)); }

// A heap copy of impl as a Trait, guarded by Runtime::owner. Destroyed once the host lets go of it,
// so it's for keep parameters and returns. Needs init.
template <class Trait, class T>
Trait keep(T impl) {
    using U = std::remove_cvref_t<T>;
    static_assert(alignof(U) <= detail::kept_offset, "keep can't align this");
    char *mem = static_cast<char *>(::operator new(detail::kept_offset + sizeof(U)));
    new (mem) detail::Destroy([](uintptr_t data) {
        reinterpret_cast<U *>(data)->~U();
        ::operator delete(reinterpret_cast<void *>(data - detail::kept_offset));
    });
    U *u = new (mem + detail::kept_offset) U(std::move(impl));
    {
        std::lock_guard<std::mutex> g(detail::kept().lock);
        detail::kept().data.insert(reinterpret_cast<uintptr_t>(u));
    }
    Object o = Runtime::host.adopt(Trait::of(*u).object(), Runtime::owner);
    return Trait::from_object(o);
}

// The one provided as name, laid out like this header's Trait. No table if there isn't one.
template <class Trait>
Trait get(std::string_view name, uint32_t major, Host host = Runtime::host) {
    return Trait::from_object(host.get(name, major, const_cast<Info *>(&Trait::salamander_info)));
}

// 0, or 1 when the name's taken, 2 out of memory, 3 when its table has no owner
template <class Trait>
uint32_t provide(std::string_view name, uint32_t major, Trait obj, Host host = Runtime::host) {
    return host.provide(name, major, obj.object());
}

// The host's copy of obj's table, which stops calling into it once owner closes
template <class Trait>
Trait own(Trait obj, Owner *owner, Host host = Runtime::host) {
    return Trait::from_object(host.adopt(obj.object(), owner));
}


// Done holding obj, from a keep parameter or a return
template <class Trait>
void release(Trait obj, Host host = Runtime::host) {
    host.release(obj.object());
}

// obj as one of its bases, with the host making a table laid out like Base's. No table across ABIs.
template <class Base, class Trait>
    requires(Trait::template extends<Base>)
Base as(Trait obj, Host host = Runtime::host) {
    return Base::from_object(host.adapt(obj.object(), const_cast<Info *>(&Base::salamander_info)));
}

// An object that's ours to let go of, like one from a keep parameter or a return. Released when it goes.
template <class Trait>
class Held {
public:
    Held() = default;
    explicit Held(Trait obj, Host host = Runtime::host) : obj_(obj), host_(host) {}
    Held(Held &&o) noexcept : obj_(std::exchange(o.obj_, Trait{})), host_(o.host_) {}
    Held &operator=(Held &&o) noexcept {
        if (this != &o) {
            reset();
            obj_ = std::exchange(o.obj_, Trait{});
            host_ = o.host_;
        }
        return *this;
    }
    Held(const Held &) = delete;
    Held &operator=(const Held &) = delete;
    ~Held() { reset(); }

    const Trait *operator->() const { return &obj_; }
    const Trait &operator*() const { return obj_; }
    const Trait &get() const { return obj_; }
    explicit operator bool() const { return static_cast<bool>(obj_); }

    // Lets go of it now
    void reset() {
        if (obj_) host_.release(obj_.object());
        obj_ = Trait{};
    }

    // Gives it up without letting go, like to a keep parameter
    Trait release() { return std::exchange(obj_, Trait{}); }

private:
    Trait obj_{};
    Host host_{};
};

template <class Trait>
Held<Trait> hold(Trait obj, Host host = Runtime::host) {
    return Held<Trait>(obj, host);
}

namespace detail {

// A task that runs f once, then deletes itself, since a promise never lets go of its task
template <class F>
struct Once {
    F f;
    void operator()() {
        Once *self = this;
        self->f();
        delete self;
    }
};

// What a coroutine's co_return gives its future
template <class T, class E>
struct Returns;

} // namespace detail

template <class T, class E>
class Settle;

// What an async method gives back, held by whoever waits and let go of when it goes.
// co_await one for its Result, and make an async method a coroutine by giving one back.
template <class T, class E = Code>
class Future {
public:
    struct promise_type;
    class Awaiter;

    Future() = default;
    explicit Future(Promise p) : p_(p) {}
    Future(Future &&o) noexcept : p_(std::exchange(o.p_, Promise{})) {}
    Future &operator=(Future &&o) noexcept {
        if (this != &o) {
            reset();
            p_ = std::exchange(o.p_, Promise{});
        }
        return *this;
    }
    Future(const Future &) = delete;
    Future &operator=(const Future &) = delete;
    ~Future() { reset(); }

    const Promise &promise() const { return p_; }
    explicit operator bool() const { return static_cast<bool>(p_); }
    bool settled() const { return p_.isSettled(); }

    // Once settled. What the value points at is good till this thread takes another.
    Result<T, E> take() const {
        if (!p_ || !p_.isSettled()) return Result<T, E>::from_code(gone);
        if constexpr (std::is_void_v<T>) {
            return Result<T, E>::from_code(p_.take(nullptr));
        } else {
            T v{};
            uint32_t code = p_.take(&v);
            return Result<T, E>::from_code(code, v);
        }
    }

    // Runs f once settled, on where's thread, or the settling one without a queue. Right away if it's settled.
    template <class F>
    void then(F f, Queue where = {}) const {
        auto *once = new detail::Once<F>{std::move(f)};
        p_.then(Task::of(*once), where);
    }

    void cancel() const { p_.cancel(); }

    // Lets go of it now
    void reset() {
        if (p_) p_.release();
        p_ = Promise{};
    }

    // Gives it up without letting go, like to an async method's caller
    Promise detach() { return std::exchange(p_, Promise{}); }

    // co_await carrying on in where's thread instead of the settling one
    Awaiter on(Queue where) const & { return Awaiter(this, where); }
    Awaiter operator co_await() const & { return Awaiter(this, Queue{}); }

private:
    Promise p_{};
};

template <class T, class E>
class Future<T, E>::Awaiter {
public:
    Awaiter(const Future *f, Queue where) : f_(f), where_(where) {}

    bool await_ready() const { return !*f_ || f_->settled(); }

    // The awaiter is the task, since it lives in the coroutine's frame till the coroutine carries on
    void await_suspend(std::coroutine_handle<> h) {
        h_ = h;
        f_->promise().then(Task::of(*this), where_);
    }

    Result<T, E> await_resume() const { return f_->take(); }

    void operator()() const { h_.resume(); }

private:
    const Future *f_;
    Queue where_;
    std::coroutine_handle<> h_{};
};

// Settles a Future once, from whoever does the work. Drops it if it goes unsettled, so the waiter gets Gone.
template <class T, class E = Code>
class Settle {
public:
    Settle() = default;
    explicit Settle(Resolver r) : r_(r) {}
    Settle(Settle &&o) noexcept : r_(std::exchange(o.r_, Resolver{})) {}
    Settle &operator=(Settle &&o) noexcept {
        if (this != &o) {
            drop();
            r_ = std::exchange(o.r_, Resolver{});
        }
        return *this;
    }
    Settle(const Settle &) = delete;
    Settle &operator=(const Settle &) = delete;
    ~Settle() { drop(); }

    // Memory kept with the value, for what it points at, like its text. Before settling only.
    void *hold(uintptr_t size, uintptr_t alignment) const { return r_.hold(size, alignment); }

    // What v points at has to last, so keep it with hold
    void resolve(const T &v)
        requires(!std::is_void_v<T>)
    {
        r_.resolve(const_cast<void *>(static_cast<const void *>(&v)));
        r_ = Resolver{};
    }
    void resolve()
        requires std::is_void_v<T>
    {
        r_.resolve(nullptr);
        r_ = Resolver{};
    }

    void reject(E e) {
        r_.reject(static_cast<uint32_t>(e));
        r_ = Resolver{};
    }

    bool cancelled() const { return r_.cancelled(); }

    // Not going to settle it, so the waiter gets Gone
    void drop() {
        if (r_) r_.drop();
        r_ = Resolver{};
    }

    explicit operator bool() const { return static_cast<bool>(r_); }

private:
    Resolver r_{};
};

template <class T, class E = Code>
struct Pending {
    Future<T, E> future;
    Settle<T, E> settle;
};

// A Future and what settles it. The future goes to the waiter, like an async method's return.
template <class T, class E = Code>
Pending<T, E> promise(Host host = Runtime::host) {
    Resolver r{};
    uintptr_t size = 0;
    if constexpr (!std::is_void_v<T>) size = sizeof(T);
    Promise p = host.promise(size, &r);
    return {Future<T, E>(p), Settle<T, E>(r)};
}

namespace detail {

template <class T, class E>
struct Returns {
    Settle<T, E> settle;
    void return_value(Result<T, E> r) {
        if (r) settle.resolve(*r);
        else settle.reject(r.error());
    }
};

// co_return {}; for success
template <class E>
struct Returns<void, E> {
    Settle<void, E> settle;
    void return_value(Result<void, E> r) {
        if (r) settle.resolve();
        else settle.reject(r.error());
    }
};

} // namespace detail

// Runs straight away, up to its first co_await that has to wait. Its future's settled by co_return. Needs init.
template <class T, class E>
struct Future<T, E>::promise_type : detail::Returns<T, E> {
    Future future;

    promise_type() {
        auto p = sal::promise<T, E>();
        future = std::move(p.future);
        this->settle = std::move(p.settle);
    }

    Future get_return_object() { return std::move(future); }
    std::suspend_never initial_suspend() noexcept { return {}; }
    std::suspend_never final_suspend() noexcept { return {}; }
    void unhandled_exception() {
        threw();
        this->settle.reject(static_cast<E>(gone));
    }
};

// What an implementation's async method gives back, as what crosses
inline Promise promise_of(Promise p) { return p; }
template <class T, class E>
Promise promise_of(Future<T, E> &&f) {
    return f.detach();
}

} // namespace sal

#endif
