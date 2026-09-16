using System.Net.Sockets;
using System.Runtime.Versioning;
using QuickProtect.App.Platform;
using Xunit;

namespace QuickProtect.App.Tests;

/// <summary>
/// Covers the two Linux-only pieces that keep the tray agent reachable: the
/// status it publishes to the tray host, and the arbitration that keeps a
/// second launch from becoming a second agent.
///
/// Every test is a no-op off Linux. The class carries
/// <c>[SupportedOSPlatform("linux")]</c> so the call sites compile warning-free
/// under TreatWarningsAsErrors; the guard inside each test is what actually
/// keeps the Windows CI leg from touching them.
/// </summary>
[SupportedOSPlatform("linux")]
public class PlatformSignalTests
{
    /// <summary>
    /// <see cref="LinuxTrayStatus"/> corrects Avalonia's invalid tray status
    /// through private fields, so an Avalonia upgrade can silently disarm it.
    /// This is the tripwire: it fails on the bump, not in a user's empty tray.
    /// </summary>
    [Fact]
    public void TrayStatusWorkaroundStillFindsAvaloniaInternals()
    {
        if (!OperatingSystem.IsLinux()) return;

        var binding = LinuxTrayStatus.ResolveBinding();

        Assert.NotNull(binding);
        Assert.Equal(typeof(string), binding.StatusProperty.PropertyType);
        Assert.True(binding.StatusProperty.CanWrite);
    }

    /// <summary>The only launch around owns the tray.</summary>
    [Fact]
    public void LoneLaunchBecomesPrimary()
    {
        if (!OperatingSystem.IsLinux()) return;

        RunIsolated(_ =>
        {
            using var lone = new LinuxSingleInstance();
            Assert.True(lone.IsPrimary);
        });
    }

    /// <summary>
    /// The heart of it: a second launch must stand down and raise the running
    /// instance's panel instead of starting a second tray agent.
    /// </summary>
    [Fact]
    public void DuplicateLaunchStandsDownAndRaisesTheRunningInstance()
    {
        if (!OperatingSystem.IsLinux()) return;

        RunIsolated(_ =>
        {
            using var running = new LinuxSingleInstance();
            using var raised = new ManualResetEventSlim(false);
            Assert.True(running.IsPrimary);
            running.OnRaiseRequested(() => raised.Set());

            using var duplicate = new LinuxSingleInstance();

            Assert.False(duplicate.IsPrimary, "a second launch claimed the tray for itself");
            Assert.True(duplicate.RaiseRunningInstance(), "the running instance did not accept the nudge");
            Assert.True(raised.Wait(TimeSpan.FromSeconds(5)), "the nudge never reached the panel");
        });
    }

    /// <summary>
    /// Disposing the duplicate must leave the running instance's socket intact,
    /// or the launch after it would find nobody home.
    /// </summary>
    [Fact]
    public void DisposingTheDuplicateLeavesTheRunningInstanceReachable()
    {
        if (!OperatingSystem.IsLinux()) return;

        RunIsolated(_ =>
        {
            using var running = new LinuxSingleInstance();
            running.OnRaiseRequested(() => { });

            using (var duplicate = new LinuxSingleInstance())
                Assert.True(duplicate.RaiseRunningInstance());

            using var third = new LinuxSingleInstance();
            Assert.False(third.IsPrimary, "the duplicate's disposal unlinked the live socket");
            Assert.True(third.RaiseRunningInstance());
        });
    }

    /// <summary>
    /// A hard kill leaves the socket path occupied with nothing listening
    /// (a clean shutdown unlinks it — .NET removes the file on Dispose). The
    /// next launch must take the path over rather than refuse to start. A
    /// leftover plain file stands in for the orphaned socket: both fail the
    /// connect probe, which is the branch under test.
    /// </summary>
    [Fact]
    public void LeftoverSocketPathDoesNotBlockTheNextLaunch()
    {
        if (!OperatingSystem.IsLinux()) return;

        RunIsolated(_ =>
        {
            File.WriteAllText(LinuxSingleInstance.SocketPath, "not a socket");

            using var next = new LinuxSingleInstance();

            Assert.True(next.IsPrimary, "a leftover file locked the app out");
            // And the path is a working socket again, not the leftover.
            using var duplicate = new LinuxSingleInstance();
            Assert.False(duplicate.IsPrimary);
        });
    }

    /// <summary>
    /// Points the socket at a scratch directory: the real path is shared with
    /// whatever QuickProtect the developer has running, and binding there would
    /// unlink its socket out from under it.
    /// </summary>
    private static void RunIsolated(Action<string> body)
    {
        var previous = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
        var sandbox = Directory.CreateTempSubdirectory("qp-singleinstance-test");
        Environment.SetEnvironmentVariable("XDG_RUNTIME_DIR", sandbox.FullName);
        try
        {
            body(sandbox.FullName);
        }
        finally
        {
            Environment.SetEnvironmentVariable("XDG_RUNTIME_DIR", previous);
            sandbox.Delete(recursive: true);
        }
    }
}
