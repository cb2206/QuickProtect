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
        // Multi-site strings built in view models (site placeholder, removal
        // confirmation, duplicate console, PTZ caption, credential help).
        foreach (var key in new[]
        {
            "New Site", "Remove", "Remove “{0}”?",
            "Its cameras disappear from every profile, and its API key and login are deleted from this computer.",
            "This console is already added as “{0}”.", "Classic API credentials · {0}",
            "Create the key on this console, not at unifi.ui.com: open UniFi Network → Integrations → Create New API Key (on Network 9: Settings → Control Plane → Integrations). Each console needs its own key.",
            "Use a local account on this console: in UniFi OS open Admins & Users → Create New, tick “Restrict to Local Access Only”, and give it a Protect role that can control cameras."
        }) keys.Add(key);
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
