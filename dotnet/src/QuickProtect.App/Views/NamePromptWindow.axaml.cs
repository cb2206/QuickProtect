using Avalonia.Controls;
using Avalonia.Interactivity;

namespace QuickProtect.App.Views;

/// <summary>Small name-entry dialog (the macOS NSAlert-with-text-field analog).</summary>
public partial class NamePromptWindow : Window
{
    public NamePromptWindow()
    {
        InitializeComponent();
        Opened += (_, _) => NameBox.Focus();
    }

    /// <summary>Show modally over <paramref name="owner"/>; null when cancelled.</summary>
    public static Task<string?> ShowAsync(Window owner, string title)
    {
        var win = new NamePromptWindow();
        win.TitleText.Text = title;
        return win.ShowDialog<string?>(owner);
    }

    private void Ok_Click(object? sender, RoutedEventArgs e) => Close(NameBox.Text);

    private void Cancel_Click(object? sender, RoutedEventArgs e) => Close(null);
}
