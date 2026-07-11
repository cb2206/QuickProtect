using Avalonia.Markup.Xaml;

namespace QuickProtect.App.Localization;

/// <summary>
/// XAML markup extension: <c>{loc:Loc 'Test Connection'}</c> resolves the English
/// source string to the current UI culture at load time (culture is set at startup).
/// </summary>
public sealed class LocExtension : MarkupExtension
{
    public string Key { get; set; } = "";

    public LocExtension() { }
    public LocExtension(string key) => Key = key;

    public override object ProvideValue(IServiceProvider serviceProvider) => Loc.Get(Key);
}
