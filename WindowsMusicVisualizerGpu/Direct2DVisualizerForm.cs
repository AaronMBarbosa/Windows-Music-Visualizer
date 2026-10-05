using System.Diagnostics;
using System.Numerics;
using System.Runtime.InteropServices;
using Vortice;
using Vortice.DCommon;
using Vortice.Direct2D1;
using Vortice.DXGI;
using Vortice.Mathematics;
using static Vortice.Direct2D1.D2D1;

namespace WindowsMusicVisualizerGpu;

public sealed class Direct2DVisualizerForm : Form
{
    private const int ModeCount = 19;
    private readonly AudioAnalyzer analyzer;
    private readonly Random random = new();
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly float[] spectrum = new float[96];
    private readonly float[] waveform = new float[768];
    private readonly float[] smoothWaveform = new float[768];
    private readonly float[,] waveformHistory = new float[6, 768];
    private readonly Vector2[] pathBuffer = new Vector2[1024];
    private readonly Vector2[] morphBuffer = new Vector2[1024];
    private readonly Vector2[] constellationNodes = new Vector2[128];
    private readonly Vector2[,] latticeNodes = new Vector2[8, 32];
    private readonly int[] modeDeck = new int[ModeCount];
    private readonly Color4[][] palettes =
    [
        [Rgb(64, 255, 255), Rgb(96, 104, 255), Rgb(255, 74, 229), Rgb(245, 250, 255)],
        [Rgb(76, 255, 138), Rgb(76, 224, 255), Rgb(255, 212, 82), Rgb(245, 250, 255)],
        [Rgb(72, 142, 255), Rgb(0, 244, 219), Rgb(170, 88, 255), Rgb(245, 245, 255)],
        [Rgb(255, 56, 206), Rgb(108, 58, 255), Rgb(0, 222, 255), Rgb(255, 255, 255)],
        [Rgb(112, 255, 96), Rgb(48, 220, 255), Rgb(255, 68, 194), Rgb(246, 255, 238)],
        [Rgb(0, 184, 255), Rgb(126, 44, 255), Rgb(255, 86, 220), Rgb(72, 255, 220)],
        [Rgb(255, 214, 82), Rgb(72, 226, 255), Rgb(255, 80, 188), Rgb(255, 255, 255)],
        [Rgb(150, 255, 255), Rgb(90, 255, 130), Rgb(182, 105, 255), Rgb(245, 245, 255)]
    ];

    private ID2D1Factory? factory;
    private ID2D1HwndRenderTarget? target;
    private ID2D1SolidColorBrush? brush;
    private double lastFrameSeconds;
    private double nextTitleUpdate;
    private float fps;
    private float time;
    private float musicalTime;
    private int mode;
    private int previousMode;
    private int paletteIndex;
    private int previousPaletteIndex;
    private int colorOffset;
    private int previousColorOffset;
    private int waveformHistoryIndex;
    private int modeDeckIndex = ModeCount;
    private float transition = 1f;
    private float waveformHistoryTimer;
    private float frameOpacity = 1f;
    private float variantSeed;
    private float variantThickness = 1f;
    private float variantTwist = 1f;
    private float variantTrail = 1f;
    private float variantStretch = 1f;
    private float variantTopEnd = 1f;
    private float previousVariantSeed;
    private float previousVariantThickness = 1f;
    private float previousVariantTwist = 1f;
    private float previousVariantTrail = 1f;
    private float previousVariantStretch = 1f;
    private float previousVariantTopEnd = 1f;
    private DateTime nextShuffle;
    private DateTime shuffleArmedAt;
    private bool shuffleArmed;
    private bool fullscreen = true;
    private Rectangle windowedBounds;

    public Direct2DVisualizerForm(AudioAnalyzer analyzer, int screenNumber)
    {
        this.analyzer = analyzer;
        Text = "Windows Music Visualizer GPU";
        BackColor = System.Drawing.Color.Black;
        KeyPreview = true;
        SetStyle(ControlStyles.Opaque | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
        SelectScreen(screenNumber);
        RandomizePreset(true);
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        CreateDeviceResources();
        Application.Idle += OnApplicationIdle;
    }

    private void SelectScreen(int screenNumber)
    {
        var screens = Screen.AllScreens;
        int index = Math.Max(0, Math.Min(screens.Length - 1, screenNumber - 1));
        StartPosition = FormStartPosition.Manual;
        Bounds = screens[index].Bounds;
        FormBorderStyle = FormBorderStyle.None;
        WindowState = FormWindowState.Normal;
    }

    private void OnApplicationIdle(object? sender, EventArgs e)
    {
        while (IsApplicationIdle)
            RenderFrame();
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        if (target != null && ClientSize.Width > 0 && ClientSize.Height > 0)
            target.Resize(new SizeI(ClientSize.Width, ClientSize.Height));
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        RenderFrame();
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.KeyCode == Keys.Escape) Close();
        if (e.KeyCode == Keys.Space) RandomizePreset(false);
        if (e.KeyCode == Keys.M || e.KeyCode == Keys.Right || e.KeyCode == Keys.PageDown)
            BeginTransition((mode + 1) % ModeCount, paletteIndex, false);
        if (e.KeyCode == Keys.Left || e.KeyCode == Keys.PageUp)
            BeginTransition((mode - 1 + ModeCount) % ModeCount, paletteIndex, false);
        if (e.KeyCode == Keys.C) BeginTransition(mode, RandomDifferent(paletteIndex, palettes.Length), false);
        if (e.KeyCode == Keys.F) ToggleFullscreen();
    }

    private void ToggleFullscreen()
    {
        if (fullscreen)
        {
            windowedBounds = Bounds;
            FormBorderStyle = FormBorderStyle.Sizable;
            Bounds = new Rectangle(Bounds.Left + 80, Bounds.Top + 80, Math.Max(960, Bounds.Width - 220), Math.Max(540, Bounds.Height - 220));
            fullscreen = false;
        }
        else
        {
            FormBorderStyle = FormBorderStyle.None;
            Bounds = Screen.FromControl(this).Bounds;
            fullscreen = true;
        }
    }

    private void CreateDeviceResources()
    {
        factory ??= D2D1CreateFactory<ID2D1Factory>(FactoryType.MultiThreaded);
        var renderProperties = new RenderTargetProperties(
            RenderTargetType.Hardware,
            new PixelFormat(Format.Unknown, Vortice.DCommon.AlphaMode.Premultiplied),
            0,
            0,
            RenderTargetUsage.None,
            FeatureLevel.Default);
        var hwndProperties = new HwndRenderTargetProperties
        {
            Hwnd = Handle,
            PixelSize = new SizeI(Math.Max(1, ClientSize.Width), Math.Max(1, ClientSize.Height)),
            PresentOptions = PresentOptions.Immediately
        };

        target = factory.CreateHwndRenderTarget(renderProperties, hwndProperties);
        brush = target.CreateSolidColorBrush(Rgba(255, 255, 255, 1));
    }

    private void RenderFrame()
    {
        if (target == null || brush == null || ClientSize.Width <= 0 || ClientSize.Height <= 0)
            return;

        double now = clock.Elapsed.TotalSeconds;
        float delta = (float)Math.Min(0.05, Math.Max(0.0001, now - lastFrameSeconds));
        lastFrameSeconds = now;
        fps = fps <= 1 ? 1f / delta : fps * 0.96f + (1f / delta) * 0.04f;
        time += delta;
        musicalTime += delta * analyzer.TempoBpm / 60f;
        float morphRate = analyzer.TempoConfidence > 0.15f
            ? Math.Clamp(analyzer.TempoBpm / 180f, 0.45f, 1.15f)
            : 0.68f;
        transition = Math.Min(1f, transition + delta * morphRate);
        MaybeShuffle();
        analyzer.Snapshot(spectrum, waveform);
        ShapeSpectrumForDisplay();
        UpdateWaveform(delta);

        target.BeginDraw();
        target.AntialiasMode = AntialiasMode.PerPrimitive;
        var pal = BuildPalette(previousPaletteIndex, paletteIndex, Ease(transition));
        int activeScene = transition < 0.5f ? previousMode : mode;
        target.Clear(SceneBackgroundColor(pal, activeScene));
        float bassShakeScale = BassShakeScale(activeScene);
        float shake = analyzer.TrebleSpark * (1.7f + variantTopEnd * 1.2f)
            + analyzer.SpectralFlux * 0.75f
            + analyzer.BassKick * bassShakeScale
            + analyzer.BeatPulse * analyzer.Bass * bassShakeScale * 0.45f;
        shake = Math.Min(shake, 18f);
        float overscan = 1f + shake / Math.Max(1f, Math.Min(ClientSize.Width, ClientSize.Height)) * 2.4f;
        Vector2 sceneCenter = new(ClientSize.Width * 0.5f, ClientSize.Height * 0.5f);
        target.Transform = Matrix3x2.CreateScale(overscan, sceneCenter)
            * Matrix3x2.CreateTranslation(
                MathF.Sin(time * (43f + variantSeed % 9f)) * shake,
                MathF.Cos(time * (37f + variantSeed % 7f)) * shake * 0.72f);
        if (transition < 1f && previousMode != mode)
        {
            frameOpacity = 1f - Ease(transition);
            RenderSceneBackdrop(target, brush, pal, previousMode);
            frameOpacity = Ease(transition);
            RenderSceneBackdrop(target, brush, pal, mode);
        }
        else
        {
            frameOpacity = 1f;
            RenderSceneBackdrop(target, brush, pal, mode);
        }
        frameOpacity = 1f;

        if (transition < 1f)
            RenderTransitionSequence(target, brush, pal, Ease(transition));
        else
            RenderMode(target, brush, pal, mode);
        frameOpacity = 1f;
        target.Transform = Matrix3x2.Identity;

        target.EndDraw(out _, out _);

        if (now >= nextTitleUpdate)
        {
            Text = $"Windows Music Visualizer GPU - {fps:0} FPS - mode {mode + 1}/{ModeCount}";
            nextTitleUpdate = now + 0.35;
        }
    }

    private void MaybeShuffle()
    {
        DateTime now = DateTime.Now;
        if (!shuffleArmed && now >= nextShuffle)
        {
            shuffleArmed = true;
            shuffleArmedAt = now;
        }

        bool phraseBoundary = analyzer.BeatPulse > 0.48f && ((int)MathF.Floor(musicalTime) & 3) == 0;
        bool musicalCue = analyzer.TempoConfidence > 0.20f ? phraseBoundary : analyzer.Onset > 0.42f;
        if (shuffleArmed && (musicalCue || (now - shuffleArmedAt).TotalSeconds > 3.5))
        {
            shuffleArmed = false;
            RandomizePreset(false);
        }
    }

    private void RandomizePreset(bool first)
    {
        BeginTransition(NextModeFromDeck(first ? -1 : mode), first ? random.Next(palettes.Length) : RandomDifferent(paletteIndex, palettes.Length), first);
        nextShuffle = DateTime.Now.AddSeconds(first ? 20 : random.Next(14, 34));
    }

    private int NextModeFromDeck(int current)
    {
        if (modeDeckIndex >= ModeCount)
        {
            for (int i = 0; i < ModeCount; i++)
                modeDeck[i] = i;
            for (int i = ModeCount - 1; i > 0; i--)
            {
                int swap = random.Next(i + 1);
                (modeDeck[i], modeDeck[swap]) = (modeDeck[swap], modeDeck[i]);
            }
            if (current >= 0 && modeDeck[0] == current)
                (modeDeck[0], modeDeck[1]) = (modeDeck[1], modeDeck[0]);
            modeDeckIndex = 0;
        }

        return modeDeck[modeDeckIndex++];
    }

    private void BeginTransition(int nextMode, int nextPalette, bool first)
    {
        previousMode = first ? nextMode : mode;
        previousColorOffset = colorOffset;
        previousVariantSeed = variantSeed;
        previousVariantThickness = variantThickness;
        previousVariantTwist = variantTwist;
        previousVariantTrail = variantTrail;
        previousVariantStretch = variantStretch;
        previousVariantTopEnd = variantTopEnd;
        mode = nextMode;
        previousPaletteIndex = first ? nextPalette : paletteIndex;
        paletteIndex = nextPalette;
        transition = first ? 1f : 0f;
        variantSeed = (float)random.NextDouble() * 1000f;
        variantThickness = 0.95f + (float)random.NextDouble() * 0.75f;
        variantTwist = 0.72f + (float)random.NextDouble() * 0.75f;
        variantTrail = 0.72f + (float)random.NextDouble() * 0.85f;
        variantStretch = 0.76f + (float)random.NextDouble() * 0.58f;
        variantTopEnd = 0.70f + (float)random.NextDouble() * 0.85f;
        colorOffset = random.Next(palettes[0].Length);
    }

    private int RandomDifferent(int current, int count)
    {
        if (count <= 1) return 0;
        int next = random.Next(count - 1);
        return next >= current ? next + 1 : next;
    }

    private void RenderMode(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal, int modeToRender)
    {
        switch (modeToRender)
        {
            case 0: RenderSilkRibbons(rt, b, pal); break;
            case 1: RenderSpectralTerrain(rt, b, pal); break;
            case 2: RenderAuroraCurtain(rt, b, pal); break;
            case 3: RenderRainbowShards(rt, b, pal); break;
            case 4: RenderRectangularTunnel(rt, b, pal); break;
            case 5: RenderWavefield(rt, b, pal); break;
            case 6: RenderParticleFlow(rt, b, pal); break;
            case 7: RenderBarCity(rt, b, pal); break;
            case 8: RenderChromaticPanels(rt, b, pal); break;
            case 9: RenderRibbonLoom(rt, b, pal); break;
            case 10: RenderPrismGrid(rt, b, pal); break;
            case 11: RenderSpectralRain(rt, b, pal); break;
            case 12: RenderBassBloom(rt, b, pal); break;
            case 13: RenderLiquidColumns(rt, b, pal); break;
            case 14: RenderVocalAurora(rt, b, pal); break;
            case 15: RenderCometTrails(rt, b, pal); break;
            case 16: RenderPulseRunner(rt, b, pal); break;
            case 17: RenderConstellationFlow(rt, b, pal); break;
            default: RenderSpectralPendulums(rt, b, pal); break;
        }

    }

