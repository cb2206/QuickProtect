using System.Xml.Linq;
using Xunit;

namespace QuickProtect.Core.Tests;

/// <summary>
/// The App's Resources.*.resx files are maintained by hand (there is no
/// generator from the macOS String Catalog), so nothing else would notice a
/// key added to the base file and forgotten in a translation — it would just
/// fall back to English in that language. This reads the files straight from
/// the source tree and fails on any drift.
/// </summary>
public class LocalizationParityTests
{
    private static readonly string[] Languages = { "de", "fr", "es", "nl", "it", "pt-BR" };

    private static string LocalizationDir()
    {
        // Walk up from the test binary to the repo's dotnet/ folder.
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !File.Exists(Path.Combine(dir.FullName, "QuickProtect.sln")))
            dir = dir.Parent;
        Assert.NotNull(dir);
        return Path.Combine(dir!.FullName, "src", "QuickProtect.App", "Localization");
    }

    private static HashSet<string> Keys(string path)
        => XDocument.Load(path).Root!.Elements("data")
            .Select(e => e.Attribute("name")!.Value)
            .ToHashSet(StringComparer.Ordinal);

    [Fact]
    public void Every_language_has_exactly_the_base_keys()
    {
        var dir = LocalizationDir();
        var baseKeys = Keys(Path.Combine(dir, "Resources.resx"));
        Assert.NotEmpty(baseKeys);
        foreach (var lang in Languages)
        {
            var keys = Keys(Path.Combine(dir, $"Resources.{lang}.resx"));
            var missing = baseKeys.Except(keys).OrderBy(k => k, StringComparer.Ordinal).ToList();
            var extra = keys.Except(baseKeys).OrderBy(k => k, StringComparer.Ordinal).ToList();
            Assert.True(missing.Count == 0, $"{lang}: untranslated keys: {string.Join(" | ", missing)}");
            Assert.True(extra.Count == 0, $"{lang}: keys not in the base file: {string.Join(" | ", extra)}");
        }
    }

    [Fact]
    public void No_translation_is_empty()
    {
        var dir = LocalizationDir();
        foreach (var lang in Languages)
        {
            var empty = XDocument.Load(Path.Combine(dir, $"Resources.{lang}.resx")).Root!.Elements("data")
                .Where(e => string.IsNullOrWhiteSpace(e.Element("value")?.Value))
                .Select(e => e.Attribute("name")!.Value).ToList();
            Assert.True(empty.Count == 0, $"{lang}: empty values: {string.Join(" | ", empty)}");
        }
    }
}
