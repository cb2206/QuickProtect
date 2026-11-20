using Avalonia;
using Avalonia.Controls;
using Xunit;

namespace QuickProtect.App.Tests;

/// <summary>
/// Avalonia 12.1.3 made a TrayIcon a managed-only object until it is attached
/// through the Application's TrayIcon.Icons; the app used to only construct
/// one, which on 12.1.6 left Windows and Linux without a tray icon.
/// </summary>
public class TrayIconTests
{
    [Fact]
    public void Tray_icon_is_registered_with_the_application()
        => UiThread.Run(() =>
        {
            var app = new Application();
            var icon = new TrayIcon { ToolTipText = "QuickProtect" };
            App.AttachTrayIcon(app, icon);
            Assert.Contains(icon, TrayIcon.GetIcons(app) ?? []);
        });
}
