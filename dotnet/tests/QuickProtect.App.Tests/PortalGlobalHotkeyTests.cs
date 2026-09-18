using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.Versioning;
using QuickProtect.App.Platform;
using Tmds.DBus.Protocol;
using Xunit;
using Xunit.Abstractions;

namespace QuickProtect.App.Tests;

/// <summary>
/// Drives <see cref="PortalGlobalHotkey"/> against a fake XDG Desktop Portal on
/// a private D-Bus daemon, end to end over a real bus.
///
/// This exists because a regression shipped past the whole suite: after the
/// Tmds.DBus 0.94 migration both match handlers read <c>Notification.Exception</c>
/// first, which throws on an ordinary value notification, and a throwing handler
/// makes Tmds drop the connection without a word — so BindShortcuts was never
/// sent. Nothing short of a real portal exchange catches that.
///
/// Linux-only, like <see cref="PlatformSignalTests"/>: each test returns early
/// off Linux, and also when <c>dbus-daemon</c> is not installed, saying so in the
/// test output. It never touches the user's session bus.
/// </summary>
[SupportedOSPlatform("linux")]
public sealed class PortalGlobalHotkeyTests
{
    /// <summary>Every wait is bounded, so a regression fails fast instead of hanging CI.</summary>
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(10);

    // P with ALT|SHIFT, in the Win32-style encoding the settings store.
    private const int KeyP = 80;
    private const int AltShift = 1 | 4;

    private readonly ITestOutputHelper _output;

    public PortalGlobalHotkeyTests(ITestOutputHelper output) => _output = output;

    /// <summary>The whole handshake, in order: register the app id, open a session, bind.</summary>
    [Fact]
    public async Task BindsTheShortcutAfterCreatingASession()
    {
        await using var h = await PortalHarness.StartAsync(_output);
        if (h is null) return;

        await h.UpdateAsync();

        Assert.Equal(new[] { "Register", "CreateSession", "BindShortcuts" }, h.Portal.Calls);
        Assert.Equal(PortalGlobalHotkey.AppId, h.Portal.RegisteredAppId);
        Assert.Equal(h.Portal.SessionHandle, h.Portal.BoundSession);
        Assert.Equal("toggle-panel", h.Portal.BoundShortcutId);
        Assert.Equal(HotkeyCodec.PortalTrigger(KeyP, AltShift), h.Portal.BoundTrigger);
        Assert.Contains(h.Logs, line => line.Contains("bound via portal"));
    }

    /// <summary>
    /// The case that would have caught the regression. Every portal response and
    /// activation is a value notification; a handler that throws on one takes the
    /// connection down, so a second press would never arrive. Two presses must
    /// both reach the callback.
    /// </summary>
    [Fact]
    public async Task EveryActivationRunsTheCallback()
    {
        await using var h = await PortalHarness.StartAsync(_output);
        if (h is null) return;
        await h.BindAsync();

        h.Portal.EmitActivated(h.Portal.SessionHandle, "toggle-panel");
        await WaitUntilAsync(() => h.Triggers == 1, "first activation to reach the callback");

        h.Portal.EmitActivated(h.Portal.SessionHandle, "toggle-panel");
        await WaitUntilAsync(() => h.Triggers == 2, "second activation to reach the callback");
    }

    /// <summary>Another shortcut or another session's press is not ours, and must not break the next one.</summary>
    [Fact]
    public async Task ActivationsForOtherShortcutsOrSessionsAreIgnored()
    {
        await using var h = await PortalHarness.StartAsync(_output);
        if (h is null) return;
        await h.BindAsync();

        h.Portal.EmitActivated(h.Portal.SessionHandle, "some-other-shortcut");
        h.Portal.EmitActivated("/org/freedesktop/portal/desktop/session/1_999/elsewhere", "toggle-panel");
        // A matching press afterwards proves the ignored ones were delivered and
        // handled — not lost — and that the connection is still up.
        h.Portal.EmitActivated(h.Portal.SessionHandle, "toggle-panel");

        await WaitUntilAsync(() => h.Triggers == 1, "the matching activation to reach the callback");
        Assert.Equal(1, h.Triggers);
    }

