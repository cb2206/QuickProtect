using System.Diagnostics;

namespace QuickProtect.Core.Services;

/// <summary>Minimal diagnostic logger (stand-in for the macOS app's RTSPClient.log).</summary>
public static class Log
{
    public static void Line(string message)
    {
        Debug.WriteLine(message);
        Console.WriteLine(message);
    }
}
