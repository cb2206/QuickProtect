using System.Runtime.Versioning;
using QuickProtect.App.Platform;
using Xunit;

namespace QuickProtect.App.Tests;

/// <summary>
/// The decisions behind <see cref="LinuxDesktopEntries"/>: when a hidden
/// application entry is written for the desktop portal, and when a stale
/// autostart entry is repointed. Pure string logic — runs on every OS; the
/// class attribute only keeps the Linux-annotated call sites warning-free.
/// </summary>
[SupportedOSPlatform("linux")]
public class LinuxDesktopEntriesTests
{
    private static bool Nothing(string _) => false;
    private static bool Everything(string _) => true;

    [Fact]
    public void Writes_an_entry_when_none_is_installed()
        => Assert.True(LinuxDesktopEntries.ApplicationEntryNeedsWrite(null, systemEntryExists: false, Everything));

    [Fact]
    public void Never_shadows_a_packaged_entry()
        => Assert.False(LinuxDesktopEntries.ApplicationEntryNeedsWrite(null, systemEntryExists: true, Everything));

    [Fact]
    public void Never_rewrites_an_entry_it_did_not_write()
    {
        const string user = "[Desktop Entry]\nType=Application\nName=QuickProtect\nExec=/gone/QuickProtect\n";
        Assert.False(LinuxDesktopEntries.ApplicationEntryNeedsWrite(user, systemEntryExists: false, Nothing));
    }

    [Fact]
    public void Rewrites_its_own_entry_only_when_the_binary_is_gone()
    {
        var ours = LinuxDesktopEntries.GeneratedApplicationEntry("/old/QuickProtect");
        Assert.True(LinuxDesktopEntries.ApplicationEntryNeedsWrite(ours, systemEntryExists: false, Nothing));
        Assert.False(LinuxDesktopEntries.ApplicationEntryNeedsWrite(ours, systemEntryExists: false, Everything));
    }

    [Fact]
    public void Generated_entry_is_hidden_marked_and_quoted()
    {
        var entry = LinuxDesktopEntries.GeneratedApplicationEntry("/home/me/Quick Protect/QuickProtect");
        Assert.Contains("NoDisplay=true\n", entry);
        Assert.Contains(LinuxDesktopEntries.GeneratedMarker, entry);
        Assert.Equal("/home/me/Quick Protect/QuickProtect", LinuxDesktopEntries.ExecTarget(entry));
    }

    [Theory]
    [InlineData("Exec=/opt/quickprotect/QuickProtect", "/opt/quickprotect/QuickProtect")]
    [InlineData("Exec=/opt/quickprotect/QuickProtect --open-panel", "/opt/quickprotect/QuickProtect")]
    [InlineData("Exec=\"/a b/Quick\\\"Protect\" %U", "/a b/Quick\"Protect")]
    [InlineData("Exec=quickprotect", "quickprotect")]
    public void Reads_the_program_from_the_exec_line(string line, string expected)
        => Assert.Equal(expected, LinuxDesktopEntries.ExecTarget($"[Desktop Entry]\nName=QuickProtect\n{line}\n"));

    [Fact]
    public void Missing_exec_line_has_no_target()
        => Assert.Null(LinuxDesktopEntries.ExecTarget("[Desktop Entry]\nName=QuickProtect\n"));

    [Fact]
    public void Only_a_missing_absolute_binary_counts_as_stale()
    {
        Assert.True(LinuxDesktopEntries.ExecTargetIsMissing("Exec=/gone/QuickProtect\n", Nothing));
        Assert.False(LinuxDesktopEntries.ExecTargetIsMissing("Exec=/here/QuickProtect\n", Everything));
        // A bare command resolves through PATH — not ours to judge.
        Assert.False(LinuxDesktopEntries.ExecTargetIsMissing("Exec=quickprotect\n", Nothing));
    }

    [Fact]
    public void Repointing_keeps_the_rest_of_the_entry()
    {
        const string autostart = "[Desktop Entry]\nType=Application\nName=QuickProtect\nExec=/old/QuickProtect\nX-GNOME-Autostart-enabled=true\n";
        var repaired = LinuxDesktopEntries.ReplaceExec(autostart, "/new/QuickProtect");
        Assert.Equal(
            "[Desktop Entry]\nType=Application\nName=QuickProtect\nExec=\"/new/QuickProtect\"\nX-GNOME-Autostart-enabled=true\n",
            repaired);
    }
}
