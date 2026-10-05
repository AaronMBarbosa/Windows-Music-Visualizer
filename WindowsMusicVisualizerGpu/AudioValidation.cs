using System.Diagnostics;

namespace WindowsMusicVisualizerGpu;

internal static class AudioValidation
{
    public static void Validate()
    {
        var left = new float[2048]; var right = new float[2048];
        for (int i = 0; i < left.Length; i++) left[i] = right[i] = MathF.Sin(i * 0.1f) * 0.1f;
        var stereo = new StereoAnalysis();
        for (int i = 0; i < 30; i++) stereo.Process(left, right, 48000);
        Require(Math.Abs(stereo.State.Z) < 0.001 && stereo.State.W < 0.001, "Mono must be centered and narrow");
        Array.Clear(right);
        for (int i = 0; i < 30; i++) stereo.Process(left, right, 48000);
        Require(stereo.State.Z < -0.99, "Left-only balance");
        (left, right) = (right, left);
        for (int i = 0; i < 30; i++) stereo.Process(left, right, 48000);
        Require(stereo.State.Z > 0.99, "Right-only balance");
        for (int i = 0; i < left.Length; i++) left[i] = -right[i];
        for (int i = 0; i < 30; i++) stereo.Process(left, right, 48000);
        Require(stereo.State.W > 0.99 && Math.Abs(stereo.State.Z) < 0.001, "Anti-phase stereo remains wide and audible");
        for (int i = 0; i < left.Length; i++) { left[i] *= 0.1f; right[i] *= 0.1f; }
        for (int i = 0; i < 30; i++) stereo.Process(left, right, 48000);
        Require(stereo.State.W > 0.99, "Volume-invariant width");
        Array.Clear(left); Array.Clear(right);
        for (int i = 0; i < 60; i++) stereo.Process(left, right, 48000);
        Require(stereo.State.Length() < 0.00001, "Silence settles to zero");
        using var monoAnalyzer = new AudioAnalyzer();
        using var phaseAnalyzer = new AudioAnalyzer();
        using var leftAnalyzer = new AudioAnalyzer();
        using var rightAnalyzer = new AudioAnalyzer();
        var silent = new float[2048];
        for (int i = 0; i < left.Length; i++) { left[i] = MathF.Sin(i * 0.1f) * 0.1f; right[i] = -left[i]; }
        for (int i = 0; i < 20; i++)
        {
            monoAnalyzer.AnalyzeStereoTest(left, left); phaseAnalyzer.AnalyzeStereoTest(left, right);
            leftAnalyzer.AnalyzeStereoTest(left, silent); rightAnalyzer.AnalyzeStereoTest(silent, left);
        }
        Require(monoAnalyzer.Level > 0.1f && Math.Abs(monoAnalyzer.Level - phaseAnalyzer.Level) < 0.001f, "Opposite-phase audio must not cancel main visual energy");
        Require(Math.Abs(leftAnalyzer.Level - rightAnalyzer.Level) < 0.001f, "Both channels drive the main visual equally");
        Require(Math.Abs(leftAnalyzer.BassKick - rightAnalyzer.BassKick) < 0.001f, "Both channels drive the beat equally");
        Console.WriteLine("Stereo: mono, left, right, anti-phase, volume invariance and silence passed.");
    }

    public static void ValidateCapture()
    {
        Task.Run(() =>
        {
            var devices = WasapiLoopbackCapture.Devices();
            Console.WriteLine($"Active output devices: {devices.Count}");
            foreach (var device in devices) Console.WriteLine(device.Name);
            var left = new float[4096]; var right = new float[4096];
            using (var capture = new WasapiLoopbackCapture())
            {
                Console.WriteLine($"Default capture: {capture.SampleRate} Hz");
                for (int i = 0; i < 20; i++) { capture.Read(left, right); Thread.Sleep(10); }
            }
            using var self = Process.GetCurrentProcess();
            foreach (var device in devices)
            {
                using var capture = new WasapiLoopbackCapture(device);
                capture.Read(left, right);
            }
            using (var analyzer = new AudioAnalyzer())
            {
                analyzer.Start();
                Thread.Sleep(150);
                if (devices.Count > 0) analyzer.SelectSource(devices[0]);
                Thread.Sleep(150);
                analyzer.SelectSource(new AudioSource("Missing app", ProcessName: "visualizer-test-missing-app"));
                Require(SpinWait.SpinUntil(() => analyzer.SourceStatus == "Waiting for app to start", 3000), "Missing-app status");
                Require(analyzer.Level < 0.001, "Missing app must not fall back to demo/system audio");
                analyzer.SelectSource(AudioSource.SystemDefault);
                Require(SpinWait.SpinUntil(() => analyzer.SourceStatus is "Stereo" or "Waiting for audio", 3000), "Default-source recovery");
            }
            Console.WriteLine("Specific outputs, live source switching, missing-app silence and recovery passed.");
            if (!WasapiLoopbackCapture.SupportsApplicationCapture)
            {
                Console.WriteLine("Device activation/read/disposal passed. App capture skipped: unsupported Windows build.");
                return;
            }
            var source = new AudioSource("Self", ProcessName: self.ProcessName);
            using (var capture = new WasapiLoopbackCapture(source, self.Id))
            {
                Console.WriteLine($"Process capture: {capture.SampleRate} Hz");
                for (int i = 0; i < 20; i++) { capture.Read(left, right); Thread.Sleep(10); }
            }
            Console.WriteLine("Device and process activation/read/disposal passed.");
        }).GetAwaiter().GetResult();
    }

    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
