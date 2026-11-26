// Salamander's ABI for C#. Generated files use this. Plain blittable types, function pointers and
// [UnmanagedCallersOnly] only, so it's the same JIT'd under CoreCLR or compiled with NativeAOT.
//
// A trait object is { data, table }. A table starts with a Header, then a function pointer per method.
// A null one is a method the table doesn't have, so the call gives zero, or Abi.Unsupported for a
// result. Before calling through a table with an owner, enter the owner, and leave after. A closed
// owner refuses, and the call gives zero, or Abi.Gone for a result. The generated helpers do all this.

#nullable enable

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Salamander;

public static unsafe class Abi
{
    public const uint Version = 1;

    // Results return a code, with the value through a pointer at the end. 0 is success.
    public const uint Ok = 0;
    public const uint Cancelled = 0xFFFFFFFD;
    public const uint Unsupported = 0xFFFFFFFE;
    public const uint Gone = 0xFFFFFFFF;

    // Set in an owner's calls once it stops taking them
    public const uint Closed = 0x80000000;

    /// <summary>False if the owner's closed. Leave after each true. No owner always enters.</summary>
    public static bool Enter(Owner* owner)
    {
        if (owner == null) return true;
        if (((uint)Interlocked.Increment(ref *(int*)&owner->calls) & Closed) != 0)
        {
            Interlocked.Decrement(ref *(int*)&owner->calls);
            return false;
        }
        return true;
    }

    public static void Leave(Owner* owner)
    {
        if (owner != null) Interlocked.Decrement(ref *(int*)&owner->calls);
    }

    /// <summary>
    /// Gets what C# implementing a trait threw, since it can't cross into native code. The call
    /// gives zero, or Abi.Gone for a result.
    /// </summary>
    public static Action<Exception>? OnException;

    public static void Threw(Exception e) => OnException?.Invoke(e);

    /// <summary>Throws if this process's pointers aren't the size a generated file was made for.</summary>
    public static void ExpectPointerSize(int size)
    {
        if (sizeof(nint) != size) throw new PlatformNotSupportedException($"these types are for {size * 8}-bit code");
    }

    /// <summary>
    /// A trait's Info, kept for good. methods is each method's name, each ending in a zero, with
    /// sigs in the same order. pointerSize is what the generated file was made for.
    /// </summary>
    public static Info* MakeInfo(int pointerSize, ulong hash, ReadOnlySpan<byte> name, ReadOnlySpan<byte> methods, ReadOnlySpan<ulong> sigs)
    {
        ExpectPointerSize(pointerSize);
        var info = (Info*)NativeMemory.AllocZeroed((nuint)sizeof(Info));
        info->hash = hash;
        info->abi = Version;
        info->name = Str.Copy(name);
        var list = (MethodInfo*)NativeMemory.AllocZeroed((nuint)(sizeof(MethodInfo) * Math.Max(sigs.Length, 1)));
        for (var i = 0; i < sigs.Length; i++)
        {
            var end = methods.IndexOf((byte)0);
            list[i].name = Str.Copy(methods[..end]);
            list[i].sig = sigs[i];
            methods = methods[(end + 1)..];
        }
        info->methods = list;
        info->methods_len = (nuint)sigs.Length;
        return info;
    }

    /// <summary>A table of size bytes, zeroed and kept for good, with its header filled in.</summary>
    public static void* MakeTable(nuint size, Info* info)
    {
        var table = (Header*)NativeMemory.AllocZeroed(size);
        table->info = info;
        return table;
    }

    /// <summary>What an object made from C# holds on to.</summary>
    public static nuint Hold(object target) => (nuint)(nint)GCHandle.ToIntPtr(GCHandle.Alloc(target));

    public static T Held<T>(nuint data) where T : class => (T)GCHandle.FromIntPtr((nint)data).Target!;

    public static void Free(nuint data) => GCHandle.FromIntPtr((nint)data).Free();
}

/// <summary>One byte, like C's and Zig's. C# bool isn't one when it crosses.</summary>
public struct Bool : IEquatable<Bool>
{
    public byte value;

    public static implicit operator bool(Bool b) => b.value != 0;
    public static implicit operator Bool(bool b) => new() { value = b ? (byte)1 : (byte)0 };
    public bool Equals(Bool other) => (value != 0) == (other.value != 0);
    public override bool Equals(object? obj) => obj is Bool b && Equals(b);
    public override int GetHashCode() => value != 0 ? 1 : 0;
    public override string ToString() => (value != 0).ToString();
}

