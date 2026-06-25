using Avalonia;
using Avalonia.Controls;
using QuickProtect.App.ViewModels;

namespace QuickProtect.App.Views;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Icon = ApertureIcon.Create(64);
    }

    // Start/stop streams as the panel is shown/hidden so a closed panel never
    // keeps server-side allocations alive (mirrors the macOS open/close cleanup).
    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == IsVisibleProperty && DataContext is MainViewModel vm)
        {
            if (change.GetNewValue<bool>()) vm.StartAll();
            else vm.StopAll();
        }
    }
}
