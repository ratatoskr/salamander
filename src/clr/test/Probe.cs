using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Loader;

namespace Probe;

public static class Exports
{
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Add(int a, int b) => a + b;

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int RuntimeMajor() => Environment.Version.Major;

    // 1 if this copy's in the default load context, where the app's own assemblies are
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int InDefaultContext() =>
        AssemblyLoadContext.GetLoadContext(typeof(Exports).Assembly) == AssemblyLoadContext.Default ? 1 : 0;
}
