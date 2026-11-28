// C++'s side of the agree test: calls Zig's tables through the generated methods, implements a trait for
// Zig to call, and provides an object through the host. Built with warnings as errors.

#include "test_schema.hpp"

// What's known while compiling

static_assert(max_players == 4);
static_assert(greeting == "hi");
static_assert(!debug);
static_assert(static_cast<uint8_t>(Job::mage) == 2);
static_assert(static_cast<uint32_t>(LoadError::Corrupt) == 7);
static_assert(static_cast<uint32_t>(LoadError::Gone) == sal::gone);
static_assert(Flags{0}.with_level(0x5a).level() == 0x5a);
static_assert(Player_heal_name == "Player.heal");
static_assert(std::is_same_v<Player_heal_fn, float (*)(Player *self, float amount)>);
static_assert(sizeof(Scene::Map_u32_Scene_NodePtr) == 4 * sizeof(void *));
static_assert(std::is_aggregate_v<Freecam> && std::is_trivially_copyable_v<Freecam>);
static_assert(Damageable::extends<Transform> && Damageable::extends<Named> && !Freecam::extends<Transform>);
static_assert(!std::is_copy_constructible_v<sal::Future<Vec3>> && std::is_move_constructible_v<sal::Future<Vec3>>);
// Ones with no value build too, with what settles them
template class sal::Future<void>;
template class sal::Settle<void>;

// A trait implemented in C++, with only some of its methods

struct Cam {
    float speed = 0;
    uint32_t restores = 0;

    void setSpeed(float s) { speed = s; }

    std::span<const uint8_t> load(std::string_view path, std::optional<uint32_t> limit) {
        size_t n = path.size();
        if (limit && *limit < n) n = *limit;
        return {reinterpret_cast<const uint8_t *>(path.data()), n};
    }

    sal::Result<Vec3, LoadError> restore(std::string_view name) {
        restores += 1;
        if (name.empty()) return LoadError::NotFound;
        return Vec3{speed, static_cast<float>(name.size()), 0};
    }

    // Settled before it's given back, through the host
    sal::Future<Damageable, LoadError> find(uint32_t id) {
        auto p = sal::promise<Damageable, LoadError>();
        if (id == 0) p.settle.reject(LoadError::Corrupt);
        else p.settle.resolve(Damageable{});
        return std::move(p.future);
    }
};

// An async method as a coroutine, or settled straight away where there are none
struct Flyer {
#if SAL_COROUTINES
    sal::Future<Vec3> flyTo(Vec3 v) { co_return Vec3{v.x * 2, v.y, v.z}; }
#else
    sal::Future<Vec3> flyTo(Vec3 v) {
        auto p = sal::promise<Vec3>();
        p.settle.resolve(Vec3{v.x * 2, v.y, v.z});
        return std::move(p.future);
    }
#endif
};

static Flyer flyer;

static Cam cam;

// damage is thiscall, so on x86 this checks the thunks agree with Zig on it
struct Target {
    float hp = 10;

    bool damage(float amount) {
        hp -= amount;
        return hp <= 0;
    }
    float health() { return hp; }
    std::string_view name() { return "target"; }
};

static Target dummy;

// Destroyed only once, by whatever holds it last
struct Probe {
    int *destroyed;
    bool live = true;

    explicit Probe(int *d) : destroyed(d) {}
    Probe(Probe &&o) noexcept : destroyed(o.destroyed), live(o.live) { o.live = false; }
    ~Probe() {
        if (live) *destroyed += 1;
    }
    bool operator()(uint32_t n) const { return n == 7; }
};