/// <summary>UTF-8, borrowed for the call.</summary>
public unsafe struct Str
{
    public byte* ptr;
    public nuint len;

    public Str(byte* ptr, nuint len)
    {
        this.ptr = ptr;
        this.len = len;
    }

    public ReadOnlySpan<byte> Bytes => new(ptr, checked((int)len));

    public override string ToString() => len == 0 ? "" : Encoding.UTF8.GetString(ptr, checked((int)len));

    /// <summary>
    /// A u8 literal's bytes, like Str.Literal("hello"u8). They're in the program's own data, so
    /// they stay put. Any other span has to be pinned for as long as the Str's used.
    /// </summary>
    public static Str Literal(ReadOnlySpan<byte> utf8)
    {
        fixed (byte* p = utf8) return new(p, (nuint)utf8.Length);
    }

    /// <summary>A native copy of text, to give back with Free.</summary>
    public static Str Alloc(string text)
    {
        var n = Encoding.UTF8.GetByteCount(text);
        var p = (byte*)NativeMemory.Alloc((nuint)Math.Max(n, 1));
        Encoding.UTF8.GetBytes(text, new Span<byte>(p, n));
        return new(p, (nuint)n);
    }

    /// <summary>One from Alloc.</summary>
    public static void Free(Str s) => NativeMemory.Free(s.ptr);

    /// <summary>text as UTF-8 in a's memory. Null is empty.</summary>
    public static Str From(string? text, IAllocator a)
    {
        if (string.IsNullOrEmpty(text)) return default;
        var n = Encoding.UTF8.GetByteCount(text);
        var p = (byte*)a.Alloc((nuint)n, 1);
        Encoding.UTF8.GetBytes(text, new Span<byte>(p, n));
        return new(p, (nuint)n);
    }

    /// <summary>text as UTF-8 ending in a zero, in a's memory. Null stays null.</summary>
    public static byte* CString(string? text, IAllocator a)
    {
        if (text == null) return null;
        var n = Encoding.UTF8.GetByteCount(text);
        var p = (byte*)a.Alloc((nuint)n + 1, 1);
        Encoding.UTF8.GetBytes(text, new Span<byte>(p, n));
        p[n] = 0;
        return p;
    }

    public static string? FromCString(byte* p) =>
        p == null ? null : Encoding.UTF8.GetString(MemoryMarshal.CreateReadOnlySpanFromNullTerminated(p));

    internal static Str Copy(ReadOnlySpan<byte> bytes)
    {
        var p = (byte*)NativeMemory.Alloc((nuint)Math.Max(bytes.Length, 1));
        bytes.CopyTo(new Span<byte>(p, bytes.Length));
        return new(p, (nuint)bytes.Length);
    }
}

public struct MethodInfo
{
    public Str name;
    public ulong sig;
}

/// <summary>What a table's methods are, so callers built against another version find theirs.</summary>
public unsafe partial struct Info
{
    public ulong hash;
    public uint abi;
    public Str name;
    public MethodInfo* methods;
    public nuint methods_len;
}

/// <summary>calls counts calls in flight, with Abi.Closed set once it stops taking them.</summary>
public partial struct Owner
{
    public uint calls;
    public Str name;
}

public unsafe struct Header
{
    public Info* info;
    public Owner* owner;
}

/// <summary>Any trait object. Each trait's AsObject and FromObject turn theirs into one and back.</summary>
public unsafe struct AnyObject
{
    public nuint data;
    public void* table;
}

// What the idiomatic layer runs on

/// <summary>Memory for what a call or a value points at, like its text.</summary>
public unsafe interface IAllocator
{
    void* Alloc(nuint size, nuint alignment);

    /// <summary>An object made in C# that's only lent out, to let go of when this memory goes.</summary>
    void Defer(nuint data);
}

public static unsafe class AllocatorExtensions
{
    public static T* Copy<T>(this IAllocator a, ReadOnlySpan<T> items) where T : unmanaged
    {
        if (items.IsEmpty) return null;
        var p = (T*)a.Alloc((nuint)(sizeof(T) * items.Length), 16);
        items.CopyTo(new Span<T>(p, items.Length));
        return p;
    }
}

