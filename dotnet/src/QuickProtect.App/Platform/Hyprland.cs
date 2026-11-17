using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Avalonia.Controls;
using Avalonia.Controls.Platform;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Platform;

/// <summary>
/// Hyprland integration, so the tray panel works on a tiling compositor.
///
/// The panel is a popover that hides when it loses focus. Hyprland (Omarchy's
/// default) focuses whatever window the pointer is over (<c>follow_mouse = 1</c>),
/// so the pointer crossing a tiled window on its way from the bar to the panel
/// already counts as leaving it, and the panel hides before it can be clicked.
/// Neither the app nor the compositor's event socket can tell that hover apart
/// from a real click elsewhere, so on Hyprland the panel becomes an overlay
/// instead, the way Omarchy presents 1Password: a floating, centered window
/// that stays up until it is dismissed on purpose (tray icon, hotkey, Escape,
/// its close button, SUPER+W) or the user switches workspace.
///
/// The app runs through XWayland (Avalonia 12 has no production Wayland
/// backend, and none with layer-shell), so it cannot become a real shell popup.
/// Marking its windows as X11 utility windows makes Hyprland float them without
/// any user window rule; the compositor's IPC socket supplies the focused
/// monitor, pinning and workspace events.
/// </summary>
internal static class Hyprland
{
    private static readonly Lazy<string?> SocketDirectory = new(FindSocketDirectory);

    /// <summary>True inside a Hyprland session with a reachable IPC socket directory.</summary>
    public static bool IsRunning => SocketDirectory.Value != null;

    private static string? FindSocketDirectory()
    {
        if (!OperatingSystem.IsLinux()) return null;
        var signature = Environment.GetEnvironmentVariable("HYPRLAND_INSTANCE_SIGNATURE");
        var runtime = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
        if (string.IsNullOrEmpty(signature) || string.IsNullOrEmpty(runtime)) return null;
        var dir = Path.Combine(runtime, "hypr", signature);
        return Directory.Exists(dir) ? dir : null;
    }

    /// <summary>
    /// Makes Hyprland float <paramref name="window"/> instead of tiling it: it
    /// floats XWayland windows of the utility type on its own. Must run before
    /// the window is first shown, while the type can still steer the mapping.
    /// </summary>
    public static void FloatWindow(Window window) =>
        X11Properties.SetNetWmWindowType(window, X11NetWmWindowType.Utility);

    /// <summary>
    /// Sends one request over the command socket (<c>hyprctl</c>'s protocol:
    /// <c>j/monitors</c>, <c>dispatch …</c>) and returns the reply, or null when
    /// Hyprland is unreachable.
    /// </summary>
    public static string? Request(string command)
    {
        if (SocketDirectory.Value is not { } dir) return null;
        try
        {
            using var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            socket.SendTimeout = 500;
            socket.ReceiveTimeout = 500;
            socket.Connect(new UnixDomainSocketEndPoint(Path.Combine(dir, ".socket.sock")));
            socket.Send(Encoding.UTF8.GetBytes(command));
            using var reply = new MemoryStream();
            var buffer = new byte[8192];
            int read;
            while ((read = socket.Receive(buffer)) > 0) reply.Write(buffer, 0, read);
            return Encoding.UTF8.GetString(reply.ToArray());
        }
        catch (Exception e) when (e is SocketException or IOException)
        {
            Log.Line($"[Hyprland] request \"{command}\" failed: {e.Message}");
            return null;
        }
    }

    /// <summary>A monitor as <c>hyprctl monitors</c> reports it, in its own (physical) pixels.</summary>
    internal sealed record Monitor(string Name, int Width, int Height, double Scale,
        int ReservedLeft, int ReservedTop, int ReservedRight, int ReservedBottom);

    /// <summary>The monitor with keyboard focus — where the user is looking.</summary>
    public static Monitor? FocusedMonitor()
    {
        var json = Request("j/monitors");
        if (json == null) return null;
        try
        {
            return ParseFocusedMonitor(json);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException)
        {
            Log.Line($"[Hyprland] unreadable monitor list: {e.Message}");
            return null;
        }
    }

    /// <summary>
    /// X11 screen pixels per Hyprland logical pixel for a screen showing
    /// <paramref name="monitor"/>: the monitor scale when XWayland runs unscaled
    /// (<c>force_zero_scaling</c>, Omarchy's default), else 1.
    /// </summary>
    public static double PixelsPerLogical(Avalonia.PixelRect screenBounds, Monitor monitor) =>
        monitor.Width > 0 ? screenBounds.Width / (monitor.Width / monitor.Scale) : 1;

    /// <summary>
    /// The pointer in Hyprland's global logical coordinates. Unlike positions an
    /// X11 client reports relative to its own window, it stays exact while that
    /// window is being moved underneath the pointer.
    /// </summary>
    public static Avalonia.Point? CursorPosition()
    {
        var json = Request("j/cursorpos");
        if (json == null) return null;
        try
        {
            return ParseCursorPosition(json);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException)
        {
            Log.Line($"[Hyprland] unreadable cursor position: {e.Message}");
            return null;
        }
    }