    private void RenderSilkRibbons(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        int ribbons = 12;
        int points = 300;
        float travel = time * (0.045f + analyzer.Brightness * 0.045f) * variantTwist;
        for (int ribbon = 0; ribbon < ribbons; ribbon++)
        {
            float depth = ribbon / (float)(ribbons - 1);
            for (int i = 0; i < points; i++)
            {
                float u = i / (float)(points - 1);
                float wave = SampleSmoothWave(Wrap01(u + travel + ribbon * 0.019f) * (smoothWaveform.Length - 1));
                float band = spectrum[18 + (i * 70 / points + ribbon * 7) % 78];
                float envelope = MathF.Sin(u * MathF.PI);
                float x = u * w;
                float y = h * (0.10f + depth * 0.80f)
                    + MathF.Sin(u * MathF.Tau * (1.25f + ribbon * 0.035f) - time * (0.35f + depth * 0.22f) + variantSeed) * h * (0.055f + analyzer.Vocal * 0.055f)
                    + wave * h * (0.025f + band * 0.040f)
                    + MathF.Sin(u * MathF.Tau * 8f + ribbon) * analyzer.Air * h * 0.012f * envelope;
                pathBuffer[i] = new Vector2(x, y);
            }
            float energy = spectrum[22 + ribbon * 6];
            Color4 color = PaletteColor(pal, ribbon);
            Polyline(rt, b, pathBuffer, points, WithAlpha(color, 0.028f + energy * 0.065f), (10f + energy * 12f) * variantThickness);
            Polyline(rt, b, pathBuffer, points, WithAlpha(color, 0.42f + energy * 0.42f), (1.25f + energy * 2.5f) * variantThickness);
        }
    }

    private void RenderSpectralTerrain(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        int rows = 22;
        int points = 120;
        for (int row = 0; row < rows; row++)
        {
            float depth = (row + 1f) / rows;
            float width = w * (0.12f + depth * 0.98f);
            float baseline = h * (0.22f + depth * 0.72f);
            for (int i = 0; i < points; i++)
            {
                float u = i / (float)(points - 1);
                int bandIndex = (i * spectrum.Length / points + row * 3) % spectrum.Length;
                float band = spectrum[bandIndex];
                float ridge = MathF.Sin(u * MathF.Tau * (2.3f + row * 0.025f) + time * (0.28f + analyzer.Mid * 0.35f) + variantSeed);
                float x = w * 0.5f + (u - 0.5f) * width;
                float y = baseline - band * h * (0.018f + depth * 0.095f)
                    - ridge * h * (0.006f + depth * 0.018f + analyzer.Vocal * 0.012f);
                pathBuffer[i] = new Vector2(x, y);
            }
            Color4 color = PaletteColor(pal, row / 2);
            Polyline(rt, b, pathBuffer, points, WithAlpha(color, 0.025f + depth * 0.035f), (5f + depth * 5f) * variantThickness);
            Polyline(rt, b, pathBuffer, points, WithAlpha(color, 0.16f + depth * 0.44f), (0.75f + depth * 1.2f) * variantThickness);
        }

        for (int ray = 0; ray <= 14; ray++)
        {
            float u = ray / 14f;
            Vector2 top = new(w * (0.44f + u * 0.12f), h * 0.22f);
            Vector2 bottom = new(u * w, h);
            Line(rt, b, top, bottom, WithAlpha(PaletteColor(pal, ray), 0.035f + analyzer.Air * 0.035f), 0.7f * variantThickness);
        }
    }

    private void RenderAuroraCurtain(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        int curtains = 28;
        int points = 130;
        for (int curtain = 0; curtain < curtains; curtain++)
        {
            float lane = (curtain + 0.5f) / curtains;
            float band = spectrum[20 + (curtain * 5) % 76];
            for (int i = 0; i < points; i++)
            {
                float v = i / (float)(points - 1);
                float taper = MathF.Sin(v * MathF.PI);
                float x = lane * w
                    + MathF.Sin(v * MathF.Tau * (1.1f + curtain * 0.013f) + time * (0.42f + analyzer.Vocal * 0.42f) + curtain) * w * (0.018f + band * 0.035f) * taper
                    + MathF.Sin(time * 0.18f + curtain * 0.7f) * w * 0.016f;
                float y = v * h;
                pathBuffer[i] = new Vector2(x, y);
            }
            Color4 color = PaletteColor(pal, curtain / 3);
            Polyline(rt, b, pathBuffer, points, WithAlpha(color, 0.020f + band * 0.055f), (13f + band * 18f) * variantThickness);
            Polyline(rt, b, pathBuffer, points, WithAlpha(color, 0.24f + band * 0.44f + analyzer.Air * 0.10f), (0.9f + band * 2.6f) * variantThickness);
        }
    }

    private void RenderRectangularTunnel(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        Vector2 center = new(
            w * (0.5f + MathF.Sin(time * 0.17f + variantSeed) * 0.12f),
            h * (0.5f + MathF.Cos(time * 0.14f + variantSeed) * 0.10f));
        int frames = 26;
        for (int frame = 0; frame < frames; frame++)
        {
            float cycle = Wrap01(frame / (float)frames + time * (0.095f + analyzer.Brightness * 0.055f));
            float depth = cycle * cycle;
            float halfW = w * (0.035f + depth * 0.68f);
            float halfH = h * (0.035f + depth * 0.68f);
            float skew = MathF.Sin(time * 0.31f + frame * 0.37f) * w * 0.035f * depth;
            pathBuffer[0] = center + new Vector2(-halfW + skew, -halfH);
            pathBuffer[1] = center + new Vector2(halfW + skew * 0.2f, -halfH * (0.86f + analyzer.Vocal * 0.15f));
            pathBuffer[2] = center + new Vector2(halfW - skew, halfH);
            pathBuffer[3] = center + new Vector2(-halfW - skew * 0.2f, halfH * (0.86f + analyzer.Mid * 0.15f));
            pathBuffer[4] = pathBuffer[0];
            float band = spectrum[(frame * 7 + 24) % spectrum.Length];
            Color4 color = PaletteColor(pal, frame);
            Polyline(rt, b, pathBuffer, 5, WithAlpha(color, 0.025f + band * 0.055f), (7f + band * 9f) * variantThickness);
            Polyline(rt, b, pathBuffer, 5, WithAlpha(color, 0.22f + band * 0.46f), (0.85f + band * 2.1f) * variantThickness);
        }
    }

    private void RenderParticleFlow(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        int particles = 340;
        for (int i = 0; i < particles; i++)
        {
            float seedX = Hash01(i * 17 + 31);
            float seedY = Hash01(i * 41 + 7);
            float band = spectrum[(i * 13 + 20) % spectrum.Length];
            float speed = 0.020f + Hash01(i * 23) * 0.055f + analyzer.Air * 0.025f;
            float y = Wrap01(seedY + musicalTime * speed) * h;
            float flow = MathF.Sin(y / h * MathF.Tau * 2.1f + musicalTime * 0.72f + seedX * 9f);
            float x = Wrap01(seedX + flow * (0.035f + analyzer.Vocal * 0.045f) + musicalTime * 0.006f) * w;
            float length = 7f + band * 42f + analyzer.Onset * 18f;
            Vector2 head = new(x, y);
            Vector2 tail = new(x - flow * length * 0.45f, y - length);
            Color4 color = PaletteColor(pal, i);
            Line(rt, b, tail, head, WithAlpha(color, 0.055f + band * 0.28f), (1.0f + band * 2.1f) * variantThickness);
            if (band + analyzer.TrebleSpark > 1.05f)
                Dot(rt, b, head, 1.2f + band * 2.8f, WithAlpha(Rgb(255, 255, 255), 0.20f + analyzer.TrebleSpark * 0.28f));
        }
    }

    private void RenderOscilloscopeGarden(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        float baseline = h * 0.86f;
        int stems = 72;
        int points = 16;
        for (int stem = 0; stem < stems; stem++)
        {
            float u = (stem + 0.5f) / stems;
            float band = BassAwareHeight(stem * spectrum.Length / stems, spectrum[stem * spectrum.Length / stems]);
            float height = h * (0.08f + band * 0.63f);
            float sway = MathF.Sin(musicalTime * MathF.Tau * 0.18f + stem * 0.42f) * (8f + analyzer.Vocal * 32f);
            for (int i = 0; i < points; i++)
            {
                float v = i / (float)(points - 1);
                float x = u * w + MathF.Sin(v * MathF.PI) * sway + MathF.Sin(v * 8f + time * 1.2f + stem) * analyzer.Air * 5f;
                float y = baseline - v * height;
                pathBuffer[i] = new Vector2(x, y);
            }
            Color4 color = PaletteColor(pal, stem / 5);
            Polyline(rt, b, pathBuffer, points, WithAlpha(color, 0.025f + band * 0.055f), (7f + band * 9f) * variantThickness);
            Polyline(rt, b, pathBuffer, points, WithAlpha(color, 0.28f + band * 0.48f), (0.9f + band * 2.2f) * variantThickness);
            if ((stem & 3) == 0 && band + analyzer.Onset > 0.72f)
            {
                Vector2 top = pathBuffer[points - 1];
                float petal = 3f + band * 8f + analyzer.BeatPulse * 4f;
                FillTriangle(rt, b, top + new Vector2(0, -petal), top + new Vector2(petal, petal), top + new Vector2(-petal, petal), WithAlpha(color, 0.18f + band * 0.38f));
            }
        }
        Line(rt, b, new Vector2(0, baseline), new Vector2(w, baseline), WithAlpha(PaletteColor(pal, 3), 0.18f), 1.2f);
    }

    private void RenderRibbonLoom(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        int points = 360;
        float turns = 2.4f + variantTwist * 0.72f + analyzer.MidPunch * 0.45f;
        float rotation = musicalTime * MathF.Tau * (0.16f + analyzer.Brightness * 0.12f);
        float amplitude = h * (0.23f + analyzer.Bass * 0.10f + analyzer.BassKick * 0.09f);
        float centerDrift = MathF.Sin(time * 0.19f + variantSeed) * h * (0.025f + analyzer.Vocal * 0.035f);

        for (int ghost = 2; ghost >= 0; ghost--)
        {
            float ghostPhase = ghost * (0.10f + variantTrail * 0.025f);
            float ghostAlpha = ghost == 0 ? 1f : (3 - ghost) * 0.055f;
            for (int strand = 0; strand < 2; strand++)
            {
                for (int i = 0; i < points; i++)
                {
                    float u = i / (float)(points - 1);
                    float spec = spectrum[(i * spectrum.Length / points + strand * 37) % spectrum.Length];
                    float sample = SampleSmoothWave(Wrap01(u + time * 0.036f + strand * 0.13f) * (smoothWaveform.Length - 1));
                    float phase = u * MathF.Tau * turns - rotation - ghostPhase + strand * MathF.PI;
                    float depth = MathF.Cos(phase);
                    float envelope = 0.72f + MathF.Sin(u * MathF.PI) * 0.28f;
                    float centerY = h * 0.5f + centerDrift
                        + MathF.Sin(u * MathF.Tau * 0.72f - time * 0.31f + variantSeed) * h * analyzer.Vocal * 0.075f;
                    float y = centerY
                        + MathF.Sin(phase) * amplitude * envelope
                        + sample * h * (0.018f + spec * 0.060f + analyzer.Vocal * 0.028f);
                    float x = u * w + depth * w * (0.010f + analyzer.Air * 0.018f) * envelope;
                    pathBuffer[i] = new Vector2(x, y);
                }

                float energy = strand == 0 ? Math.Max(analyzer.Bass, analyzer.MidPunch) : Math.Max(analyzer.Vocal, analyzer.Treble);
                Color4 color = ToneColor(PaletteColor(pal, strand + ghost + 1), 1.18f, 0.72f + energy * 0.68f);
                if (ghost > 0)
                    Polyline(rt, b, pathBuffer, points, WithAlpha(color, ghostAlpha + energy * 0.030f), (1.0f + ghost * 1.4f) * variantThickness);
                else
                {
                    Polyline(rt, b, pathBuffer, points, WithAlpha(color, 0.020f + energy * 0.060f), (15f + energy * 16f) * variantThickness);
                    Polyline(rt, b, pathBuffer, points, WithAlpha(color, 0.46f + energy * 0.42f), (1.25f + energy * 3.0f) * variantThickness);
                }
            }
        }

        int rungs = 64;
        for (int rung = 0; rung < rungs; rung++)
        {
            float u = (rung + 0.5f) / rungs;
            float phase = u * MathF.Tau * turns - rotation;
            float depth = 0.5f + 0.5f * MathF.Cos(phase);
            float spec = spectrum[(rung * 5 + 18) % spectrum.Length];
            float envelope = 0.72f + MathF.Sin(u * MathF.PI) * 0.28f;
            float centerY = h * 0.5f + centerDrift
                + MathF.Sin(u * MathF.Tau * 0.72f - time * 0.31f + variantSeed) * h * analyzer.Vocal * 0.075f;
            float sample = SampleSmoothWave(Wrap01(u + time * 0.036f) * (smoothWaveform.Length - 1));
            float displacement = MathF.Sin(phase) * amplitude * envelope;
            float detail = sample * h * (0.012f + spec * 0.050f);
            float x = u * w + MathF.Cos(phase) * w * (0.010f + analyzer.Air * 0.018f) * envelope;
            Vector2 top = new(x, centerY + displacement + detail);
            Vector2 bottom = new(x, centerY - displacement - detail);
            float travelingPulse = MathF.Exp(-MathF.Abs(WrapSigned(u - analyzer.BeatPhase)) * 11f) * analyzer.BeatPulse;
            float response = Math.Clamp(spec * 0.62f + depth * 0.22f + travelingPulse * 0.55f, 0, 1);
            Color4 color = ToneColor(PaletteColor(pal, rung / 8), 1.10f + response * 0.42f, 0.62f + response * 0.76f);
            Line(rt, b, top, bottom, WithAlpha(color, 0.045f + response * 0.36f), (0.65f + response * 2.4f) * variantThickness);
            if ((rung & 3) == 0 && spec + analyzer.TrebleSpark > 0.72f)
                Dot(rt, b, depth > 0.5f ? top : bottom, 1.2f + spec * 3.2f + analyzer.TrebleSpark * 1.6f, WithAlpha(Rgb(255, 255, 255), 0.12f + spec * 0.40f));
        }
    }