/// <summary>Native memory handed out in order and given back all at once.</summary>
public sealed unsafe class Arena : IAllocator, IDisposable
{
    readonly List<nint> chunks = new();
    readonly List<nuint> sizes = new();
    readonly List<nuint> deferred = new();
    int current = -1;
    nuint used;

    public readonly struct Mark
    {
        internal readonly int chunk;
        internal readonly nuint used;
        internal readonly int deferred;

        internal Mark(int chunk, nuint used, int deferred)
        {
            this.chunk = chunk;
            this.used = used;
            this.deferred = deferred;
        }
    }

    public void* Alloc(nuint size, nuint alignment)
    {
        if (alignment == 0) alignment = 1;
        while (true)
        {
            if (current >= 0)
            {
                var start = (used + alignment - 1) & ~(alignment - 1);
                if (start + size <= sizes[current])
                {
                    used = start + size;
                    return (byte*)chunks[current] + start;
                }
            }
            current++;
            used = 0;
            var want = Math.Max((nuint)4096, size + alignment);
            if (current == chunks.Count)
            {
                chunks.Add((nint)NativeMemory.AlignedAlloc(want, 16));
                sizes.Add(want);
            }
            else if (sizes[current] < size + alignment)
            {
                NativeMemory.AlignedFree((void*)chunks[current]);
                chunks[current] = (nint)NativeMemory.AlignedAlloc(want, 16);
                sizes[current] = want;
            }
        }
    }

    public void Defer(nuint data) => deferred.Add(data);

    public Mark Save() => new(current, used, deferred.Count);

    /// <summary>Gives back everything since mark, and lets go of what was deferred since.</summary>
    public void Restore(Mark mark)
    {
        for (var i = deferred.Count - 1; i >= mark.deferred; i--) Abi.Free(deferred[i]);
        deferred.RemoveRange(mark.deferred, deferred.Count - mark.deferred);
        current = mark.chunk;
        used = mark.used;
    }

    public void Reset() => Restore(new(-1, 0, 0));

    public void Dispose()
    {
        Reset();
        foreach (var c in chunks) NativeMemory.AlignedFree((void*)c);
        chunks.Clear();
        sizes.Clear();
    }
}

/// <summary>This thread's memory for one call, given back when it's disposed.</summary>
public readonly struct Scratch : IDisposable
{
    [ThreadStatic] static Arena? arena;

    readonly Arena a;
    readonly Arena.Mark mark;

    Scratch(Arena a)
    {
        this.a = a;
        mark = a.Save();
    }

    public static Scratch Enter() => new(arena ??= new Arena());

    public IAllocator Allocator => a;

    public void Dispose() => a.Restore(mark);
}

/// <summary>A call failed with a code. Each error set has its own, with its codes as an enum.</summary>
public class SalamanderException : Exception
{
    public uint Code { get; }

    public SalamanderException(uint code, string? message = null) : base(message ?? Describe(code)) => Code = code;

    static string Describe(uint code) => code switch
    {
        Abi.Gone => "gone, there was nothing to call or it threw",
        Abi.Unsupported => "unsupported, there's no such method there",
        _ => $"failed with code {code}",
    };
}

/// <summary>The host this process's C# uses, from its plugin's loader.</summary>
public static unsafe class Runtime
{
    static Raw.Host host;

    /// <summary>Guards what From makes, so the host lets go of it through Abi.Free.</summary>
    public static Owner* Owner;

    public static bool Ready => host.table != null;

    public static Raw.Host Host => host.table != null ? host : throw new InvalidOperationException("Salamander.Runtime.Init hasn't been called with the host");

    /// <summary>
    /// What a plugin does first, with the host it got. Objects made with From after this have an
    /// owner, so ones passed to keep parameters are let go of when the host's done with them.
    /// </summary>
    public static void Init(Raw.Host host, string name = "csharp")
    {
        Runtime.host = host;
        using var s = Scratch.Enter();
        Owner = host.owner(Str.From(name, s.Allocator));
        if (Owner != null) host.releasable(Owner, Raw.Release.Unowned(new ReleaseHook()));
    }

    /// <summary>Like Init, with an owner the host made already, like a plugin's from its loader.</summary>
    public static void Init(Raw.Host host, Owner* owner)
    {
        Runtime.host = host;
        Owner = owner;
        if (owner != null) host.releasable(owner, Raw.Release.Unowned(new ReleaseHook()));
    }

