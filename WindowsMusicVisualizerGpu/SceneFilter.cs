using System.Numerics;

namespace WindowsMusicVisualizerGpu;

internal sealed class SceneFilter
{
    internal const int Count = 14;
    private readonly int[] lastByScene = Enumerable.Repeat(-1, 35).ToArray();
    private int last = -1;
    internal bool Enabled = true;
    internal int Override = -1;
    internal Vector4 Parameters { get; private set; }

    internal void Reroll(Random random, int scene)
    {
        int choice;
        do { choice = random.Next(Count); }
        while (choice == last || choice == lastByScene[scene]);
        last = lastByScene[scene] = choice;
        Parameters = new(choice, 0.35f + random.NextSingle() * 0.45f,
            random.NextSingle() * MathF.Tau, random.NextSingle());
    }

    internal Vector4 Packed => new(Override >= 0 ? Override : Parameters.X,
        Enabled ? Parameters.Y : 0f, Parameters.Z, Parameters.W);

    internal static void Validate()
    {
        var filter = new SceneFilter();
        var random = new Random(1977);
        var seen = new HashSet<int>();
        int[] previous = Enumerable.Repeat(-1, 35).ToArray();
        int last = -1;
        for (int i = 0; i < 3500; i++)
        {
            int scene = i % 35;
            filter.Reroll(random, scene);
            int type = (int)filter.Parameters.X;
            if (type == last || type == previous[scene] || filter.Parameters.Y < 0.35f || filter.Parameters.Y > 0.8f)
                throw new InvalidOperationException("Scene filter variation failed.");
            previous[scene] = last = type;
            seen.Add(type);
        }
        if (seen.Count != Count) throw new InvalidOperationException("Missing filter type.");
        filter.Enabled = false;
        if (filter.Packed.Y != 0) throw new InvalidOperationException("Filter bypass failed.");
        File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "filter-validation.txt"),
            $"Passed: all {Count} filters, no consecutive or per-scene repeat, bounded strength, bypass.");
    }
}
