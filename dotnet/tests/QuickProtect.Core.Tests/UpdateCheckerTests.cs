using QuickProtect.Core.Services;
using Xunit;

namespace QuickProtect.Core.Tests;

public class UpdateAssetTests
{
    [Theory]
    [InlineData("QuickProtect-1.3.0-win-x64.exe", "-win", true)]
    [InlineData("QuickProtect-1.3.0-WIN-X64.EXE", "-win", true)]   // case-insensitive
    [InlineData("QuickProtect-darwin.dmg", "-win", false)]         // "win" inside "darwin" must not match
    [InlineData("QuickProtect-1.3.0-linux-x64.tar.gz", "-linux", true)]
    [InlineData("QuickProtect-1.3.0-linux-x64.tar.gz", "-win", false)]
    [InlineData("QuickProtect-1.2.1.dmg", ".dmg", true)]
    [InlineData("QuickProtect-1.2.1.dmg", "-linux", false)]
    public void HasAsset_matches_platform_tokens(string assetName, string token, bool expected)
        => Assert.Equal(expected, UpdateChecker.HasAsset(new[] { assetName }, token));

    [Fact]
    public void HasCurrentPlatformAsset_true_for_full_multi_platform_release()
    {
        var names = new[]
        {
            "QuickProtect-1.3.0.dmg",
            "QuickProtect-1.3.0-win-x64.exe",
            "QuickProtect-1.3.0-linux-x64.tar.gz"
        };
        Assert.True(UpdateChecker.HasCurrentPlatformAsset(names));
    }

    [Fact]
    public void HasCurrentPlatformAsset_false_for_empty_release()
        => Assert.False(UpdateChecker.HasCurrentPlatformAsset(Array.Empty<string>()));
}

public class AppDistributionTests
{
    /// <summary>Runs the assertion with an env var temporarily set, then restores it.</summary>
    private static void WithEnv(string name, string? value, Action assert)
    {
        var previous = Environment.GetEnvironmentVariable(name);
        Environment.SetEnvironmentVariable(name, value);
        try { assert(); }
        finally { Environment.SetEnvironmentVariable(name, previous); }
    }

    [Fact]
    public void Flatpak_detected_via_env_var()
        => WithEnv("FLATPAK_ID", "app.quickprotect.QuickProtect", () =>
        {
            Assert.True(AppDistribution.IsFlatpak);
            Assert.True(AppDistribution.IsExternallyManaged);
        });

    [Fact]
    public void Snap_detected_via_env_var()
        => WithEnv("SNAP", "/snap/quickprotect/1", () =>
        {
            Assert.True(AppDistribution.IsSnap);
            Assert.True(AppDistribution.IsExternallyManaged);
        });

    // Process-wide environment mutation: xunit runs test classes in parallel,
    // so this must not overlap with anything else reading AppDistribution.
    [Fact]
    public void Force_store_override_only_forces_on()
    {
        WithEnv("QUICKPROTECT_FORCE_STORE", "1", () => Assert.True(AppDistribution.IsExternallyManaged));
        // "0" (or unset) must not force anything off — genuine detection still applies.
        WithEnv("QUICKPROTECT_FORCE_STORE", "0", () => Assert.False(AppDistribution.IsForcedStore));
    }

    [Fact]
    public void Loose_build_is_not_windows_packaged()
        // The test host is never MSIX-packaged (and the check is a no-op off Windows).
        => Assert.False(AppDistribution.IsWindowsPackaged);
}