    private void RenderPrismGrid(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        int columns = 18;
        int rows = 11;
        for (int row = 0; row < rows - 1; row++)
        {
            for (int column = 0; column < columns - 1; column++)
            {
                if (((row + column) & 1) != 0)
                    continue;
                float band = spectrum[(column * 5 + row * 9) % spectrum.Length];
                float pulse = 0.5f + 0.5f * MathF.Sin(musicalTime * MathF.Tau - column * 0.34f - row * 0.52f);
                Color4 fill = ToneColor(PaletteColor(pal, row + column), 1.20f, 0.48f + band * 0.72f + pulse * analyzer.BeatPulse * 0.30f);
                Vector2 p1 = PrismNode(column, row, columns, rows, w, h);
                Vector2 p2 = PrismNode(column + 1, row, columns, rows, w, h);
                Vector2 p3 = PrismNode(column + 1, row + 1, columns, rows, w, h);
                Vector2 p4 = PrismNode(column, row + 1, columns, rows, w, h);
                float alpha = 0.005f + band * 0.045f + pulse * analyzer.BeatPulse * 0.018f;
                FillTriangle(rt, b, p1, p2, p3, WithAlpha(fill, alpha));
                FillTriangle(rt, b, p1, p3, p4, WithAlpha(fill, alpha * 0.72f));
            }
        }

        for (int row = 0; row < rows; row++)
        {
            for (int column = 0; column < columns; column++)
                pathBuffer[column] = PrismNode(column, row, columns, rows, w, h);
            float band = spectrum[20 + row * 6];
            float impact = Math.Clamp(band * 0.70f + analyzer.BassKick * 0.42f + analyzer.BeatPulse * 0.22f, 0, 1);
            Color4 color = ToneColor(PaletteColor(pal, row), 1.05f + impact * 0.45f, 0.70f + impact * 0.62f);
            Polyline(rt, b, pathBuffer, columns, WithAlpha(color, 0.12f + impact * 0.56f), (0.85f + impact * 3.2f) * variantThickness);
        }
        for (int column = 0; column < columns; column++)
        {
            for (int row = 0; row < rows; row++)
                pathBuffer[row] = PrismNode(column, row, columns, rows, w, h);
            float band = spectrum[25 + (column * 4) % 68];
            float impact = Math.Clamp(band * 0.68f + analyzer.MidPunch * 0.38f + analyzer.Vocal * 0.18f, 0, 1);
            Color4 color = ToneColor(PaletteColor(pal, column + 1), 1.02f + impact * 0.38f, 0.66f + impact * 0.58f);
            Polyline(rt, b, pathBuffer, rows, WithAlpha(color, 0.10f + impact * 0.48f), (0.72f + impact * 2.7f) * variantThickness);
        }
    }

    private Vector2 PrismNode(int column, int row, int columns, int rows, float w, float h)
    {
        float u = column / (float)(columns - 1);
        float v = row / (float)(rows - 1);
        float band = spectrum[(column * 5 + row * 9) % spectrum.Length];
        float dx = u - 0.5f;
        float dy = v - 0.5f;
        float radius = MathF.Sqrt(dx * dx + dy * dy);
        float lowWave = MathF.Sin((u * 1.25f + v * 0.72f) * MathF.Tau - musicalTime * MathF.Tau * 0.24f);
        float midWave = MathF.Sin((u * 2.20f - v * 1.45f) * MathF.Tau + musicalTime * MathF.Tau * 0.19f + variantSeed);
        float shockPosition = Wrap01(analyzer.BeatPhase * 1.15f) * 0.82f;
        float shock = MathF.Exp(-MathF.Abs(radius - shockPosition) * 15f) * analyzer.Bass * (0.35f + analyzer.BeatPulse * 0.65f);
        float depth = lowWave * (0.012f + band * 0.070f) + midWave * analyzer.Vocal * 0.025f + shock * 0.095f;
        float scale = 1f + depth;
        float x = w * (0.5f + dx * scale)
            + MathF.Sin(v * MathF.Tau * 1.6f + musicalTime * 1.25f + column * 0.31f) * w * (0.006f + band * 0.040f + analyzer.MidPunch * 0.012f);
        float y = h * (0.5f + dy * scale)
            + MathF.Sin(u * MathF.Tau * 2.1f - musicalTime * 1.08f + row * 0.43f) * h * (0.008f + band * 0.058f + analyzer.BassKick * 0.018f);
        return new Vector2(x, y);
    }

    private void RenderSpectralRain(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        int drops = 150;
        for (int i = 0; i < drops; i++)
        {
            float seed = Hash01(i * 37 + 5);
            float band = spectrum[18 + (i * 11) % 78];
            float fall = Wrap01(Hash01(i * 19) + musicalTime * (0.035f + seed * 0.085f + analyzer.Air * 0.025f));
            float x = (i + 0.5f) / drops * w + MathF.Sin(time * 0.28f + i) * w * 0.004f;
            float y = fall * h;
            float length = h * (0.025f + band * 0.16f + analyzer.Onset * 0.035f);
            Color4 color = PaletteColor(pal, i / 10);
            Line(rt, b, new Vector2(x, y - length), new Vector2(x, y), WithAlpha(color, 0.035f + band * 0.10f), (5f + band * 7f) * variantThickness);
            Line(rt, b, new Vector2(x, y - length), new Vector2(x, y), WithAlpha(color, 0.24f + band * 0.48f), (0.8f + band * 1.8f) * variantThickness);
        }
    }

    private void RenderLiquidColumns(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        float centerY = h * 0.5f;
        int columns = 72;
        float cell = w / columns;
        for (int i = 0; i < columns; i++)
        {
            float band = BassAwareHeight(i * spectrum.Length / columns, spectrum[i * spectrum.Length / columns]);
            float ripple = 0.72f + 0.28f * MathF.Sin(musicalTime * MathF.Tau + i * 0.21f);
            float height = h * (0.025f + band * 0.42f * ripple);
            float x = i * cell + cell * 0.12f;
            Color4 color = PaletteColor(pal, i / 8);
            FillRect(rt, b, x, centerY - height, x + cell * 0.76f, centerY + height, WithAlpha(color, 0.18f + band * 0.52f));
            Line(rt, b, new Vector2(x, centerY - height), new Vector2(x + cell * 0.76f, centerY - height), WithAlpha(Rgb(255, 255, 255), 0.10f + analyzer.Air * 0.25f), 1.0f);
            Line(rt, b, new Vector2(x, centerY + height), new Vector2(x + cell * 0.76f, centerY + height), WithAlpha(color, 0.24f), 1.0f);
        }
    }

    private void RenderChromaticPanels(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        int columns = 11;
        int rows = 7;
        float cellW = w / columns;
        float cellH = h / rows;
        for (int row = 0; row < rows; row++)
        {
            for (int column = 0; column < columns; column++)
            {
                int bandIndex = (column * 7 + row * 13) % spectrum.Length;
                float band = spectrum[bandIndex];
                float beatPush = analyzer.BeatPulse * (6f + band * 18f);
                float sway = MathF.Sin(musicalTime * MathF.Tau * 0.16f + column * 0.7f + row) * (4f + band * 16f);
                float left = column * cellW + 2f;
                float top = row * cellH + 2f;
                Vector2 p1 = new(left + sway, top - beatPush);
                Vector2 p2 = new(left + cellW - 3f, top + sway * 0.35f);
                Vector2 p3 = new(left + cellW - sway * 0.28f, top + cellH - 3f + beatPush);
                Vector2 p4 = new(left + 3f, top + cellH - sway * 0.45f);
                float beatWave = 0.5f + 0.5f * MathF.Sin(musicalTime * MathF.Tau - column * 0.62f - row * 0.48f);
                float impact = Math.Clamp(band * 0.64f + beatWave * analyzer.BeatPulse * 0.48f + analyzer.BassKick * 0.30f, 0, 1);
                Color4 color = ToneColor(PaletteColor(pal, column + row * 2), 0.92f + impact * 0.82f, 0.48f + analyzer.Level * 0.24f + impact * 0.88f);
                float alpha = 0.045f + band * 0.31f + impact * 0.16f;
                FillTriangle(rt, b, p1, p2, p3, WithAlpha(color, alpha));
                FillTriangle(rt, b, p1, p3, p4, WithAlpha(color, alpha * 0.72f));
                Color4 glint = ToneColor(PaletteColor(pal, column + row + 1), 1.25f, 0.72f + impact * 0.72f);
                Line(rt, b, p1, p3, WithAlpha(glint, 0.05f + band * 0.30f + analyzer.TrebleSpark * beatWave * 0.18f), (0.65f + impact * 2.1f) * variantThickness);
            }
        }
    }

    private void RenderPulseRunner(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        int climbers = 3;
        int points = 420;
        for (int climber = 0; climber < climbers; climber++)
        {
            float reaction = climber switch
            {
                0 => Math.Clamp(analyzer.Bass * 0.40f + analyzer.BassKick * 0.85f + analyzer.BeatPulse * 0.20f, 0, 1),
                1 => Math.Clamp(analyzer.Vocal * 0.62f + analyzer.MidPunch * 0.65f + analyzer.TrebleSpark * 0.18f, 0, 1),
                _ => Math.Clamp(analyzer.Treble * 0.52f + analyzer.Air * 0.42f + analyzer.TrebleSpark * 0.72f, 0, 1)
            };
            float head = Wrap01(musicalTime * (0.054f + climber * 0.006f) + Hash01((int)variantSeed + climber * 73));
            for (int i = 0; i < points; i++)
            {
                float u = i / (float)(points - 1);
                float localBand = spectrum[(climber * 31 + i / 5 + 12) % spectrum.Length];
                float sample = SampleSmoothWave(Wrap01(u + time * (0.028f + climber * 0.008f)) * (smoothWaveform.Length - 1));
                float distanceToHead = MathF.Abs(u - head);
                float liftEnvelope = MathF.Exp(-distanceToHead * 13f);
                float laneOffset = (climber - 1f) * h * 0.105f;
                float steadyClimb = h * (0.88f - u * 0.72f) + laneOffset;
                float route = MathF.Sin(u * MathF.Tau * (1.55f + climber * 0.27f) - time * (0.46f + climber * 0.08f) + variantSeed)
                    * h * (0.020f + reaction * 0.070f + localBand * 0.025f);
                float detail = sample * h * (0.008f + reaction * 0.070f + localBand * 0.026f);
                float lift = liftEnvelope * reaction * h * (0.055f + climber * 0.012f);
                float x = u * w;
                float y = steadyClimb + route + detail - lift;
                pathBuffer[i] = new Vector2(x, y);
            }

            Color4 color = ToneColor(PaletteColor(pal, climber + 1), 1.24f, 0.72f + reaction * 0.70f);
            Polyline(rt, b, pathBuffer, points, WithAlpha(color, 0.018f + reaction * 0.030f), (13f + reaction * 15f) * variantThickness);
            Polyline(rt, b, pathBuffer, points, WithAlpha(color, 0.09f + reaction * 0.14f), (0.78f + reaction * 1.3f) * variantThickness);
            int segments = 10;
            for (int segment = 0; segment < segments; segment++)
            {
                float fade = (segment + 1f) / segments;
                float start = head * segment / segments;
                float end = head * (segment + 1f) / segments;
                DrawPathInterval(rt, b, pathBuffer, points, start, end, WithAlpha(color, (0.08f + fade * 0.72f) * (0.74f + reaction * 0.36f)), (0.85f + fade * 2.4f + reaction * 1.9f) * variantThickness);
            }
            Vector2 headPoint = pathBuffer[Math.Clamp((int)(head * (points - 1)), 0, points - 1)];
            Dot(rt, b, headPoint, (8f + reaction * 12f) * variantThickness, WithAlpha(color, 0.07f + reaction * 0.12f));
            Dot(rt, b, headPoint, (2.6f + reaction * 5.2f) * variantThickness, WithAlpha(Rgb(255, 255, 255), 0.56f + reaction * 0.38f));
        }
    }

    private void RenderConstellationFlow(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        int nodes = 104;
        for (int i = 0; i < nodes; i++)
        {
            float seedX = Hash01(i * 53 + 11);
            float seedY = Hash01(i * 97 + 29);
            float band = spectrum[(i * 17 + 18) % spectrum.Length];
            float x = Wrap01(seedX + musicalTime * (0.004f + Hash01(i * 7) * 0.012f)) * w;
            float y = h * (seedY + MathF.Sin(musicalTime * MathF.Tau * 0.11f + i * 0.73f) * (0.025f + band * 0.060f));
            constellationNodes[i] = new Vector2(x, Math.Clamp(y, 0, h));
        }

        float maxDistance = Math.Min(w, h) * (0.14f + analyzer.Vocal * 0.045f);
        float maxDistanceSq = maxDistance * maxDistance;
        for (int i = 0; i < nodes; i++)
        {
            float band = spectrum[(i * 17 + 18) % spectrum.Length];
            for (int step = 1; step <= 4; step++)
            {
                int j = (i + step * 13) % nodes;
                float distanceSq = Vector2.DistanceSquared(constellationNodes[i], constellationNodes[j]);
                if (distanceSq > maxDistanceSq)
                    continue;
                float closeness = 1f - MathF.Sqrt(distanceSq) / maxDistance;
                Line(rt, b, constellationNodes[i], constellationNodes[j], WithAlpha(PaletteColor(pal, i / 9), (0.035f + band * 0.16f) * closeness), (0.6f + band * 1.2f) * variantThickness);
            }
            float spark = Math.Max(band, analyzer.TrebleSpark * Hash01(i * 31));
            Dot(rt, b, constellationNodes[i], 1.0f + spark * 3.3f, WithAlpha(PaletteColor(pal, i), 0.18f + spark * 0.46f));
        }
    }

