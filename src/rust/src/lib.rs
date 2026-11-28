//! Salamander's ABI for Rust. Generated modules use it, with the runtime's own traits from `core.sal`.
//!
//! A trait object is `{ data, table }`. A table starts with a [`Header`], then a function pointer per
//! method. Callers enter a table's owner around each call, which the generated methods do.
//!
//! What crosses is `#[repr(C)]`, so it's passed like C's. Methods take and give plain Rust like `&str`,
//! slices, `Option` and `Result`, and any type implements a trait through its generated `...Impl` trait.

#![allow(clippy::missing_safety_doc)]

use std::collections::HashMap;
use std::ffi::c_void;
use std::marker::PhantomData;
use std::pin::Pin;
use std::sync::atomic::{AtomicU32, AtomicU8, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Wake, Waker};

mod sal_core;
pub use sal_core::*;

pub const ABI_VERSION: u32 = 1;

/// Results return a code, with the value through a pointer at the end. 0 is success.
pub const OK: u32 = 0;
pub const CANCELLED: u32 = 0xFFFF_FFFD;
pub const UNSUPPORTED: u32 = 0xFFFF_FFFE;
pub const GONE: u32 = 0xFFFF_FFFF;

/// Set in an owner's calls once it stops taking them.
pub const CLOSED: u32 = 0x8000_0000;

/// UTF-8, borrowed for the call.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Str {
    pub ptr: *const u8,
    pub len: usize,
}

unsafe impl Send for Str {}
unsafe impl Sync for Str {}

impl Default for Str {
    fn default() -> Self {
        Str { ptr: std::ptr::null(), len: 0 }
    }
}

impl Str {
    pub const fn new(s: &str) -> Str {
        Str { ptr: s.as_ptr(), len: s.len() }
    }

    /// Its text, empty if it isn't UTF-8. Good as long as what it points at is.
    pub unsafe fn get<'a>(self) -> &'a str {
        if self.len == 0 || self.ptr.is_null() {
            return "";
        }
        std::str::from_utf8(unsafe { std::slice::from_raw_parts(self.ptr, self.len) }).unwrap_or("")
    }
}

impl From<&str> for Str {
    fn from(s: &str) -> Str {
        Str::new(s)
    }
}

/// Borrowed, like a `&[T]`.
#[repr(C)]
pub struct Slice<T> {
    pub ptr: *const T,
    pub len: usize,
}

impl<T> Clone for Slice<T> {
    fn clone(&self) -> Self {
        *self
    }
}
impl<T> Copy for Slice<T> {}
unsafe impl<T: Sync> Send for Slice<T> {}
unsafe impl<T: Sync> Sync for Slice<T> {}

impl<T> Default for Slice<T> {
    fn default() -> Self {
        Slice { ptr: std::ptr::null(), len: 0 }
    }
}

impl<T> Slice<T> {
    pub const fn of(s: &[T]) -> Slice<T> {
        Slice { ptr: s.as_ptr(), len: s.len() }
    }

    /// Good as long as what it points at is.
    pub unsafe fn get<'a>(self) -> &'a [T] {
        if self.len == 0 || self.ptr.is_null() {
            return &[];
        }
        unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
    }
}

/// A value optional. Pointers and objects have their own null.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Opt<T> {
    pub value: T,
    pub some: bool,
}

impl<T: Copy + Default> Opt<T> {
    pub fn of(o: Option<T>) -> Opt<T> {
        match o {
            Some(value) => Opt { value, some: true },
            None => Opt::default(),
        }
    }

    pub fn get(self) -> Option<T> {
        if self.some { Some(self.value) } else { None }
    }
}

/// Any trait object. Each trait's `object` and `from_object` turn theirs into one and back.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Object {
    pub data: usize,
    pub table: *const c_void,
}

unsafe impl Send for Object {}
unsafe impl Sync for Object {}

impl Default for Object {
    fn default() -> Self {
        Object { data: 0, table: std::ptr::null() }
    }
}

impl Object {
    pub fn is_some(&self) -> bool {
        !self.table.is_null()
    }
}

/// A value with its `TypeInfo`, borrowed for the call. A null type is none.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Any {
    pub r#type: *const TypeInfo,
    pub value: *const c_void,
}

