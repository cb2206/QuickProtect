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

    private readonly Action _onTriggered;
    // Serializes UpdateAsync runs; _generation lets a newer Update supersede a
    // stalled one (e.g. the user re-records while a bind dialog sits unanswered).
    private readonly SemaphoreSlim _gate = new(1, 1);
    // Our own bus connection (the shared Connection.Session forbids explicit
    // ConnectAsync); the portal reaps the session when this connection drops.
    private Connection? _conn;
    private int _generation;
    private string? _sessionHandle;
    private IDisposable? _activatedMatch;
    private TaskCompletionSource<(uint Code, Dictionary<string, VariantValue> Results)>? _pending;

    public PortalGlobalHotkey(Action onTriggered) => _onTriggered = onTriggered;

    public void Update(int? keyCode, int? modifiers)
    {
        var gen = Interlocked.Increment(ref _generation);
        _pending?.TrySetCanceled();
        _ = Task.Run(() => UpdateAsync(gen, keyCode, modifiers));
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
                _conn = new Connection(Address.Session!);
                await _conn.ConnectAsync();
            }
            var conn = _conn;

            // 1. CreateSession → the portal session all shortcuts live in.
            var sessionToken = NewToken();
            var (code, results) = await PortalRequestAsync(
                conn, CreateSessionMessage(conn, sessionToken), sessionToken);
            if (code != 0 || !results.TryGetValue("session_handle", out var handle))
            {
                Log.Line($"[Hotkey] portal CreateSession failed (response {code}).");
                return;
            }
            _sessionHandle = AsPath(handle);

            // 2. Listen for activations before binding, so no press is missed.
            _activatedMatch = await conn.AddMatchAsync(
                new MatchRule
                {
                    Type = MessageType.Signal, Sender = Service, Path = DesktopPath,
                    Interface = ShortcutsIface, Member = "Activated",
                },
                static (m, _) =>
                {
                    var r = m.GetBodyReader();
                    return (Session: r.ReadObjectPath().ToString(), Id: r.ReadString());
                },
                (ex, a, _, _) =>
                {
                    if (ex is null && a.Session == _sessionHandle && a.Id == ShortcutId)
                        Dispatcher.UIThread.Post(_onTriggered);
                },
                ObserverFlags.None);

            // 3. BindShortcuts — the compositor may show a one-time consent
            // dialog; the response reports the trigger it actually granted.
            var bindToken = NewToken();
            var trigger = HotkeyCodec.PortalTrigger(keyCode.Value, modifiers ?? 0);
            var (bindCode, bindResults) = await PortalRequestAsync(
                conn, BindShortcutsMessage(conn, _sessionHandle, trigger, bindToken), bindToken);
            if (bindCode != 0)
            {
                // 1 = the user dismissed the consent dialog, 2 = other failure.
                Log.Line($"[Hotkey] portal BindShortcuts declined (response {bindCode}).");
                await CloseSessionAsync();
                return;
            }
            Log.Line($"[Hotkey] bound via portal: {DescribeBoundTrigger(bindResults)}");
        }
        catch (OperationCanceledException)
        {
            // Superseded by a newer Update (or disposed) while awaiting the portal.
        }
        catch (Exception e)
        {
            Log.Line($"[Hotkey] portal GlobalShortcuts unavailable — global hotkey disabled ({e.Message}).");
        }
        finally
        {
            _gate.Release();
        }
    }

    private static MessageBuffer CreateSessionMessage(Connection conn, string handleToken)
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
        Connection conn, string session, string trigger, string handleToken)
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

    private static MessageBuffer CloseSessionMessage(Connection conn, string session)
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
        Connection conn, MessageBuffer call, string handleToken)
    {
        var sender = conn.UniqueName![1..].Replace('.', '_');
        var requestPath = $"{DesktopPath}/request/{sender}/{handleToken}";
        var tcs = new TaskCompletionSource<(uint, Dictionary<string, VariantValue>)>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        _pending = tcs;
        using var match = await conn.AddMatchAsync(
            new MatchRule
            {
                Type = MessageType.Signal, Sender = Service, Path = requestPath,
                Interface = "org.freedesktop.portal.Request", Member = "Response",
            },
            static (m, _) =>
            {
                var r = m.GetBodyReader();
                return (r.ReadUInt32(), r.ReadDictionaryOfStringToVariantValue());
            },
            (ex, arg, _, _) =>
            {
                if (ex is null) tcs.TrySetResult(arg);
                else tcs.TrySetException(ex);
            },
            ObserverFlags.None);
        var returned = await conn.CallMethodAsync(call,
            static (m, _) => m.GetBodyReader().ReadObjectPath().ToString(), null);
        if (returned != requestPath)
            Log.Line($"[Hotkey] portal returned a legacy request path ({returned}) — response may be missed.");
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
            Log.Line($"[Hotkey] portal session close: {e.Message}");
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
