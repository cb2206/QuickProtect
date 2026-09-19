using System.Net.Sockets;
using System.Runtime.Versioning;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Platform;

/// <summary>
/// Keeps exactly one tray agent alive per user, and carries the "show your
/// panel" nudge from any later launch to the one already running. Two copies
/// would mean two tray icons and two sets of server-side stream allocations.
/// </summary>
internal interface ISingleInstance : IDisposable
{
    /// <summary>False when another instance already owns the session.</summary>
    bool IsPrimary { get; }

    /// <summary>
    /// From a duplicate launch: ask the running instance to show its panel.
    /// False when nobody answered — it is still starting up, or this platform
    /// has no channel.
    /// </summary>
    bool RaiseRunningInstance();

    /// <summary>From the primary: run <paramref name="handler"/> for every later launch.</summary>
    void OnRaiseRequested(Action handler);
}

internal static class SingleInstanceFactory
{
    /// <summary>Shared rendezvous name — a kernel object on Windows, a socket filename on Linux.</summary>
    internal const string ChannelName = "QuickProtect-ShowPanel";
    internal const string MutexName = "QuickProtect-SingleInstance";

    /// <summary>Claims primary status for this process, or discovers that another holds it.</summary>
    public static ISingleInstance Acquire()
    {
        if (OperatingSystem.IsWindows()) return new WindowsSingleInstance();
        if (OperatingSystem.IsLinux()) return new LinuxSingleInstance();
        return new NoopSingleInstance();
    }
}

/// <summary>A named mutex to arbitrate, a named event to nudge.</summary>
[SupportedOSPlatform("windows")]
internal sealed class WindowsSingleInstance : ISingleInstance
{
    private readonly Mutex _mutex;
    private EventWaitHandle? _handle;

    public WindowsSingleInstance()
    {
        _mutex = new Mutex(initiallyOwned: true, SingleInstanceFactory.MutexName, out var isPrimary);
        IsPrimary = isPrimary;
    }

    public bool IsPrimary { get; }

    public bool RaiseRunningInstance()
    {
        try
        {
            using var channel = EventWaitHandle.OpenExisting(SingleInstanceFactory.ChannelName);
            // This launch may take the foreground; the running instance may not.
            // Pass the right on, or its panel opens behind the current window,
            // never active, so clicking elsewhere can't dismiss it.
            AllowSetForegroundWindow(AsfwAny);
            channel.Set();
            return true;
        }
        catch (WaitHandleCannotBeOpenedException)
        {
            // The running instance has not created it yet — nothing to nudge.
            return false;
        }
    }

    private const int AsfwAny = -1;

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool AllowSetForegroundWindow(int processId);

    public void OnRaiseRequested(Action handler)
    {
        _handle = new EventWaitHandle(false, EventResetMode.AutoReset, SingleInstanceFactory.ChannelName);
        var handle = _handle;
        var thread = new Thread(() =>
        {
            while (handle.WaitOne())
                handler();
        })
        { IsBackground = true, Name = "QP-ShowPanel" };
        thread.Start();
    }

    public void Dispose()
    {
        _handle?.Dispose();
        _mutex.Dispose();
    }
}

/// <summary>
/// One Unix domain socket does both jobs: whoever binds it is the primary, and
/// anyone who can connect to it has someone to nudge.
///
/// A named mutex cannot arbitrate this on Linux. .NET scopes those per Unix
/// session (<c>/tmp/.dotnet/lockfiles/session&lt;sid&gt;/</c>), so a launch from
/// the desktop's app launcher and a launch from a terminal land in different
/// namespaces and both believe they are the only instance. Named
/// <see cref="EventWaitHandle"/>s do not exist here at all — .NET throws
/// PlatformNotSupportedException — which is why a duplicate launch used to exit
/// without telling anyone, leaving no way to reopen a running instance's panel.
///
/// The socket lives in <c>$XDG_RUNTIME_DIR</c>: per-user, already mode 0700,
/// cleared on logout, and it cannot collide with another user's.
/// </summary>
[SupportedOSPlatform("linux")]
internal sealed class LinuxSingleInstance : ISingleInstance
{
    private Socket? _listener;
    private bool _disposed;

