using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Platform.Storage;
using QuickProtect.App.ViewModels;

namespace QuickProtect.App.Views;

public partial class SettingsWindow : Window
{
    public SettingsWindow()
    {
        InitializeComponent();
        Icon = ApertureIcon.Create(64);
        // Give the view model a way to open a native folder picker.
        DataContextChanged += (_, _) =>
        {
            if (DataContext is SettingsViewModel vm)
                vm.PickFolderAsync = PickFolderAsync;
        };
    }

    private async Task<string?> PickFolderAsync()
    {
        var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions
        {
            Title = Localization.Loc.Get("Choose a folder for saved snapshots"),
            AllowMultiple = false
        });
        return folders.Count > 0 ? folders[0].TryGetLocalPath() : null;
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