    private void RenderSpectralPendulums(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        int pendulums = 52;
        for (int i = 0; i < pendulums; i++)
        {
            float lane = (i + 0.5f) / pendulums;
            int bandIndex = i * spectrum.Length / pendulums;
            float band = spectrum[bandIndex];
            bool fromTop = (i & 1) == 0;
            float anchorY = fromTop ? 0 : h;
            float reach = h * (0.12f + band * 0.70f);
            float bobY = fromTop ? reach : h - reach;
            float swing = MathF.Sin(musicalTime * MathF.Tau * (0.18f + bandIndex * 0.0008f) + i * 0.44f)
                * w * (0.012f + band * 0.030f + analyzer.BeatPulse * 0.010f);
            Vector2 anchor = new(lane * w, anchorY);
            Vector2 bob = new(lane * w + swing, bobY);
            Color4 color = PaletteColor(pal, i / 6);
            Line(rt, b, anchor, bob, WithAlpha(color, 0.025f + band * 0.060f), (7f + band * 9f) * variantThickness);
            Line(rt, b, anchor, bob, WithAlpha(color, 0.25f + band * 0.50f), (0.8f + band * 1.8f) * variantThickness);
            Dot(rt, b, bob, 1.8f + band * 5.5f + analyzer.Onset * 2f, WithAlpha(Rgb(255, 255, 255), 0.18f + band * 0.52f));
        }
    }

    private Color4 SceneBackgroundColor(Color4[] pal, int scene)
    {
        Color4 primary = PaletteColorAtOffset(pal, scene, colorOffset);
        Color4 secondary = PaletteColorAtOffset(pal, scene + 2, colorOffset);
        float depth = 0.018f + analyzer.Level * 0.030f + analyzer.Bass * 0.014f + analyzer.Brightness * 0.010f;
        return new Color4(
            (primary.R * 0.68f + secondary.R * 0.32f) * depth,
            (primary.G * 0.68f + secondary.G * 0.32f) * depth,
            (primary.B * 0.68f + secondary.B * 0.32f) * depth,
            1f);
    }

    private void RenderSceneBackdrop(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal, int scene)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        float activity = Math.Clamp(analyzer.Level * 0.55f + analyzer.Bass * 0.28f + analyzer.Vocal * 0.17f, 0, 1);
        float pulse = analyzer.BeatPulse * (0.45f + analyzer.Bass * 0.55f);
        Color4 a = ToneColor(PaletteColorAtOffset(pal, scene + 1, colorOffset), 1.12f, 0.72f + activity * 0.36f);
        Color4 c = ToneColor(PaletteColorAtOffset(pal, scene + 3, colorOffset), 1.06f, 0.62f + activity * 0.30f);
        float alpha = 0.028f + activity * 0.050f + pulse * 0.028f;

        if (scene == 16)
        {
            RenderAscendingBackdrop(rt, b, pal, activity, pulse);
            return;
        }

