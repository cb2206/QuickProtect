using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Platform;

/// <summary>
/// Routes SIGTERM, SIGINT and SIGHUP into the app's own quit path.
///
/// The runtime's default for those signals is to run ProcessExit handlers and
/// then call <c>exit()</c>. Avalonia is never told to stop, so the C runtime's
/// exit handlers tear down Skia and the GL driver while the render thread is
/// still drawing through them. That race segfaults inside Mesa on roughly one
/// termination in three — two cores captured on Hyprland/virgl carry identical
/// faulting frames, one thread in <c>__run_exit_handlers</c> and the render
/// thread mid-call in the driver. The same shortcut skips Avalonia's
/// <c>Exit</c> event, so the server-side stream allocations
/// <c>App.OnExit</c> releases are left behind on the controller.
///
/// Cancelling the runtime's default and quitting through
/// <c>desktop.Shutdown()</c> — the tray Quit item's path — stops the renderer
/// first and lets <c>Exit</c> run.
///
/// A signal must still be final, so the graceful attempt is bounded: if it has
/// not finished within <see cref="GracePeriod"/>, or a second signal arrives,
/// the process leaves through <c>_exit()</c>, which terminates without running
/// the exit handlers that caused the crash to begin with. Nothing is lost that
/// way — preferences are written on every change, not buffered until quit.
/// </summary>
[SupportedOSPlatform("linux")]
internal static class LinuxTerminationSignal
{
    /// <summary>
    /// How long a graceful quit gets before the process is taken down. A real
    /// quit runs 1-4 seconds here — App.OnExit alone waits up to two of them
    /// for the controller to accept the stream DELETEs — so the bound sits well
    /// clear of that, and still well inside what systemd waits before it sends
    /// SIGKILL. Firing this timer during an honest quit would abandon exactly
    /// the cleanup the graceful path exists to run.
    /// </summary>
    internal static readonly TimeSpan GracePeriod = TimeSpan.FromSeconds(10);

    private static readonly PosixSignal[] TerminationSignals =
    {
        PosixSignal.SIGTERM, PosixSignal.SIGINT, PosixSignal.SIGHUP,
    };

    /// <summary>
    /// Ends the process immediately, without running the C exit handlers —
    /// <c>Environment.Exit</c> would run exactly the ones this class exists to
    /// stay out of.
    /// </summary>
    [DllImport("libc", EntryPoint = "_exit")]
    private static extern void Exit(int status);

    /// <summary>
    /// Installs the handlers. The result holds them for as long as the app
    /// should answer signals — for the process's lifetime, in practice.
    /// </summary>
    internal static IDisposable Install(Action requestShutdown)
        => Install(requestShutdown, GracePeriod, status =>
        {
            Log.Line("[Quit] terminating without waiting for the shutdown to finish");
            Exit(status);
        });

    /// <summary>
    /// The testable form: takes the grace period and the way out, so a test can
    /// signal the process for real without ending the test run.
    /// </summary>
    internal static IDisposable Install(Action requestShutdown, TimeSpan grace, Action<int> hardExit)
    {
        var quitting = 0;
        var registrations = TerminationSignals.Select(signal => PosixSignalRegistration.Create(signal, context =>
        {
            // The runtime's own handler is the one that calls exit().
            context.Cancel = true;

            if (Interlocked.Exchange(ref quitting, 1) == 1)
            {
                // Signalled twice: whoever is asking has stopped waiting.
                hardExit(0);
                return;
            }

            requestShutdown();
            StartWatchdog(grace, hardExit);
        })).ToArray();

        return new Handlers(registrations);
    }

    /// <summary>
    /// Insurance against a quit that never finishes: a wedged UI thread must
    /// not leave the app answerable to nothing but SIGKILL.
    ///
    /// Its own thread rather than a timer, because shutdown is exactly when the
    /// thread pool is busiest — a queued continuation is not guaranteed to run
    /// anywhere near its due time, and this one is the last resort.
    /// </summary>
    private static void StartWatchdog(TimeSpan grace, Action<int> hardExit)
    {
        var watchdog = new Thread(() =>
        {
            Thread.Sleep(grace);
            hardExit(0);
        })
        {
            IsBackground = true, // a quit that finishes in time must not wait on this
            Name = "QuickProtect shutdown watchdog",
        };
        watchdog.Start();
    }

    private sealed class Handlers : IDisposable
    {
        private readonly PosixSignalRegistration[] _registrations;

        internal Handlers(PosixSignalRegistration[] registrations) => _registrations = registrations;

        public void Dispose()
        {
            foreach (var registration in _registrations) registration.Dispose();
        }
    }
}