    /// <summary>A refused session ends the update — it must not wait forever for a bind that never comes.</summary>
    [Fact]
    public async Task RefusedSessionEndsTheUpdateWithoutBinding()
    {
        await using var h = await PortalHarness.StartAsync(_output, createSessionCode: 2);
        if (h is null) return;

        await h.UpdateAsync();

        Assert.Equal(new[] { "Register", "CreateSession" }, h.Portal.Calls);
        Assert.Contains(h.Logs, line => line.Contains("CreateSession failed (response 2)"));
    }

    /// <summary>A dismissed consent dialog ends the update and gives the session back.</summary>
    [Fact]
    public async Task DeclinedBindEndsTheUpdateAndClosesTheSession()
    {
        await using var h = await PortalHarness.StartAsync(_output, bindShortcutsCode: 1);
        if (h is null) return;

        await h.UpdateAsync();

        Assert.Equal(new[] { "Register", "CreateSession", "BindShortcuts", "Close" }, h.Portal.Calls);
        Assert.Contains(h.Logs, line => line.Contains("BindShortcuts declined (response 1)"));
    }

    private static async Task WaitUntilAsync(Func<bool> condition, string what)
    {
        var deadline = Stopwatch.StartNew();
        while (!condition())
        {
            if (deadline.Elapsed > Timeout)
                Assert.Fail($"Timed out after {Timeout.TotalSeconds}s waiting for {what}.");
            await Task.Delay(20);
        }
    }

    /// <summary>A private bus, a fake portal on it, and a hotkey pointed at both.</summary>
    private sealed class PortalHarness : IAsyncDisposable
    {
        private int _triggers;

        private PortalHarness(PrivateBus bus, FakePortal portal)
        {
            Bus = bus;
            Portal = portal;
            Hotkey = new PortalGlobalHotkey(
                onTriggered: () => Interlocked.Increment(ref _triggers),
                busAddress: bus.Address,
                // Runs the callback inline on the D-Bus thread: no Avalonia needed.
                dispatch: static action => action(),
                log: Logs.Enqueue);
        }

        public PrivateBus Bus { get; }
        public FakePortal Portal { get; }
        public PortalGlobalHotkey Hotkey { get; }
        public ConcurrentQueue<string> Logs { get; } = new();
        public int Triggers => Volatile.Read(ref _triggers);

        /// <summary>Null when the environment cannot run the test; the reason goes to the test output.</summary>
        public static async Task<PortalHarness?> StartAsync(
            ITestOutputHelper output, uint createSessionCode = 0, uint bindShortcutsCode = 0)
        {
            if (!OperatingSystem.IsLinux())
            {
                output.WriteLine("Skipped: the XDG Desktop Portal hotkey is Linux-only.");
                return null;
            }
            if (PrivateBus.FindDaemon() is not { } daemon)
            {
                output.WriteLine("Skipped: dbus-daemon is not installed, so no private bus can be started.");
                return null;
            }

            var bus = await PrivateBus.StartAsync(daemon);
            try
            {
                var portal = await FakePortal.StartAsync(bus.Address, createSessionCode, bindShortcutsCode);
                return new PortalHarness(bus, portal);
            }
            catch
            {
                bus.Dispose();
                throw;
            }
        }

        /// <summary>
        /// Runs one Update to completion. On a timeout it reports how far the
        /// exchange got — which portal calls arrived and what the hotkey logged —
        /// since a bare TimeoutException says nothing about where it stalled.
        /// </summary>
        public async Task UpdateAsync()
        {
            Assert.True(Hotkey.Update(KeyP, AltShift), "Update reports the portal's answer asynchronously; it returns true.");
            try
            {
                await Hotkey.LastUpdate.WaitAsync(Timeout);
            }
            catch (TimeoutException)
            {
                Assert.Fail($"The hotkey update did not finish within {Timeout.TotalSeconds}s. " +
                            $"Portal calls received: [{string.Join(", ", Portal.Calls)}]. " +
                            $"Hotkey log: [{string.Join(" | ", Logs)}].");
            }
        }

        /// <summary>Completes a successful bind, so a test can start from a live session.</summary>
        public async Task BindAsync()
        {
            await UpdateAsync();
            Assert.Contains("BindShortcuts", Portal.Calls);
        }

        public ValueTask DisposeAsync()
        {
            Hotkey.Dispose();
            Portal.Dispose();
            Bus.Dispose();
            return ValueTask.CompletedTask;
        }
    }

