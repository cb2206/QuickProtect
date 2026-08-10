using Avalonia.Controls;

namespace QuickProtect.App.Views;

public partial class OnboardingWindow : Window
{
    public OnboardingWindow()
    {
        InitializeComponent();
        Icon = ApertureIcon.Create(64);
    }
}