    public LinuxSingleInstance() => IsPrimary = TryBind();

    public bool IsPrimary { get; }

    /// <summary>
    /// Without <c>$XDG_RUNTIME_DIR</c>, a user-qualified directory under the
    /// temp dir keeps two users on one machine apart.
    /// </summary>
    internal static string SocketPath
    {
        get
        {
            var runtimeDir = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
            if (!string.IsNullOrEmpty(runtimeDir) && Directory.Exists(runtimeDir))
                return Path.Combine(runtimeDir, $"{SingleInstanceFactory.ChannelName}.sock");
            var fallback = Path.Combine(Path.GetTempPath(), $"quickprotect-{Environment.UserName}");
            Directory.CreateDirectory(fallback);
            return Path.Combine(fallback, $"{SingleInstanceFactory.ChannelName}.sock");
        }
    }

    /// <summary>
    /// Binds the socket, clearing a file left behind by a crash first. Returns
    /// false when a live instance already holds it.
    /// </summary>
    private bool TryBind()
    {
        var path = SocketPath;
        // Two attempts: the second covers losing a bind race to another launch
        // that appeared between the connect probe and the bind.
        for (var attempt = 0; attempt < 2; attempt++)
        {
            if (File.Exists(path))
            {
                if (CanConnect(path)) return false;
                File.Delete(path); // Refused: outlived the process that bound it.
            }

            try
            {
                var listener = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
                listener.Bind(new UnixDomainSocketEndPoint(path));
                listener.Listen(backlog: 4);
                _listener = listener;
                return true;
            }
            catch (SocketException ex) when (ex.SocketErrorCode == SocketError.AddressAlreadyInUse)
            {
                // Someone won the race; go round and connect to them instead.
            }
        }
        return false;
    }

    private static bool CanConnect(string path)
    {
        try
        {
            using var probe = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            probe.Connect(new UnixDomainSocketEndPoint(path));
            return true;
        }
        catch (SocketException)
        {
            return false;
        }
    }

    public bool RaiseRunningInstance()
    {
        var path = SocketPath;
        if (!File.Exists(path)) return false;
        try
        {
            using var client = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            client.Connect(new UnixDomainSocketEndPoint(path));
            client.Send(new byte[] { 1 });
            return true;
        }
        catch (SocketException)
        {
            return false;
        }
    }

    public void OnRaiseRequested(Action handler)
    {
        if (_listener is not { } listener) return; // A duplicate has nothing to listen for.

        var thread = new Thread(() =>
        {
            while (!_disposed)
            {
                try
                {
                    using var connection = listener.Accept();
                    var buffer = new byte[1];
                    if (connection.Receive(buffer) > 0) handler();
                }
                catch (SocketException ex)
                {
                    if (_disposed) return;
                    Log.Line($"[ShowPanel] accept failed: {ex.SocketErrorCode}");
                }
                catch (ObjectDisposedException)
                {
                    return; // Shutting down.
                }
            }
        })
        { IsBackground = true, Name = "QP-ShowPanel" };
        thread.Start();
    }

    public void Dispose()
    {
        _disposed = true;
        // Only the instance that bound the socket may unlink it; a duplicate
        // disposes one of these too and must leave the primary's socket alone.
        if (_listener is null) return;
        _listener.Dispose();
        var path = SocketPath;
        if (File.Exists(path)) File.Delete(path);
    }
}

/// <summary>Platforms with no arbitration story: every launch is its own instance.</summary>
internal sealed class NoopSingleInstance : ISingleInstance
{
    public bool IsPrimary => true;
    public bool RaiseRunningInstance() => false;
    public void OnRaiseRequested(Action handler) { }
    public void Dispose() { }
}