    /// <summary>
    /// A throwaway dbus-daemon. Deliberately not <c>--session</c>: the stock session
    /// config lists the system's service directories, so a call reaching the bus
    /// before the fake owns its name could auto-start the real xdg-desktop-portal.
    /// This config allows nothing to be activated.
    /// </summary>
    private sealed class PrivateBus : IDisposable
    {
        private const string Config = """
            <busconfig>
              <type>session</type>
              <listen>unix:tmpdir=/tmp</listen>
              <auth>EXTERNAL</auth>
              <policy context="default">
                <allow send_destination="*" eavesdrop="true"/>
                <allow eavesdrop="true"/>
                <allow own="*"/>
              </policy>
            </busconfig>
            """;

        private readonly Process _process;
        private readonly string _configPath;

        private PrivateBus(Process process, string configPath, string address)
        {
            _process = process;
            _configPath = configPath;
            Address = address;
        }

        public string Address { get; }

        public static string? FindDaemon()
            => (Environment.GetEnvironmentVariable("PATH") ?? "")
                .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
                .Select(dir => Path.Combine(dir, "dbus-daemon"))
                .FirstOrDefault(File.Exists);

        public static async Task<PrivateBus> StartAsync(string daemon)
        {
            var configPath = Path.Combine(Path.GetTempPath(), $"qp-test-bus-{Guid.NewGuid():N}.conf");
            await File.WriteAllTextAsync(configPath, Config);
            var process = Process.Start(new ProcessStartInfo(daemon)
            {
                ArgumentList = { $"--config-file={configPath}", "--print-address", "--nofork" },
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
            }) ?? throw new InvalidOperationException("dbus-daemon did not start.");
            try
            {
                var address = await process.StandardOutput.ReadLineAsync().WaitAsync(Timeout);
                if (string.IsNullOrWhiteSpace(address))
                    throw new InvalidOperationException(
                        $"dbus-daemon printed no address: {await process.StandardError.ReadToEndAsync()}");
                return new PrivateBus(process, configPath, address.Trim());
            }
            catch
            {
                process.Kill(entireProcessTree: true);
                process.Dispose();
                File.Delete(configPath);
                throw;
            }
        }

        public void Dispose()
        {
            if (!_process.HasExited)
            {
                _process.Kill(entireProcessTree: true);
                _process.WaitForExit(Timeout);
            }
            _process.Dispose();
            File.Delete(_configPath);
        }
    }

    /// <summary>
    /// Just enough of org.freedesktop.portal.Desktop: app-id registration,
    /// GlobalShortcuts.CreateSession / BindShortcuts answered the portal way
    /// (return the request path, then emit Request.Response on it), Session.Close,
    /// and Activated on demand.
    /// </summary>
    private sealed class FakePortal : IPathMethodHandler, IDisposable
    {
        private const string DesktopPath = "/org/freedesktop/portal/desktop";
        private const string ShortcutsIface = "org.freedesktop.portal.GlobalShortcuts";

        private readonly DBusConnection _conn;
        private readonly uint _createSessionCode;
        private readonly uint _bindShortcutsCode;
        private readonly List<string> _calls = new();
        private readonly Lock _lock = new();

        private FakePortal(DBusConnection conn, uint createSessionCode, uint bindShortcutsCode)
        {
            _conn = conn;
            _createSessionCode = createSessionCode;
            _bindShortcutsCode = bindShortcutsCode;
        }

        public string Path => DesktopPath;
        // Session.Close arrives on the session's own path, below ours.
        public bool HandlesChildPaths => true;

        public string[] Calls
        {
            get { lock (_lock) return _calls.ToArray(); }
        }

        public string SessionHandle { get; private set; } = "";
        public string? RegisteredAppId { get; private set; }
        public string? BoundSession { get; private set; }
        public string? BoundShortcutId { get; private set; }
        public string? BoundTrigger { get; private set; }

        public static async Task<FakePortal> StartAsync(string address, uint createSessionCode, uint bindShortcutsCode)
        {
            var conn = new DBusConnection(address);
            try
            {
                await conn.ConnectAsync().AsTask().WaitAsync(Timeout);
                var portal = new FakePortal(conn, createSessionCode, bindShortcutsCode);
                conn.AddMethodHandler(portal);
                // Own the name before the hotkey can call it.
                await conn.RequestNameAsync("org.freedesktop.portal.Desktop").WaitAsync(Timeout);
                return portal;
            }
            catch
            {
                conn.Dispose();
                throw;
            }
        }