impl Default for Any {
    fn default() -> Self {
        Any { r#type: std::ptr::null(), value: std::ptr::null() }
    }
}

impl Any {
    /// `v`, a generated type's value. It has to outlive the call.
    pub fn of<T: TypeOf>(v: &T) -> Any {
        Any { r#type: T::type_info(), value: v as *const T as *const c_void }
    }

    /// The value if it's a `T`, matched by hash.
    pub fn get<T: TypeOf>(&self) -> Option<&T> {
        // SAFETY: an any's type says what its value is, and it lives for the call
        unsafe {
            if self.r#type.is_null() || (*self.r#type).hash != T::type_info().hash {
                return None;
            }
            Some(&*(self.value as *const T))
        }
    }
}

/// What a type is. Generated types implement it.
pub trait TypeOf {
    fn type_info() -> &'static TypeInfo;
}

// Type info is kept for good, and never changes
unsafe impl Send for TypeInfo {}
unsafe impl Sync for TypeInfo {}
unsafe impl Send for FieldInfo {}
unsafe impl Sync for FieldInfo {}
unsafe impl Send for EnumValue {}
unsafe impl Sync for EnumValue {}

const fn str_of(s: &'static str) -> Str {
    Str { ptr: s.as_ptr(), len: s.len() }
}

impl TypeInfo {
    /// For generated code, with its padding zeroed.
    #[allow(clippy::too_many_arguments)]
    pub const fn new(kind: TypeKind, name: &'static str, hash: u64, size: usize, alignment: usize, child: *const TypeInfo, len: usize, fields: &'static [FieldInfo], values: &'static [EnumValue]) -> TypeInfo {
        // SAFETY: every field is a number or pointer, which zero is fine for
        let mut t: TypeInfo = unsafe { ::core::mem::zeroed() };
        t.kind = kind;
        t.name = str_of(name);
        t.hash = hash;
        t.size = size;
        t.alignment = alignment;
        t.child = child as *mut TypeInfo;
        t.len = len;
        t.fields = Slice { ptr: fields.as_ptr(), len: fields.len() };
        t.values = Slice { ptr: values.as_ptr(), len: values.len() };
        t
    }
}

impl FieldInfo {
    /// For generated code, with its padding zeroed.
    pub const fn new(name: &'static str, ty: *const TypeInfo, offset: usize, bit: u16, bits: u16) -> FieldInfo {
        // SAFETY: as for `TypeInfo::new`
        let mut f: FieldInfo = unsafe { ::core::mem::zeroed() };
        f.name = str_of(name);
        f.r#type = ty as *mut TypeInfo;
        f.offset = offset;
        f.bit = bit;
        f.bits = bits;
        f
    }
}

impl EnumValue {
    pub const fn new(name: &'static str, value: i64) -> EnumValue {
        // SAFETY: as for `TypeInfo::new`
        let mut v: EnumValue = unsafe { ::core::mem::zeroed() };
        v.name = str_of(name);
        v.value = value;
        v
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MethodInfo {
    pub name: Str,
    pub sig: u64,
}

/// What a table's methods are, so callers built against another version find theirs.
#[repr(C)]
pub struct Info {
    pub hash: u64,
    pub abi: u32,
    pub name: Str,
    pub methods: *const MethodInfo,
    pub methods_len: usize,
}

unsafe impl Sync for Info {}
unsafe impl Send for Info {}

/// `calls` counts calls in flight, with [`CLOSED`] set once it stops taking them.
#[repr(C)]
pub struct Owner {
    pub calls: AtomicU32,
    pub name: Str,
}

#[repr(C)]
pub struct Header {
    pub info: *const Info,
    pub owner: *mut Owner,
}

/// In an owner while it lives. None if it's closed. No owner always enters.
pub struct Entered(*mut Owner);

impl Entered {
    pub unsafe fn new(owner: *mut Owner) -> Option<Entered> {
        if let Some(o) = unsafe { owner.as_ref() } {
            if o.calls.fetch_add(1, Ordering::AcqRel) & CLOSED != 0 {
                o.calls.fetch_sub(1, Ordering::AcqRel);
                return None;
            }
        }
        Some(Entered(owner))
    }
}

impl Drop for Entered {
    fn drop(&mut self) {
        if let Some(o) = unsafe { self.0.as_ref() } {
            o.calls.fetch_sub(1, Ordering::AcqRel);
        }
    }
}

/// Runs what a table calls, giving zero if it panics, since a panic can't cross.
pub fn guard<R>(f: impl FnOnce() -> R) -> R {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(r) => r,
        // What crosses is plain data, which zero is a value of
        Err(_) => unsafe { std::mem::zeroed() },
    }
}

/// The same for a result's code, which gives Gone if it panics.
pub fn guard_code(f: impl FnOnce() -> u32) -> u32 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or(GONE)
}

/// An error set's codes. Each has its own, with these too.
pub trait ErrorCode: Copy {
    const CANCELLED: Self;
    const UNSUPPORTED: Self;
    const GONE: Self;
    fn from_code(code: u32) -> Self;
    fn code(self) -> u32;
}

/// The codes every result can give, for async methods with no error set.
#[repr(transparent)]
#[derive(Clone, Copy, Default, PartialEq, Eq, Hash, Debug)]
pub struct Code(pub u32);

impl ErrorCode for Code {
    const CANCELLED: Self = Code(CANCELLED);
    const UNSUPPORTED: Self = Code(UNSUPPORTED);
    const GONE: Self = Code(GONE);
    fn from_code(code: u32) -> Self {
        Code(code)
    }
    fn code(self) -> u32 {
        self.0
    }
}

impl std::fmt::Display for Code {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.0 {
            CANCELLED => f.write_str("Cancelled"),
            UNSUPPORTED => f.write_str("Unsupported"),
            GONE => f.write_str("Gone"),
            c => write!(f, "code {c}"),
        }
    }
}

