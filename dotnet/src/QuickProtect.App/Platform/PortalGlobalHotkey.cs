using System.Runtime.Versioning;
using Avalonia.Threading;
using QuickProtect.Core.Services;
using Tmds.DBus.Protocol;

namespace QuickProtect.App.Platform;

/// <summary>
/// Linux global hotkey via the XDG Desktop Portal (org.freedesktop.portal.
/// GlobalShortcuts — GNOME 45+ and KDE Plasma 5.27+, Wayland and X11 alike).
/// The compositor owns the actual grab: BindShortcuts asks it to bind our
/// stored combo (the first request per app shows a system confirmation
/// dialog), and it raises an Activated signal whenever the user presses the
/// key, panel visibility and app focus notwithstanding. Environments without
/// the portal (bare X11 window managers) log and stay a documented no-op —
/// see PARITY.md.
/// </summary>
[SupportedOSPlatform("linux")]
public sealed class PortalGlobalHotkey : IGlobalHotkey
{
    private const string Service = "org.freedesktop.portal.Desktop";
    private const string DesktopPath = "/org/freedesktop/portal/desktop";
    private const string ShortcutsIface = "org.freedesktop.portal.GlobalShortcuts";
    private const string ShortcutId = "toggle-panel";
    /// <summary>
    /// Our desktop-entry id (quickprotect.desktop, shipped in the Linux tarball).
    /// Declared to the portal so the shortcut is always "quickprotect:toggle-panel",
    /// however the app was launched — see <see cref="RegisterAppIdAsync"/>.
    /// </summary>
    internal const string AppId = "quickprotect";

    private readonly Action _onTriggered;
    // Injected only by the tests (see the internal constructor); production uses
    // the session bus, Avalonia's UI thread and the shared log.
    private readonly string? _busAddress;
    private readonly Action<Action> _dispatch;
    private readonly Action<string> _log;
    // Serializes UpdateAsync runs; _generation lets a newer Update supersede a
    // stalled one (e.g. the user re-records while a bind dialog sits unanswered).
    private readonly SemaphoreSlim _gate = new(1, 1);
    // Our own bus connection: we need an explicit ConnectAsync, and
    // the portal reaps the session when this connection drops.
    private DBusConnection? _conn;
    private int _generation;
    private string? _sessionHandle;
    private IDisposable? _activatedMatch;
    private TaskCompletionSource<(uint Code, Dictionary<string, VariantValue> Results)>? _pending;

    public PortalGlobalHotkey(Action onTriggered)
        : this(onTriggered, busAddress: null, dispatch: static action => Dispatcher.UIThread.Post(action), log: Log.Line)
    {
    }

    /// <summary>
    /// Test seam: a private bus instead of the session bus, a dispatch that does
    /// not need a running Avalonia UI thread, and a log sink to assert on.
    /// </summary>
    internal PortalGlobalHotkey(Action onTriggered, string? busAddress, Action<Action> dispatch, Action<string> log)
    {
        _onTriggered = onTriggered;
        _busAddress = busAddress;
        _dispatch = dispatch;
        _log = log;
    }

    /// <summary>The most recent Update's portal exchange, so tests can await it.</summary>
    internal Task LastUpdate { get; private set; } = Task.CompletedTask;

    public bool Update(int? keyCode, int? modifiers)
    {
        var gen = Interlocked.Increment(ref _generation);
        _pending?.TrySetCanceled();
        LastUpdate = Task.Run(() => UpdateAsync(gen, keyCode, modifiers));
        // The compositor owns the binding and answers asynchronously (possibly
        // via a consent dialog); the granted trigger is logged when it arrives.
        return true;
    }

