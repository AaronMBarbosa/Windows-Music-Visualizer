using System.Numerics;

namespace WindowsMusicVisualizerGpu;

internal static class CameraValidation
{
    private readonly record struct Hit(double Time, CameraAccent Accent);

    public static void Validate()
    {
        var report = new List<string>();
        foreach (int rate in new[] { 44100, 48000 })
        foreach (float frequency in new[] { 60f, 220f, 900f, 2400f, 7800f })
        {
            var hits = Detect(t => Tone(t, frequency) * Pulse(t, 0.5) * 0.2f, 4.5, rate);
            Require(hits.Count is >= 6 and <= 8, $"{frequency} Hz/{rate}: expected seven accents, got {hits.Count}.");
            double worstDelay = 0;
            foreach (var hit in hits)
            {
                double nearest = 1.0 + Math.Round((hit.Time - 1.0) / 0.5) * 0.5;
                double delay = hit.Time - nearest;
                Require(delay >= 0 && delay < 0.115, $"{frequency} Hz: accent is not aligned ({delay:0.000}s).");
                Require(Math.Abs(Math.Log2(hit.Accent.Frequency / frequency)) < 0.8, "Wrong dominant frequency selected.");
                worstDelay = Math.Max(delay, worstDelay);
            }
            report.Add($"{frequency} Hz at {rate}: {hits.Count} hits, maximum detection delay {worstDelay * 1000:0} ms.");
        }

        var loud = Detect(t => Tone(t, 900) * Pulse(t, 0.5) * 0.3f, 4.5);
        var quiet = Detect(t => Tone(t, 900) * Pulse(t, 0.5) * 0.015f, 4.5);
        Require(loud.Count == quiet.Count, "Volume changed the accent count.");
        for (int i = 0; i < loud.Count; i++)
        {
            Require(Math.Abs(loud[i].Time - quiet[i].Time) < 0.025, "Volume changed accent timing.");
            Require(Math.Abs(loud[i].Accent.Strength - quiet[i].Accent.Strength) < 0.08f, "Volume changed camera strength excessively.");
        }
        report.Add("20:1 volume change: matching accent count, timing, and strength.");

        var sustain = Detect(t => Tone(t, 900) * 0.15f, 5);
        var vibrato = Detect(t => (float)Math.Sin(Math.Tau * 900 * t + 3 * Math.Sin(Math.Tau * 5 * t)) * 0.15f, 5);
        Require(sustain.Count(h => h.Time > 0.4) == 0, "A held tone kept shaking the camera.");
        Require(vibrato.Count(h => h.Time > 0.4) <= 1, "Vibrato created spurious camera hits.");
        Require(Detect(_ => 0, 2).Count == 0, "Silence triggered the camera.");
        var noiseRandom = new Random(47);
        var noiseSamples = Enumerable.Range(0, 48000 * 5 + 2048).Select(_ => (float)(noiseRandom.NextDouble() * 2 - 1)).ToArray();
        var noise = Detect(t => noiseSamples[(int)(t * 48000)] * 0.04f, 5);
        Require(noise.Count(h => h.Time > 0.6) <= 3, $"Steady noise triggered {noise.Count} hits: " +
            string.Join(", ", noise.Select(h => $"{h.Time:0.00}s/{h.Accent.Frequency:0}Hz/{h.Accent.Strength:0.00}")));
        Require(Detect(t => noiseSamples[(int)(t * 48000)] * 0.00001f, 3).Count == 0, "Inaudible noise triggered movement.");
        report.Add($"Sustained tone/vibrato/silence rejected; steady noise: {noise.Count(h => h.Time > 0.6)} hits after warmup.");

        var vocal = Detect(t => Tone(t, 60) * 0.08f + (Tone(t, 900) + Tone(t, 1800) * 0.45f) * Pulse(t, 0.5) * 0.2f, 4.5);
        Require(vocal.Count(h => h.Time > 0.7 && h.Accent.Frequency > 600) >= 6, "Midrange accents were masked by sustained bass.");
        var dominant = Detect(t => Tone(t, 60) * Pulse(t, 0.5) * 0.3f + Tone(t, 7800) * Pulse(t, 0.125) * 0.01f, 4.5);
        Require(dominant.Count(h => h.Time > 0.7 && h.Accent.Frequency < 150) >= 6, "Strong bass attacks were missed.");
        Require(dominant.Count(h => h.Time > 0.7 && h.Accent.Frequency > 1000) <= 3, "Quiet subdivisions dominated camera motion.");
        var fast = Detect(t => Tone(t, 900) * Pulse(t, 0.167) * 0.2f, 4.5);
        Require(fast.Count >= 18 && fast.Count <= 23, $"Fast accents missed or duplicated: {fast.Count}.");
        Require(quiet.All(h => h.Time <= 4.12), "Motion invented accents after the final hit.");
        report.Add($"Dominant midrange and bass selected independently; fast pattern: {fast.Count} hits.");
        var percussive = Detect(t => noiseSamples[(int)(t * 48000)] * Pulse(t, 0.5) * 0.3f, 4.5);
        Require(percussive.Count is >= 6 and <= 8, $"Broadband percussive attacks missed or duplicated: {percussive.Count}.");
        report.Add($"Broadband percussive bursts: {percussive.Count} clean hits.");

        var random = new Random(87);
        var camera = new AccentCamera();
        var styles = new HashSet<int>();
        for (int scene = 0; scene < 100; scene++)
        {
            int prior = camera.Style;
            Vector4 before = camera.Transform;
            camera.Reroll(random, scene % 35);
            Require(camera.Style != prior, "Camera style repeated on reroll.");
            Require(camera.Transform == before, "Scene change snapped camera position.");
            styles.Add(camera.Style);
            for (int frame = 0; frame < 72; frame++)
            {
                if (frame % 16 == 0) camera.Add(new CameraAccent(1f, 60 + scene * 70, 0.11f));
                camera.Update(1f / 144);
                Vector4 p = camera.Transform;
                Require(float.IsFinite(p.LengthSquared()) && Math.Abs(p.X) <= 0.05 && Math.Abs(p.Y) <= 0.05
                    && Math.Abs(p.Z) <= 0.026 && p.W >= 0 && p.W <= 0.030, "Camera exceeded motion bounds.");
                CheckViewport(p);
            }
        }
        Require(styles.Count == 5, "Not all five motion styles are reachable.");
        for (int i = 0; i < 144; i++) camera.Update(1f / 144);
        Require(camera.Transform.Length() < 0.00002f, "Camera did not settle in silence.");

        var sixty = SimulateCamera(60);
        var highRefresh = SimulateCamera(144);
        Require(Vector4.Distance(sixty, highRefresh) < 0.00005f, "Camera motion depends on display frame rate.");
        camera.Enabled = false;
        for (int i = 0; i < 144; i++) { camera.Add(new CameraAccent(1, 900, 0.2f)); camera.Update(1f / 144); }
        Require(camera.Transform.Length() < 0.00002f, "Disabled camera still reacts.");
        report.Add("All five styles: bounded transforms, edge coverage, smooth rerolls, silence settling, disable, 60/144 Hz consistency passed.");
        File.WriteAllLines(Path.Combine(AppContext.BaseDirectory, "camera-validation.txt"), report);
    }

