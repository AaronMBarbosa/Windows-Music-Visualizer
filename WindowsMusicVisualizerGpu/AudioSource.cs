using System.Diagnostics;

namespace WindowsMusicVisualizerGpu;

public sealed record AudioSource(string Name, string? DeviceId = null, string? ProcessName = null, string? ProcessPath = null)
{
    public static AudioSource SystemDefault { get; } = new("All system audio (default output)");
    public override string ToString() => Name;

    public Process? FindProcess()
    {
        Process? selected = null;
        DateTime oldest = DateTime.MaxValue;
        // Prefer the app parent over its newer renderer/audio worker processes.
        foreach (var process in Process.GetProcessesByName(ProcessName ?? ""))
        {
            try
            {
                if (ProcessPath != null && !string.Equals(process.MainModule?.FileName, ProcessPath, StringComparison.OrdinalIgnoreCase)) continue;
                if (process.StartTime >= oldest) continue;
                selected?.Dispose();
                selected = process;
                oldest = process.StartTime;
            }
            catch { }
            finally { if (process != selected) process.Dispose(); }
        }
        return selected;
    }

    public static List<AudioSource> Applications()
    {
        var sources = new Dictionary<string, AudioSource>(StringComparer.OrdinalIgnoreCase);
        using var self = Process.GetCurrentProcess();
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try
                {
                    if (process.SessionId != self.SessionId || process.Id == self.Id) continue;
                    string? path = process.MainModule?.FileName;
                    if (path == null) continue;
                    sources.TryAdd(path, new AudioSource($"App: {process.ProcessName}.exe", ProcessName: process.ProcessName, ProcessPath: path));
                }
                catch { }
            }
        }
        return sources.Values.OrderBy(s => s.Name).ToList();
    }
}