impl std::error::Error for Code {}

/// A generated trait object or function value.
pub unsafe trait TraitObject: Copy + Default {
    const INFO: &'static Info;
    fn object(self) -> Object;
    fn from_object(o: Object) -> Self;
    fn is_some(&self) -> bool {
        self.object().is_some()
    }
}

/// A trait object whose table T's methods fill in.
pub unsafe trait Implements<T>: TraitObject {
    fn table() -> *const c_void;
}

/// Says a trait is one of another's bases, so [`as_base`] can make it one.
pub trait Extends<B: TraitObject>: TraitObject {}

/// One calling `imp`, which lives as long as the program.
pub fn from_static<O: Implements<T>, T>(imp: &'static T) -> O {
    O::from_object(Object { data: imp as *const T as usize, table: O::table() })
}

/// One calling `imp`, which has to outlive it.
pub unsafe fn borrowed<O: Implements<T>, T>(imp: &T) -> O {
    O::from_object(Object { data: imp as *const T as usize, table: O::table() })
}

// The runtime

static HOST: (AtomicUsize, AtomicUsize) = (AtomicUsize::new(0), AtomicUsize::new(0));
static OWNER: AtomicUsize = AtomicUsize::new(0);

/// The host [`init`] gave. No table before then.
pub fn host() -> Host {
    Host::from_object(Object { data: HOST.0.load(Ordering::Acquire), table: HOST.1.load(Ordering::Acquire) as *const c_void })
}

/// What guards what [`keep`] makes. Null before [`init`].
pub fn owner() -> *mut Owner {
    OWNER.load(Ordering::Acquire) as *mut Owner
}

/// What [`keep`] made, by its data, and what destroys it. The owner can guard other objects too.
type Kept = Mutex<HashMap<usize, unsafe fn(usize)>>;

fn kept() -> &'static Kept {
    static KEPT: std::sync::OnceLock<Kept> = std::sync::OnceLock::new();
    KEPT.get_or_init(|| Mutex::new(HashMap::new()))
}

fn release_kept(data: usize) {
    let destroy = kept().lock().map(|mut k| k.remove(&data)).unwrap_or(None);
    if let Some(d) = destroy {
        unsafe { d(data) }
    }
}

static RELEASE_HOOK: fn(usize) = release_kept;

