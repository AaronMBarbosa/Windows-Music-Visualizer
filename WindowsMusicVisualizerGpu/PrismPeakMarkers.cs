namespace WindowsMusicVisualizerGpu;

internal sealed class PrismPeakMarkers
{
    internal const float FallSpeed = 2.8f;
    internal readonly float[] Heights = new float[24];

    // Keep in sync with concertoHeight in Visualizer.hlsl; upper energy retains headroom.
    internal static float BarTop(float value)
    {
        value = Math.Clamp(value, 0f, 1f);
        float note = value / (0.14f + value);
        return 0.1f + MathF.Pow(note, 0.9f) * 4.6f + 2.4f * MathF.Pow(value, 1.6f);
    }

    internal void Update(ReadOnlySpan<float> bands, float seconds)
    {
        for (int i = 0; i < Heights.Length; i++)
        {
            float value = Math.Max(0f, bands[(int)MathF.Round(i / 23f * 31f)]);
            float top = BarTop(value);
            Heights[i] = Math.Max(top, Heights[i] - FallSpeed * seconds);
        }
    }

    internal static void Validate()
    {
        if (BarTop(1f) < 6.5f || BarTop(1f) - BarTop(0.8f) < 0.8f)
            throw new InvalidOperationException("Strong prism peaks lost their height headroom.");
        float previous = BarTop(0);
        for (int step = 1; step <= 100; step++)
        {
            float next = BarTop(step / 100f);
            if (next <= previous) throw new InvalidOperationException("Prism heights must increase without a plateau.");
            previous = next;
        }
        foreach (int fps in new[] { 30, 60, 144 })
        {
            var markers = new PrismPeakMarkers();
            float[] bands = new float[32];
            bands[0] = 0.8f;
            markers.Update(bands, 1f / fps);
            float peak = markers.Heights[0];
            bands[0] = 0f;
            for (int frame = 0; frame < fps; frame++) markers.Update(bands, 1f / fps);
            if (Math.Abs(markers.Heights[0] - (peak - FallSpeed)) > 0.0001f)
                throw new InvalidOperationException("Peak marker fall is not constant.");
            if (markers.Heights[1] != 0.1f)
                throw new InvalidOperationException("Peak markers are not independent.");
            bands[0] = 0.8f;
            markers.Update(bands, 1f / fps);
            if (Math.Abs(markers.Heights[0] - peak) > 0.0001f)
                throw new InvalidOperationException("Peak marker did not catch the renewed bar.");
            bands[0] = 0f;
            for (int frame = 0; frame < fps * 3; frame++) markers.Update(bands, 1f / fps);
            if (markers.Heights[0] != 0.1f)
                throw new InvalidOperationException("Peak marker did not settle on the idle bar.");
        }
        File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "prism-peak-validation.txt"),
            "Passed: constant fall, independent markers, renewed peaks, idle settling at 30/60/144 FPS.");
    }
}
