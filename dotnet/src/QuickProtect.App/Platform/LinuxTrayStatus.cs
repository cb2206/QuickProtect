using System.Reflection;
using System.Runtime.Versioning;
using Avalonia.Controls;
using Avalonia.Threading;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Platform;

/// <summary>
/// Forces the freedesktop tray item's <c>Status</c> property to the
/// spec-mandated <c>"Active"</c>.
///
/// Avalonia 11.3.x never writes a valid status: what reaches the bus is the tray
/// icon's title/tooltip string (QuickProtect publishes <c>Status="QuickProtect"</c>).
/// StatusNotifierItem hosts that follow the spec — quickshell, waybar, KDE —
/// treat anything other than "Active" or "NeedsAttention" as "Passive" and
/// hide the item, so the icon silently never appears.
///
/// Upstream is AvaloniaUI/Avalonia#22218, closed as not-planned: the bug was
/// fixed incidentally on main by PR #21472 (a Tmds.DBus refactor) and ships
/// from 12.1.0, but the maintainers have declined to backport DBus changes to
/// the 11.3.x line — which includes the 11.3.19 this app pins and the latest
/// 11.3.22. So the escape from this workaround is the 12.x upgrade, not a
/// patch release.
///
/// The property lives on a private D-Bus object Avalonia owns and exposes no
/// public setter, so reflection is the only correction available from outside
/// the framework. If a future Avalonia moves those internals, the lookup fails
/// and we log and stand down rather than fighting it — see
/// <see cref="ResolveBinding"/>, which the test suite pins so the breakage
/// surfaces on an Avalonia bump instead of in a user's empty tray.
/// </summary>
[SupportedOSPlatform("linux")]
internal static class LinuxTrayStatus
{
    private const string ActiveStatus = "Active";
    /// <summary>Until the host connects there is nothing to correct; poll briskly so the icon appears promptly.</summary>
    private static readonly TimeSpan StartupInterval = TimeSpan.FromMilliseconds(500);
    /// <summary>Once corrected, only a tray-host restart can clobber it again — that needs no urgency.</summary>
    private static readonly TimeSpan HealInterval = TimeSpan.FromSeconds(15);

    /// <summary>Rooted so the dispatcher's timer is not collected while the app runs.</summary>
    private static DispatcherTimer? _timer;

    /// <summary>The Avalonia internals this workaround reaches through.</summary>
    internal sealed record Binding(
        FieldInfo ImplField,
        Type ImplType,
        FieldInfo DbusObjectField,
        PropertyInfo StatusProperty,
        MethodInfo InvalidateAll);

    /// <summary>
    /// Locates <c>TrayIcon._impl</c> → <c>DBusTrayIconImpl._statusNotifierItemDbusObj</c>
    /// → its writable <c>Status</c> property and <c>InvalidateAll()</c>.
    /// Returns null if any link of that chain has moved.
    /// </summary>
    internal static Binding? ResolveBinding()
    {
        var implField = typeof(TrayIcon).GetField("_impl", BindingFlags.Instance | BindingFlags.NonPublic);
        if (implField is null) return null;

        // Loaded already when a tray exists; the qualified lookup covers the
        // test, which pins this chain without ever building one.
        const string implTypeName = "Avalonia.FreeDesktop.DBusTrayIconImpl";
        var implType = AppDomain.CurrentDomain.GetAssemblies()
                           .Select(assembly => assembly.GetType(implTypeName))
                           .FirstOrDefault(type => type is not null)
                       ?? Type.GetType($"{implTypeName}, Avalonia.FreeDesktop");
        if (implType is null) return null;

        var dbusObjectField = implType.GetField("_statusNotifierItemDbusObj", BindingFlags.Instance | BindingFlags.NonPublic);
        if (dbusObjectField is null) return null;

        // Status is declared on the generated Tmds handler the D-Bus object derives from.
        var statusProperty = dbusObjectField.FieldType.GetProperty("Status",
            BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
        if (statusProperty is null || !statusProperty.CanWrite || statusProperty.PropertyType != typeof(string)) return null;

        var invalidateAll = dbusObjectField.FieldType.GetMethod("InvalidateAll",
            BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic, Type.EmptyTypes);
        if (invalidateAll is null) return null;

        return new Binding(implField, implType, dbusObjectField, statusProperty, invalidateAll);
    }

    /// <summary>
    /// Starts correcting <paramref name="tray"/>'s published status, and keeps
    /// correcting it: the tray host disappearing and coming back (a bar reload)
    /// makes Avalonia rebuild the item with the same bad value.
    /// </summary>
    internal static void KeepActive(TrayIcon tray)
    {
        var binding = ResolveBinding();
        if (binding is null)
        {
            Log.Line("[Tray] Avalonia's status-notifier internals have moved; leaving the published status alone. " +
                     "The tray icon will stay hidden on spec-compliant hosts until this workaround is updated.");
            return;
        }

        object? corrected = null;
        _timer = new DispatcherTimer(StartupInterval, DispatcherPriority.Background, (_, _) =>
        {
            try
            {
                if (!TryCorrect(tray, binding, ref corrected)) return;
                // Corrected at least once: the remaining job is only to heal a host restart.
                if (_timer is { } timer) timer.Interval = HealInterval;
            }
            catch (Exception ex) when (ex is TargetInvocationException or MemberAccessException or InvalidOperationException)
            {
                // Reaching into another library's internals is inherently brittle; a
                // failure here means the shape changed under us. Say so once and stop,
                // rather than logging on every tick forever.
                Log.Line($"[Tray] could not publish an Active status ({ex.GetType().Name}: {ex.Message}); giving up.");
                _timer?.Stop();
            }
        });
        _timer.Start();
    }

    /// <summary>
    /// Writes "Active" if the item exists and does not already say so.
    /// Returns true once the live item carries the correct status.
    /// </summary>
    private static bool TryCorrect(TrayIcon tray, Binding binding, ref object? corrected)
    {
        var impl = binding.ImplField.GetValue(tray);
        // A non-D-Bus backend (or a tray not built yet) is not ours to fix.
        if (impl is null || !binding.ImplType.IsInstanceOfType(impl)) return false;

        var dbusObject = binding.DbusObjectField.GetValue(impl);
        // Null until the StatusNotifierWatcher shows up on the bus.
        if (dbusObject is null) return false;

        var current = binding.StatusProperty.GetValue(dbusObject) as string;
        // Same object, already correct: nothing to do and nothing to announce.
        if (ReferenceEquals(dbusObject, corrected) && current == ActiveStatus) return true;

        binding.StatusProperty.SetValue(dbusObject, ActiveStatus);
        binding.InvalidateAll.Invoke(dbusObject, null);
        corrected = dbusObject;
        Log.Line($"[Tray] published status corrected to \"{ActiveStatus}\" (Avalonia had set \"{current}\")");
        return true;
    }
}
