using System.Runtime.Versioning;
using QuickProtect.Core.Services;

namespace QuickProtect.App.Platform;

/// <summary>
/// Keeps a Hyprland key binding in step with the global hotkey set in Settings.
///
/// The portal registers our shortcut (<c>quickprotect:toggle-panel</c>) with
/// Hyprland, but Hyprland never assigns keys to portal shortcuts — the
/// preferred trigger we send is ignored, so the recorded combo does nothing
/// until the user's config binds it. This writes that bind for them.
///
/// The bind lives in a file of its own that this class owns and rewrites
/// wholesale (<c>quickprotect.lua</c>, or <c>quickprotect.conf</c> for a
/// classic hyprlang config). The user's main config gains a single line that
/// loads it, added once and never touched again. For Lua the load is wrapped
/// in <c>pcall</c>, so a later-deleted file can't break the user's config.
/// Hyprland only reloads when the file's content actually changed.
/// </summary>
[SupportedOSPlatform("linux")]
internal static class HyprlandShortcutConfig
{
    private const string ShortcutId = PortalGlobalHotkey.AppId + ":toggle-panel";
    private const string ManagedHeader =
        "Managed by QuickProtect: rewritten whenever the global hotkey changes in its Settings.";

    /// <summary>Applies the shortcut to the running Hyprland's user config.</summary>
    public static void Apply(int? keyCode, int? modifiers)
    {
        var configHome = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
        if (string.IsNullOrEmpty(configHome))
            configHome = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
        try
        {
            if (Write(Path.Combine(configHome, "hypr"), keyCode, modifiers))
                Hyprland.Request("reload");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentOutOfRangeException)
        {
            Log.Line($"[Hotkey] could not update the Hyprland config: {e.Message}");
        }
    }

    /// <summary>
    /// Writes the managed file and makes sure the main config loads it. Returns
    /// true when anything on disk changed (so Hyprland needs a reload); false
    /// when it was already current or there is no Hyprland config to extend.
    /// </summary>
    internal static bool Write(string hyprDir, int? keyCode, int? modifiers)
    {
        var lua = Path.Combine(hyprDir, "hyprland.lua");
        var conf = Path.Combine(hyprDir, "hyprland.conf");
        bool isLua;
        string main;
        if (File.Exists(lua)) (isLua, main) = (true, lua);
        else if (File.Exists(conf)) (isLua, main) = (false, conf);
        else
        {
            Log.Line($"[Hotkey] no Hyprland config in {hyprDir}; bind {ShortcutId} to a key yourself.");
            return false;
        }

        var managed = Path.Combine(hyprDir, isLua ? "quickprotect.lua" : "quickprotect.conf");
        var content = isLua ? LuaFile(keyCode, modifiers) : ConfFile(keyCode, modifiers);
        var changed = false;
        if (!File.Exists(managed) || File.ReadAllText(managed) != content)
        {
            File.WriteAllText(managed, content);
            changed = true;
        }

        var include = isLua ? $"pcall(dofile, \"{managed}\")" : $"source = {managed}";
        var mainText = File.ReadAllText(main);
        if (!mainText.Contains(managed, StringComparison.Ordinal))
        {
            var separator = mainText.Length == 0 || mainText.EndsWith('\n') ? "" : "\n";
            var comment = isLua ? "--" : "#";
            File.AppendAllText(main,
                $"{separator}\n{comment} QuickProtect's global hotkey (the file is managed by the app).\n{include}\n");
            changed = true;
        }
        if (changed) Log.Line($"[Hotkey] Hyprland bind written to {managed}");
        return changed;
    }

    internal static string LuaFile(int? keyCode, int? modifiers)
    {
        var body = keyCode is { } key
            ? $"hl.bind(\"{Keys(key, modifiers ?? 0, " + ")}\", hl.dsp.global(\"{ShortcutId}\"), " +
              "{ description = \"QuickProtect\" })\n"
            : "-- No global hotkey set.\n";
        return $"-- {ManagedHeader}\n{body}";
    }

    internal static string ConfFile(int? keyCode, int? modifiers)
    {
        string body;
        if (keyCode is { } key)
        {
            var mods = Modifiers(modifiers ?? 0);
            body = $"bind = {string.Join(" ", mods)}, {KeyName(key)}, global, {ShortcutId}\n";
        }
        else body = "# No global hotkey set.\n";
        return $"# {ManagedHeader}\n{body}";
    }

    /// <summary>Hyprland's key-combo string, e.g. "SHIFT + ALT + P".</summary>
    internal static string Keys(int keyCode, int modifiers, string separator) =>
        string.Join(separator, Modifiers(modifiers).Append(KeyName(keyCode)));

    // Stored as Win32 MOD_* flags (see HotkeyCodec): ALT=1, CONTROL=2, SHIFT=4, WIN=8.
    private static IEnumerable<string> Modifiers(int modifiers)
    {
        if ((modifiers & 8) != 0) yield return "SUPER";
        if ((modifiers & 2) != 0) yield return "CTRL";
        if ((modifiers & 4) != 0) yield return "SHIFT";
        if ((modifiers & 1) != 0) yield return "ALT";
    }

    // The recordable set (HotkeyCodec.VirtualKey): letters, digits, F-keys.
    private static string KeyName(int keyCode) => keyCode switch
    {
        >= 0x41 and <= 0x5A => ((char)keyCode).ToString(),
        >= 0x30 and <= 0x39 => ((char)keyCode).ToString(),
        >= 0x70 and <= 0x87 => "F" + (keyCode - 0x6F),
        _ => throw new ArgumentOutOfRangeException(nameof(keyCode), keyCode, "not a recordable hotkey key"),
    };
}
