using System.Runtime.InteropServices;

namespace QuickProtect.Core.Services;

/// <summary>
/// Identifies how this build was distributed — the port of the macOS
/// <c>AppDistribution</c> receipt check. Store/packaged builds (Microsoft
/// Store MSIX, Flatpak, Snap) are updated by their store or package manager,
/// so the notify-only updater stays idle for them; only the loose GitHub
/// build (not code-signed) keeps the version check.
/// </summary>
public static class AppDistribution
{
    private const int AppModelErrorNoPackage = 15700;

    /// <summary>
    /// True when updates arrive through an external channel and the in-app
    /// checker must stay idle.
    /// </summary>
    public static bool IsExternallyManaged => IsForcedStore || IsWindowsPackaged || IsFlatpak || IsSnap;

    /// <summary>
    /// Demo/testing override mirroring the macOS <c>QUICKPROTECT_FORCE_APPSTORE</c>
    /// flag: it can only force store presentation ON, never disable genuine
    /// detection, so it is safe to ship.
    /// </summary>
    public static bool IsForcedStore =>
        Environment.GetEnvironmentVariable("QUICKPROTECT_FORCE_STORE") == "1";

    /// <summary>
    /// MSIX package identity (Microsoft Store install or a sideloaded
    /// package). The loose GitHub build has no package identity, so the API
    /// reports APPMODEL_ERROR_NO_PACKAGE.
    /// </summary>
    public static bool IsWindowsPackaged
    {
        get
        {
            if (!OperatingSystem.IsWindows()) return false;
            var length = 0;
            return GetCurrentPackageFullName(ref length, null) != AppModelErrorNoPackage;
        }
    }

    /// <summary>Flatpak sets FLATPAK_ID and mounts /.flatpak-info in the sandbox.</summary>
    public static bool IsFlatpak =>
        !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("FLATPAK_ID"))
        || File.Exists("/.flatpak-info");

    /// <summary>Snapd sets SNAP to the snap's mount path.</summary>
    public static bool IsSnap =>
        !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("SNAP"));

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int GetCurrentPackageFullName(ref int packageFullNameLength, char[]? packageFullName);
}