    internal static Avalonia.Point ParseCursorPosition(string json)
    {
        using var doc = JsonDocument.Parse(json);
        return new Avalonia.Point(doc.RootElement.GetProperty("x").GetDouble(),
            doc.RootElement.GetProperty("y").GetDouble());
    }

    internal static Monitor? ParseFocusedMonitor(string json)
    {
        using var doc = JsonDocument.Parse(json);
        foreach (var m in doc.RootElement.EnumerateArray())
        {
            if (!m.TryGetProperty("focused", out var focused) || !focused.GetBoolean()) continue;
            // reserved: [left, top, right, bottom] in logical pixels (the bar's strip).
            var reserved = m.TryGetProperty("reserved", out var r)
                ? r.EnumerateArray().Select(v => v.GetInt32()).ToArray()
                : [];
            int At(int i) => i < reserved.Length ? reserved[i] : 0;
            return new Monitor(m.GetProperty("name").GetString() ?? "",
                m.GetProperty("width").GetInt32(), m.GetProperty("height").GetInt32(),
                m.GetProperty("scale").GetDouble(), At(0), At(1), At(2), At(3));
        }
        return null;
    }

    /// <summary>
    /// Shows this process's window titled <paramref name="title"/> on every
    /// workspace (Hyprland's <c>pin</c>) — the macOS "all Spaces" behavior of
    /// pinned camera windows. <c>pin</c> toggles, so an already pinned window is
    /// left alone.
    /// </summary>
    public static void PinWindow(string title)
    {
        if (OwnWindow(title) is { Pinned: false } client)
            Dispatch($"hl.dsp.window.pin({{ window = \"address:{client.Address}\" }})",
                $"pin address:{client.Address}");
    }

    /// <summary>
    /// Gives this process's window titled <paramref name="title"/> keyboard
    /// focus. Hyprland ignores an X11 client's own activation request, so a
    /// panel opened from the tray or hotkey would otherwise leave focus (and
    /// Escape) with the window underneath until the pointer wanders over it.
    /// Returns false while the window isn't mapped yet.
    /// </summary>
    public static bool FocusWindow(string title)
    {
        if (OwnWindow(title) is not { } client) return false;
        Dispatch($"hl.dsp.focus({{ window = \"address:{client.Address}\" }})",
            $"focuswindow address:{client.Address}");
        return true;
    }

    private static Client? OwnWindow(string title)
    {
        var json = Request("j/clients");
        if (json == null) return null;
        try
        {
            return FindClient(json, Environment.ProcessId, title);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException)
        {
            Log.Line($"[Hyprland] unreadable client list: {e.Message}");
            return null;
        }
    }

    /// <summary>
    /// Runs a dispatcher. Hyprland 0.56+ configured in Lua only takes the Lua
    /// form (<c>hl.dsp…</c>); older releases only the classic one — the same
    /// fallback Omarchy's own scripts use.
    /// </summary>
    private static void Dispatch(string lua, string classic)
    {
        if (Request($"dispatch {lua}") is "ok") return;
        if (Request($"dispatch {classic}") is not "ok")
            Log.Line($"[Hyprland] dispatcher failed: {classic}");
    }

    internal sealed record Client(string Address, bool Pinned);

    internal static Client? FindClient(string json, int pid, string title)
    {
        using var doc = JsonDocument.Parse(json);
        foreach (var c in doc.RootElement.EnumerateArray())
        {
            if (c.GetProperty("pid").GetInt32() != pid || c.GetProperty("title").GetString() != title) continue;
            return new Client(c.GetProperty("address").GetString() ?? "",
                c.TryGetProperty("pinned", out var p) && p.GetBoolean());
        }
        return null;
    }

    /// <summary>Splits one event-socket line, <c>EVENT&gt;&gt;DATA</c>.</summary>
    internal static bool TryParseEvent(string line, out string name, out string data)
    {
        var split = line.IndexOf(">>", StringComparison.Ordinal);
        if (split <= 0)
        {
            name = data = "";
            return false;
        }
        name = line[..split];
        data = line[(split + 2)..];
        return true;
    }

    /// <summary>
    /// Subscribes to the event socket (<c>.socket2.sock</c>). The callback runs
    /// on a background thread with each event's name and data; dispose to stop.
    /// Null outside Hyprland.
    /// </summary>
    public static IDisposable? Subscribe(Action<string, string> onEvent)
    {
        if (SocketDirectory.Value is not { } dir) return null;
        var cts = new CancellationTokenSource();
        _ = ListenAsync(Path.Combine(dir, ".socket2.sock"), onEvent, cts.Token);
        return cts;
    }

    private static async Task ListenAsync(string path, Action<string, string> onEvent, CancellationToken ct)
    {
        try
        {
            using var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            await socket.ConnectAsync(new UnixDomainSocketEndPoint(path), ct);
            using var reader = new StreamReader(new NetworkStream(socket, ownsSocket: false), Encoding.UTF8);
            while (await reader.ReadLineAsync(ct) is { } line)
                if (TryParseEvent(line, out var name, out var data))
                    onEvent(name, data);
        }
        catch (OperationCanceledException)
        {
            // Disposed: the subscriber is gone.
        }
        catch (Exception e) when (e is SocketException or IOException)
        {
            Log.Line($"[Hyprland] event socket closed: {e.Message}");
        }
    }
}
