using Avalonia.Controls;
using Avalonia.Interactivity;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Views;

/// <summary>
/// Shows the trusted and the new controller key so a certificate change can be
/// verified out of band, and asks whether to trust the new one (the macOS
/// <c>CertificateReviewAlert</c> analog).
/// </summary>
public partial class CertificateReviewWindow : Window
{
    public CertificateReviewWindow() => InitializeComponent();

    /// <summary>Show modally over <paramref name="owner"/>; true when the user chose to trust the new key.</summary>
    public static Task<bool> ShowAsync(Window owner, CertificateChange change)
    {
        var win = new CertificateReviewWindow();
        win.Title = Localization.Loc.Get("Trust the controller's new certificate?");
        win.HostText.Text = Localization.Loc.Get("Controller: %@").Replace("%@", change.Host);
        win.TrustedPanel.IsVisible = change.TrustedFingerprint != null;
        if (change.TrustedFingerprint is { } trusted)
            win.TrustedText.Text = CertificateTrust.DisplayFingerprint(trusted, bytesPerLine: 16);
        win.NewText.Text = CertificateTrust.DisplayFingerprint(change.NewFingerprint, bytesPerLine: 16);
        return win.ShowDialog<bool>(owner);
    }

    private void Trust_Click(object? sender, RoutedEventArgs e) => Close(true);

    private void Cancel_Click(object? sender, RoutedEventArgs e) => Close(false);
}
