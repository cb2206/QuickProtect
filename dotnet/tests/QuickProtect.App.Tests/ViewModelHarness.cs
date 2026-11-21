using System.Diagnostics;
using Avalonia.Threading;
using QuickProtect.App.Video;
using QuickProtect.App.ViewModels;
using QuickProtect.Core.Models;
using QuickProtect.Core.Services;
using QuickProtect.Core.Tests;

namespace QuickProtect.App.Tests;

/// <summary>
/// What the view models need without a running app: settings over in-memory
/// stores, a real <see cref="ProtectHub"/> whose one site talks to a scripted
/// console (<see cref="FakeProtectConsole"/>, shared with the Core tests), and
/// a dispatcher pump for the work the view models post to the UI thread.
/// Use it inside <see cref="UiThread.Run"/>.
/// </summary>
internal sealed class ViewModelHarness : IDisposable
{
    /// <summary>
    /// Tiles acquire streams from this coordinator instead of the app's. Its
    /// allocator never grants a stream and its clients never open FFmpeg, so
    /// a tile can start whether or not another test loaded the engine.
    /// </summary>
    private static readonly VideoStreamCoordinator Streams = new(new NoStreams())
    {
        ClientFactory = static () => new VideoStreamClient { SessionOverride = static _ => false }
    };

    static ViewModelHarness() => CameraTileViewModel.Streams = static () => Streams;

    private sealed class NoStreams : IStreamAllocator
    {
        public Task<(string url, string quality)?> CreateRtspStreamUrlAsync(Camera camera, string quality)
            => Task.FromResult<(string url, string quality)?>(null);
        public Task<(string url, string quality)?> CreatePinnedStreamUrlAsync(Camera camera, string quality)
            => Task.FromResult<(string url, string quality)?>(null);
        public void ReleaseStream(string cameraId, string quality) { }
        public void ReleasePinnedStream(string cameraId, string quality) { }
    }

    public FakeProtectConsole Console { get; } = new();
    public InMemoryPreferences Prefs { get; } = new();
    public InMemorySecretStore Secrets { get; } = new();
    public AppSettings Settings { get; }
    public CertificateTrust Trust { get; } = new(new InMemoryPreferences());
    public ProtectHub Hub { get; }
    public ControllerSite Site => Settings.Sites[0];

    /// <param name="cameras">The Integration API's camera list (the console's default when null).</param>
    /// <param name="fetch">Fetch the camera list before returning, so view models start with cameras.</param>
    public ViewModelHarness(string? cameras = null, string username = "", string password = "", bool fetch = true)
    {
        // Bind the dispatcher to this (the UI) thread before anything posts to it.
        Dispatcher.UIThread.RunJobs();
        if (cameras != null) Console.IntegrationBody = cameras;
        Settings = new AppSettings(Prefs, Secrets);
        Site.IpAddress = Console.Address;
        Site.ApiKey = "test-api-key";
        Site.Username = username;
        Site.Password = password;
        Hub = new ProtectHub(Settings, site => new ProtectService(site, Trust));
        if (fetch) Refetch();
    }

    /// <summary>A forced fetch of every site, then the UI work it posted.</summary>
    public void Refetch() => Pump(Hub.FetchCamerasAsync(forced: true));

    /// <summary>Runs posted UI work until <paramref name="task"/> completes, then rethrows its failure.</summary>
    public static void Pump(Task task, int timeoutMs = 15_000)
    {
        var clock = Stopwatch.StartNew();
        while (!task.IsCompleted)
        {
            Dispatcher.UIThread.RunJobs();
            if (clock.ElapsedMilliseconds > timeoutMs) throw new TimeoutException("task did not complete");
            Thread.Sleep(5);
        }
        Dispatcher.UIThread.RunJobs();
        task.GetAwaiter().GetResult();
    }

    /// <summary>Runs posted UI work until <paramref name="condition"/> holds.</summary>
    public static void PumpUntil(Func<bool> condition, int timeoutMs = 15_000)
    {
        var clock = Stopwatch.StartNew();
        while (true)
        {
            Dispatcher.UIThread.RunJobs();
            if (condition()) return;
            if (clock.ElapsedMilliseconds > timeoutMs) throw new TimeoutException("condition not met");
            Thread.Sleep(5);
        }
    }

    /// <summary>Runs posted UI work for <paramref name="duration"/>.</summary>
    public static void PumpFor(TimeSpan duration)
    {
        var clock = Stopwatch.StartNew();
        while (clock.Elapsed < duration)
        {
            Dispatcher.UIThread.RunJobs();
            Thread.Sleep(5);
        }
    }

    /// <summary>An Integration API camera list: <c>(id, name, state)</c> per camera.</summary>
    public static string CameraList(params (string Id, string Name, string State)[] cameras)
        => "{\"data\":[" + string.Join(",", cameras.Select(c =>
               $$"""{"id":"{{c.Id}}","name":"{{c.Name}}","state":"{{c.State}}"}""")) + "]}";

    public void Dispose()
    {
        Hub.Dispose();
        Console.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }
}