    private static Vector4 SimulateCamera(int fps)
    {
        var camera = new AccentCamera();
        camera.Reroll(new Random(4), 2);
        for (int i = 0; i < fps * 3 / 4; i++)
        {
            if (i == 0 || i == fps / 2) camera.Add(new CameraAccent(0.85f, 900, 0.5f));
            camera.Update(1f / fps);
        }
        return camera.Transform;
    }

    private static void CheckViewport(Vector4 camera)
    {
        foreach (float aspect in new[] { 9f / 16, 1f, 16f / 9, 32f / 9 })
        {
            float c = Math.Abs(MathF.Cos(camera.Z)), s = Math.Abs(MathF.Sin(camera.Z));
            float fit = Math.Min(1f, Math.Min((aspect - 2 * Math.Abs(camera.X)) / (aspect * c + s),
                (1 - 2 * Math.Abs(camera.Y)) / (c + aspect * s))) / (1 + camera.W);
            Require((aspect * c + s) * fit / 2 + Math.Abs(camera.X) <= aspect / 2 + 0.000001f
                && (c + aspect * s) * fit / 2 + Math.Abs(camera.Y) <= 0.500001f, "Camera exposes image borders.");
        }
    }

    private static List<Hit> Detect(Func<double, float> signal, double duration, int rate = 48000)
    {
        var detector = new CameraAccentDetector();
        var block = new float[2048];
        var result = new List<Hit>();
        for (int offset = 0; offset + block.Length < duration * rate; offset += 1024)
        {
            for (int i = 0; i < block.Length; i++) block[i] = signal((offset + i) / (double)rate);
            var hit = detector.Process(block, rate);
            if (hit.HasValue) result.Add(new Hit((offset + block.Length) / (double)rate, hit.Value));
        }
        return result;
    }

    private static float Tone(double t, float frequency) => (float)Math.Sin(Math.Tau * t * frequency);

    private static float Pulse(double t, double interval)
    {
        if (t < 1.0) return 0f;
        double age = (t - 1.0) % interval;
        return (float)(Math.Min(1.0, age / 0.006) * Math.Exp(-age / 0.035));
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
