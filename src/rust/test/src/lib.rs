//! Rust's side of the agree test: calls Zig's tables through the generated methods, implements traits for
//! Zig to call, and provides an object through the host. Built as a DLL the test loads, with
//! `test.sal`'s Rust as `schema.rs` beside its Cargo.toml, which the build puts there.

use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, Ordering};

#[allow(dead_code)]
mod schema {
    include!(concat!(env!("CARGO_MANIFEST_DIR"), "/schema.rs"));
}

use salamander::{Held, Host, Str, TraitObject};
use schema::*;

// What's known while compiling

const _: () = assert!(MAX_PLAYERS == 4);
const _: () = assert!(!DEBUG);
const _: () = assert!(Job::MAGE.0 == 2);
const _: () = assert!(LoadError::CORRUPT.0 == 7);
const _: () = assert!(Flags(0).with_level(0x5a).level() == 0x5a);
const _: () = assert!(std::mem::size_of::<scene::MapU32SceneNodePtr>() == 4 * std::mem::size_of::<usize>());

fn is_extends<B: TraitObject, O: salamander::Extends<B>>() {}

// A trait implemented in Rust, with only some of its methods

struct Cam {
    speed: AtomicU32,
}

impl FreecamImpl for Cam {
    fn set_speed(&self, speed: f32) {
        self.speed.store(speed.to_bits(), Ordering::Relaxed);
    }

    // What it gives back is its own, so it lasts
    fn load(&self, path: &str, limit: Option<u32>) -> &[u8] {
        let n = limit.map_or(path.len(), |l| (l as usize).min(path.len()));
        &b"abcdefgh"[..n.min(8)]
    }

    fn restore(&self, name: &str) -> Result<Vec3, LoadError> {
        if name.is_empty() {
            return Err(LoadError::NOT_FOUND);
        }
        Ok(Vec3 { x: f32::from_bits(self.speed.load(Ordering::Relaxed)), y: name.len() as f32, z: 0.0 })
    }

    // Settled by an async block, through the host init gave it
    fn find(&self, id: u32) -> salamander::Future<Damageable, LoadError> {
        salamander::spawn(async move { if id == 0 { Err(LoadError::CORRUPT) } else { Ok(Damageable::default()) } })
    }
}

static CAM: Cam = Cam { speed: AtomicU32::new(0) };

// damage is thiscall, so on x86 this checks the thunks agree with Zig on it
struct Target {
    hp: AtomicU32,
}

impl DamageableImpl for Target {
    fn damage(&self, amount: f32) -> bool {
        let hp = f32::from_bits(self.hp.load(Ordering::Relaxed)) - amount;
        self.hp.store(hp.to_bits(), Ordering::Relaxed);
        hp <= 0.0
    }
    fn health(&self) -> f32 {
        f32::from_bits(self.hp.load(Ordering::Relaxed))
    }
    fn name(&self) -> &str {
        "target"
    }
}

static TARGET: Target = Target { hp: AtomicU32::new(0x4120_0000) };

// Dropped only once, by whatever holds it last
struct Probe {
    dropped: &'static AtomicI32,
}

impl Drop for Probe {
    fn drop(&mut self) {
        self.dropped.fetch_add(1, Ordering::Relaxed);
    }
}

impl VisitorImpl for Probe {
    fn call(&self, n: u32) -> bool {
        n == 7
    }
}

// Calls into Zig. The ones taking pointers are unsafe, since Zig says what they point at

#[unsafe(no_mangle)]
pub extern "C" fn rs_damage(d: Damageable, amount: f32) -> bool {
    d.damage(amount)
}

#[unsafe(no_mangle)]
pub extern "C" fn rs_health(d: Damageable) -> f32 {
    d.health()
}

#[unsafe(no_mangle)]
pub extern "C" fn rs_position(d: Damageable) -> Vec3 {
    d.position()
}

