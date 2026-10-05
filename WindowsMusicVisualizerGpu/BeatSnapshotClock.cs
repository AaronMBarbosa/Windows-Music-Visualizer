namespace WindowsMusicVisualizerGpu;

internal sealed class BeatSnapshotClock
{
    private double progress;
    private float tempo = 120f;
    private bool initialized;
    private bool phaseLocked;
    public float Progress => (float)progress;

    public bool Update(float dt, float bpm, float confidence, float beatPhase)
    {
        if (!float.IsFinite(dt) || dt <= 0f) return false;
        float target = float.IsFinite(bpm) ? Math.Clamp(bpm, 55f, 200f) : tempo;
        if (!initialized) { tempo = target; initialized = true; }
        tempo += (target - tempo) * (1f - MathF.Exp(-dt * 0.8f));
        if (confidence > 0.30f) phaseLocked = true;
        else if (confidence < 0.18f) phaseLocked = false;
        float rate = tempo / 60f;
        if (phaseLocked && float.IsFinite(beatPhase))
        {
            float error = beatPhase - (float)progress;
            error -= MathF.Floor(error + 0.5f);
            // Slew toward the audio phase instead of resetting and double-capturing.
            rate *= Math.Clamp(1f + error * 1.3f, 0.82f, 1.18f);
        }
        progress += dt * rate;
        if (progress < 1.0 - 0.000001) return false;
        progress = Math.Max(0.0, progress - Math.Floor(progress + 0.000001));
        return true;
    }

    public static void Validate()
    {
        foreach (int fps in new[] { 30, 60, 144 })
        foreach (int bpm in new[] { 60, 90, 120, 180 })
        {
            var clock = new BeatSnapshotClock();
            int captures = 0;
            for (int i = 0; i < fps * 20; i++)
                if (clock.Update(1f / fps, bpm, 0f, 0f)) captures++;
            if (Math.Abs(captures - 20f * bpm / 60f) > 1)
                throw new InvalidOperationException($"Snapshot cadence mismatch: {bpm} BPM at {fps} Hz.");
        }
        var tracking = new BeatSnapshotClock();
        float lastCapture = -1;
        float phase = 0.37f;
        float maxLatePhaseError = 0f;
        for (int frame = 0; frame < 144 * 30; frame++)
        {
            float t = frame / 144f;
            float bpm = t < 10f ? 90f : 150f;
            if (tracking.Update(1f / 144f, bpm, t > 20 && t < 22 ? 0.1f : 0.8f, phase))
            {
                if (lastCapture > 0 && t - lastCapture < 0.25f)
                    throw new InvalidOperationException("Tempo change created duplicate snapshots.");
                if (t > 25) maxLatePhaseError = Math.Max(maxLatePhaseError, Math.Min(phase, 1f - phase));
                lastCapture = t;
            }
            phase = (phase + bpm / 60f / 144f) % 1f;
        }
        if (maxLatePhaseError > 0.05f)
            throw new InvalidOperationException("Snapshots did not align with the detected beat phase.");
        File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "snapshot-validation.txt"),
            "Passed: 60/90/120/180 BPM at 30/60/144 Hz, gradual tempo changes, confidence loss/recovery, phase alignment, no duplicate captures.");
    }
}