    sealed class ReleaseHook : Raw.IRelease
    {
        public void call(nuint data) => Abi.Free(data);
    }

    /// <summary>Done holding obj, from a keep parameter or a return.</summary>
    public static void Release(AnyObject obj)
    {
        if (host.table != null) host.release(obj);
    }

    /// <summary>Why the error called name happened, for whoever called in to show.</summary>
    public static void Explain(string name, string message)
    {
        if (host.table == null) return;
        using var s = Scratch.Enter();
        host.explain(Str.From(name, s.Allocator), Str.From(message, s.Allocator));
    }

    /// <summary>What was last explained for the error called name on this thread, or null.</summary>
    public static string? Explanation(string name)
    {
        if (host.table == null) return null;
        using var s = Scratch.Enter();
        var e = host.explanation(Str.From(name, s.Allocator));
        return e.len == 0 ? null : e.ToString();
    }
}

/// <summary>A trait's class, so generic code can wrap an object as one, like a plugin's services.</summary>
public interface ITrait<T> where T : class, ITrait<T>
{
    /// <summary>Its name in its schema, which services and the host's registry go by.</summary>
    static abstract string TraitName { get; }

    /// <summary>Null without a table. owned when the object's the caller's to let go of.</summary>
    static abstract T? FromObject(AnyObject o, bool owned = false);
}

/// <summary>
/// The single objects of traits the host gives a plugin, like another plugin's service, by full trait
/// name. Whatever loads the plugin sets them, and the generated Instance of each trait in a schema's
/// singletons reads its own.
/// </summary>
public static class Singletons
{
    static readonly System.Collections.Concurrent.ConcurrentDictionary<string, AnyObject> objects = new();

    public static void Set(string trait, AnyObject obj) => objects[trait] = obj;

    public static void Clear() => objects.Clear();

    /// <summary>The one of T, or throws saying there's none.</summary>
    public static T Get<T>() where T : class, ITrait<T>
    {
        if (objects.TryGetValue(T.TraitName, out var o) && T.FromObject(o) is { } found) return found;
        throw new InvalidOperationException($"There's no {T.TraitName} here. Does the plugin depend on the one that offers it?");
    }
}
/// <summary>
/// Finds code a schema declares in what already exists, like a game's functions by signature, for the
/// generated wrappers. Whatever loads this sets Locator, which gives an address or throws saying why.
/// What it finds is kept.
/// </summary>
public static class Declared
{
    public static Func<string, nuint>? Locator;

    static readonly System.Collections.Concurrent.ConcurrentDictionary<string, nuint> found = new();

    /// <summary>Where name is, like Player.heal or spawn. Throws if it isn't there.</summary>
    public static nuint Address(string name)
    {
        if (found.TryGetValue(name, out var at)) return at;
        var locate = Locator ?? throw new InvalidOperationException($"{name}: nothing here finds the code schemas declare");
        at = locate(name);
        if (at == 0) throw new InvalidOperationException($"{name} wasn't found");
        found[name] = at;
        return at;
    }

    /// <summary>Slot slot of the vtable at the start of obj.</summary>
    public static unsafe nuint Virtual(void* obj, int slot) => (*(nuint**)obj)[slot];
}

/// <summary>
/// What a hooked handler's first argument reads: the function as it was and the hook's context. The
/// host fills it once the hook's made, before anything calls the handler.
/// </summary>
public sealed class HookCell
{
    public nuint Original;
    public nuint Context;
}

/// <summary>
/// A function a schema declares, like a game's, as a value: its name, and handlers of its type. Each
/// generated one is under its owner's Fns, like Player.Fns.Heal. Handler takes its arguments, and
/// Hooked the hook's details first.
/// </summary>
public abstract class DeclaredFunction<Handler, Hooked>(string name) where Handler : Delegate where Hooked : Delegate
{
    /// <summary>Its full name, like Game.Player.heal.</summary>
    public string Name { get; } = name;

    /// <summary>Where it is, found by name the first time.</summary>
    public nuint Address() => Declared.Address(Name);

    /// <summary>A function value of its type calling handler, held till the host lets it go.</summary>
    public abstract AnyObject Lower(Handler handler);

