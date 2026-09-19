using System.Globalization;
using System.Resources;
using QuickProtect.App.Localization;
using QuickProtect.Core.Services;
using Xunit;

namespace QuickProtect.App.Tests;

/// <summary>
/// Strings built in code have no XAML to catch a missing key: an absent
/// catalog entry silently shows English. Every such key must exist in every
/// shipped language.
/// </summary>
public class CatalogCoverageTests
{
    private static readonly ResourceManager Catalog =
        new("QuickProtect.App.Localization.Resources", typeof(Loc).Assembly);

    public static TheoryData<string> Keys()
    {
        var keys = new TheoryData<string>();
        foreach (var message in ControllerErrors.All) keys.Add(message);
        // Stream-quality menu (MainWindow.QualityName, "Use default" + " (name)").
        foreach (var key in new[] { "Use default", "Auto", "High", "Medium", "Low" }) keys.Add(key);
        return keys;
    }

    [Theory]
    [MemberData(nameof(Keys))]
    public void Key_is_translated_in_every_language(string key)
    {
        foreach (var language in Loc.Supported)
        {
            // No fallback: a key missing from one language must fail here.
            var set = Catalog.GetResourceSet(new CultureInfo(language == "en" ? "" : language), true, false);
            Assert.True(set?.GetString(key) is { Length: > 0 }, $"'{key}' is missing from the {language} catalog");
        }
    }
}
