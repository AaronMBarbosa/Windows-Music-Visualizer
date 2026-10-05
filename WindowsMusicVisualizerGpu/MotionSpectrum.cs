namespace WindowsMusicVisualizerGpu;

internal sealed class MotionSpectrum
{
    public float[] Values { get; } = new float[32];
    private readonly float[] baselines = new float[32];

    public void Update(float[] spectrum, float delta)
    {
        // Keep local note contrast separate from global loudness and onset.
        for (int i = 0; i < Values.Length; i++)
        {
            int center = i * 3 + 1;
            float value = spectrum[center] * 0.7f + (spectrum[center - 1] + spectrum[center + 1]) * 0.15f;
            float excess = Math.Max(0f, value - baselines[i] - 0.045f);
            // Preserve note envelopes as well as attacks; contrast alone erases held notes.
            float target = Math.Clamp(excess * 1.15f + Math.Max(0f, value - 0.04f) * 0.32f, 0f, 1f);
            target *= target / (target + 0.06f);
            float follow = 1f - MathF.Exp(-delta * 20f);
            Values[i] += (target - Values[i]) * follow;
            float baselineFollow = 1f - MathF.Exp(-delta * (value > baselines[i] ? 2.0f : 0.7f));
            baselines[i] += (value - baselines[i]) * baselineFollow;
        }
    }

    public static void Validate()
    {
        var sustained = new MotionSpectrum();
        var notes = new float[96];
        Array.Fill(notes, 0.3f, 30, 3);
        for (int frame = 0; frame < 180; frame++) sustained.Update(notes, 1f / 60f);
        if (sustained.Values[10] < 0.04f || sustained.Values[10] > 0.15f)
            throw new InvalidOperationException("Moderate held notes lost their visible envelope or overreacted.");
        float held = sustained.Values[10];
        Array.Fill(notes, 0.65f, 30, 3);
        for (int frame = 0; frame < 6; frame++) sustained.Update(notes, 1f / 60f);
        if (sustained.Values[10] < held * 3f)
            throw new InvalidOperationException("A growing note did not produce a prompt motion response.");
        foreach (int band in new[] { 1, 6, 11, 16, 21, 26, 31 })
        {
            var processor = new MotionSpectrum();
            var input = new float[96];
            for (int j = band * 3; j < band * 3 + 3; j++) input[j] = 0.9f;
            float peak = 0f;
            for (int frame = 0; frame < 120; frame++)
            {
                processor.Update(input, 1f / 60f);
                peak = Math.Max(peak, processor.Values[band]);
            }
            if (peak < 0.3f || processor.Values[band] > peak * 0.35f)
                throw new InvalidOperationException("Motion response did not attack and settle.");
            for (int other = 0; other < 32; other++)
                if (other != band && processor.Values[other] != 0f)
                    throw new InvalidOperationException("Frequency leaked into an unrelated motion band.");
            Array.Clear(input);
            for (int frame = 0; frame < 18; frame++) processor.Update(input, 1f / 60f);
            if (processor.Values[band] > 0.002f)
                throw new InvalidOperationException("Motion did not release into silence.");
        }
        File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "motion-validation.txt"),
            "Passed: seven isolated frequency bands, transient attack, sustained-tone settling, and silence release.");
    }
}
