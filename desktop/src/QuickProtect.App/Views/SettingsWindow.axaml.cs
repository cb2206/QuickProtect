using Avalonia.Controls;
using Avalonia.Input;
using QuickProtect.App.ViewModels;

namespace QuickProtect.App.Views;

public partial class SettingsWindow : Window
{
    public SettingsWindow()
    {
        InitializeComponent();
        Icon = ApertureIcon.Create(64);
    }

    // While recording a global shortcut, capture the next key combo here (tunneling
    // so it fires before a TextBox swallows the key).
    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (DataContext is SettingsViewModel { IsRecordingHotkey: true } vm)
        {
            vm.CaptureHotkey(e.Key, e.KeyModifiers);
            e.Handled = true;
            return;
        }
        base.OnKeyDown(e);
    }
}
