using Avalonia.Controls;

namespace QuickProtect.App.Views;

public partial class SettingsWindow : Window
{
    public SettingsWindow()
    {
        InitializeComponent();
        Icon = ApertureIcon.Create(64);
    }
}
