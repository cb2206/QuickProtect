using System.Runtime.Versioning;
using QuickProtect.App.Platform;
using Xunit;

namespace QuickProtect.App.Tests;

/// <summary>
/// <see cref="HyprlandShortcutConfig"/> writing the Hyprland bind for the global
/// hotkey: the managed file's content, the one-time include in the user's main
/// config, and leaving everything else in that config alone. Runs against a
/// temporary config directory, never the real one.
/// </summary>
[SupportedOSPlatform("linux")]
public sealed class HyprlandShortcutConfigTests : IDisposable
{
    private const int KeyP = 0x50;
    private const int AltShift = 1 | 4;
    private readonly string _dir = Directory.CreateTempSubdirectory("qp-hypr-").FullName;

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private string Main(string name) => Path.Combine(_dir, name);

    [Fact]
    public void LuaBindUsesHyprlandKeyNamesAndThePortalShortcut()
    {
        Assert.Equal(
            "-- Managed by QuickProtect: rewritten whenever the global hotkey changes in its Settings.\n" +
            "hl.bind(\"SHIFT + ALT + P\", hl.dsp.global(\"quickprotect:toggle-panel\"), { description = \"QuickProtect\" })\n",
            HyprlandShortcutConfig.LuaFile(KeyP, AltShift));
    }

    [Fact]
    public void ConfBindUsesHyprlangSyntax()
    {
        Assert.EndsWith("bind = SUPER CTRL, F5, global, quickprotect:toggle-panel\n",
            HyprlandShortcutConfig.ConfFile(0x74, 8 | 2));
    }

    [Fact]
    public void ClearedHotkeyLeavesNoBind()
    {
        Assert.DoesNotContain("hl.bind", HyprlandShortcutConfig.LuaFile(null, null));
        Assert.DoesNotContain("bind =", HyprlandShortcutConfig.ConfFile(null, null));
    }

    [Fact]
    public void LuaConfigGetsTheManagedFileAndOneGuardedInclude()
    {
        const string original = "require(\"hypr.bindings\")\n";
        File.WriteAllText(Main("hyprland.lua"), original);

        Assert.True(HyprlandShortcutConfig.Write(_dir, KeyP, AltShift));

        var managed = Path.Combine(_dir, "quickprotect.lua");
        Assert.Equal(HyprlandShortcutConfig.LuaFile(KeyP, AltShift), File.ReadAllText(managed));
        var main = File.ReadAllText(Main("hyprland.lua"));
        Assert.StartsWith(original, main);
        Assert.Contains($"pcall(dofile, \"{managed}\")", main);
    }

    /// <summary>Unchanged settings on every launch must not reload Hyprland or grow the config.</summary>
    [Fact]
    public void RewritingTheSameHotkeyChangesNothing()
    {
        File.WriteAllText(Main("hyprland.lua"), "");
        HyprlandShortcutConfig.Write(_dir, KeyP, AltShift);
        var main = File.ReadAllText(Main("hyprland.lua"));

        Assert.False(HyprlandShortcutConfig.Write(_dir, KeyP, AltShift));
        Assert.Equal(main, File.ReadAllText(Main("hyprland.lua")));
    }

    [Fact]
    public void ChangedHotkeyRewritesOnlyTheManagedFile()
    {
        File.WriteAllText(Main("hyprland.lua"), "");
        HyprlandShortcutConfig.Write(_dir, KeyP, AltShift);
        var main = File.ReadAllText(Main("hyprland.lua"));

        Assert.True(HyprlandShortcutConfig.Write(_dir, 0x51, AltShift));
        Assert.Contains("\"SHIFT + ALT + Q\"", File.ReadAllText(Path.Combine(_dir, "quickprotect.lua")));
        Assert.Equal(main, File.ReadAllText(Main("hyprland.lua")));
    }

    [Fact]
    public void ClassicConfigIsSourced()
    {
        File.WriteAllText(Main("hyprland.conf"), "monitor = ,preferred,auto,1");

        Assert.True(HyprlandShortcutConfig.Write(_dir, KeyP, AltShift));

        var managed = Path.Combine(_dir, "quickprotect.conf");
        Assert.True(File.Exists(managed));
        Assert.Contains($"\nsource = {managed}\n", File.ReadAllText(Main("hyprland.conf")));
    }

    [Fact]
    public void NoHyprlandConfigWritesNothing()
    {
        Assert.False(HyprlandShortcutConfig.Write(_dir, KeyP, AltShift));
        Assert.Empty(Directory.GetFiles(_dir));
    }
}
