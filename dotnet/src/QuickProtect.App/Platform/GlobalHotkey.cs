using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Avalonia.Input;
using Avalonia.Threading;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Platform;

/// <summary>
/// A system-wide hotkey that toggles the camera panel. Stored generically in
/// settings as (keyCode = Win32 virtual-key, modifiers = Win32 MOD_* flags).
/// Windows registers it natively; Linux binds it through the XDG Desktop
/// Portal (see <see cref="PortalGlobalHotkey"/>); portal-less environments
/// are a documented no-op — track in PARITY.md.
/// </summary>
public interface IGlobalHotkey : IDisposable
{
    /// <summary>Register (or re-register) the hotkey; pass null to clear.</summary>
    void Update(int? keyCode, int? modifiers);
}

public static class GlobalHotkeyFactory
{
    public static IGlobalHotkey Create(Action onTriggered)
        => OperatingSystem.IsWindows() ? new WindowsGlobalHotkey(onTriggered)
        : OperatingSystem.IsLinux() ? new PortalGlobalHotkey(onTriggered)
        : new NoopGlobalHotkey();
}

public sealed class NoopGlobalHotkey : IGlobalHotkey
{
    public void Update(int? keyCode, int? modifiers)
    {
        if (keyCode != null && !OperatingSystem.IsWindows())
            Log.Line("[Hotkey] global hotkeys are not yet supported on this platform.");
    }
    public void Dispose() { }
}

/// <summary>
/// Windows global hotkey. <c>RegisterHotKey</c> posts <c>WM_HOTKEY</c> to the
/// registering thread's message queue, so we run a dedicated thread with a
/// <c>GetMessage</c> loop and marshal the trigger back to the UI thread.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class WindowsGlobalHotkey : IGlobalHotkey
{
    private const int HotkeyId = 0xB001;
    private const uint WmHotkey = 0x0312;
    private const uint WmQuit = 0x0012;
    private const uint WmApp = 0x8000; // custom "register" signal

    private readonly Action _onTriggered;
    private Thread? _thread;
    private uint _threadId;
    private int? _vk, _mod;

    public WindowsGlobalHotkey(Action onTriggered) => _onTriggered = onTriggered;

    public void Update(int? keyCode, int? modifiers)
    {
        Stop();
        _vk = keyCode;
        _mod = modifiers;
        if (keyCode is null) return;

        var ready = new ManualResetEventSlim(false);
        _thread = new Thread(() =>
        {
            _threadId = GetCurrentThreadId();
            RegisterHotKey(IntPtr.Zero, HotkeyId, (uint)(modifiers ?? 0), (uint)keyCode.Value);
            ready.Set();
            while (GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
            {
                if (msg.message == WmQuit) break;
                if (msg.message == WmHotkey)
                    Dispatcher.UIThread.Post(_onTriggered);
            }
            UnregisterHotKey(IntPtr.Zero, HotkeyId);
        })
        { IsBackground = true, Name = "QP-GlobalHotkey" };
        _thread.Start();
        ready.Wait(1000);
    }

    private void Stop()
    {
        if (_thread is { IsAlive: true } && _threadId != 0)
        {
            PostThreadMessage(_threadId, WmQuit, IntPtr.Zero, IntPtr.Zero);
            _thread.Join(500);
        }
        _thread = null;
        _threadId = 0;
    }

    public void Dispose() => Stop();

    // P/Invoke
    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int ptX;
        public int ptY;
    }

    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] private static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool PostThreadMessage(uint threadId, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
}

/// <summary>
/// Translates Avalonia <see cref="Key"/>/<see cref="KeyModifiers"/> to the Win32
/// virtual-key + MOD_* flags stored in settings, and renders a display string.
/// </summary>
public static class HotkeyCodec
{
    // MOD_ALT=1, MOD_CONTROL=2, MOD_SHIFT=4, MOD_WIN=8
    public static int Modifiers(KeyModifiers m)
    {
        var mod = 0;
        if (m.HasFlag(KeyModifiers.Alt)) mod |= 1;
        if (m.HasFlag(KeyModifiers.Control)) mod |= 2;
        if (m.HasFlag(KeyModifiers.Shift)) mod |= 4;
        if (m.HasFlag(KeyModifiers.Meta)) mod |= 8;
        return mod;
    }

    /// <summary>Virtual-key for the supported set (letters, digits, F-keys), or null.</summary>
    public static int? VirtualKey(Key key)
    {
        if (key is >= Key.A and <= Key.Z) return 0x41 + (key - Key.A);
        if (key is >= Key.D0 and <= Key.D9) return 0x30 + (key - Key.D0);
        if (key is >= Key.F1 and <= Key.F24) return 0x70 + (key - Key.F1);
        return null;
    }

    /// <summary>Whether a key is a bare modifier (so recording waits for a real key).</summary>
    public static bool IsModifierKey(Key key) => key is
        Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or
        Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin;

    public static string Display(int? keyCode, int? modifiers)
    {
        if (keyCode is null) return Localization.Loc.Get("Not set");
        var parts = new List<string>();
        var mod = modifiers ?? 0;
        if ((mod & 2) != 0) parts.Add("Ctrl");
        if ((mod & 1) != 0) parts.Add("Alt");
        if ((mod & 4) != 0) parts.Add("Shift");
        if ((mod & 8) != 0) parts.Add("Win");
        parts.Add(KeyName(keyCode.Value));
        return string.Join("+", parts);
    }

    /// <summary>
    /// XDG "shortcuts" spec trigger string for the portal, e.g. "CTRL+SHIFT+p".
    /// A hint only — the compositor (or the user, in its consent dialog) has
    /// the final say on the binding.
    /// </summary>
    public static string PortalTrigger(int keyCode, int modifiers)
    {
        var parts = new List<string>();
        if ((modifiers & 2) != 0) parts.Add("CTRL");
        if ((modifiers & 1) != 0) parts.Add("ALT");
        if ((modifiers & 4) != 0) parts.Add("SHIFT");
        if ((modifiers & 8) != 0) parts.Add("LOGO");
        parts.Add(keyCode switch
        {
            >= 0x41 and <= 0x5A => char.ToLowerInvariant((char)keyCode).ToString(), // a-z
            >= 0x30 and <= 0x39 => ((char)keyCode).ToString(),                      // 0-9
            >= 0x70 and <= 0x87 => "F" + (keyCode - 0x6F),                          // F1-F24
            _ => "unknown"
        });
        return string.Join("+", parts);
    }

    private static string KeyName(int vk) => vk switch
    {
        >= 0x41 and <= 0x5A => ((char)vk).ToString(),           // A-Z
        >= 0x30 and <= 0x39 => ((char)vk).ToString(),           // 0-9
        >= 0x70 and <= 0x87 => "F" + (vk - 0x6F),               // F1-F24
        _ => "Key"
    };
}
