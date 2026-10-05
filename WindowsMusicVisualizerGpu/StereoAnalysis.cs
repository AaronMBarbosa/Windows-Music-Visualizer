using System.Numerics;

namespace WindowsMusicVisualizerGpu;

internal sealed class StereoAnalysis
{
    public Vector4 State { get; private set; }
    public float Correlation { get; private set; } = 1;
    public void Process(ReadOnlySpan<float> left, ReadOnlySpan<float> right, int sampleRate)
    {
        double l = 0, r = 0, cross = 0;
        int count = Math.Min(left.Length, right.Length);
        if (count == 0) return;
        for (int i = 0; i < count; i++) { l += left[i] * left[i]; r += right[i] * right[i]; cross += left[i] * right[i]; }
        float total = (float)(l + r);
        bool audible = total / count > 1e-9f;
        Correlation = audible ? Math.Clamp((float)(cross / Math.Sqrt(Math.Max(1e-20, l * r))), -1, 1) : 1;
        float balance = audible ? (float)((Math.Sqrt(r) - Math.Sqrt(l)) / (Math.Sqrt(r) + Math.Sqrt(l))) : 0;
        float width = audible ? MathF.Sqrt(Math.Clamp((float)((l + r - 2 * cross) / (2 * (l + r))), 0, 1)) : 0;
        float alpha = 1 - MathF.Exp(-count / (float)sampleRate / 0.07f);
        State = Vector4.Lerp(State, new Vector4(audible ? (float)Math.Sqrt(l / count) : 0, audible ? (float)Math.Sqrt(r / count) : 0, balance, width), alpha);
    }
    public void Decay() => State *= 0.88f;
    public void Reset() { State = Vector4.Zero; Correlation = 1; }
}
