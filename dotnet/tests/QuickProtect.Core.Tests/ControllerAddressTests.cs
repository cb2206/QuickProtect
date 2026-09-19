using QuickProtect.Core.Models;
using Xunit;

namespace QuickProtect.Core.Tests;

public class ControllerAddressTests
{
    [Fact]
    public void Bare_ip()
    {
        var a = ControllerAddress.Parse("192.168.1.1")!;
        Assert.Equal("192.168.1.1", a.Host);
        Assert.Null(a.Port);
        Assert.Equal("192.168.1.1", a.Authority);
        Assert.Equal("https://192.168.1.1", a.HttpsBase);
        Assert.Equal("192.168.1.1", a.PinKey);
    }

    [Theory]
    [InlineData("  https://192.168.1.1/  ", "192.168.1.1")]
    [InlineData("http://udm.local/protect", "udm.local")]
    [InlineData("UDM.Local", "udm.local")]
    [InlineData("admin:pw@10.0.0.1", "10.0.0.1")]
    public void Scheme_path_whitespace_case_and_userinfo_are_normalised(string raw, string authority)
        => Assert.Equal(authority, ControllerAddress.Parse(raw)!.Authority);

    [Fact]
    public void Explicit_port_kept_except_default()
    {
        Assert.Equal(8443, ControllerAddress.Parse("10.0.0.1:8443")!.Port);
        Assert.Equal("10.0.0.1:8443", ControllerAddress.Parse("10.0.0.1:8443")!.Authority);
        Assert.Equal("10.0.0.1", ControllerAddress.Parse("10.0.0.1:8443")!.PinKey);
        Assert.Null(ControllerAddress.Parse("10.0.0.1:443")!.Port);
        Assert.Equal("10.0.0.1", ControllerAddress.Parse("10.0.0.1:443")!.Authority);
    }

    [Fact]
    public void Ipv6_is_bracketed_in_authority_but_bare_in_pin_key()
    {
        var a = ControllerAddress.Parse("[fd00::1]:7443")!;
        Assert.Equal("fd00::1", a.Host);
        Assert.Equal("[fd00::1]:7443", a.Authority);
        Assert.Equal("[fd00::1]", ControllerAddress.Parse("https://[fd00::1]/")!.Authority);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("https://")]
    [InlineData(null)]
    public void Empty_and_garbage_are_null(string? raw)
        => Assert.Null(ControllerAddress.Parse(raw));
}
