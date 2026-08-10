using System.Text.Json;
using System.Text.Json.Serialization;

namespace QuickProtect.Core.Models;

/// <summary>
/// A UniFi Protect camera. Decoded leniently from both the Integration API
/// (<c>{ data: [...] }</c>, id/name/state/hasPackageCamera) and the classic API
/// (plain array with <c>featureFlags</c>). Mirrors <c>Camera</c> in the macOS app.
/// </summary>
[JsonConverter(typeof(CameraJsonConverter))]
public sealed class Camera
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public string State { get; init; } = "UNKNOWN";
    public IReadOnlyList<Channel> Channels { get; init; } = Array.Empty<Channel>();

    /// <summary>True if the camera supports physical pan/tilt/zoom (classic-API enrichment).</summary>
    public bool IsPtz { get; set; }

    /// <summary>True if the camera has an optical zoom lens.</summary>
    public bool CanZoom { get; set; }

    /// <summary>Secondary lens (e.g. doorbell package camera), or null for single-lens cameras.</summary>
    public SecondaryLens? Secondary { get; init; }

    public bool IsOnline => State == "CONNECTED";

    /// <summary>Prefer the first enabled channel; fall back to any channel that has an alias.</summary>
    public string? PrimaryRtspAlias =>
        Channels.FirstOrDefault(c => c.IsRtspEnabled && c.RtspAlias != null)?.RtspAlias
        ?? Channels.FirstOrDefault(c => c.RtspAlias != null)?.RtspAlias;

    public sealed record SecondaryLens(string Quality, string Label);

    public sealed record Channel(int Id, string Name, string? RtspAlias, bool IsRtspEnabled);
}

/// <summary>
/// Lenient converter handling both API shapes, equivalent to the macOS app's
/// hand-written <c>Codable</c> conformance. Tolerates missing fields rather than throwing.
/// </summary>
public sealed class CameraJsonConverter : JsonConverter<Camera>
{
    public override Camera Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;

        var id = root.TryGetProperty("id", out var idEl) ? idEl.GetString() ?? "" : "";
        var name = root.TryGetProperty("name", out var nameEl) ? nameEl.GetString() ?? "" : "";
        var state = root.TryGetProperty("state", out var stateEl) ? stateEl.GetString() ?? "UNKNOWN" : "UNKNOWN";

        var channels = new List<Camera.Channel>();
        if (root.TryGetProperty("channels", out var chEl) && chEl.ValueKind == JsonValueKind.Array)
        {
            foreach (var c in chEl.EnumerateArray())
            {
                var alias = c.TryGetProperty("rtspAlias", out var a) && a.ValueKind == JsonValueKind.String
                    ? a.GetString() : null;
                var chId = c.TryGetProperty("id", out var ci) && ci.TryGetInt32(out var civ) ? civ : 0;
                var chName = c.TryGetProperty("name", out var cn) ? cn.GetString() ?? "" : "";
                // field is isRtspEnabled in classic API; treat missing as "usable if it has an alias"
                var enabled = c.TryGetProperty("isRtspEnabled", out var en) && en.ValueKind is JsonValueKind.True or JsonValueKind.False
                    ? en.GetBoolean() : alias != null;
                channels.Add(new Camera.Channel(chId, chName, alias, enabled));
            }
        }

        bool isPtz = false, canZoom = false;
        if (root.TryGetProperty("featureFlags", out var ff) && ff.ValueKind == JsonValueKind.Object)
        {
            var flagPtz = ff.TryGetProperty("isPtz", out var p) && p.ValueKind == JsonValueKind.True;
            var canOptical = ff.TryGetProperty("canOpticalZoom", out var co) && co.ValueKind == JsonValueKind.True;
            double zoomRatio = 1;
            if (ff.TryGetProperty("zoom", out var z) && z.ValueKind == JsonValueKind.Object
                && z.TryGetProperty("ratio", out var r) && r.TryGetDouble(out var rv))
                zoomRatio = rv;
            var hasOpticalZoom = canOptical || zoomRatio > 1;
            isPtz = flagPtz || hasOpticalZoom;
            canZoom = hasOpticalZoom;
        }

        Camera.SecondaryLens? secondary = null;
        if (root.TryGetProperty("hasPackageCamera", out var pkg) && pkg.ValueKind == JsonValueKind.True)
            secondary = new Camera.SecondaryLens("package", "Package Camera");

        return new Camera
        {
            Id = id,
            Name = name,
            State = state,
            Channels = channels,
            IsPtz = isPtz,
            CanZoom = canZoom,
            Secondary = secondary
        };
    }

    public override void Write(Utf8JsonWriter writer, Camera value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("id", value.Id);
        writer.WriteString("name", value.Name);
        writer.WriteString("state", value.State);
        writer.WriteBoolean("hasPackageCamera", value.Secondary?.Quality == "package");
        writer.WriteEndObject();
    }
}