extern "C" {

// Calls into Zig

bool cpp_damage(Damageable d, float amount) { return d.damage(amount); }

float cpp_health(Damageable d) { return d.health(); }

Vec3 cpp_position(Damageable d) { return d.position(); }

uint32_t cpp_restore(Freecam f, sal::String name, Vec3 *out) {
    auto r = f.restore(name);
    if (r) *out = *r;
    return r.code();
}

sal::String cpp_load(Freecam f, sal::String path, sal::Opt<uint32_t> limit) {
    auto s = f.load(path, sal::lift(limit));
    return {reinterpret_cast<const char *>(s.data()), s.size()};
}

// Zig's is settled already
float cpp_fly(Freecam f, float x) {
    auto fut = f.flyTo(Vec3{x, 0, 0});
    auto r = fut.take();
    return r ? r->x : -1;
}

// Bitfields go through accessors, so Zig checks C++ reads its bits the same

uint32_t cpp_flags_level(uint32_t f) { return Flags{f}.level(); }

uint32_t cpp_flags_with_job(uint32_t f, uint8_t j) { return Flags{f}.with_job(static_cast<Job>(j)).bits; }

Freecam cpp_cam() { return Freecam::of(cam); }

float cpp_cam_speed() { return cam.speed; }

Damageable cpp_target() { return Damageable::of(dummy); }

bool cpp_init(sal::Host host) { return sal::init(host, "cpp"); }

Freecam cpp_flyer() { return Freecam::of(flyer); }

// A base's table, made by the host from the Damageable's
uint32_t cpp_as_named(sal::Host host) {
    Named n = sal::as<Named>(Damageable::of(dummy), host);
    return n && n.name() == "target" ? 1 : 0;
}

// Provides one through the host, owned so the host never points at code that's gone
uint32_t cpp_provide(sal::Host host) {
    sal::Owner *owner = host.owner("cpp");
    return sal::provide("cpp.cam", 1, sal::own(Freecam::of(cam), owner, host), host);
}

// Gets one back through the host, laid out like this header's version
float cpp_get_and_set(sal::Host host, float speed) {
    auto f = sal::get<Freecam>("cpp.cam", 1, host);
    if (!f) return -1;
    f.setSpeed(speed);
    return cam.speed;
}

// A lambda as a function value, lent for the call
uint32_t cpp_visit(uint32_t n) {
    uint32_t seen = 0;
    bool r = Visitor::of([&](uint32_t x) {
        seen = x;
        return x > 2;
    })(n);
    return seen * 10 + (r ? 1 : 0);
}

// One kept on the heap, destroyed once the host lets go of it
int cpp_keep(sal::Host host) {
    if (!sal::init(host, "cpp.keep")) return -1;
    static int destroyed = 0;
    Visitor v = sal::keep<Visitor>(Probe{&destroyed});
    bool hit = v(7);
    int before = destroyed;
    sal::release(v);
    return (hit ? 1 : 0) + before * 10 + destroyed * 100;
}

bool cpp_coroutines() { return SAL_COROUTINES; }

// A coroutine waiting on a future that's settled later, then on Zig's, which already is
uint32_t cpp_coroutine(Freecam zig) {
#if !SAL_COROUTINES
    (void)zig;
    return 0;
#else
    auto p = sal::promise<uint32_t>();
    auto task = [](sal::Future<uint32_t> f, Freecam z) -> sal::Future<uint32_t> {
        auto r = co_await f;
        if (!r) co_return r.error();
        auto v = co_await z.flyTo(Vec3{1, 0, 0});
        co_return r.value() * 2 + static_cast<uint32_t>(v.value().x);
    };
    sal::Future<uint32_t> outer = task(std::move(p.future), zig);
    uint32_t waited = outer.settled() ? 0 : 1000;
    p.settle.resolve(20);
    auto r = outer.take();
    return waited + r.value_or(0);
#endif
}

// A settle that goes unsettled drops, so its waiter gets Gone
uint32_t cpp_dropped() {
    sal::Future<uint32_t> f;
    {
        auto p = sal::promise<uint32_t>();
        f = std::move(p.future);
    }
    return f.take().code();
}

// Held lets go of what it holds when it goes
int cpp_held() {
    static int destroyed = 0;
    {
        auto v = sal::hold(sal::keep<Visitor>(Probe{&destroyed}));
        if (!(*v)(7)) return -1;
        if (destroyed != 0) return -2;
    }
    return destroyed;
}

// Game code through the locator Zig gives, standing in for a loader
static uintptr_t (*zig_locate)(sal::String name);

uint32_t cpp_game(uintptr_t (*locate)(sal::String name)) {
    zig_locate = locate;
    sal::declared::locator = [](std::string_view name) { return zig_locate(sal::String::of(name)); };
    Player *p = Player::main();
    if (!p) return 1;
    if (p->heal(10) != 20) return 2;
    if (p->attack(3) != 60) return 3;
    if (Player::total(4) != 8) return 4;
    *Player::count() += 1;
    if (*answer() != 42) return 5;
    if (entry(3, 4) != 7) return 6;
    if (Scene::Graph::sum(3, 4) != 7) return 7;
    if (sal::declared::address("nope") != 0) return 8;
    sal::declared::locator = nullptr;
    return 0;
}

// Type info, which has to be the same as every other language's
const sal::TypeInfo *cpp_type_info(uint32_t which) {
    switch (which) {
    case 0: return &sal::TypeOf<Player>::info;
    case 1: return &sal::TypeOf<Scene::Graph>::info;
    case 2: return &sal::TypeOf<Bag>::info;
    case 3: return &sal::TypeOf<Shape>::info;
    default: return nullptr;
    }
}

// A tagged union's members, only as the tag says
float cpp_shape() {
    Shape s = Shape::of_circle(2.5f);
    if (s.box() || !Shape::of_none().none() || Shape::of_none().circle()) return -1;
    return *s.circle();
}

// A Vec3 through an any, and back only as one
float cpp_any_y() {
    Vec3 v{1, 2, 3};
    sal::Any a = sal::Any::of(v);
    const Vec3 *back = a.as<Vec3>();
    return back && !a.as<Pair>() ? back->y : -1;
}

} // extern "C"