#[unsafe(no_mangle)]
#[allow(clippy::missing_safety_doc)]
pub unsafe extern "C" fn rs_restore(f: Freecam, name: Str, out: *mut Vec3) -> u32 {
    match f.restore(unsafe { name.get() }) {
        Ok(v) => {
            unsafe { *out = v };
            salamander::OK
        }
        Err(e) => e.0,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn rs_load(f: Freecam, path: Str, limit: salamander::Opt<u32>) -> Str {
    let s = f.load(unsafe { path.get() }, limit.get());
    Str { ptr: s.as_ptr(), len: s.len() }
}

// Zig's is settled already
#[unsafe(no_mangle)]
pub extern "C" fn rs_fly(f: Freecam, x: f32) -> f32 {
    f.fly_to(Vec3 { x, y: 0.0, z: 0.0 }).wait().map_or(-1.0, |v| v.x)
}

// Bitfields have their own accessors, so Zig checks Rust reads its bits the same

#[unsafe(no_mangle)]
pub extern "C" fn rs_flags_level(f: u32) -> u32 {
    Flags(f).level()
}

#[unsafe(no_mangle)]
pub extern "C" fn rs_flags_with_job(f: u32, j: u8) -> u32 {
    Flags(f).with_job(Job(j)).0
}

#[unsafe(no_mangle)]
pub extern "C" fn rs_cam() -> Freecam {
    Freecam::from_static(&CAM)
}

#[unsafe(no_mangle)]
pub extern "C" fn rs_cam_speed() -> f32 {
    f32::from_bits(CAM.speed.load(Ordering::Relaxed))
}

#[unsafe(no_mangle)]
pub extern "C" fn rs_target() -> Damageable {
    Damageable::from_static(&TARGET)
}

#[unsafe(no_mangle)]
pub extern "C" fn rs_init(host: Host) -> bool {
    salamander::init_named(host, "rust")
}

// Provides one through the host, owned so the host never points at code that's gone
#[unsafe(no_mangle)]
pub extern "C" fn rs_provide() -> u32 {
    let owner = salamander::host().owner("rust.cam");
    salamander::provide("rust.cam", 1, salamander::own(Freecam::from_static(&CAM), owner))
}

// Gets one back through the host, laid out like this module's version
#[unsafe(no_mangle)]
pub extern "C" fn rs_get_and_set(speed: f32) -> f32 {
    let f: Freecam = salamander::get("rust.cam", 1);
    if !f.is_some() {
        return -1.0;
    }
    f.set_speed(speed);
    rs_cam_speed()
}

// A closure as a function value, lent for the call
#[unsafe(no_mangle)]
pub extern "C" fn rs_visit(n: u32) -> u32 {
    let seen = AtomicU32::new(0);
    let f = |x: u32| {
        seen.store(x, Ordering::Relaxed);
        x > 2
    };
    let r = unsafe { Visitor::borrowed(&f) }.call(n);
    seen.load(Ordering::Relaxed) * 10 + r as u32
}

// One kept on the heap, dropped once the host lets go of it, and Held letting go when it's dropped
#[unsafe(no_mangle)]
pub extern "C" fn rs_keep() -> i32 {
    static DROPPED: AtomicI32 = AtomicI32::new(0);
    let v = Visitor::keep(Probe { dropped: &DROPPED });
    let hit = v.call(7);
    let before = DROPPED.load(Ordering::Relaxed);
    salamander::release(v);
    let after = DROPPED.load(Ordering::Relaxed);
    {
        let held = Held::new(Visitor::keep(Probe { dropped: &DROPPED }));
        if !held.call(7) {
            return -1;
        }
    }
    hit as i32 + before * 10 + after * 100 + DROPPED.load(Ordering::Relaxed) * 1000
}

// A base's table, made by the host from the Damageable's
#[unsafe(no_mangle)]
pub extern "C" fn rs_as_named() -> u32 {
    is_extends::<Transform, Damageable>();
    let n: Named = salamander::as_base(Damageable::from_static(&TARGET));
    (n.is_some() && n.name() == "target") as u32
}

// An async block waiting on a future that's settled later, then on Zig's, which already is
#[unsafe(no_mangle)]
pub extern "C" fn rs_async(zig: Freecam) -> u32 {
    let (later, settle) = salamander::promise::<u32, salamander::Code>();
    let outer = salamander::spawn(async move {
        let n = later.await?;
        let v = zig.fly_to(Vec3 { x: 1.0, y: 0.0, z: 0.0 }).await?;
        Ok::<u32, salamander::Code>(n * 2 + v.x as u32)
    });
    let waited = if outer.is_settled() { 0 } else { 1000 };
    settle.resolve(20);
    waited + outer.take().unwrap_or(0)
}

// A settle that's dropped unsettled, so its waiter gets Gone
#[unsafe(no_mangle)]
pub extern "C" fn rs_dropped() -> u32 {
    let (f, settle) = salamander::promise::<u32, salamander::Code>();
    drop(settle);
    match f.take() {
        Ok(_) => 0,
        Err(e) => e.0,
    }
}

// Game code through the locator Zig gives, standing in for a loader. Zig and C++ healed it first
static LOCATE: std::sync::OnceLock<extern "C" fn(Str) -> usize> = std::sync::OnceLock::new();
static GAME_ONCE: AtomicBool = AtomicBool::new(false);

#[unsafe(no_mangle)]
pub extern "C" fn rs_game(locate: extern "C" fn(Str) -> usize) -> u32 {
    let _ = LOCATE.set(locate);
    GAME_ONCE.store(true, Ordering::Relaxed);
    salamander::declared::set_locator(Some(|name| LOCATE.get().map_or(0, |f| f(Str::new(name)))));
    let r = unsafe {
        let p = Player::main();
        if p.is_null() {
            return 1;
        }
        let p = &mut *p;
        if p.heal(10.0) != 30.0 {
            return 2;
        }
        if p.attack(3) != 90 {
            return 3;
        }
        if Player::total(4) != 8 {
            return 4;
        }
        *Player::count() += 1;
        if *answer() != 42 {
            return 5;
        }
        if entry(3, 4) != 7 {
            return 6;
        }
        if scene::Graph::sum(3, 4) != 7 {
            return 7;
        }
        if salamander::declared::address("nope") != 0 {
            return 8;
        }
        0
    };
    salamander::declared::set_locator(None);
    r
}
