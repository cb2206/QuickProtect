using QuickProtect.App.Video;
using QuickProtect.App.ViewModels;
using QuickProtect.Core.Models;
using QuickProtect.Core.Services;
using Xunit;

namespace QuickProtect.App.Tests;

/// <summary>
/// A stopped tile lets go of the stream client, so its surface stops showing
/// the client's last frame (e.g. after a controller change tore it down).
/// </summary>
public class CameraTileStopTests
{
    private sealed class NoSecrets : ISecretStore
    {
        public string? Get(string account) => null;
        public void Set(string account, string? value) { }
        public void Remove(string account) { }
    }

    [Fact]
    public void Stop_unbinds_the_client_and_clears_the_failure()
    {
        var dir = Path.Combine(Path.GetTempPath(), "qp-tile-stop-" + Guid.NewGuid().ToString("N"));
        try
        {
            var settings = new AppSettings(new JsonFilePreferences(Path.Combine(dir, "prefs.json")), new NoSecrets());
            using var service = new ProtectService(settings,
                new CertificateTrust(new JsonFilePreferences(Path.Combine(dir, "trust.json"))));
            using var client = new VideoStreamClient();
            var tile = new CameraTileViewModel(new Camera { Id = "cam1", Name = "Front", State = "CONNECTED" },
                service, settings)
            {
                Client = client,
                StreamFailure = "Connection lost"
            };

            tile.Stop();

            Assert.Null(tile.Client);
            Assert.Null(tile.StreamFailure);
            Assert.False(tile.IsPlaying);
        }
        finally
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
        }
    }
}
