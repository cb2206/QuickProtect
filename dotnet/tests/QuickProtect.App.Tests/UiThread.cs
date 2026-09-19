using System.Collections.Concurrent;

namespace QuickProtect.App.Tests;

/// <summary>
/// Avalonia binds <c>Dispatcher.UIThread</c> to the first thread that touches
/// it, while xUnit runs test classes in parallel on different threads. Tests
/// that use controls or the dispatcher run their body here, on one dedicated
/// thread, so they never trip over each other's thread affinity.
/// </summary>
internal static class UiThread
{
    private static readonly BlockingCollection<Action> Work = new();

    static UiThread()
    {
        var thread = new Thread(() =>
        {
            foreach (var item in Work.GetConsumingEnumerable()) item();
        })
        {
            IsBackground = true,
            Name = "Avalonia test UI thread"
        };
        thread.Start();
    }

    /// <summary>Runs <paramref name="body"/> on the UI thread and rethrows its failure here.</summary>
    public static void Run(Action body)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Work.Add(() =>
        {
            try
            {
                body();
                done.SetResult();
            }
            catch (Exception ex)
            {
                done.SetException(ex); // surfaces as the test's failure
            }
        });
        done.Task.GetAwaiter().GetResult();
    }
}