        public ValueTask HandleMethodAsync(MethodContext context)
        {
            var request = context.Request;
            var member = request.MemberAsString ?? "";
            lock (_lock) _calls.Add(member);

            switch ((request.InterfaceAsString, member))
            {
                case ("org.freedesktop.host.portal.Registry", "Register"):
                    RegisterAppId(context);
                    break;
                case (ShortcutsIface, "CreateSession"):
                    CreateSession(context);
                    break;
                case (ShortcutsIface, "BindShortcuts"):
                    BindShortcuts(context);
                    break;
                case ("org.freedesktop.portal.Session", "Close"):
                    ReplyEmpty(context);
                    break;
                default:
                    context.ReplyUnknownMethodError();
                    break;
            }
            return default;
        }

        private void RegisterAppId(MethodContext context)
        {
            var reader = context.Request.GetBodyReader();
            RegisteredAppId = reader.ReadString();
            ReplyEmpty(context);
        }

        private void CreateSession(MethodContext context)
        {
            var reader = context.Request.GetBodyReader();
            var options = reader.ReadDictionaryOfStringToVariantValue();
            var sender = SenderPathElement(context);
            SessionHandle = $"{DesktopPath}/session/{sender}/{options["session_handle_token"].GetString()}";

            var requestPath = ReplyWithRequestPath(context, options["handle_token"].GetString());
            EmitResponse(requestPath, _createSessionCode,
                _createSessionCode == 0
                    // Hyprland sends the handle as a string; the hotkey accepts either form.
                    ? new Dictionary<string, VariantValue> { ["session_handle"] = SessionHandle }
                    : new Dictionary<string, VariantValue>());
        }

        private void BindShortcuts(MethodContext context)
        {
            var reader = context.Request.GetBodyReader();
            BoundSession = reader.ReadObjectPathAsString();
            var shortcuts = reader.ReadArrayStart(DBusType.Struct);
            while (reader.HasNext(shortcuts))
            {
                reader.AlignStruct();
                BoundShortcutId = reader.ReadString();
                var props = reader.ReadDictionaryOfStringToVariantValue();
                BoundTrigger = props.TryGetValue("preferred_trigger", out var trigger) ? trigger.GetString() : null;
            }
            reader.ReadString(); // parent_window
            var options = reader.ReadDictionaryOfStringToVariantValue();

            var requestPath = ReplyWithRequestPath(context, options["handle_token"].GetString());
            EmitResponse(requestPath, _bindShortcutsCode, new Dictionary<string, VariantValue>());
        }

        public void EmitActivated(string sessionHandle, string shortcutId)
        {
            using var writer = _conn.GetMessageWriter();
            writer.WriteSignalHeader(path: DesktopPath, @interface: ShortcutsIface, member: "Activated", signature: "osta{sv}");
            writer.WriteObjectPath(sessionHandle);
            writer.WriteString(shortcutId);
            writer.WriteUInt64(0); // timestamp
            writer.WriteDictionary(new Dictionary<string, VariantValue>());
            Assert.True(_conn.TrySendMessage(writer.CreateMessage()), "Activated signal could not be sent.");
        }

        /// <summary>The portal's documented request path: sender without ':' and with '.' as '_', then the token.</summary>
        private static string ReplyWithRequestPath(MethodContext context, string handleToken)
        {
            var requestPath = $"{DesktopPath}/request/{SenderPathElement(context)}/{handleToken}";
            using var writer = context.CreateReplyWriter("o");
            writer.WriteObjectPath(requestPath);
            context.Reply(writer.CreateMessage());
            return requestPath;
        }

        private static string SenderPathElement(MethodContext context)
            => context.Request.SenderAsString![1..].Replace('.', '_');

        private static void ReplyEmpty(MethodContext context)
        {
            using var writer = context.CreateReplyWriter(null);
            context.Reply(writer.CreateMessage());
        }

        private void EmitResponse(string requestPath, uint code, Dictionary<string, VariantValue> results)
        {
            using var writer = _conn.GetMessageWriter();
            writer.WriteSignalHeader(path: requestPath, @interface: "org.freedesktop.portal.Request",
                member: "Response", signature: "ua{sv}");
            writer.WriteUInt32(code);
            writer.WriteDictionary(results);
            _conn.TrySendMessage(writer.CreateMessage());
        }

        public void Dispose() => _conn.Dispose();
    }
}
