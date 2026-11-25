using System;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Probe.Sal;
using Salamander;

namespace Probe;

// The C# side of the tests passing test.sal's types and traits with Zig
public static unsafe class Traits
{
    // Sizes and offsets as C# lays them out, for Zig to check against its own
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Layout(nuint* into, int max)
    {
        Mixed m = default;
        var at = (byte*)&m;
        Span<nuint> got =
        [
            (nuint)sizeof(Vec3), (nuint)sizeof(Num), (nuint)sizeof(Flags), (nuint)sizeof(Mixed),
            (nuint)((byte*)&m.Big - at), (nuint)((byte*)&m.Yes - at), (nuint)((byte*)&m.At - at),
            (nuint)((byte*)&m.Shorts - at), (nuint)((byte*)&m.Flags - at), (nuint)((byte*)&m.Points - at),
            (nuint)((byte*)&m.Num - at), (nuint)sizeof(Sal.Raw.Opt_u32), (nuint)sizeof(Sal.Raw.Counter_Table),
            (nuint)sizeof(Sal.Raw.Tagged),
        ];
        got[..Math.Min(max, got.Length)].CopyTo(new Span<nuint>(into, max));
        return got.Length;
    }

    // Calls a counter Zig made, raw. 0 if it all came back right, or which check didn't.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static uint UseRaw(Sal.Raw.Counter c)
    {
        if (c.add(2) != 12) return 1;
        var v = c.scale(new Vec3 { X = 1, Y = 2, Z = 3 }, 2);
        if (v.X != 2 || v.Y != 4 || v.Z != 6) return 2;
        if (c.flip(true)) return 3;
        if (c.name().ToString() != "zig") return 4;
        uint got;
        if (c.check(4, &got) != Abi.Ok || got != 8) return 5;
        if (c.check(0, &got) != (uint)Fail.Bad) return 6;
        var m = new Mixed { Small = 1, Big = 2, Yes = true };
        m.Shorts[2] = 7;
        m.Flags.Level = 9;
        m.Flags.Mode = Mode.On;
        m.Num.Float = 1.5f;
        var back = c.echo(m);
        if (back.Small != 2 || back.Big != 2 || !back.Yes || back.Shorts[2] != 7 || back.Flags.Level != 9 || back.Flags.Mode != Mode.On || back.Num.Float != 1.5f) return 7;
        var found = c.find(3);
        if (!found.some || found.value != 6) return 8;
        if (c.find(0).some) return 9;
        // No table gives zero, or Gone for a result
        if (default(Sal.Raw.Counter).add(1) != 0 || default(Sal.Raw.Counter).check(1, &got) != Abi.Gone) return 10;
        return 0;
    }

    // The same through the plain class
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static uint UsePlain(Sal.Raw.Counter raw)
    {
        var c = Counter.FromRaw(raw)!;
        if (c.Add(2) != 12) return 1;
        if (c.Scale(new Vec3 { X = 1, Y = 2, Z = 3 }, 2).Z != 6) return 2;
        if (c.Flip(true)) return 3;
        if (c.Name() != "zig") return 4;
        if (c.Check(4) != 8) return 5;
        try
        {
            c.Check(0);
            return 6;
        }
        catch (FailException e) when (e.Error == Fail.Bad) { }
        if (c.Find(3) != 6 || c.Find(0) != null) return 7;
        if (c.Greet("cs") != "hi cs") return 8;
        if (c.Sum([1, 2, 3]) != 6) return 9;
        if (!c.Range(3).SequenceEqual(new uint[] { 0, 1, 2 })) return 10;
        var t = c.Retag(new Tagged { Tag = "x", Ids = [4, 5], At = new Vec3 { X = 1 } });
        if (t.Tag != "x" || t.Ids.Length != 2 || t.Ids[1] != 5 || t.At.X != 2) return 11;
        if (c.Each(5, i => i % 2 == 0) != 3) return 12;
        if (c.LaterAsync(4).GetAwaiter().GetResult() != 8) return 13;
        try
        {
            c.LaterCheckAsync(0).GetAwaiter().GetResult();
            return 14;
        }
        catch (FailException e) when (e.Error == Fail.Bad) { }
        if (c.LaterCheckAsync(2).GetAwaiter().GetResult() != 6) return 15;
        var v = new Vec3 { X = 1 };
        c.Bump(ref v);
        if (v.X != 2) return 16;
        return 0;
    }

    static int thrown;

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static void Init(Salamander.Raw.Host host)
    {
        Abi.OnException = _ => thrown++;
        Runtime.Init(host);
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static Sal.Raw.Counter MakePlain() => Counter.From(new PlainCounter()).Raw;

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static void FreeCounter(Sal.Raw.Counter c) => Sal.Raw.Counter.Free(c);

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Thrown() => thrown;
}

// A counter in plain C#, for Zig to call
// Not in Traits, since async methods can't be in unsafe code
sealed class PlainCounter : ICounter
{
    uint total = 100;

    public uint Add(uint n) => total += n;
    public Vec3 Scale(Vec3 v, float by) => new() { X = v.X * by, Y = v.Y * by, Z = v.Z * by };
    public bool Flip(bool b) => !b;
    public string Name() => "cs";

    public uint Check(uint n) => n switch
    {
        0 => throw new FailException(Fail.Bad),
        13 => throw new InvalidOperationException("unlucky"),
        _ => n * 3,
    };

    public Mixed Echo(Mixed m)
    {
        m.Big *= 10;
        m.Shorts[0] = 42;
        m.Flags.Alive = true;
        return m;
    }

    public uint? Find(uint n) => n == 0 ? null : n + 1;
    public string Greet(string who) => "hello " + who;

    public uint Sum(ReadOnlySpan<uint> ids)
    {
        uint t = 0;
        foreach (var i in ids) t += i;
        return t;
    }

    public uint[] Range(uint n) => Enumerable.Range(0, (int)n).Select(i => (uint)i).ToArray();

    public Tagged Retag(Tagged t) => new()
    {
        Tag = t.Tag + "!",
        Ids = Enumerable.Reverse(t.Ids).ToArray(),
        At = new Vec3 { X = t.At.X + 10, Y = t.At.Y, Z = t.At.Z },
    };

    public uint Each(uint n, Visit? visit)
    {
        uint c = 0;
        for (uint i = 0; i < n; i++) if (visit!(i)) c++;
        return c;
    }

    public Task<uint> LaterAsync(uint n, CancellationToken cancel) => Task.FromResult(n * 10);

    public async Task<uint> LaterCheckAsync(uint n, CancellationToken cancel)
    {
        await Task.Yield();
        if (n == 0) throw new FailException(Fail.Bad);
        return n * 10;
    }

    public void Bump(ref Vec3 v) => v.Y += 1;
}