        switch (scene % 5)
        {
            case 0:
            {
                float focus = w * (0.42f + Hash01(scene * 31) * 0.16f);
                FillTriangle(rt, b, new Vector2(0, 0), new Vector2(focus + pulse * w * 0.05f, h * 0.42f), new Vector2(0, h), WithAlpha(a, alpha));
                FillTriangle(rt, b, new Vector2(w, 0), new Vector2(focus - pulse * w * 0.04f, h * 0.58f), new Vector2(w, h), WithAlpha(c, alpha * 0.84f));
                break;
            }
            case 1:
            {
                for (int layer = 0; layer < 5; layer++)
                {
                    float depth = (layer + 1f) / 5f;
                    float y = h * (0.46f + depth * depth * 0.55f);
                    float half = w * (0.10f + depth * 0.58f + pulse * 0.025f);
                    float thickness = h * (0.020f + depth * 0.035f);
                    FillQuad(rt, b,
                        new Vector2(w * 0.5f - half * 0.18f, y - thickness),
                        new Vector2(w * 0.5f + half * 0.18f, y - thickness),
                        new Vector2(w * 0.5f + half, y + thickness),
                        new Vector2(w * 0.5f - half, y + thickness),
                        WithAlpha(layer % 2 == 0 ? a : c, alpha * (0.64f - depth * 0.20f)));
                }
                break;
            }
            case 2:
            {
                Vector2 focus = new(w * 0.48f, h * 0.52f);
                for (int plane = 0; plane < 4; plane++)
                {
                    float topStart = (plane * 0.28f - 0.18f) * w;
                    float bottomStart = ((plane + 1) * 0.26f - 0.14f) * w;
                    FillTriangle(rt, b,
                        new Vector2(topStart, -h * 0.12f),
                        new Vector2(topStart + w * 0.62f, -h * 0.12f),
                        focus + new Vector2((plane - 1.5f) * w * 0.06f, 0),
                        WithAlpha(plane % 2 == 0 ? a : c, alpha * 0.45f));
                    FillTriangle(rt, b,
                        new Vector2(bottomStart, h * 1.12f),
                        new Vector2(bottomStart + w * 0.62f, h * 1.12f),
                        focus + new Vector2((1.5f - plane) * w * 0.06f, 0),
                        WithAlpha(plane % 2 == 0 ? c : a, alpha * 0.40f));
                }
                break;
            }
            case 3:
            {
                Vector2 focus = new(w * (0.46f + Hash01(scene * 43) * 0.08f), h * (0.44f + Hash01(scene * 59) * 0.12f));
                FillTriangle(rt, b, new Vector2(0, 0), new Vector2(w * 0.62f, 0), focus, WithAlpha(a, alpha * 0.72f));
                FillTriangle(rt, b, new Vector2(w, h), new Vector2(w * 0.28f, h), focus, WithAlpha(c, alpha));
                FillTriangle(rt, b, new Vector2(w, 0), new Vector2(w, h * 0.54f), focus, WithAlpha(a, alpha * 0.48f));
                break;
            }
            default:
            {
                float inset = Math.Min(w, h) * (0.075f + pulse * 0.025f);
                FillQuad(rt, b,
                    new Vector2(inset, 0), new Vector2(w - inset, 0),
                    new Vector2(w, h * 0.30f), new Vector2(0, h * 0.22f),
                    WithAlpha(a, alpha * 0.58f));
                FillQuad(rt, b,
                    new Vector2(0, h * 0.78f), new Vector2(w, h * 0.70f),
                    new Vector2(w - inset, h), new Vector2(inset, h),
                    WithAlpha(c, alpha * 0.72f));
                break;
            }
        }
    }

    private void RenderAscendingBackdrop(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal, float activity, float pulse)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        int bands = 8;
        for (int band = 0; band < bands; band++)
        {
            float climb = Wrap01(time * (0.025f + analyzer.Bass * 0.022f) + band / (float)bands);
            float y = h * (1.30f - climb * 1.65f);
            float thickness = h * (0.055f + activity * 0.025f + pulse * 0.018f);
            Color4 color = ToneColor(PaletteColor(pal, band), 1.08f, 0.50f + activity * 0.58f);
            FillQuad(rt, b,
                new Vector2(-w * 0.12f, y),
                new Vector2(w * 0.08f, y + thickness),
                new Vector2(w * 1.12f, y - h * 0.68f + thickness),
                new Vector2(w * 0.92f, y - h * 0.68f),
                WithAlpha(color, 0.024f + activity * 0.050f + pulse * 0.024f));
        }
    }

    private static float BassShakeScale(int scene)
    {
        return scene switch
        {
            3 or 4 or 7 or 8 or 11 or 12 or 13 or 15 or 16 => 7.2f,
            1 or 5 or 10 or 18 => 3.4f,
            _ => 1.1f
        };
    }

    private void ShapeSpectrumForDisplay()
    {
        float transientLift = 1f + analyzer.Onset * 0.24f;
        for (int i = 0; i < spectrum.Length; i++)
        {
            float lowTrim = i < 16 ? 0.90f + i * 0.0055f : 1.04f;
            float value = Math.Clamp((spectrum[i] - 0.08f) * 1.18f + 0.08f, 0, 1);
            spectrum[i] = Math.Clamp(MathF.Pow(value, 0.90f) * lowTrim * transientLift, 0, 1);
        }
    }

    private void RenderReactiveBackdrop(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        Vector2 center = new(w * 0.5f, h * 0.5f);
        float max = Math.Min(w, h);
        int rings = 8;
        int points = 180;
        float drift = time * (0.045f + analyzer.Brightness * 0.04f);
        for (int ring = 0; ring < rings; ring++)
        {
            float depth = ring / (float)(rings - 1);
            float rx = max * (0.24f + depth * 0.46f + analyzer.BassKick * 0.030f);
            float ry = rx * (0.48f + depth * 0.12f);
            Vector2 last = default;
            for (int i = 0; i <= points; i++)
            {
                float p = i / (float)points;
                float a = p * MathF.Tau + drift + ring * 0.33f;
                float spec = spectrum[(i * 3 + ring * 13) % spectrum.Length];
                float lace = MathF.Sin(a * (3.0f + ring * 0.45f) + time * (0.55f + analyzer.MidPunch * 0.50f)) * max * (0.010f + spec * 0.015f);
                Vector2 next = center + new Vector2(MathF.Cos(a) * (rx + lace), MathF.Sin(a) * (ry + lace));
                next.X += MathF.Sin(a * 0.7f + time * 0.18f) * max * 0.035f;
                next.Y += MathF.Cos(a * 0.9f - time * 0.16f) * max * 0.025f;
                if (i > 0)
                    Line(rt, b, last, next, WithAlpha(pal[(ring + 2) % pal.Length], 0.010f + spec * 0.030f + analyzer.SpectralFlux * 0.012f), 0.55f + spec * 0.9f);
                last = next;
            }
        }

        for (int flare = 0; flare < 4; flare++)
        {
            float phase = time * (0.10f + flare * 0.018f) + variantSeed + flare * 1.7f;
            float pulse = 0.5f + 0.5f * MathF.Sin(time * (0.34f + flare * 0.07f) + flare);
            Vector2 flareCenter = center + new Vector2(
                MathF.Sin(phase * 1.3f) * w * 0.20f,
                MathF.Cos(phase) * h * 0.15f);
            float rx = max * (0.16f + flare * 0.075f + analyzer.Vocal * 0.035f);
            float ry = rx * (0.30f + variantStretch * 0.12f);
            Color4 color = PaletteColor(pal, flare + 1);
            EllipseOutline(rt, b, flareCenter, rx, ry, WithAlpha(color, (0.008f + analyzer.Air * 0.016f) * pulse), 18f + analyzer.SpectralFlux * 16f);
            EllipseOutline(rt, b, flareCenter, rx, ry, WithAlpha(color, (0.020f + analyzer.Vocal * 0.030f) * pulse), 1.0f + analyzer.TrebleSpark * 1.4f);
        }
    }

    private void RenderSpectralCorona(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        Vector2 center = new(
            w * (0.5f + MathF.Sin(time * 0.11f + variantSeed) * 0.025f),
            h * (0.5f + MathF.Cos(time * 0.09f + variantSeed) * 0.020f));
        int rings = 15;
        int points = 240;
        float voice = analyzer.Vocal;
        float sparkle = analyzer.Air * 0.55f + analyzer.TrebleSpark * 0.75f;
        for (int r = 0; r < rings; r++)
        {
            float ringBase = Math.Min(w, h) * (0.075f + r * 0.031f + analyzer.Bass * 0.012f);
            for (int i = 0; i <= points; i++)
            {
                float p = i / (float)points;
                float a = p * MathF.Tau + time * (0.16f + r * 0.018f + analyzer.Brightness * 0.16f) * variantTwist;
                float spec = spectrum[(i + r * 11) % spectrum.Length];
                float jag = MathF.Sin(a * (7 + r) + time * (1.7f + voice * 2.2f)) * (8f + voice * 28f)
                    + spec * Math.Min(w, h) * (0.060f + sparkle * 0.035f)
                    + MathF.Sin(a * 3f - time * 0.5f + variantSeed) * analyzer.MidPunch * 18f;
                float radius = ringBase + jag;
                pathBuffer[i] = center + new Vector2(MathF.Cos(a) * radius, MathF.Sin(a) * radius * variantStretch);
            }

            float band = spectrum[(r * 7 + 19) % spectrum.Length];
            Color4 color = PaletteColor(pal, r);
            Polyline(rt, b, pathBuffer, points + 1, WithAlpha(color, 0.030f + band * 0.09f), (5.0f + band * 8.0f) * variantThickness);
            Polyline(rt, b, pathBuffer, points + 1, WithAlpha(color, 0.42f + band * 0.42f + sparkle * 0.10f), (1.15f + band * 2.2f) * variantThickness);
        }
    }

    private void RenderMagentaVortex(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        Vector2 center = new(w * 0.5f, h * 0.5f);
        int arms = 38;
        int points = 170;
        float maxR = Math.Max(w, h) * 0.76f;
        for (int arm = 0; arm < arms; arm++)
        {
            Vector2 last = center;
            float phase = arm * MathF.Tau / arms;
            for (int i = 1; i < points; i++)
            {
                float t = i / (float)(points - 1);
                float spec = spectrum[(i * 2 + arm * 3) % spectrum.Length];
                float a = phase + t * (10.8f + analyzer.MidPunch * 4.5f) + time * (0.68f + analyzer.Treble * 0.35f + analyzer.Brightness * 0.55f);
                float r = maxR * t * t + spec * (80f + analyzer.TrebleSpark * 120f) + analyzer.BassKick * 55f * MathF.Sin(t * MathF.PI);
                Vector2 next = center + new Vector2(MathF.Cos(a) * r, MathF.Sin(a) * r * 0.68f);
                Line(rt, b, last, next, WithAlpha(pal[arm % pal.Length], 0.08f + spec * 0.52f + analyzer.TrebleSpark * 0.12f), 0.55f + spec * 2.5f + analyzer.BassKick);
                last = next;
            }
        }
    }

    private void RenderElectricWeb(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        Vector2 center = new(w * (0.5f + MathF.Sin(time * 0.33f) * 0.08f), h * (0.5f + MathF.Cos(time * 0.29f) * 0.07f));
        int strands = 190;
        int points = 28;
        for (int s = 0; s < strands; s++)
        {
            Vector2 last = center;
            float a = s * MathF.Tau / strands + MathF.Sin(time * 0.4f + s) * 0.22f;
            float source = spectrum[(s * 5) % spectrum.Length];
            float reach = Math.Max(w, h) * (0.16f + source * 0.66f + analyzer.BassKick * 0.08f);
            for (int i = 1; i < points; i++)
            {
                float t = i / (float)(points - 1);
                float kink = MathF.Sin(t * (18f + analyzer.MidPunch * 8f) + time * (3.1f + analyzer.TrebleSpark * 4f) + s) * (16f + analyzer.Treble * 46f + analyzer.SpectralFlux * 55f);
                float r = reach * t + analyzer.BassKick * 95f * MathF.Sin(t * MathF.PI);
                Vector2 dir = new(MathF.Cos(a), MathF.Sin(a));
                Vector2 side = new(-dir.Y, dir.X);
                Vector2 next = center + dir * r + side * kink;
                Line(rt, b, last, next, WithAlpha(pal[s % pal.Length], 0.07f + source * 0.42f + analyzer.TrebleSpark * 0.16f), 0.65f + analyzer.Beat * 1.8f + source * 1.2f);
                last = next;
            }
        }
    }

    private void RenderRainbowShards(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        Vector2 center = new(w * (0.50f + MathF.Sin(time * 0.31f) * 0.06f), h * (0.50f + MathF.Cos(time * 0.27f) * 0.05f));
        int shards = 144;
        for (int i = 0; i < shards; i++)
        {
            float spec = spectrum[(i * 7) % spectrum.Length];
            float a = i * MathF.Tau / shards + musicalTime * MathF.Tau * (0.025f + analyzer.Brightness * 0.022f);
            float beatRipple = MathF.Sin(musicalTime * MathF.Tau - i * 0.16f) * analyzer.BeatPulse;
            float inner = Math.Min(w, h) * (0.055f + (i % 5) * 0.008f + beatRipple * 0.018f);
            float outer = Math.Max(w, h) * (0.055f + spec * 0.31f + analyzer.Onset * 0.07f);
            Vector2 dir = new(MathF.Cos(a), MathF.Sin(a));
            Vector2 side = new(-dir.Y, dir.X);
            Color4 c = PaletteColor(pal, i / 9);
            Vector2 p1 = center + dir * inner;
            Vector2 p2 = center + dir * (inner + outer) + side * (4 + spec * 18);
            Vector2 p3 = center + dir * (inner + outer * (0.72f + analyzer.Vocal * 0.14f)) - side * (4 + spec * 15);
            FillTriangle(rt, b, p1, p2, p3, WithAlpha(c, 0.025f + spec * 0.19f + analyzer.Onset * 0.055f));
            Line(rt, b, p1, p2, WithAlpha(c, 0.16f + spec * 0.42f), (0.7f + spec * 1.7f) * variantThickness);
            if (spec + analyzer.TrebleSpark > 1.12f)
                Line(rt, b, p1, p2, WithAlpha(Rgb(255, 255, 255), 0.08f + analyzer.TrebleSpark * 0.18f), 0.7f + spec * 1.3f);
        }
    }

    private void RenderTunnel(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        Vector2 center = new(w * 0.5f, h * 0.5f);
        int rings = 46;
        int points = 96;
        for (int r = 0; r < rings; r++)
        {
            float t = r / (float)rings;
            float radius = Math.Min(w, h) * (0.04f + t * 0.64f);
            Vector2 last = default;
            for (int i = 0; i <= points; i++)
            {
                float p = i / (float)points;
                float a = p * MathF.Tau + time * (0.26f + t * 0.7f) + r * 0.14f;
                float spec = spectrum[(i + r * 4) % spectrum.Length];
                float warp = MathF.Sin(a * 5f + time * 2f) * 10f + spec * 130f * (0.22f + t);
                Vector2 next = center + new Vector2(MathF.Cos(a), MathF.Sin(a)) * (radius + warp);
                if (i > 0)
                    Line(rt, b, last, next, WithAlpha(pal[r % pal.Length], 0.08f + (1f - t) * 0.42f), 0.8f + analyzer.Beat * 1.5f);
                last = next;
            }
        }
    }

    private void RenderWavefield(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        int layers = 11;
        int points = 420;
        float travel = time * (0.075f + analyzer.Brightness * 0.055f) * variantTwist;
        float centerDrift = MathF.Sin(time * 0.23f + variantSeed) * h * (0.018f + analyzer.Bass * 0.040f);
        for (int layer = 0; layer < layers; layer++)
        {
            for (int age = 4; age >= 1; age--)
            {
                BuildWavePath(pathBuffer, w, h, points, layer, layers, travel - age * 0.010f * variantTrail, age, centerDrift);
                float fade = (5 - age) / 4f;
                Polyline(rt, b, pathBuffer, points, WithAlpha(PaletteColor(pal, layer + age), (0.018f + analyzer.Vocal * 0.018f) * fade), (1.0f + fade * 1.2f) * variantThickness);
            }

            BuildWavePath(pathBuffer, w, h, points, layer, layers, travel, 0, centerDrift);
            float layerBand = spectrum[(layer * 7 + 31) % spectrum.Length];
            float channel = layer % 5 switch
            {
                0 => Math.Max(analyzer.Bass, analyzer.BassKick),
                1 => Math.Max(analyzer.Mid, analyzer.MidPunch),
                2 => analyzer.Vocal,
                3 => analyzer.Treble,
                _ => analyzer.Air
            };
            float response = Math.Clamp(layerBand * 0.62f + channel * 0.52f + analyzer.Onset * 0.18f, 0, 1);
            Color4 color = ToneColor(PaletteColor(pal, layer), 1.04f + response * 0.38f, 0.70f + response * 0.62f);
            Polyline(rt, b, pathBuffer, points, WithAlpha(color, 0.022f + response * 0.075f), (5.0f + response * 8.0f) * variantThickness);
            Polyline(rt, b, pathBuffer, points, WithAlpha(color, 0.28f + response * 0.58f), (0.95f + response * 2.9f) * variantThickness);
        }
    }

    private void RenderParticleGalaxy(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        Vector2 center = new(w * 0.5f, h * 0.5f);
        int arms = 10;
        int points = 240;
        float max = Math.Min(w, h);
        for (int arm = 0; arm < arms; arm++)
        {
            Vector2 last = center;
            Vector2 ghost = center;
            float phase = arm * MathF.Tau / arms;
            for (int i = 1; i < points; i++)
            {
                float p = i / (float)(points - 1);
                float spec = spectrum[(i * 5 + arm * 11) % spectrum.Length];
                float wave = waveform[(i * waveform.Length / points + arm * 41) % waveform.Length];
                float a = phase + p * (7.6f + analyzer.MidPunch * 2.4f) + time * (0.24f + analyzer.Brightness * 0.28f);
                float r = max * (0.025f + p * p * (0.60f + analyzer.BassKick * 0.11f)) + spec * max * 0.11f + wave * max * 0.030f;
                Vector2 next = center + new Vector2(MathF.Cos(a) * r, MathF.Sin(a) * r * 0.64f);
                Vector2 echo = center + new Vector2(MathF.Cos(a - 0.035f - analyzer.SpectralFlux * 0.04f) * r * 1.018f, MathF.Sin(a - 0.035f) * r * 0.660f);
                if (i > 1)
                {
                    Line(rt, b, ghost, echo, WithAlpha(pal[(arm + 2) % pal.Length], 0.018f + spec * 0.060f), 4.0f + spec * 5.5f);
                    Line(rt, b, last, next, WithAlpha(pal[arm % pal.Length], 0.070f + spec * 0.36f + analyzer.TrebleSpark * 0.055f), 0.65f + spec * 2.1f);
                    if ((i + arm) % 23 == 0 && spec + analyzer.TrebleSpark > 0.55f)
                        Dot(rt, b, next, 1.4f + spec * 4.0f, WithAlpha(Rgb(255, 255, 255), 0.18f + analyzer.TrebleSpark * 0.25f));
                }
                last = next;
                ghost = echo;
            }
        }
    }

    private void RenderPinwheel(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        Vector2 center = new(w * 0.5f, h * 0.5f);
        int blades = 72;
        float radius = Math.Max(w, h) * (0.56f + analyzer.BassKick * 0.24f);
        for (int ring = 0; ring < 4; ring++)
        {
            float ringStart = Math.Min(w, h) * (0.03f + ring * 0.070f + analyzer.BassKick * 0.025f);
            float ringReach = radius * (0.34f + ring * 0.16f);
            float twist = time * (0.28f + ring * 0.10f + analyzer.Brightness * 0.40f) + ring * 0.8f;
            for (int i = 0; i < blades; i++)
            {
                float spec = spectrum[(i * 5 + ring * 13) % spectrum.Length];
                float a = i * MathF.Tau / blades + twist + spec * 0.22f;
                float width = 0.010f + spec * 0.020f + analyzer.MidPunch * 0.010f;
                Vector2 dir = new(MathF.Cos(a), MathF.Sin(a));
                Vector2 left = new(MathF.Cos(a - width), MathF.Sin(a - width));
                Vector2 right = new(MathF.Cos(a + width), MathF.Sin(a + width));
                Vector2 p1 = center + dir * ringStart;
                Vector2 p2 = center + left * (ringStart + ringReach * (0.42f + spec * 0.48f));
                Vector2 p3 = center + right * (ringStart + ringReach * (0.34f + spec * 0.40f));
                Color4 color = ring % 2 == 0 ? pal[(i + ring) % pal.Length] : Color4.FromHSV((i / (float)blades + time * 0.04f) % 1f, 0.92f, 1f, 1f);
                FillTriangle(rt, b, p1, p2, p3, WithAlpha(color, 0.035f + spec * 0.18f + analyzer.BassKick * 0.05f));
                if ((i + ring) % 3 == 0)
                    Line(rt, b, p1, p2, WithAlpha(Rgb(255, 255, 255), analyzer.TrebleSpark * 0.12f + spec * 0.08f), 0.45f + spec);
            }
        }
        Dot(rt, b, center, 18f + analyzer.BassKick * 28f, WithAlpha(Rgb(0, 0, 0), 0.95f));
        Dot(rt, b, center, 8f + analyzer.TrebleSpark * 14f, WithAlpha(Rgb(255, 255, 255), 0.20f + analyzer.TrebleSpark * 0.32f));
    }

    private void RenderNebula(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        Vector2 center = new(w * 0.5f, h * 0.5f);
        int filaments = 18;
        int points = 150;
        float max = Math.Min(w, h);
        for (int f = 0; f < filaments; f++)
        {
            Vector2 last = default;
            float phase = f * 0.71f;
            for (int i = 0; i < points; i++)
            {
                float p = i / (float)(points - 1);
                float spec = spectrum[(i * 4 + f * 9) % spectrum.Length];
                float wave = waveform[(i * waveform.Length / points + f * 29) % waveform.Length];
                float x = w * (0.5f + (p - 0.5f) * 1.05f);
                float y = h * (0.5f
                    + MathF.Sin(p * MathF.Tau * (1.2f + f * 0.045f) + phase + time * (0.18f + analyzer.Brightness * 0.12f)) * 0.27f
                    + MathF.Cos(p * MathF.Tau * 3.0f - time * (0.28f + analyzer.MidPunch * 0.25f) + f) * 0.055f
                    + wave * (0.050f + analyzer.BassKick * 0.025f));
                y += spec * max * 0.10f * MathF.Sin(phase + time * 0.4f);
                Vector2 next = new(x, y);
                if (i > 0)
                {
                    Line(rt, b, last, next, WithAlpha(pal[f % pal.Length], 0.018f + spec * 0.12f), 5.0f + spec * 8.0f);
                    Line(rt, b, last, next, WithAlpha(pal[(f + 1) % pal.Length], 0.080f + spec * 0.34f), 0.75f + spec * 1.6f);
                }
                last = next;
            }
        }
        Dot(rt, b, center, 14f + analyzer.BassKick * 22f, WithAlpha(Rgb(0, 0, 0), 0.90f));
    }

    private void RenderBarCity(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        float baseline = h * 0.80f;
        float barWidth = w / (spectrum.Length + 10f);
        for (int i = 0; i < spectrum.Length; i++)
        {
            float value = BassAwareHeight(i, spectrum[i]);
            float x = i * barWidth + barWidth * 4f;
            float height = value * h * 0.52f;
            FillRect(rt, b, x, baseline - height, x + barWidth * 0.72f, baseline, WithAlpha(pal[i % pal.Length], 0.74f));
            Line(rt, b, new Vector2(x, baseline - height - 12 * analyzer.Beat), new Vector2(x + barWidth * 0.72f, baseline - height - 12 * analyzer.Beat), WithAlpha(Rgb(255, 255, 255), 0.46f), 1.2f);
        }
        Line(rt, b, new Vector2(0, baseline), new Vector2(w, baseline), WithAlpha(Rgb(65, 190, 255), 0.72f), 2f);
    }

    private void RenderFlowerScope(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        Vector2 center = new(w * 0.5f, h * 0.5f);
        int layers = 8;
        int points = 240;
        for (int layer = 0; layer < layers; layer++)
        {
            Vector2 last = default;
            for (int i = 0; i <= points; i++)
            {
                float p = i / (float)points;
                float a = p * MathF.Tau;
                float wave = waveform[(i * waveform.Length / points + layer * 37) % waveform.Length];
                float spec = spectrum[(i * spectrum.Length / points + layer * 9) % spectrum.Length];
                float petals = MathF.Sin(a * (3 + layer) + time * (0.78f + layer * 0.12f));
                float r = Math.Min(w, h) * (0.12f + layer * 0.034f + spec * 0.17f + wave * 0.08f + petals * 0.035f);
                Vector2 next = center + new Vector2(MathF.Cos(a + time * 0.08f * layer), MathF.Sin(a + time * 0.08f * layer)) * r;
                if (i > 0)
                    Line(rt, b, last, next, WithAlpha(pal[layer % pal.Length], 0.18f + spec * 0.46f), 0.9f + analyzer.Beat * 2f);
                last = next;
            }
        }
    }

    private void RenderLaserLattice(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        Vector2 center = new(w * 0.5f, h * 0.5f);
        int sides = 32;
        int rings = 8;
        for (int ring = 0; ring < rings; ring++)
        {
            float depth = (ring + 1f) / rings;
            for (int side = 0; side <= sides; side++)
            {
                int wrapped = side % sides;
                float a = wrapped * MathF.Tau / sides + time * (0.055f + depth * 0.12f) * variantTwist + ring * 0.10f;
                float spec = spectrum[(wrapped * 3 + ring * 11) % spectrum.Length];
                float radius = Math.Min(w, h) * (0.055f + depth * 0.52f)
                    + spec * Math.Min(w, h) * (0.035f + depth * 0.045f)
                    + analyzer.Vocal * 18f * MathF.Sin(a * 4f + time);
                Vector2 point = center + new Vector2(MathF.Cos(a) * radius, MathF.Sin(a) * radius * (0.62f + variantStretch * 0.18f));
                pathBuffer[side] = point;
                if (side < sides)
                    latticeNodes[ring, side] = point;
            }
            Color4 color = PaletteColor(pal, ring);
            Polyline(rt, b, pathBuffer, sides + 1, WithAlpha(color, 0.025f + analyzer.Air * 0.035f), 5.5f * variantThickness);
            Polyline(rt, b, pathBuffer, sides + 1, WithAlpha(color, 0.26f + analyzer.Vocal * 0.23f), (0.9f + analyzer.TrebleSpark * 1.7f) * variantThickness);
        }

        for (int side = 0; side < sides; side += 2)
        {
            for (int ring = 0; ring < rings; ring++)
                pathBuffer[ring] = latticeNodes[ring, (side + ring * (colorOffset % 3)) % sides];
            float spec = spectrum[(side * 3 + 58) % spectrum.Length];
            Polyline(rt, b, pathBuffer, rings, WithAlpha(PaletteColor(pal, side), 0.16f + spec * 0.32f), (0.8f + spec * 1.8f) * variantThickness);
            if (analyzer.TrebleSpark + spec > 1.12f)
                Polyline(rt, b, pathBuffer, rings, WithAlpha(Rgb(255, 255, 255), 0.08f + analyzer.TrebleSpark * 0.20f), 0.75f * variantThickness);
        }
    }

    private void RenderBassBloom(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        Vector2 center = new(
            w * (0.46f + (Hash01((int)variantSeed + 29) - 0.5f) * 0.055f),
            h * (0.51f + (Hash01((int)variantSeed + 71) - 0.5f) * 0.055f));
        float safeX = MathF.Min(center.X, w - center.X) * 0.93f;
        float safeY = MathF.Min(center.Y, h - center.Y) * 0.89f;
        int points = 520;
        float turns = 2.72f + variantTwist * 0.48f;
        float rotation = -time * (0.16f + analyzer.Brightness * 0.18f) + variantSeed;
        for (int i = 0; i < points; i++)
        {
            float u = i / (float)(points - 1);
            float growth = MathF.Pow(u, 0.78f);
            int bandIndex = 8 + i * 84 / points;
            float spec = spectrum[bandIndex];
            float sample = SampleSmoothWave(Wrap01(u + time * 0.035f) * (smoothWaveform.Length - 1));
            float travelingBeat = MathF.Exp(-MathF.Abs(WrapSigned(u - analyzer.BeatPhase)) * 9f) * analyzer.BeatPulse;
            float chamber = MathF.Sin(u * MathF.Tau * (8.5f + variantTwist * 1.6f)
                - musicalTime * MathF.Tau * (0.21f + analyzer.MidPunch * 0.10f));
            float angle = u * MathF.Tau * turns + rotation
                + sample * (0.025f + analyzer.Vocal * 0.13f)
                + chamber * analyzer.Treble * 0.025f;
            float radius = 0.020f + growth * 0.865f
                + growth * spec * (0.018f + analyzer.Brightness * 0.048f)
                + growth * sample * (0.008f + analyzer.Vocal * 0.038f)
                + growth * chamber * (0.004f + analyzer.MidPunch * 0.018f)
                + growth * analyzer.BassKick * 0.046f
                + growth * travelingBeat * 0.034f;
            radius = Math.Clamp(radius, 0.012f, 0.935f);
            float width = 0.018f
                + growth * (0.022f + analyzer.Vocal * 0.042f + spec * 0.038f)
                + analyzer.BassKick * growth * 0.018f
                + travelingBeat * 0.024f;
            float outer = Math.Min(0.975f, radius + width * 0.58f);
            float inner = Math.Max(0.004f, radius - width * 0.42f);
            float cosine = MathF.Cos(angle);
            float sine = MathF.Sin(angle);
            pathBuffer[i] = center + new Vector2(cosine * safeX * outer, sine * safeY * outer);
            morphBuffer[i] = center + new Vector2(cosine * safeX * inner, sine * safeY * inner);
        }

        for (int end = 7; end < points; end += 7)
        {
            int start = end - 7;
            float u = end / (float)(points - 1);
            float energy = spectrum[8 + end * 84 / points];
            float pulse = MathF.Exp(-MathF.Abs(WrapSigned(u - analyzer.BeatPhase)) * 8f) * analyzer.BeatPulse;
            float response = Math.Clamp(energy * 0.66f + analyzer.Vocal * 0.24f + pulse * 0.42f, 0, 1);
            Color4 fill = ToneColor(PaletteColor(pal, end / 42), 1.18f + response * 0.32f, 0.58f + response * 0.82f);
            FillQuad(rt, b, pathBuffer[start], pathBuffer[end], morphBuffer[end], morphBuffer[start], WithAlpha(fill, 0.018f + response * 0.105f));
        }

        float shellEnergy = Math.Clamp(analyzer.Bass * 0.36f + analyzer.Vocal * 0.34f + analyzer.Brightness * 0.30f, 0, 1);
        Color4 glow = ToneColor(PaletteColor(pal, 1), 1.22f, 0.76f + shellEnergy * 0.58f);
        Polyline(rt, b, pathBuffer, points, WithAlpha(glow, 0.022f + shellEnergy * 0.060f), (15f + shellEnergy * 20f) * variantThickness);
        Polyline(rt, b, morphBuffer, points, WithAlpha(glow, 0.014f + shellEnergy * 0.042f), (9f + shellEnergy * 13f) * variantThickness);

        for (int start = 0; start < points - 1; start += 26)
        {
            int count = Math.Min(28, points - start);
            float response = spectrum[8 + start * 84 / points];
            Color4 edge = ToneColor(PaletteColor(pal, start / 52), 1.28f, 0.72f + response * 0.76f + analyzer.Onset * 0.18f);
            PolylineRange(rt, b, pathBuffer, start, count, WithAlpha(edge, 0.34f + response * 0.54f), (1.25f + response * 3.4f + analyzer.BassKick * 1.5f) * variantThickness);
            PolylineRange(rt, b, morphBuffer, start, count, WithAlpha(edge, 0.20f + response * 0.42f), (0.80f + response * 2.2f) * variantThickness);
        }

        for (int rib = 24; rib < points; rib += 22)
        {
            float energy = spectrum[8 + rib * 84 / points];
            float response = Math.Clamp(energy * 0.72f + analyzer.MidPunch * 0.24f + analyzer.TrebleSpark * 0.22f, 0, 1);
            Color4 ribColor = ToneColor(PaletteColor(pal, rib / 44 + 2), 1.20f, 0.62f + response * 0.82f);
            Line(rt, b, morphBuffer[rib], pathBuffer[rib], WithAlpha(ribColor, 0.06f + response * 0.44f), (0.75f + response * 2.4f) * variantThickness);
            if ((rib & 1) == 0 && response + analyzer.TrebleSpark > 0.78f)
                Dot(rt, b, pathBuffer[rib], 1.3f + response * 3.5f + analyzer.TrebleSpark * 1.8f, WithAlpha(Rgb(255, 255, 255), 0.10f + response * 0.46f));
        }
    }

    private void RenderChromaticWaveTunnel(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        Vector2 center = new(w * 0.5f, h * 0.5f);
        int ribbons = 22;
        int points = 190;
        for (int ribbon = 0; ribbon < ribbons; ribbon++)
        {
            float z = ribbon / (float)(ribbons - 1);
            float baseRadius = Math.Min(w, h) * (0.05f + z * z * 0.58f + analyzer.BassKick * 0.06f);
            Vector2 last = default;
            for (int i = 0; i <= points; i++)
            {
                float p = i / (float)points;
                int wi = i * (waveform.Length - 1) / points;
                float spec = spectrum[(i * spectrum.Length / points + ribbon * 7) % spectrum.Length];
                float a = p * MathF.Tau + time * (0.35f + z * 0.92f + analyzer.Brightness * 0.30f) + ribbon * 0.23f;
                float warp = waveform[wi] * Math.Min(w, h) * (0.04f + z * 0.05f)
                    + spec * Math.Min(w, h) * (0.045f + analyzer.SpectralFlux * 0.035f)
                    + MathF.Sin(p * MathF.Tau * (3 + ribbon % 5) + time * (1.6f + analyzer.MidPunch * 2.4f)) * 18f;
                Vector2 next = center + new Vector2(MathF.Cos(a) * (baseRadius + warp), MathF.Sin(a) * (baseRadius + warp) * (0.62f + z * 0.30f));
                if (i > 0)
                {
                    Color4 color = Color4.FromHSV((p + z * 0.35f + time * 0.025f) % 1f, 0.92f, 1f, 0.055f + spec * 0.25f + analyzer.TrebleSpark * 0.07f);
                    Line(rt, b, last, next, color, 0.5f + spec * 2.0f + analyzer.BassKick * 0.9f);
                }
                last = next;
            }
        }
    }

    private void RenderVocalAurora(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        int ribbons = 11;
        int points = 300;
        float travel = time * (0.055f + analyzer.Brightness * 0.04f) * variantTwist;
        for (int ribbon = 0; ribbon < ribbons; ribbon++)
        {
            float depth = ribbon / (float)(ribbons - 1);
            for (int i = 0; i < points; i++)
            {
                float u = i / (float)(points - 1);
                float sample = SampleSmoothWave(Wrap01(u + travel + ribbon * 0.013f) * (smoothWaveform.Length - 1));
                int bandIndex = 24 + (i * 61 / points + ribbon * 5) % 71;
                float vocalBand = spectrum[bandIndex];
                float x = u * w;
                float y = h * (0.18f + depth * 0.64f)
                    + MathF.Sin(u * MathF.Tau * (1.15f + ribbon * 0.045f) + time * (0.38f + depth * 0.30f) + variantSeed) * h * (0.055f + analyzer.Vocal * 0.075f)
                    + sample * h * (0.035f + vocalBand * 0.045f)
                    + MathF.Sin(u * MathF.Tau * 7f - time * 1.7f + ribbon) * h * analyzer.Air * 0.018f;
                pathBuffer[i] = new Vector2(x, y);
            }

            float band = spectrum[28 + ribbon * 5];
            Color4 color = PaletteColor(pal, ribbon);
            Polyline(rt, b, pathBuffer, points, WithAlpha(color, 0.025f + band * 0.070f), (8f + band * 10f) * variantThickness);
            Polyline(rt, b, pathBuffer, points, WithAlpha(color, 0.38f + band * 0.38f + analyzer.Vocal * 0.12f), (1.15f + band * 2.4f) * variantThickness);
        }
    }

    private void RenderCometTrails(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        Vector2 vanishingPoint = new(-w * 0.06f, h * (0.47f + MathF.Sin(time * 0.12f + variantSeed) * 0.035f));
        int comets = 15;
        int points = 150;
        for (int comet = 0; comet < comets; comet++)
        {
            float lane = (comet + 0.5f) / comets;
            float laneY = h * (0.06f + lane * 0.88f);
            float energy = spectrum[(comet * 7 + 24) % spectrum.Length];
            float headDepth = Wrap01(Hash01(comet * 71 + (int)variantSeed) + musicalTime * (0.064f + analyzer.Brightness * 0.035f));
            float trailDepth = 0.20f + variantTrail * 0.055f;
            int firstVisible = points - 1;
            for (int i = 0; i < points; i++)
            {
                float age = (points - 1 - i) / (float)(points - 1);
                float depth = Math.Max(0, headDepth - age * trailDepth);
                if (depth > 0.001f && firstVisible == points - 1)
                    firstVisible = i;
                float perspective = depth * depth * (3f - 2f * depth);
                float localBand = spectrum[(comet * 11 + i / 5 + 18) % spectrum.Length];
                float bend = MathF.Sin(depth * MathF.Tau * (1.4f + comet % 4 * 0.18f) - time * (0.42f + analyzer.Vocal * 0.34f) + comet)
                    * h * depth * (0.010f + analyzer.Vocal * 0.032f + localBand * 0.014f);
                float bassLift = analyzer.BassKick * MathF.Exp(-age * 7f) * h * (lane - 0.5f) * 0.10f;
                float x = vanishingPoint.X + perspective * w * 1.15f;
                float y = vanishingPoint.Y + (laneY - vanishingPoint.Y) * (0.16f + perspective * 0.96f) + bend + bassLift;
                pathBuffer[i] = new Vector2(x, y);
            }

            int visibleCount = points - firstVisible;
            if (visibleCount < 2)
                continue;
            Color4 color = ToneColor(PaletteColor(pal, comet), 1.14f, 0.70f + energy * 0.72f);
            PolylineRange(rt, b, pathBuffer, firstVisible, visibleCount, WithAlpha(color, 0.020f + energy * 0.060f), (12f + energy * 18f) * variantThickness);
            int segments = 6;
            for (int segment = 0; segment < segments; segment++)
            {
                int start = firstVisible + segment * (visibleCount - 1) / segments;
                int end = firstVisible + (segment + 1) * (visibleCount - 1) / segments + 1;
                float fade = (segment + 1f) / segments;
                PolylineRange(rt, b, pathBuffer, start, end - start, WithAlpha(color, 0.08f + fade * (0.44f + energy * 0.38f)), (0.75f + fade * 2.2f + energy * 1.8f) * variantThickness);
            }
            Vector2 head = pathBuffer[points - 1];
            Dot(rt, b, head, (5f + energy * 8f) * variantThickness, WithAlpha(color, 0.08f + energy * 0.12f));
            Dot(rt, b, head, (1.8f + energy * 4.4f + analyzer.Onset * 2.2f) * variantThickness, WithAlpha(Rgb(255, 255, 255), 0.34f + energy * 0.54f));
        }
    }

    private void BuildWavePath(Vector2[] path, float w, float h, int points, int layer, int layers, float travel, int historyAge, float centerDrift)
    {
        for (int i = 0; i < points; i++)
        {
            float u = i / (float)(points - 1);
            float samplePosition = Wrap01(u + travel - historyAge * 0.004f) * (smoothWaveform.Length - 1);
            float sample = historyAge == 0 ? SampleSmoothWave(samplePosition) : SampleWaveHistory(historyAge, samplePosition);
            int bandIndex = 18 + (i * 72 / points + layer * 5) % 78;
            float spec = spectrum[bandIndex];
            float channel = layer % 5 switch
            {
                0 => Math.Max(analyzer.Bass, analyzer.BassKick),
                1 => Math.Max(analyzer.Mid, analyzer.MidPunch),
                2 => analyzer.Vocal,
                3 => analyzer.Treble,
                _ => analyzer.Air
            };
            float response = Ease(Math.Clamp(spec * 0.58f + channel * 0.58f + analyzer.Onset * 0.20f, 0, 1));
            float harmonic = MathF.Sin(u * MathF.Tau * (3.2f + layer * 0.09f) - time * (0.72f + layer * 0.065f) * variantTwist + variantSeed);
            float fine = MathF.Sin(u * MathF.Tau * (12f + layer * 0.17f) + time * 1.4f) * analyzer.Air;
            float x = u * w + MathF.Sin(u * MathF.Tau + time * 0.18f) * analyzer.Vocal * 9f;
            float y = h * (0.5f + (layer - (layers - 1) * 0.5f) * 0.027f) + centerDrift
                + sample * h * (0.020f + response * 0.165f)
                + harmonic * h * (0.006f + response * 0.096f)
                + fine * h * (0.003f + response * 0.018f)
                + MathF.Sin(time * 0.65f + layer) * analyzer.Bass * h * (0.004f + response * 0.018f);
            path[i] = new Vector2(x, y);
        }
    }

    private void UpdateWaveform(float delta)
    {
        for (int i = 0; i < smoothWaveform.Length; i++)
        {
            float previous = waveform[Math.Max(0, i - 1)];
            float current = waveform[i];
            float next = waveform[Math.Min(waveform.Length - 1, i + 1)];
            float targetValue = previous * 0.22f + current * 0.56f + next * 0.22f;
            float speed = MathF.Abs(targetValue) > MathF.Abs(smoothWaveform[i]) ? 0.38f : 0.21f;
            smoothWaveform[i] += (targetValue - smoothWaveform[i]) * speed;
        }

        waveformHistoryTimer += delta;
        if (waveformHistoryTimer < 0.045f)
            return;

        waveformHistoryTimer %= 0.045f;
        waveformHistoryIndex = (waveformHistoryIndex + 1) % waveformHistory.GetLength(0);
        for (int i = 0; i < smoothWaveform.Length; i++)
            waveformHistory[waveformHistoryIndex, i] = smoothWaveform[i];
    }

    private float SampleSmoothWave(float position)
    {
        int left = Math.Clamp((int)position, 0, smoothWaveform.Length - 1);
        int right = Math.Min(smoothWaveform.Length - 1, left + 1);
        float amount = Math.Clamp(position - left, 0, 1);
        return smoothWaveform[left] + (smoothWaveform[right] - smoothWaveform[left]) * amount;
    }

    private float SampleWaveHistory(int age, float position)
    {
        int slot = (waveformHistoryIndex - age + waveformHistory.GetLength(0)) % waveformHistory.GetLength(0);
        int left = Math.Clamp((int)position, 0, smoothWaveform.Length - 1);
        int right = Math.Min(smoothWaveform.Length - 1, left + 1);
        float amount = Math.Clamp(position - left, 0, 1);
        return waveformHistory[slot, left] + (waveformHistory[slot, right] - waveformHistory[slot, left]) * amount;
    }

    private void RenderTransitionSequence(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] blendedPalette, float mix)
    {
        if (previousMode == mode)
        {
            frameOpacity = 1f;
            RenderMode(rt, b, blendedPalette, mode);
            return;
        }

        bool helicalHandoff = IsRadialScene(previousMode) || IsRadialScene(mode);
        float oldOpacity = 1f - SmoothRange(mix, 0.10f, helicalHandoff ? 0.70f : 0.62f);
        if (oldOpacity > 0.01f)
        {
            frameOpacity = oldOpacity;
            RenderPreviousPreset(rt, b, palettes[previousPaletteIndex]);
        }

        float bridgeOpacity = SmoothRange(mix, 0.06f, 0.24f)
            * (1f - SmoothRange(mix, 0.76f, 0.98f));
        if (bridgeOpacity > 0.01f)
        {
            frameOpacity = bridgeOpacity;
            RenderMorphTransition(rt, b, blendedPalette, mix);
        }

        float targetOpacity = SmoothRange(mix, helicalHandoff ? 0.50f : 0.47f, 0.94f);
        if (targetOpacity > 0.01f)
        {
            frameOpacity = targetOpacity;
            RenderMode(rt, b, palettes[paletteIndex], mode);
        }

        if (!helicalHandoff && !IsLineScene(previousMode) && !IsLineScene(mode) && SceneAxis(previousMode) != SceneAxis(mode))
            RenderFocusSweep(rt, b, blendedPalette, mix, 0.16f);
        frameOpacity = 1f;
    }

    private void RenderPreviousPreset(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] palette)
    {
        int currentColorOffset = colorOffset;
        float currentSeed = variantSeed;
        float currentThickness = variantThickness;
        float currentTwist = variantTwist;
        float currentTrail = variantTrail;
        float currentStretch = variantStretch;
        float currentTopEnd = variantTopEnd;

        colorOffset = previousColorOffset;
        variantSeed = previousVariantSeed;
        variantThickness = previousVariantThickness;
        variantTwist = previousVariantTwist;
        variantTrail = previousVariantTrail;
        variantStretch = previousVariantStretch;
        variantTopEnd = previousVariantTopEnd;
        RenderMode(rt, b, palette, previousMode);

        colorOffset = currentColorOffset;
        variantSeed = currentSeed;
        variantThickness = currentThickness;
        variantTwist = currentTwist;
        variantTrail = currentTrail;
        variantStretch = currentStretch;
        variantTopEnd = currentTopEnd;
    }

    private void RenderMorphTransition(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal, float mix)
    {
        float w = ClientSize.Width;
        float h = ClientSize.Height;
        float arc = MathF.Sin(mix * MathF.PI);
        int threads = 15;
        int points = 170;
        for (int thread = 0; thread < threads; thread++)
        {
            for (int i = 0; i < points; i++)
            {
                float u = i / (float)(points - 1);
                Vector2 from = TransitionPoint(previousMode, thread, threads, u, w, h, previousVariantSeed, previousVariantTwist);
                Vector2 to = TransitionPoint(mode, thread, threads, u, w, h, variantSeed, variantTwist);
                Vector2 point;
                if (IsRadialScene(previousMode) || IsRadialScene(mode))
                {
                    Vector2 helix = HelicalTransitionPoint(thread, threads, u, w, h, variantSeed * 0.37f + previousVariantSeed * 0.23f);
                    point = mix < 0.5f
                        ? Vector2.Lerp(from, helix, Ease(mix * 2f))
                        : Vector2.Lerp(helix, to, Ease((mix - 0.5f) * 2f));
                }
                else if (IsLineScene(previousMode) || IsLineScene(mode))
                {
                    Vector2 ribbon = LineTransitionPoint(thread, threads, u, w, h, previousMode, mode);
                    point = mix < 0.5f
                        ? Vector2.Lerp(from, ribbon, Ease(mix * 2f))
                        : Vector2.Lerp(ribbon, to, Ease((mix - 0.5f) * 2f));
                }
                else
                {
                    point = Vector2.Lerp(from, to, Ease(mix));
                }
                Vector2 direction = to - from;
                Vector2 normal = direction.LengthSquared() > 0.001f
                    ? Vector2.Normalize(new Vector2(-direction.Y, direction.X))
                    : Vector2.Zero;
                float focus = MathF.Exp(-MathF.Abs(u - Wrap01(mix * 1.32f - 0.16f)) * 8f);
                float flourish = MathF.Sin(u * MathF.Tau * 2f + thread * 0.63f + musicalTime * MathF.Tau * 0.25f)
                    * Math.Min(w, h) * (0.024f + analyzer.Onset * 0.020f)
                    * arc * (0.50f + analyzer.Vocal * 0.50f + focus * analyzer.BeatPulse * 0.45f);
                Vector2 screenCenter = new(w * 0.5f, h * 0.5f);
                float pulseScale = 1f + analyzer.BeatPulse * arc * (0.010f + 0.012f * MathF.Sin(thread * 1.7f));
                morphBuffer[i] = screenCenter + (point - screenCenter) * pulseScale + normal * flourish;
            }

            SmoothTransitionPath(morphBuffer, pathBuffer, points);
            SmoothTransitionPath(pathBuffer, morphBuffer, points);
            SmoothTransitionPath(morphBuffer, pathBuffer, points);
            SmoothTransitionPath(pathBuffer, morphBuffer, points);

            float energy = spectrum[(thread * 7 + 24) % spectrum.Length];
            Color4 oldColor = PaletteColorAtOffset(pal, thread, previousColorOffset);
            Color4 newColor = PaletteColorAtOffset(pal, thread, colorOffset);
            Color4 color = Lerp(oldColor, newColor, mix);
            float morphThickness = previousVariantThickness + (variantThickness - previousVariantThickness) * mix;
            Polyline(rt, b, morphBuffer, points, WithAlpha(color, 0.012f + energy * 0.030f + analyzer.Onset * 0.012f), (22f + energy * 18f + arc * 7f) * morphThickness);
            Polyline(rt, b, morphBuffer, points, WithAlpha(color, 0.040f + energy * 0.080f), (9f + energy * 11f + arc * 4f) * morphThickness);
            Polyline(rt, b, morphBuffer, points, WithAlpha(color, 0.40f + energy * 0.40f + analyzer.Onset * 0.12f), (1.15f + energy * 2.3f + analyzer.BeatPulse * 0.7f) * morphThickness);
        }
    }

    private void RenderFocusSweep(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Color4[] pal, float mix, float strength)
    {
        float envelope = MathF.Sin(mix * MathF.PI) * strength;
        if (envelope <= 0.004f)
            return;

        float w = ClientSize.Width;
        float h = ClientSize.Height;
        int points = 96;
        bool vertical = SceneAxis(mode) == 1;
        for (int ribbon = 0; ribbon < 5; ribbon++)
        {
            float laneOffset = (ribbon - 2f) * (vertical ? w : h) * 0.035f;
            for (int i = 0; i < points; i++)
            {
                float u = i / (float)(points - 1);
                float bend = MathF.Sin(u * MathF.Tau + musicalTime * MathF.Tau * 0.25f + ribbon) * (18f + analyzer.Vocal * 34f);
                if (vertical)
                {
                    float x = (-0.18f + mix * 1.36f) * w + laneOffset + bend;
                    pathBuffer[i] = new Vector2(x, u * h);
                }
                else
                {
                    float y = (-0.18f + mix * 1.36f) * h + laneOffset + bend;
                    pathBuffer[i] = new Vector2(u * w, y);
                }
            }

            Color4 color = PaletteColor(pal, ribbon + 1);
            float reactive = envelope * (0.55f + analyzer.Vocal * 0.25f + analyzer.Onset * 0.35f);
            Polyline(rt, b, pathBuffer, points, WithAlpha(color, 0.025f * reactive), 34f + analyzer.BeatPulse * 18f);
            Polyline(rt, b, pathBuffer, points, WithAlpha(color, 0.14f * reactive), 3.0f + analyzer.TrebleSpark * 2.5f);
        }
    }

    private static void SmoothTransitionPath(Vector2[] source, Vector2[] destination, int count)
    {
        destination[0] = source[0];
        for (int i = 1; i < count - 1; i++)
            destination[i] = source[i - 1] * 0.22f + source[i] * 0.56f + source[i + 1] * 0.22f;
        destination[count - 1] = source[count - 1];
    }

    private static int SceneAxis(int scene)
    {
        return scene switch
        {
            2 or 11 or 13 or 18 => 1,
            3 or 12 => 2,
            4 or 6 or 8 or 9 or 10 or 15 or 16 or 17 => 3,
            _ => 0
        };
    }

    private Vector2 TransitionPoint(int scene, int thread, int threads, float u, float w, float h, float styleSeed, float styleTwist)
    {
        float lane = (thread + 0.5f) / threads;
        float band = spectrum[(thread * 7 + (int)(u * 67f) + 18) % spectrum.Length];
        float phase = musicalTime * MathF.Tau * 0.18f * styleTwist + styleSeed;
        switch (scene)
        {
            case 0:
            case 5:
            case 14:
                return new Vector2(
                    u * w,
                    lane * h + MathF.Sin(u * MathF.Tau * (1.2f + thread * 0.035f) - phase + thread) * h * (0.025f + band * 0.065f));
            case 1:
            {
                float depth = lane;
                float width = w * (0.12f + depth * 0.98f);
                return new Vector2(
                    w * 0.5f + (u - 0.5f) * width,
                    h * (0.22f + depth * 0.72f) - band * h * (0.02f + depth * 0.10f));
            }
            case 2:
            case 11:
            case 13:
            case 18:
                return new Vector2(
                    lane * w + MathF.Sin(u * MathF.Tau * 1.3f + phase + thread) * w * (0.012f + band * 0.028f),
                    u * h);
            case 3:
            {
                float a = lane * MathF.Tau + MathF.Sin(u * 3f + phase) * 0.10f;
                float radius = u * MathF.Sqrt(w * w + h * h) * (0.54f + band * 0.14f);
                return new Vector2(w * 0.5f + MathF.Cos(a) * radius, h * 0.5f + MathF.Sin(a) * radius);
            }
            case 4:
                return RectanglePerimeter(u, w, h, 0.12f + lane * 0.72f, phase + lane);
            case 6:
            case 17:
                return new Vector2(
                    u * w,
                    h * (0.5f + MathF.Sin(u * MathF.Tau * 1.7f + phase + thread * 0.54f) * (0.16f + band * 0.18f)));
            case 7:
                return new Vector2(
                    lane * w + MathF.Sin(u * MathF.PI) * MathF.Sin(phase + thread) * w * 0.025f,
                    h * (0.92f - u * (0.15f + band * 0.72f)));
            case 9:
                return new Vector2(
                    u * w,
                    h * (0.5f + MathF.Sin(u * MathF.Tau * (2.2f + lane * 1.6f) - phase + thread * 0.31f) * (0.12f + band * 0.16f)));
            case 8:
            case 10:
                return (thread & 1) == 0
                    ? new Vector2(u * w, lane * h + MathF.Sin(u * MathF.Tau * 2f + phase + thread) * h * 0.045f)
                    : new Vector2(lane * w + MathF.Sin(u * MathF.Tau * 2f - phase + thread) * w * 0.035f, u * h);
            case 12:
                return HelicalTransitionPoint(thread, threads, u, w, h, styleSeed);
            default:
            {
                float a = u * MathF.Tau * (1f + thread % 3 * 0.25f) + phase + thread;
                return new Vector2(
                    w * (0.5f + MathF.Sin(a) * (0.20f + lane * 0.25f)),
                    h * (0.5f + MathF.Sin(a * 1.37f + thread) * (0.18f + lane * 0.22f)));
            }
        }
    }

    private static bool IsRadialScene(int scene) => scene is 3 or 12;

    private static bool IsLineScene(int scene) => scene is 0 or 1 or 2 or 5 or 6 or 9 or 10 or 14 or 16 or 17 or 18;

    private Vector2 HelicalTransitionPoint(int thread, int threads, float u, float w, float h, float seed)
    {
        const float goldenAngle = 2.39996323f;
        float lane = (thread + 0.5f) / threads;
        float band = spectrum[(thread * 7 + (int)(u * 71f) + 19) % spectrum.Length];
        Vector2 center = new(
            w * (0.42f + MathF.Sin(seed) * 0.035f),
            h * (0.52f + MathF.Cos(seed * 0.73f) * 0.035f));
        float growth = MathF.Pow(u, 0.72f);
        float angle = u * MathF.Tau * (3.35f + variantTwist * 0.42f)
            + thread * goldenAngle * 0.31f
            - musicalTime * MathF.Tau * 0.055f;
        float radius = Math.Min(w, h) * (0.018f + growth * (0.58f + lane * 0.10f) + band * growth * 0.055f);
        return center + new Vector2(MathF.Cos(angle) * radius, MathF.Sin(angle) * radius * 0.72f);
    }

    private Vector2 LineTransitionPoint(int thread, int threads, float u, float w, float h, int fromScene, int toScene)
    {
        float fromAngle = TransitionLineAngle(fromScene);
        float toAngle = TransitionLineAngle(toScene);
        float angle = (fromAngle + toAngle) * 0.5f;
        Vector2 tangent = new(MathF.Cos(angle), MathF.Sin(angle));
        Vector2 normal = new(-tangent.Y, tangent.X);
        float lane = (thread + 0.5f) / threads - 0.5f;
        float length = MathF.Sqrt(w * w + h * h) * 0.78f;
        float bend = MathF.Sin(u * MathF.Tau * 1.35f + thread * 0.58f + musicalTime * MathF.Tau * 0.18f)
            * Math.Min(w, h) * (0.010f + analyzer.Vocal * 0.030f);
        return new Vector2(w * 0.5f, h * 0.5f)
            + tangent * ((u - 0.5f) * length)
            + normal * (lane * Math.Min(w, h) * 0.92f + bend);
    }

    private static float TransitionLineAngle(int scene)
    {
        if (scene is 2 or 18)
            return MathF.PI * 0.5f;
        if (scene is 10)
            return MathF.PI * 0.25f;
        return 0f;
    }

    private static Vector2 RectanglePerimeter(float u, float w, float h, float scale, float phase)
    {
        float p = Wrap01(u + phase * 0.015f) * 4f;
        float halfW = w * scale * 0.5f;
        float halfH = h * scale * 0.5f;
        Vector2 center = new(w * 0.5f, h * 0.5f);
        if (p < 1f) return center + new Vector2(-halfW + p * halfW * 2f, -halfH);
        if (p < 2f) return center + new Vector2(halfW, -halfH + (p - 1f) * halfH * 2f);
        if (p < 3f) return center + new Vector2(halfW - (p - 2f) * halfW * 2f, halfH);
        return center + new Vector2(-halfW, halfH - (p - 3f) * halfH * 2f);
    }

    private Color4 PaletteColor(Color4[] palette, int index)
    {
        return PaletteColorAtOffset(palette, index, colorOffset);
    }

    private static Color4 PaletteColorAtOffset(Color4[] palette, int index, int offset)
    {
        int wrapped = (index + offset) % palette.Length;
        return palette[wrapped < 0 ? wrapped + palette.Length : wrapped];
    }

    private void Polyline(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Vector2[] points, int count, Color4 color, float stroke)
    {
        count = Math.Min(count, points.Length);
        if (count < 2 || stroke <= 0)
            return;

        using var geometry = factory!.CreatePathGeometry();
        using var sink = geometry.Open();
        sink.BeginFigure(points[0], FigureBegin.Hollow);
        for (int i = 1; i < count; i++)
            sink.AddLine(points[i]);
        sink.EndFigure(FigureEnd.Open);
        sink.Close();
        b.Color = color;
        rt.DrawGeometry(geometry, b, stroke);
    }

    private void PolylineRange(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Vector2[] points, int start, int count, Color4 color, float stroke)
    {
        start = Math.Clamp(start, 0, points.Length - 1);
        count = Math.Min(count, points.Length - start);
        if (count < 2 || stroke <= 0)
            return;

        using var geometry = factory!.CreatePathGeometry();
        using var sink = geometry.Open();
        sink.BeginFigure(points[start], FigureBegin.Hollow);
        for (int i = 1; i < count; i++)
            sink.AddLine(points[start + i]);
        sink.EndFigure(FigureEnd.Open);
        sink.Close();
        b.Color = color;
        rt.DrawGeometry(geometry, b, stroke);
    }

    private void DrawWrappedPathInterval(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Vector2[] points, int count, float start, float end, Color4 color, float stroke)
    {
        while (start < 0f)
        {
            start += 1f;
            end += 1f;
        }
        while (start >= 1f)
        {
            start -= 1f;
            end -= 1f;
        }

        if (end <= 1f)
        {
            DrawPathInterval(rt, b, points, count, start, end, color, stroke);
            return;
        }

        DrawPathInterval(rt, b, points, count, start, 1f, color, stroke);
        DrawPathInterval(rt, b, points, count, 0f, end - 1f, color, stroke);
    }

    private void DrawPathInterval(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Vector2[] points, int count, float start, float end, Color4 color, float stroke)
    {
        int first = Math.Clamp((int)MathF.Floor(start * (count - 1)), 0, count - 1);
        int last = Math.Clamp((int)MathF.Ceiling(end * (count - 1)), first, count - 1);
        PolylineRange(rt, b, points, first, last - first + 1, color, stroke);
    }

    private static void EllipseOutline(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Vector2 center, float radiusX, float radiusY, Color4 color, float stroke)
    {
        if (radiusX <= 0 || radiusY <= 0 || stroke <= 0)
            return;
        b.Color = color;
        rt.DrawEllipse(new Ellipse(center, radiusX, radiusY), b, stroke);
    }

    private void Line(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Vector2 a, Vector2 c, Color4 color, float stroke)
    {
        b.Color = color;
        rt.DrawLine(a, c, b, stroke);
    }

    private void Dot(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Vector2 center, float radius, Color4 color)
    {
        b.Color = color;
        var ellipse = new Ellipse(center, radius, radius);
        rt.FillEllipse(ellipse, b);
    }

    private void FillRect(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, float left, float top, float right, float bottom, Color4 color)
    {
        b.Color = color;
        rt.FillRectangle(new RawRectF(left, top, right, bottom), b);
    }

    private void FillTriangle(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Vector2 p1, Vector2 p2, Vector2 p3, Color4 color)
    {
        b.Color = color;
        using var geometry = factory!.CreatePathGeometry();
        using var sink = geometry.Open();
        sink.BeginFigure(p1, FigureBegin.Filled);
        sink.AddLine(p2);
        sink.AddLine(p3);
        sink.EndFigure(FigureEnd.Closed);
        sink.Close();
        rt.FillGeometry(geometry, b);
    }

    private void FillQuad(ID2D1HwndRenderTarget rt, ID2D1SolidColorBrush b, Vector2 p1, Vector2 p2, Vector2 p3, Vector2 p4, Color4 color)
    {
        FillTriangle(rt, b, p1, p2, p3, color);
        FillTriangle(rt, b, p1, p3, p4, color);
    }

    private Color4[] BuildPalette(int fromIndex, int toIndex, float amount)
    {
        Color4[] from = palettes[Math.Clamp(fromIndex, 0, palettes.Length - 1)];
        Color4[] to = palettes[Math.Clamp(toIndex, 0, palettes.Length - 1)];
        Color4[] result = new Color4[from.Length];
        for (int i = 0; i < result.Length; i++)
            result[i] = Lerp(from[i], to[i], amount);
        return result;
    }

    private static float BassAwareHeight(int band, float value)
    {
        float shaped = MathF.Pow(Math.Clamp(value, 0, 1), 1.02f);
        if (band < 18)
        {
            float blend = band / 18f;
            float ceiling = 0.62f + blend * 0.22f;
            shaped = ceiling * (1f - MathF.Exp(-shaped * 1.85f));
        }
        return Math.Clamp(shaped, 0, 1);
    }

    private static Color4 Rgb(int r, int g, int b) => Rgba(r, g, b, 1f);
    private static Color4 Rgba(int r, int g, int b, float a) => new(r / 255f, g / 255f, b / 255f, a);
    private static Color4 ToneColor(Color4 color, float saturation, float brightness)
    {
        float luma = color.R * 0.2126f + color.G * 0.7152f + color.B * 0.0722f;
        return new Color4(
            Math.Clamp((luma + (color.R - luma) * saturation) * brightness, 0, 1),
            Math.Clamp((luma + (color.G - luma) * saturation) * brightness, 0, 1),
            Math.Clamp((luma + (color.B - luma) * saturation) * brightness, 0, 1),
            color.A);
    }
    private Color4 WithAlpha(Color4 c, float alpha) => new(c.R, c.G, c.B, Math.Clamp(alpha * frameOpacity, 0, 1));
    private static Color4 Lerp(Color4 a, Color4 b, float t) => new(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t, a.A + (b.A - a.A) * t);
    private static float Ease(float t) => t * t * (3f - 2f * t);
    private static float SmoothRange(float value, float start, float end)
    {
        float t = Math.Clamp((value - start) / Math.Max(0.0001f, end - start), 0f, 1f);
        return Ease(t);
    }
    private static float Wrap01(float value) => value - MathF.Floor(value);
    private static float WrapSigned(float value) => Wrap01(value + 0.5f) - 0.5f;

    private static float Hash01(int value)
    {
        uint x = unchecked((uint)value);
        x ^= x >> 16;
        x *= 0x7feb352d;
        x ^= x >> 15;
        x *= 0x846ca68b;
        x ^= x >> 16;
        return (x & 0x00ffffff) / 16777215f;
    }

    protected override void Dispose(bool disposing)
    {
        Application.Idle -= OnApplicationIdle;
        brush?.Dispose();
        target?.Dispose();
        factory?.Dispose();
        base.Dispose(disposing);
    }

    private static bool IsApplicationIdle
    {
        get
        {
            return !PeekMessage(out _, IntPtr.Zero, 0, 0, 0);
        }
    }

    [DllImport("user32.dll")]
    private static extern bool PeekMessage(out NativeMessage message, IntPtr hwnd, uint filterMin, uint filterMax, uint remove);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeMessage
    {
        public IntPtr HWnd;
        public uint Msg;
        public UIntPtr WParam;
        public IntPtr LParam;
        public uint Time;
        public Point Point;
    }
}