/// What a plugin does first, with its host and the owner guarding what [`keep`] makes, like its loader's.
/// False out of memory.
pub fn init(host: Host, owner: *mut Owner) -> bool {
    let o = host.object();
    HOST.0.store(o.data, Ordering::Release);
    HOST.1.store(o.table as usize, Ordering::Release);
    OWNER.store(owner as usize, Ordering::Release);
    if owner.is_null() {
        return false;
    }
    host.releasable(owner, from_static(&RELEASE_HOOK))
}

/// The same with an owner of its own called `name`. False if the host had none.
pub fn init_named(host: Host, name: &str) -> bool {
    init(host, host.owner(name))
}

/// A heap copy of `imp` as an `O`, guarded by [`owner`], destroyed once the host lets go of it.
/// For keep parameters and returns. Needs [`init`].
pub fn keep<O: Implements<T>, T: Send + Sync + 'static>(imp: T) -> O {
    unsafe fn destroy<T>(data: usize) {
        drop(unsafe { Box::from_raw(data as *mut T) });
    }
    let data = Box::into_raw(Box::new(imp)) as usize;
    if let Ok(mut k) = kept().lock() {
        k.insert(data, destroy::<T>);
    }
    let made = Object { data, table: O::table() };
    O::from_object(host().adopt(made, owner()))
}

/// The one provided as `name`, laid out like this module's `O`. No table if there isn't one.
pub fn get<O: TraitObject>(name: &str, major: u32) -> O {
    O::from_object(host().get(name, major, O::INFO as *const Info as *mut Info))
}

/// 0, or 1 when the name's taken, 2 out of memory, 3 when its table has no owner.
pub fn provide<O: TraitObject>(name: &str, major: u32, obj: O) -> u32 {
    host().provide(name, major, obj.object())
}

/// The host's copy of obj's table, which stops calling into it once `owner` closes.
pub fn own<O: TraitObject>(obj: O, owner: *mut Owner) -> O {
    O::from_object(host().adopt(obj.object(), owner))
}

/// Done holding obj, from a keep parameter or a return.
pub fn release<O: TraitObject>(obj: O) {
    host().release(obj.object())
}

/// `obj` as one of its bases, with the host making a table laid out like `B`'s. No table across ABIs.
pub fn as_base<B: TraitObject, O: Extends<B>>(obj: O) -> B {
    B::from_object(host().adapt(obj.object(), B::INFO as *const Info as *mut Info))
}

/// An object that's ours to let go of, like one from a keep parameter or a return. Released when dropped.
pub struct Held<O: TraitObject>(O);

impl<O: TraitObject> Held<O> {
    pub fn new(obj: O) -> Held<O> {
        Held(obj)
    }

    /// Gives it up without letting go, like to a keep parameter.
    pub fn into_inner(self) -> O {
        let o = self.0;
        std::mem::forget(self);
        o
    }
}

impl<O: TraitObject> std::ops::Deref for Held<O> {
    type Target = O;
    fn deref(&self) -> &O {
        &self.0
    }
}

impl<O: TraitObject> Drop for Held<O> {
    fn drop(&mut self) {
        if self.0.is_some() {
            release(self.0);
        }
    }
}

// Promises

/// What an async method gives back, held by whoever waits and let go of when dropped. `.await` it for its
/// `Result`, or `wait` for it. What the value points at is good till this thread takes another.
pub struct Future<T, E = Code> {
    promise: Promise,
    waiting: Option<Arc<Waiting>>,
    _value: PhantomData<fn() -> (T, E)>,
}

unsafe impl<T, E> Send for Future<T, E> {}

/// The waker a promise's task wakes, kept up to date by each poll.
struct Waiting {
    waker: Mutex<Option<Waker>>,
}

impl Waiting {
    /// What the promise runs once settled. It lets go of its own count, since a promise never lets go of its task.
    fn call(&self) {
        let me = unsafe { Arc::from_raw(self as *const Waiting) };
        if let Some(w) = me.waker.lock().ok().and_then(|mut w| w.take()) {
            w.wake();
        }
    }
}

impl TaskImpl for Waiting {
    fn call(&self) {
        Waiting::call(self)
    }
}

impl<T, E> Default for Future<T, E> {
    fn default() -> Self {
        Future { promise: Promise::default(), waiting: None, _value: PhantomData }
    }
}

