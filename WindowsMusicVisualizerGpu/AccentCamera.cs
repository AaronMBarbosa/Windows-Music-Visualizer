using System.Numerics;

namespace WindowsMusicVisualizerGpu;

internal sealed class AccentCamera
{
    private Vector4 position;
    private Vector4 velocity;
    private float omega = 18f;
    private float angle;
    private float variation = 1f;
    private float sceneScale = 1f;
    private float targetScale = 1f;
    private float enabledAmount = 1f;
    private int stroke;
    public int Style { get; private set; } = -1;
    public bool Enabled { get; set; } = true;

    public void Reroll(Random random, int scene)
    {
        int next = random.Next(4);
        Style = Style < 0 ? random.Next(5) : next >= Style ? next + 1 : next;
        angle = (float)random.NextDouble() * MathF.Tau;
        variation = 0.85f + (float)random.NextDouble() * 0.3f;
        targetScale = scene is 14 or 15 or 17 ? 0.65f : scene >= 32 ? 0.85f : 1f;
        stroke = 0;
    }

    public void Add(CameraAccent accent)
    {
        if (!Enabled || accent.Strength <= 0f) return;
        float strength = Math.Clamp(accent.Strength, 0f, 1f);
        omega = Math.Clamp(7f / Math.Max(0.105f, accent.Interval), 13f, 28f);
        float sign = (++stroke & 1) == 0 ? -1f : 1f;
        float pitch = Math.Clamp(MathF.Log2(Math.Max(35f, accent.Frequency) / 35f) / 9f, 0f, 1f);
        float a = angle + (pitch - 0.5f) * 0.35f;
        Vector4 direction = Style switch
        {
            0 => new(sign, sign * 0.16f * MathF.Sin(a), sign * 0.16f, 0.08f),
            1 => new(sign * 0.18f * MathF.Cos(a), sign, sign * 0.12f, 0.12f),
            2 => new(sign * MathF.Cos(a), sign * MathF.Sin(a), sign * 0.26f, 0.08f),
            3 => new(MathF.Cos(a + stroke * 2.4f) * 0.75f, MathF.Sin(a + stroke * 2.4f) * 0.75f, sign * 0.45f, 0.12f),
            _ => new(sign * 0.25f, -sign * 0.35f, sign * 0.65f, 0.40f)
        };
        float amplitude = (0.006f + 0.038f * MathF.Pow(strength, 1.5f)) * variation;
        // Velocity impulse preserves position continuity. Critical damping returns
        // to rest without free-running vibration; new accents reverse the stroke.
        velocity += direction * (amplitude * omega * MathF.E);
    }

    public void Update(float dt)
    {
        if (!float.IsFinite(dt) || dt <= 0f) return;
        Vector4 c = velocity + position * omega;
        float decay = MathF.Exp(-omega * dt);
        position = (position + c * dt) * decay;
        velocity = (velocity - c * (omega * dt)) * decay;
        sceneScale += (targetScale - sceneScale) * (1f - MathF.Exp(-dt * 8f));
        enabledAmount += ((Enabled ? 1f : 0f) - enabledAmount) * (1f - MathF.Exp(-dt * 12f));
    }

    public Vector4 Transform => new Vector4(
        Limit(position.X, 0.050f), Limit(position.Y, 0.050f),
        Limit(position.Z, 0.026f), Math.Max(0f, Limit(position.W, 0.030f))) * (sceneScale * enabledAmount);

    private static float Limit(float value, float bound) => bound * MathF.Tanh(value / bound);
}
