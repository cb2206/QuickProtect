using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace QuickProtect.App.Views;

/// <summary>
/// Two-button confirmation (the macOS warning NSAlert analog). Cancel is the
/// default and Esc answers it, so a destructive action takes a deliberate click.
/// </summary>
public sealed class ConfirmWindow : Window
{
    private ConfirmWindow(string title, string message, string confirm)
    {
        Title = "QuickProtect";
        SizeToContent = SizeToContent.WidthAndHeight;
        CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;

        var cancel = new Button { Content = Localization.Loc.Get("Cancel"), IsDefault = true, IsCancel = true };
        cancel.Click += (_, _) => Close(false);
        var ok = new Button { Content = confirm };
        ok.Click += (_, _) => Close(true);

        Content = new StackPanel
        {
            Margin = new Thickness(22, 18),
            Spacing = 10,
            MaxWidth = 380,
            Children =
            {
                new TextBlock { Text = title, FontWeight = FontWeight.SemiBold, FontSize = 14, TextWrapping = TextWrapping.Wrap },
                new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 8,
                    HorizontalAlignment = HorizontalAlignment.Right,
                    Margin = new Thickness(0, 6, 0, 0),
                    Children = { cancel, ok }
                }
            }
        };
    }

    /// <summary>Show modally over <paramref name="owner"/>; true when confirmed.</summary>
    public static Task<bool> ShowAsync(Window owner, string title, string message, string confirm)
        => new ConfirmWindow(title, message, confirm).ShowDialog<bool>(owner);
}