impl<T, E> Future<T, E> {
    pub fn from_promise(promise: Promise) -> Self {
        Future { promise, waiting: None, _value: PhantomData }
    }

    /// One for no promise, which gives Gone.
    pub fn none() -> Self {
        Self::default()
    }

    pub fn promise(&self) -> Promise {
        self.promise
    }

    pub fn is_settled(&self) -> bool {
        self.promise.is_settled()
    }

    /// Gives it up without letting go, like to an async method's caller.
    pub fn into_promise(self) -> Promise {
        let p = self.promise;
        std::mem::forget(self);
        p
    }

    pub fn cancel(self) {
        let p = self.into_promise();
        p.cancel();
    }
}

impl<T: Copy + Default, E: ErrorCode> Future<T, E> {
    /// Once settled. Gone if it isn't yet.
    pub fn take(&self) -> Result<T, E> {
        if !self.promise.is_some() || !self.promise.is_settled() {
            return Err(E::GONE);
        }
        let mut v = T::default();
        let code = self.promise.take(&mut v as *mut T as *mut c_void);
        if code == OK { Ok(v) } else { Err(E::from_code(code)) }
    }

    /// Blocks this thread till it's settled.
    pub fn wait(self) -> Result<T, E> {
        struct Thread(std::thread::Thread);
        impl Wake for Thread {
            fn wake(self: Arc<Self>) {
                self.0.unpark();
            }
        }
        let waker = Waker::from(Arc::new(Thread(std::thread::current())));
        let mut cx = Context::from_waker(&waker);
        let mut me = self;
        loop {
            if let Poll::Ready(r) = std::future::Future::poll(Pin::new(&mut me), &mut cx) {
                return r;
            }
            std::thread::park();
        }
    }
}

impl<T: Copy + Default, E: ErrorCode> std::future::Future for Future<T, E> {
    type Output = Result<T, E>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        if !self.promise.is_some() || self.promise.is_settled() {
            return Poll::Ready(self.take());
        }
        if let Some(w) = &self.waiting {
            if let Ok(mut slot) = w.waker.lock() {
                *slot = Some(cx.waker().clone());
            }
        } else {
            let w = Arc::new(Waiting { waker: Mutex::new(Some(cx.waker().clone())) });
            // The task's count, let go of when it runs
            let task: Task = unsafe { borrowed(&*Arc::into_raw(w.clone())) };
            self.waiting = Some(w);
            self.promise.then(task, Queue::default());
        }
        // Settled between looking and waiting, so the task woke nobody
        if self.promise.is_settled() { Poll::Ready(self.take()) } else { Poll::Pending }
    }
}

impl<T, E> Drop for Future<T, E> {
    fn drop(&mut self) {
        if self.promise.is_some() {
            self.promise.release();
        }
    }
}

/// Settles a [`Future`] once, from whoever does the work. Dropped unsettled, the waiter gets Gone.
pub struct Settle<T, E = Code> {
    resolver: Resolver,
    _value: PhantomData<fn(T, E)>,
}

unsafe impl<T, E> Send for Settle<T, E> {}

impl<T: Copy, E: ErrorCode> Settle<T, E> {
    /// Memory kept with the value, for what it points at, like its text. Before settling only.
    pub fn hold(&self, size: usize, alignment: usize) -> *mut c_void {
        self.resolver.hold(size, alignment)
    }

    /// What `v` points at has to last, so keep it with `hold`.
    pub fn resolve(mut self, v: T) {
        let r = std::mem::take(&mut self.resolver);
        r.resolve(&v as *const T as *mut c_void);
    }

    pub fn reject(mut self, e: E) {
        let r = std::mem::take(&mut self.resolver);
        r.reject(e.code());
    }

    pub fn settle(self, r: Result<T, E>) {
        match r {
            Ok(v) => self.resolve(v),
            Err(e) => self.reject(e),
        }
    }

    pub fn cancelled(&self) -> bool {
        self.resolver.cancelled()
    }
}

impl<T, E> Drop for Settle<T, E> {
    fn drop(&mut self) {
        if self.resolver.is_some() {
            self.resolver.drop();
        }
    }
}

