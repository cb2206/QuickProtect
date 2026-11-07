using CommunityToolkit.Mvvm.ComponentModel;
using QuickProtect.Core.Services;

namespace QuickProtect.App.ViewModels;

/// <summary>One entry of Settings' site list: label, address and connection state.</summary>
public sealed partial class SiteRowViewModel : ObservableObject
{
    public SiteRowViewModel(ControllerSite site) => Site = site;

    public ControllerSite Site { get; }

    [ObservableProperty] private string _displayName = "";
    [ObservableProperty] private string _address = "";
    [ObservableProperty] private bool _connected;
    [ObservableProperty] private string _statusText = "";

    /// <summary>Re-reads the site and its service (address, name, last fetch result).</summary>
    public void Refresh(ProtectService? service)
    {
        DisplayName = Site.DisplayName.Length > 0 ? Site.DisplayName : Localization.Loc.Get("New Site");
        // The address on its own line only when the label isn't the address already.
        Address = Site.IpAddress != DisplayName ? Site.IpAddress : "";
        var healthy = service is { ErrorMessage: null, CertificateChange: null };
        Connected = healthy && service!.Cameras.Count > 0;
        StatusText = !Site.IsConfigured
            ? Localization.Loc.Get("Not configured")
            : Localization.Loc.Get(healthy ? "Connected" : "Disconnected");
    }
}