    /// <summary>The same for a handler wanting the hook's details first, which it reads from cell.</summary>
    public abstract AnyObject Lower(Hooked handler, HookCell cell);
}
/// <summary>Turns promises into tasks and back.</summary>
public static unsafe class Promises
{
    /// <summary>The built-in codes as exceptions. Cancelled is .NET's own.</summary>
    public static Exception Fail(uint code) =>
        code == Abi.Cancelled ? new OperationCanceledException() : new SalamanderException(code);

    /// <summary>What an exception crosses as, when its error set doesn't have it.</summary>
    public static uint CodeOf(Exception e)
    {
        if (e is OperationCanceledException) return Abi.Cancelled;
        if (e is SalamanderException s) return s.Code;
        Abi.Threw(e);
        return Abi.Gone;
    }

    interface ISettle
    {
        void Cancel();
    }

    sealed class Settle<W, P> : Raw.ITask, ISettle where W : unmanaged
    {
        internal Raw.Promise promise;
        internal TaskCompletionSource<P> done = null!;
        internal Func<uint, Exception> fail = null!;
        internal Func<W, P> lift = null!;
        internal CancellationTokenRegistration cancel;
        internal nuint data;

        public void Cancel() => promise.cancel();

        public void call()
        {
            // Settled first and tidied, then carried on, since carrying on runs the awaiting code
            // right here, on the thread that settled it
            Exception? failed = null;
            P? value = default;
            try
            {
                W w;
                var code = promise.take(&w);
                // Lifted here, since what the value points at is only good till this thread takes another
                if (code == Abi.Ok) value = lift(w);
                else failed = fail(code);
            }
            catch (Exception e)
            {
                failed = e;
            }
            finally
            {
                promise.release();
                cancel.Dispose();
                Abi.Free(data);
            }
            if (failed != null) done.TrySetException(failed);
            else done.TrySetResult(value!);
        }
    }

    /// <summary>
    /// A task for p's value, lifted to C# with lift. Cancelling cancel cancels p. Awaiting it carries
    /// on on the thread that settled p, so the host decides where code goes after an await.
    /// </summary>
    public static Task<P> Await<W, P>(Raw.Promise p, CancellationToken cancel, Func<uint, Exception> fail, Func<W, P> lift) where W : unmanaged
    {
        var done = new TaskCompletionSource<P>();
        if (p.table == null)
        {
            done.SetException(fail(Abi.Gone));
            return done.Task;
        }
        var s = new Settle<W, P> { promise = p, done = done, fail = fail, lift = lift };
        var task = Raw.Task.Unowned(s);
        s.data = task.data;
        if (cancel.CanBeCanceled) s.cancel = cancel.Register(static o => ((ISettle)o!).Cancel(), s);
        p.then(task, default);
        return done.Task;
    }

    public static Task AwaitVoid(Raw.Promise p, CancellationToken cancel, Func<uint, Exception> fail) =>
        Await<byte, bool>(p, cancel, fail, static _ => true);

    sealed class Holding : IAllocator
    {
        readonly Raw.Resolver resolver;

        public Holding(Raw.Resolver resolver) => this.resolver = resolver;

        public void* Alloc(nuint size, nuint alignment) => resolver.hold(size, alignment);

        // What the value holds outlives it, like a keep
        public void Defer(nuint data) { }
    }

    /// <summary>A promise the host settles with task's value, lowered with lower. Needs Runtime.Init.</summary>
    public static Raw.Promise Make<W, P>(Task<P> task, Func<P, IAllocator, W> lower, Func<Exception, uint> codeOf) where W : unmanaged
    {
        Raw.Resolver made;
        var p = Runtime.Host.promise((nuint)sizeof(W), &made);
        if (p.table == null) return p;
        var resolver = made;
        task.ContinueWith(t =>
        {
            if (t.IsCanceled)
            {
                resolver.reject(Abi.Cancelled);
                return;
            }
            if (t.IsFaulted)
            {
                resolver.reject(codeOf(t.Exception!.InnerException ?? t.Exception));
                return;
            }
            try
            {
                var w = lower(t.Result, new Holding(resolver));
                resolver.resolve(&w);
            }
            catch (Exception e)
            {
                resolver.reject(codeOf(e));
            }
        }, TaskScheduler.Default);
        return p;
    }

    public static Raw.Promise MakeVoid(Task task, Func<Exception, uint> codeOf) =>
        Make<byte, bool>(task.ContinueWith(static t =>
        {
            t.GetAwaiter().GetResult();
            return true;
        }, TaskScheduler.Default), static (_, _) => 0, codeOf);
}
