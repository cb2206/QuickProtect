using Avalonia.Threading;
using QuickProtect.App.ViewModels;
using QuickProtect.Core.Services;
using Xunit;

namespace QuickProtect.App.Tests;

/// <summary>
/// Settings' certificate section follows the pin store while the window is
/// open: trusting from the panel card or a pinned window clears it, and a new
/// rejection shows up without reopening Settings.
/// </summary>
public class SettingsCertificateTests
{
    private sealed class NoSecrets : ISecretStore
    {
        public string? Get(string account) => null;
        public void Set(string account, string? value) { }
        public void Remove(string account) { }
    }

    [Fact]
    public void Pending_list_follows_changes_made_outside_settings() => UiThread.Run(() =>
    {
        var dir = Path.Combine(Path.GetTempPath(), "qp-settings-cert-" + Guid.NewGuid().ToString("N"));
        try
        {
            var trust = new CertificateTrust(new JsonFilePreferences(Path.Combine(dir, "trust.json")));
            var settings = new AppSettings(new JsonFilePreferences(Path.Combine(dir, "prefs.json")), new NoSecrets())
            {
                IpAddress = "10.0.0.5"
            };
            using var service = new ProtectService(settings, trust);
            trust.Evaluate("10.0.0.5", "aa");

            var vm = new SettingsViewModel(service, settings, trust, new UpdateChecker("1.0"));
            Assert.False(vm.HasPendingCert);

            // Rejection while Settings is open (TLS callback path).
            trust.Evaluate("10.0.0.5", "bb");
            Dispatcher.UIThread.RunJobs();
            Assert.True(vm.HasPendingCert);

            // Trusted from the panel card / a pinned window, not from Settings.
            service.TrustPendingCertificate("10.0.0.5");
            Dispatcher.UIThread.RunJobs();
            Assert.False(vm.HasPendingCert);
            Assert.Empty(vm.PendingCertificates);
        }
        finally
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
        }
    });
}