    private async Task UpdateAsync(int gen, int? keyCode, int? modifiers)
    {
        await _gate.WaitAsync();
        try
        {
            if (gen != _generation) return; // superseded while queued
            await CloseSessionAsync();
            if (keyCode is null) return;

            if (_conn is null)
            {
                _conn = new DBusConnection(_busAddress ?? DBusAddress.Session!);
                await _conn.ConnectAsync();
                // Must precede every other portal call on this connection.
                await RegisterAppIdAsync(_conn);
            }
            var conn = _conn;

            // 1. CreateSession → the portal session all shortcuts live in.
            var sessionToken = NewToken();
            var (code, results) = await PortalRequestAsync(
                conn, CreateSessionMessage(conn, sessionToken), sessionToken);
            if (code != 0 || !results.TryGetValue("session_handle", out var handle))
            {
                _log($"[Hotkey] portal CreateSession failed (response {code}).");
                return;
            }
            _sessionHandle = AsPath(handle);

            // 2. Listen for activations before binding, so no press is missed.
            _activatedMatch = await conn.AddMatchAsync(
                new MatchRule
                {
                    Type = MessageType.Signal,
                    Sender = Service,
                    Path = DesktopPath,
                    Interface = ShortcutsIface,
                    Member = "Activated",
                },
                static (m, _) =>
                {
                    var r = m.GetBodyReader();
                    return (Session: r.ReadObjectPath().ToString(), Id: r.ReadString());
                },
                // Handlers must not throw: Tmds disconnects the whole connection if
                // one does. Notification.Exception throws unless IsCompletion, so
                // branch on HasValue/IsCompletion and never touch Exception first.
                n =>
                {
                    if (n.HasValue && n.Value.Session == _sessionHandle && n.Value.Id == ShortcutId)
                        _dispatch(_onTriggered);
                },
                flags: ObserverFlags.None);

            // 3. BindShortcuts — the compositor may show a one-time consent
            // dialog; the response reports the trigger it actually granted.
            var bindToken = NewToken();
            var trigger = HotkeyCodec.PortalTrigger(keyCode.Value, modifiers ?? 0);
            var (bindCode, bindResults) = await PortalRequestAsync(
                conn, BindShortcutsMessage(conn, _sessionHandle, trigger, bindToken), bindToken);
            if (bindCode != 0)
            {
                // 1 = the user dismissed the consent dialog, 2 = other failure.
                _log($"[Hotkey] portal BindShortcuts declined (response {bindCode}).");
                await CloseSessionAsync();
                return;
            }
            _log($"[Hotkey] bound via portal: {DescribeBoundTrigger(bindResults)}");
        }
        catch (OperationCanceledException)
        {
            // Superseded by a newer Update (or disposed) while awaiting the portal.
        }
        catch (Exception e)
        {
            _log($"[Hotkey] portal GlobalShortcuts unavailable — global hotkey disabled ({e.Message}).");
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    /// Tells the portal which app this unsandboxed connection belongs to. Without
    /// it the portal infers the id from the launching process's scope, so the
    /// shortcut id changes with how QuickProtect was started — launched from a
    /// terminal it belongs to the terminal — and a compositor bind written against
    /// one id (Hyprland needs one: it registers portal shortcuts but never assigns
    /// keys) silently stops matching after the next launch.
    ///
    /// The portal only accepts an id it can resolve to an installed desktop entry,
    /// so a checkout run without quickprotect.desktop installed gets refused. That
    /// is not fatal: the portal falls back to its own inference, as before.
    /// </summary>
    private async Task RegisterAppIdAsync(DBusConnection conn)
    {
        try
        {
            await conn.CallMethodAsync(RegisterAppIdMessage(conn));
            _log($"[Hotkey] registered with the portal as \"{AppId}\" — shortcut id \"{AppId}:{ShortcutId}\"");
        }
        catch (DBusErrorReplyException e)
        {
            _log($"[Hotkey] portal did not accept app id \"{AppId}\" ({e.ErrorMessage}); the shortcut id will " +
                     $"depend on how QuickProtect was launched. Installing {AppId}.desktop into " +
                     "~/.local/share/applications makes it stable.");
        }
    }

    private static MessageBuffer RegisterAppIdMessage(DBusConnection conn)
    {
        using var w = conn.GetMessageWriter();
        w.WriteMethodCallHeader(destination: Service, path: DesktopPath,
            @interface: "org.freedesktop.host.portal.Registry", member: "Register", signature: "sa{sv}");
        w.WriteString(AppId);
        w.WriteDictionary(new Dictionary<string, VariantValue>());
        return w.CreateMessage();
    }

    private static MessageBuffer CreateSessionMessage(DBusConnection conn, string handleToken)
    {
        using var w = conn.GetMessageWriter();
        w.WriteMethodCallHeader(destination: Service, path: DesktopPath,
            @interface: ShortcutsIface, member: "CreateSession", signature: "a{sv}");
        w.WriteDictionary(new Dictionary<string, VariantValue>
        {
            ["handle_token"] = handleToken,
            ["session_handle_token"] = "quickprotect",
        });
        return w.CreateMessage();
    }

    private static MessageBuffer BindShortcutsMessage(
        DBusConnection conn, string session, string trigger, string handleToken)
    {
        using var w = conn.GetMessageWriter();
        w.WriteMethodCallHeader(destination: Service, path: DesktopPath,
            @interface: ShortcutsIface, member: "BindShortcuts", signature: "oa(sa{sv})sa{sv}");
        w.WriteObjectPath(session);
        var shortcuts = w.WriteArrayStart(DBusType.Struct);
        w.WriteStructureStart();
        w.WriteString(ShortcutId);
        w.WriteDictionary(new Dictionary<string, VariantValue>
        {
            ["description"] = Localization.Loc.Get("Toggle QuickProtect"),
            ["preferred_trigger"] = trigger,
        });
        w.WriteArrayEnd(shortcuts);
        w.WriteString(""); // parent_window: no exportable window handle
        w.WriteDictionary(new Dictionary<string, VariantValue> { ["handle_token"] = handleToken });
        return w.CreateMessage();
    }

    private static MessageBuffer CloseSessionMessage(DBusConnection conn, string session)
    {
        using var w = conn.GetMessageWriter();
        w.WriteMethodCallHeader(destination: Service, path: session,
            @interface: "org.freedesktop.portal.Session", member: "Close");
        return w.CreateMessage();
    }

    /// <summary>
    /// Sends a portal method call and awaits the matching Response signal.
    /// Subscribes on the predictable request path derived from handle_token
    /// before sending (the portal-documented way to avoid the reply race).
    /// </summary>
    private async Task<(uint Code, Dictionary<string, VariantValue> Results)> PortalRequestAsync(
        DBusConnection conn, MessageBuffer call, string handleToken)
    {
        var sender = conn.UniqueName![1..].Replace('.', '_');
        var requestPath = $"{DesktopPath}/request/{sender}/{handleToken}";
        var tcs = new TaskCompletionSource<(uint, Dictionary<string, VariantValue>)>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        _pending = tcs;
        using var match = await conn.AddMatchAsync(
            new MatchRule
            {
                Type = MessageType.Signal,
                Sender = Service,
                Path = requestPath,
                Interface = "org.freedesktop.portal.Request",
                Member = "Response",
            },
            static (m, _) =>
            {
                var r = m.GetBodyReader();
                return (r.ReadUInt32(), r.ReadDictionaryOfStringToVariantValue());
            },
            n =>
            {
                if (n.IsCompletion) tcs.TrySetException(n.Exception);
                else tcs.TrySetResult(n.Value);
            },
            flags: ObserverFlags.None);
        var returned = await conn.CallMethodAsync(call,
            static (m, _) => m.GetBodyReader().ReadObjectPath().ToString(), null);
        if (returned != requestPath)
            _log($"[Hotkey] portal returned a legacy request path ({returned}) — response may be missed.");
        try
        {
            return await tcs.Task;
        }
        finally
        {
            if (ReferenceEquals(_pending, tcs)) _pending = null;
        }
    }

    private async Task CloseSessionAsync()
    {
        _activatedMatch?.Dispose();
        _activatedMatch = null;
        if (_sessionHandle is not { } session || _conn is not { } conn) return;
        _sessionHandle = null;
        try
        {
            await conn.CallMethodAsync(CloseSessionMessage(conn, session));
        }
        catch (Exception e)
        {
            // Best-effort: the portal also reaps sessions when we disconnect.
            _log($"[Hotkey] portal session close: {e.Message}");
        }
    }

    public void Dispose()
    {
        Interlocked.Increment(ref _generation);
        _pending?.TrySetCanceled();
        _ = Task.Run(async () =>
        {
            await _gate.WaitAsync();
            try { await CloseSessionAsync(); }
            finally
            {
                _gate.Release();
                // Dropping the connection lets the portal reap anything left.
                _conn?.Dispose();
                _conn = null;
            }
        });
    }

    /// <summary>Handle tokens must be unique per request and free of '.'/'/'.</summary>
    private static string NewToken() => "qp" + Guid.NewGuid().ToString("N");

    /// <summary>Portals return session handles as 's' or 'o' depending on version.</summary>
    private static string AsPath(VariantValue v)
        => v.Type == VariantValueType.ObjectPath ? v.GetObjectPathAsString() : v.GetString();

    /// <summary>The compositor-granted trigger from the BindShortcuts results, for the log.</summary>
    private static string DescribeBoundTrigger(Dictionary<string, VariantValue> results)
    {
        if (results.TryGetValue("shortcuts", out var shortcuts) && shortcuts.Count > 0)
        {
            var props = shortcuts.GetItem(0).GetItem(1).GetDictionary<string, VariantValue>();
            if (props.TryGetValue("trigger_description", out var trigger))
                return trigger.GetString();
        }
        return "(trigger not reported)";
    }
}