/// A future and what settles it. The future goes to the waiter, like an async method's return. Needs [`init`].
pub fn promise<T: Copy, E: ErrorCode>() -> (Future<T, E>, Settle<T, E>) {
    let mut r = Resolver::default();
    let p = host().promise(std::mem::size_of::<T>(), &mut r);
    (Future::from_promise(p), Settle { resolver: r, _value: PhantomData })
}

/// Runs `f` till it finishes, settling the future it gives. It runs straight away, up to its first `.await`
/// that has to wait, then carries on wherever what it waits on wakes it. Needs [`init`].
pub fn spawn<T, E, F>(f: F) -> Future<T, E>
where
    T: Copy + Send + 'static,
    E: ErrorCode + Send + 'static,
    F: std::future::Future<Output = Result<T, E>> + Send + 'static,
{
    let (future, settle) = promise::<T, E>();
    let task = Arc::new(Spawned { state: AtomicU8::new(IDLE), body: Mutex::new(Some(Box::pin(async move { settle.settle(f.await) }))) });
    task.run();
    future
}

const IDLE: u8 = 0;
const POLLING: u8 = 1;
const AGAIN: u8 = 2;
const DONE: u8 = 3;

struct Spawned {
    state: AtomicU8,
    body: Mutex<Option<Pin<Box<dyn std::future::Future<Output = ()> + Send>>>>,
}

impl Spawned {
    /// Polls it, or has whoever's polling poll again, so it's polled on one thread at a time.
    fn run(self: &Arc<Self>) {
        loop {
            match self.state.compare_exchange(IDLE, POLLING, Ordering::AcqRel, Ordering::Acquire) {
                Ok(_) => break,
                Err(POLLING) => {
                    if self.state.compare_exchange(POLLING, AGAIN, Ordering::AcqRel, Ordering::Acquire).is_ok() {
                        return;
                    }
                }
                Err(_) => return,
            }
        }
        let waker = Waker::from(self.clone());
        let mut cx = Context::from_waker(&waker);
        loop {
            let done = match self.body.lock() {
                Ok(mut body) => {
                    let ready = match body.as_mut() {
                        Some(f) => f.as_mut().poll(&mut cx).is_ready(),
                        None => true,
                    };
                    if ready {
                        *body = None;
                    }
                    ready
                }
                Err(_) => true,
            };
            if done {
                self.state.store(DONE, Ordering::Release);
                return;
            }
            if self.state.compare_exchange(POLLING, IDLE, Ordering::AcqRel, Ordering::Acquire).is_ok() {
                return;
            }
            // Woken while polling
            self.state.store(POLLING, Ordering::Release);
        }
    }
}

impl Wake for Spawned {
    fn wake(self: Arc<Self>) {
        self.run();
    }
}

// Declared code

/// Finds code a schema declares, like a game's functions and globals.
pub mod declared {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::RwLock;

    type Locate = fn(&str) -> usize;
    static LOCATOR: RwLock<Option<Locate>> = RwLock::new(None);

    /// Says where a name is, like `Player.heal`, `spawn`, or `Player` for its vtable. 0 if it isn't there.
    /// The loader sets it.
    pub fn set_locator(f: Option<fn(&str) -> usize>) {
        if let Ok(mut l) = LOCATOR.write() {
            *l = f;
        }
    }

    pub fn address(name: &str) -> usize {
        LOCATOR.read().ok().and_then(|l| *l).map(|f| f(name)).unwrap_or(0)
    }

    /// Calling a missing function can't do anything sensible.
    pub fn missing(name: &str) -> ! {
        panic!("{name} wasn't found, so it can't be called")
    }

    /// One name's address, kept once it's found.
    pub struct Site {
        name: &'static str,
        at: AtomicUsize,
    }

    impl Site {
        pub const fn new(name: &'static str) -> Site {
            Site { name, at: AtomicUsize::new(0) }
        }

        pub fn get(&self) -> usize {
            let a = self.at.load(Ordering::Acquire);
            if a != 0 {
                return a;
            }
            let a = address(self.name);
            self.at.store(a, Ordering::Release);
            a
        }
    }

    /// Slot `n` of the vtable at the start of `obj`.
    pub unsafe fn slot(obj: *const std::ffi::c_void, n: usize) -> usize {
        unsafe { *(*(obj as *const *const usize)).add(n) }
    }
}
