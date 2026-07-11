using System.Globalization;
using System.Resources;

namespace QuickProtect.App.Localization;

/// <summary>
/// String lookup keyed by the English source text (the same keys the macOS
/// String Catalog uses), backed by the embedded <c>Resources.*.resx</c> imported
/// from that catalog. Unknown keys fall back to the literal text, so wrapping a
/// string is always safe even before it's translated.
/// </summary>
public static class Loc
{
    private static readonly ResourceManager Rm =
        new("QuickProtect.App.Localization.Resources", typeof(Loc).Assembly);

    public static string Get(string key)
    {
        try { return Rm.GetString(key, CultureInfo.CurrentUICulture) ?? key; }
        catch { return key; }
    }

    /// <summary>Supported UI cultures (the languages the macOS app ships).</summary>
    public static readonly string[] Supported = { "en", "de", "fr", "es", "nl", "it", "pt-BR" };

    /// <summary>
    /// Apply a UI culture for the process. <paramref name="code"/> null/empty = use
    /// the OS culture, mapped to the nearest supported language (else English).
    /// </summary>
    public static void ApplyCulture(string? code)
    {
        var culture = Resolve(code);
        CultureInfo.DefaultThreadCurrentUICulture = culture;
        CultureInfo.CurrentUICulture = culture;
    }

    private static CultureInfo Resolve(string? code)
    {
        if (!string.IsNullOrWhiteSpace(code) && Supported.Contains(code))
            return new CultureInfo(code);

        var os = CultureInfo.CurrentUICulture;
        // Exact match (e.g. pt-BR), then language-only (e.g. de-DE → de).
        if (Supported.Contains(os.Name)) return os;
        var lang = os.TwoLetterISOLanguageName;
        var match = Supported.FirstOrDefault(s => s.StartsWith(lang, StringComparison.OrdinalIgnoreCase));
        return match != null ? new CultureInfo(match) : new CultureInfo("en");
    }
}
