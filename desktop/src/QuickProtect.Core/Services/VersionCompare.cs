namespace QuickProtect.Core.Services;

/// <summary>
/// Semantic-version comparison, ported verbatim from the macOS app's
/// <c>RTPParser.isNewer</c> so the shipping comparison can't drift from the tests.
/// </summary>
public static class VersionCompare
{
    /// <summary>True if <paramref name="remote"/> &gt; <paramref name="local"/>.</summary>
    public static bool IsNewer(string remote, string local)
    {
        var r = Parse(remote);
        var l = Parse(local);
        for (var i = 0; i < Math.Max(r.Count, l.Count); i++)
        {
            var rv = i < r.Count ? r[i] : 0;
            var lv = i < l.Count ? l[i] : 0;
            if (rv > lv) return true;
            if (rv < lv) return false;
        }
        return false;
    }

    private static List<int> Parse(string version)
        => version.Split('.')
                  .Select(s => int.TryParse(s, out var n) ? (int?)n : null)
                  .Where(n => n.HasValue)
                  .Select(n => n!.Value)
                  .ToList();
}
