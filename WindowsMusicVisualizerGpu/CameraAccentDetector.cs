using System.Numerics;

namespace WindowsMusicVisualizerGpu;

internal readonly record struct CameraAccent(float Strength, float Frequency, float Interval);

internal sealed class CameraAccentDetector
{
    private const int Size = 2048;
    private const int BandCount = 32;
    private readonly Complex[] bins = new Complex[Size];
    private readonly float[] window = new float[Size];
    private readonly float[] energy = new float[BandCount];
    private readonly float[] previous = new float[BandCount];
    private readonly float[] envelopes = new float[BandCount];
    private readonly int[] binBands = new int[Size / 2];
    private int configuredRate;
    private float reference;
    private float mean;
    private float deviation;
    private float previousScore;
    private float olderScore;
    private float previousThreshold;
    private int previousBand;
    private double clock;
    private double lastAccent = -10;

    public CameraAccentDetector()
    {
        for (int i = 0; i < Size; i++)
            window[i] = 0.5f - 0.5f * MathF.Cos(2f * MathF.PI * i / (Size - 1));
    }

    public CameraAccent? Process(ReadOnlySpan<float> samples, int sampleRate)
    {
        if (samples.Length != Size || sampleRate < 8000)
            throw new ArgumentException("Camera analysis requires a 2048-sample audio window.");
        if (configuredRate != sampleRate)
        {
            for (int i = 1; i < binBands.Length; i++)
            {
                float frequency = i * sampleRate / (float)Size;
                binBands[i] = frequency < 35f || frequency > 16000f ? -1
                    : Math.Clamp((int)(MathF.Log(frequency / 35f) / MathF.Log(16000f / 35f) * BandCount), 0, BandCount - 1);
            }
            configuredRate = sampleRate;
        }

        float dt = Size / 2f / sampleRate;
        clock += dt;
        float rms = 0f;
        for (int i = 0; i < Size; i++)
        {
            float sample = float.IsFinite(samples[i]) ? samples[i] : 0f;
            rms += sample * sample;
            bins[i] = new Complex(sample * window[i], 0);
        }
        rms = MathF.Sqrt(rms / Size);
        AudioAnalyzer.Fft(bins);
        Array.Clear(energy);
        for (int i = 1; i < binBands.Length; i++)
        {
            int band = binBands[i];
            if (band >= 0)
                energy[band] += (float)(bins[i].Real * bins[i].Real + bins[i].Imaginary * bins[i].Imaginary) / (Size * Size);
        }
        float peak = 0f;
        for (int i = 0; i < BandCount; i++)
        {
            energy[i] = MathF.Sqrt(energy[i]);
            peak = Math.Max(peak, energy[i]);
        }
        reference = Math.Max(peak, reference * MathF.Exp(-dt / 1.4f));
        float score = 0f;
        int winner = 0;
        if (rms > 0.00006f && reference > 0.00002f)
        {
            // Local maximum reference suppresses pitch/vibrato jitter. Only positive
            // spectral change counts, weighted by audibility, not a bass-only beat clock.
            float floor = Math.Max(0.000002f, reference * 0.025f);
            for (int i = 0; i < BandCount; i++)
            {
                float prior = Math.Max(previous[i], Math.Max(previous[Math.Max(0, i - 1)], previous[Math.Min(BandCount - 1, i + 1)]));
                float rise = Math.Max(0f, MathF.Log((energy[i] + floor) / (prior + floor)) - 0.10f);
                float audibility = MathF.Pow(Math.Clamp(energy[i] / reference, 0f, 1f), 0.7f);
                float contrast = Math.Clamp((energy[i] - envelopes[i] * 1.12f) / (envelopes[i] * 0.85f + floor), 0f, 1f);
                float novelty = rise / (1f + rise) * audibility * contrast;
                if (novelty > score) { score = novelty; winner = i; }
            }
        }
        Array.Copy(energy, previous, BandCount);
        for (int i = 0; i < BandCount; i++)
            envelopes[i] += (energy[i] - envelopes[i]) * (1f - MathF.Exp(-dt / 0.12f));

        float threshold = Math.Max(0.24f, mean + deviation * 1.7f);
        CameraAccent? result = null;
        // One-hop lookahead selects a local peak instead of retriggering through an
        // attack. The refractory period rejects flams/ringing but permits fast accents.
        double peakTime = clock - dt;
        if (previousScore > previousThreshold && previousScore > olderScore && previousScore >= score
            && peakTime - lastAccent >= 0.105)
        {
            float strength = Math.Clamp((previousScore - 0.12f) / 0.65f, 0f, 1f);
            float frequency = 35f * MathF.Pow(16000f / 35f, (previousBand + 0.5f) / BandCount);
            result = new CameraAccent(strength, frequency, (float)Math.Clamp(peakTime - lastAccent, 0.105, 1.2));
            lastAccent = peakTime;
        }
        float follow = 1f - MathF.Exp(-dt / 1.2f);
        deviation += (Math.Abs(score - mean) - deviation) * follow;
        mean += (score - mean) * follow;
        olderScore = previousScore;
        previousScore = score;
        previousThreshold = threshold;
        previousBand = winner;
        return result;
    }

    public void ResetAfterGap()
    {
        Array.Clear(previous);
        Array.Clear(envelopes);
        previousScore = olderScore = 0f;
        reference = mean = deviation = 0f;
        lastAccent = clock - 1.2;
    }
}
