using System.Diagnostics;
using System.Numerics;
using System.Runtime.InteropServices;
using Vortice.D3DCompiler;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;
using static Vortice.Direct3D11.D3D11;
using static Vortice.DXGI.DXGI;

namespace WindowsMusicVisualizerGpu;

public sealed class Direct3DVisualizerForm : Form
{
    private const int ModeCount = 35;
    private const int SpectrumBands = 32;
    private const int BarSpectrumBands = 64;
    private const int WaveformSamples = 64;
    internal string? CapturePath;
    internal float CaptureAfterSeconds;
    internal bool TestPrismHeadroom;
    private string? recordingDirectory;
    private int recordingFrame;
    private readonly int[] portfolioScenes = [7, 1, 3, 22, 25, 31];

    internal void ConfigurePortfolioRecording(string directory)
    {
        recordingDirectory = Path.GetFullPath(directory);
        Directory.CreateDirectory(recordingDirectory);
        new Random(1000).Shuffle(portfolioScenes);
        fullscreen = false;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Location = new System.Drawing.Point(-10000, -10000);
        ClientSize = new System.Drawing.Size(1280, 720);
        ShowInTaskbar = false;
        verticalSync = false;
        sceneFilter.Enabled = false;
        BeginTransition(portfolioScenes[0], 0, true);
        File.WriteAllText(Path.Combine(recordingDirectory, "recording.json"),
            System.Text.Json.JsonSerializer.Serialize(new { width = 1280, height = 720, fps = 30, frames = 900, scenes = portfolioScenes.Select(s => s + 1), audio = "Generated analysis signal; no music or desktop audio recorded", filters = false }));
    }
    private int captureCount;
    private int captureAccentCount;
    private float captureMaxCameraMotion;
    internal int CaptureTransitionMode = -1;
    private static readonly string[] SceneShaderEntries =
    [
        "PSLiquidGlass",
        "PSFilamentKaleidoscope",
        "PSVolumetricTunnel",
        "PSPlasmaNebula",
        "PSCrystalMirror",
        "PSRibbonCanyon",
        "PSElectricLattice",
        "PSPrismConcerto",
        "PSFibonacciShell",
        "PSRisingFlame",
        "PSGlassMosaic",
        "PSCometTrace",
        "PSFractalWings",
        "PSSpectralCathedral",
        "PSOscilloscopeRibbon",
        "PSVocalLoom",
        "PSBassTerrain",
        "PSDiscoCubeFloor",
        "PSHelixReactor",
        "PSOrbitalShardStorm",
        "PSSpectralGyroscope",
        "PSLiquidChromeTorus",
        "PSGeissSilk",
        "PSKineticMobile", "PSSandPlate", "PSResonanceTunnel", "PSInterferencePrism",
        "PSChromaticLoom", "PSRippleBloom", "PSMagneticSculpture", "PSSpectralWaterfall", "PSFerrofluid",
        "PSRasterCurtain", "PSRadialLightFan", "PSPhosphorEcho"
    ];
    private readonly AudioAnalyzer analyzer;
    private readonly Random random;
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly float[] spectrum = new float[96];
    private readonly float[] waveform = new float[768];
    private readonly float[] displayBands = new float[SpectrumBands];
    private readonly MotionSpectrum motionSpectrum = new();
    private readonly AccentCamera accentCamera = new();
    private readonly SceneFilter sceneFilter = new();
    private readonly float[] stereoBands = new float[16];
    internal void SetFilterOverride(int value) => sceneFilter.Override = Math.Clamp(value, -1, SceneFilter.Count - 1);
    internal void SetCameraEnabled(bool enabled) => accentCamera.Enabled = enabled;
    private float[] motionBands => motionSpectrum.Values;
    private readonly PrismPeakMarkers prismPeakMarkers = new();
    private readonly float[] barDisplayBands = new float[BarSpectrumBands];
    private readonly float[] barBaselines = new float[BarSpectrumBands];
    private readonly float[] barPeakReferences = new float[BarSpectrumBands];
    private readonly float[] displayWaveform = new float[WaveformSamples];
    private readonly int[] modeDeck = new int[ModeCount];
    private readonly Vector4[][] palettes =
    [
        [Rgb(0x17D8E6), Rgb(0x5365FF), Rgb(0xEC3CCB), Rgb(0xF4FAFF)],
        [Rgb(0x40FF91), Rgb(0x22CBEA), Rgb(0xFFD34E), Rgb(0xF7FFF0)],
        [Rgb(0x318DFF), Rgb(0x00EFCB), Rgb(0xB64DFF), Rgb(0xF1E8FF)],
        [Rgb(0xFF35C6), Rgb(0x763BFF), Rgb(0x00DDF5), Rgb(0xFFF7DB)],
        [Rgb(0x7BFF55), Rgb(0x18D1F0), Rgb(0xFF508E), Rgb(0xF8FFF5)],
        [Rgb(0x00B9FF), Rgb(0x802CFF), Rgb(0xFF56DA), Rgb(0x4BFFE0)],
        [Rgb(0xFFD14D), Rgb(0x47DFFF), Rgb(0xFF4FB1), Rgb(0xFFFFFF)],
        [Rgb(0xA2FFFF), Rgb(0x62FF84), Rgb(0xC276FF), Rgb(0xF7F7FF)],
        [Rgb(0xFFD166), Rgb(0x42E2B8), Rgb(0x4EA5FF), Rgb(0xFFF3D0)],
        [Rgb(0x65A7FF), Rgb(0xD95CFF), Rgb(0xFF8C65), Rgb(0xDFFFF9)]
    ];

    private IDXGIFactory1? factory;
    private IDXGISwapChain? swapChain;
    private ID3D11Device? device;
    private ID3D11DeviceContext? context;
    private ID3D11VertexShader? vertexShader;
    private readonly ID3D11PixelShader?[] scenePixelShaders = new ID3D11PixelShader?[ModeCount];
    private static readonly object ShaderCompileSync = new();
    private ID3D11Buffer? constantBuffer;
    private ID3D11SamplerState? sampler;
    private ID3D11Texture2D? backBuffer;
    private ID3D11Texture2D? presentedTexture;
    private bool graphicsDisposed;
    private ID3D11PixelShader? transitionShader;
    private ID3D11RenderTargetView? backBufferView;
    private string? shaderPath;
    private readonly ID3D11Texture2D?[] feedbackTextures = new ID3D11Texture2D?[2];
    private readonly ID3D11RenderTargetView?[] feedbackViews = new ID3D11RenderTargetView?[2];
    private readonly ID3D11ShaderResourceView?[] feedbackResources = new ID3D11ShaderResourceView?[2];
    private ID3D11Texture2D? transitionTexture;
    private ID3D11ShaderResourceView? transitionResource;

    private double lastFrameSeconds;
    private double nextTitleUpdate;
    private float fps;
    private float time;
    private float musicalTime;
    private float transition = 1f;
    private float transitionDuration = 3.4f;
    private float previousSeed;
    private float currentSeed;
    private float colorPhase;
    private float feedbackPersistence = 0.92f;
    private float warpStrength = 1f;
    private float symmetry = 6f;
    private float hueRate = 1f;
    private float visualActivity;
    private float visualImpact;
    private float visualDensity;
    private float visualClarity = 1f;
    private float sceneTravel;
    private readonly float[] spectralHistory = new float[256];
    private float historyTimer;
    private float snapshotInterval = 0.25f;
    private readonly BeatSnapshotClock beatSnapshotClock = new();
    private int snapshotCount;
    private float rhythmColor;
    private float activityFloor = 0.10f;
    private float activityCeiling = 0.68f;
    private int mode;
    private int previousMode;
    private int paletteIndex;
    private int previousPaletteIndex;
    private int modeDeckIndex = ModeCount;
    private int feedbackIndex;
    private long frameIndex;
    private DateTime nextShuffle;
    private DateTime shuffleArmedAt;
    private bool shuffleArmed;
    private bool fullscreen = true;
    private bool verticalSync = true;
    private bool resizing;
    private bool timerResolutionEnabled;
    private Rectangle windowedBounds;

    public Direct3DVisualizerForm(AudioAnalyzer analyzer, int screenNumber, int startMode = -1, int? diagnosticSeed = null)
    {
        random = diagnosticSeed.HasValue ? new Random(diagnosticSeed.Value) : new Random();
        this.analyzer = analyzer;
        Text = "Windows Music Visualizer - Direct3D 11";
        BackColor = System.Drawing.Color.Black;
        KeyPreview = true;
        ContextMenuStrip = new ContextMenuStrip();
        ContextMenuStrip.Items.Add("Audio source...", null, (_, _) => ShowAudioSource());
        SetStyle(ControlStyles.Opaque | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
        SelectScreen(screenNumber);
        if (startMode >= 0)
        {
            BeginTransition(Math.Clamp(startMode, 0, ModeCount - 1), random.Next(palettes.Length), true);
            nextShuffle = DateTime.Now.AddSeconds(30);
        }
        else
            RandomizePreset(true);
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        timerResolutionEnabled = timeBeginPeriod(1) == 0;
        CreateDeviceResources();
        Application.Idle += OnApplicationIdle;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        RenderFrame();
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
    }

    private void ShowAudioSource()
    {
        using var picker = new AudioSourceDialog(analyzer);
        picker.ShowDialog(this);
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        if (swapChain != null && !resizing && ClientSize.Width > 0 && ClientSize.Height > 0)
            ResizeTargets();
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
        if (e.KeyCode == Keys.V) verticalSync = !verticalSync;
        if (e.KeyCode == Keys.K) accentCamera.Enabled = !accentCamera.Enabled;
        if (e.KeyCode == Keys.G) sceneFilter.Enabled = !sceneFilter.Enabled;
        if (e.KeyCode == Keys.A)
            ShowAudioSource();
    }

    private void SelectScreen(int screenNumber)
    {
        Screen[] screens = Screen.AllScreens;
        int index = Math.Clamp(screenNumber - 1, 0, screens.Length - 1);
        StartPosition = FormStartPosition.Manual;
        Bounds = screens[index].Bounds;
        FormBorderStyle = FormBorderStyle.None;
        WindowState = FormWindowState.Normal;
        TopMost = true;
    }

    private void ToggleFullscreen()
    {
        resizing = true;
        if (fullscreen)
        {
            windowedBounds = Bounds;
            FormBorderStyle = FormBorderStyle.Sizable;
            Bounds = new Rectangle(Bounds.Left + 80, Bounds.Top + 80, Math.Max(960, Bounds.Width - 220), Math.Max(540, Bounds.Height - 220));
            TopMost = false;
        }
        else
        {
            FormBorderStyle = FormBorderStyle.None;
            Bounds = Screen.FromControl(this).Bounds;
            TopMost = true;
        }
        fullscreen = !fullscreen;
        resizing = false;
        ResizeTargets();
    }

    private void CreateDeviceResources()
    {
        DeviceCreationFlags flags = DeviceCreationFlags.BgraSupport;
#if DEBUG
        flags |= DeviceCreationFlags.Debug;
#endif
        FeatureLevel[] levels = [FeatureLevel.Level_11_1, FeatureLevel.Level_11_0];
        device = D3D11CreateDevice(DriverType.Hardware, flags, levels);
        context = device.ImmediateContext;
        factory = CreateDXGIFactory1<IDXGIFactory1>();

        SwapChainDescription description = new()
        {
            BufferDescription = new ModeDescription((uint)Math.Max(1, ClientSize.Width), (uint)Math.Max(1, ClientSize.Height), Format.R8G8B8A8_UNorm),
            SampleDescription = new SampleDescription(1, 0),
            BufferUsage = Usage.RenderTargetOutput,
            BufferCount = 2,
            OutputWindow = Handle,
            Windowed = true,
            SwapEffect = SwapEffect.FlipDiscard,
            Flags = SwapChainFlags.None
        };
        swapChain = factory.CreateSwapChain(device, description);
        factory.MakeWindowAssociation(Handle, WindowAssociationFlags.IgnoreAltEnter);

        shaderPath = Path.Combine(AppContext.BaseDirectory, "Visualizer.hlsl");
        ReadOnlyMemory<byte> vsBytecode = LoadOrCompileShader(shaderPath, "VSMain", "vs_5_0");
        vertexShader = device.CreateVertexShader(vsBytecode.Span);
        transitionShader = device.CreatePixelShader(LoadOrCompileShader(shaderPath, "PSTransitionBlend", "ps_5_0").Span);
        EnsureSceneShader(mode);
        _ = Task.Run(() => PrewarmShaderCache(shaderPath, mode));

        constantBuffer = device.CreateBuffer(
            new BufferDescription((uint)Marshal.SizeOf<ShaderConstants>(), BindFlags.ConstantBuffer, ResourceUsage.Default, CpuAccessFlags.None));
        sampler = device.CreateSamplerState(new SamplerDescription(
            Filter.MinMagMipLinear,
            TextureAddressMode.Mirror,
            0,
            1,
            ComparisonFunction.Never,
            0,
            float.MaxValue));

        ResizeTargets();
    }

    private static ReadOnlyMemory<byte> LoadOrCompileShader(string shaderPath, string entryPoint, string profile)
    {
        lock (ShaderCompileSync)
        {
            string cachePath = Path.Combine(AppContext.BaseDirectory, $"{entryPoint}-{profile}.cso");
            if (File.Exists(cachePath) && File.GetLastWriteTimeUtc(cachePath) >= File.GetLastWriteTimeUtc(shaderPath))
                return File.ReadAllBytes(cachePath);

            ShaderFlags flags = ShaderFlags.EnableStrictness | ShaderFlags.OptimizationLevel3;
            ReadOnlyMemory<byte> bytecode = Compiler.CompileFromFile(shaderPath, entryPoint, profile, flags, EffectFlags.None);
            File.WriteAllBytes(cachePath, bytecode.ToArray());
            return bytecode;
        }
    }

    private static void PrewarmShaderCache(string shaderPath, int activeMode)
    {
        for (int i = 0; i < SceneShaderEntries.Length; i++)
        {
            if (i == activeMode) continue;
            try
            {
                _ = LoadOrCompileShader(shaderPath, SceneShaderEntries[i], "ps_5_0");
            }
            catch
            {
                // The foreground load will surface a useful compiler error if this scene is selected.
            }
        }
    }

    internal static void ValidateShaders()
    {
        string path = Path.Combine(AppContext.BaseDirectory, "Visualizer.hlsl");
        _ = LoadOrCompileShader(path, "PSTransitionBlend", "ps_5_0");
        foreach (string entry in SceneShaderEntries)
            _ = LoadOrCompileShader(path, entry, "ps_5_0");
        File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "shader-validation.txt"), $"Compiled {ModeCount} scene shaders successfully.");
    }

    private void EnsureSceneShader(int scene)
    {
        if (device == null || shaderPath == null || scenePixelShaders[scene] != null)
            return;

        ReadOnlyMemory<byte> bytecode = LoadOrCompileShader(shaderPath, SceneShaderEntries[scene], "ps_5_0");
        scenePixelShaders[scene] = device.CreatePixelShader(bytecode.Span);
    }

    private void ResizeTargets()
    {
        if (swapChain == null || device == null || context == null || ClientSize.Width <= 0 || ClientSize.Height <= 0)
            return;

        context.PSUnsetShaderResource(0);
        context.PSUnsetShaderResource(1);
        context.UnsetRenderTargets();
        DisposeTargets();
        swapChain.ResizeBuffers(2, (uint)ClientSize.Width, (uint)ClientSize.Height, Format.R8G8B8A8_UNorm, SwapChainFlags.None).CheckError();

        backBuffer = swapChain.GetBuffer<ID3D11Texture2D>(0);
        backBufferView = device.CreateRenderTargetView(backBuffer);

        Texture2DDescription textureDescription = new(
            Format.R8G8B8A8_UNorm,
            (uint)ClientSize.Width,
            (uint)ClientSize.Height,
            1,
            1,
            BindFlags.RenderTarget | BindFlags.ShaderResource);

        for (int i = 0; i < 2; i++)
        {
            feedbackTextures[i] = device.CreateTexture2D(textureDescription);
            feedbackViews[i] = device.CreateRenderTargetView(feedbackTextures[i]!);
            feedbackResources[i] = device.CreateShaderResourceView(feedbackTextures[i]!);
            context.ClearRenderTargetView(feedbackViews[i]!, new Color4(0, 0, 0, 1));
        }

        transitionTexture = device.CreateTexture2D(textureDescription);
        presentedTexture = device.CreateTexture2D(textureDescription);
        context.CopyResource(presentedTexture, feedbackTextures[0]!);
        transitionResource = device.CreateShaderResourceView(transitionTexture);
        context.CopyResource(transitionTexture, feedbackTextures[0]!);

        feedbackIndex = 0;
        context.RSSetViewport(new Viewport(0, 0, ClientSize.Width, ClientSize.Height));
    }

    private void OnApplicationIdle(object? sender, EventArgs e)
    {
        while (IsApplicationIdle)
            RenderFrame();
    }

    private void RenderFrame()
    {
        if (context == null || swapChain == null || vertexShader == null || constantBuffer == null || sampler == null ||
            backBuffer == null || feedbackViews[0] == null || feedbackViews[1] == null || transitionResource == null ||
            ClientSize.Width <= 0 || ClientSize.Height <= 0)
            return;

        EnsureSceneShader(mode);
        if (scenePixelShaders[mode] == null)
            return;

        double now = clock.Elapsed.TotalSeconds;
        if (verticalSync && lastFrameSeconds > 0)
        {
            const double targetFrameSeconds = 1.0 / 60.0;
            double remaining = targetFrameSeconds - (now - lastFrameSeconds);
            if (remaining > 0.0015)
                Thread.Sleep(Math.Max(0, (int)((remaining - 0.0008) * 1000.0)));
            while ((now = clock.Elapsed.TotalSeconds) - lastFrameSeconds < targetFrameSeconds)
                Thread.SpinWait(24);
        }
        float delta = (float)Math.Clamp(now - lastFrameSeconds, 0.0001, 0.05);
        if (recordingDirectory != null)
        {
            delta = 1f / 30f;
            analyzer.AnalyzePortfolioFrame(recordingFrame / 30f);
            if (recordingFrame > 0 && recordingFrame % 150 == 0)
                BeginTransition(portfolioScenes[recordingFrame / 150], (paletteIndex + 1) % palettes.Length, false);
        }
        lastFrameSeconds = now;
        fps = fps <= 1 ? 1f / delta : fps * 0.94f + (1f / delta) * 0.06f;
        time += delta;
        musicalTime += delta * analyzer.TempoBpm / 60f;
        transition = Math.Min(1f, transition + delta / transitionDuration);
        colorPhase += delta * (0.018f + analyzer.Brightness * 0.032f) * hueRate;
        if (recordingDirectory == null) MaybeShuffle();
        analyzer.Snapshot(spectrum, waveform);
        while (analyzer.TryTakeCameraAccent(out CameraAccent accent))
        {
            accentCamera.Add(accent);
            if (CapturePath != null) captureAccentCount++;
        }
        accentCamera.Update(delta);
        if (CapturePath != null)
            captureMaxCameraMotion = Math.Max(captureMaxCameraMotion, accentCamera.Transform.Length());
        UpdateDisplayBands(delta);
        if (TestPrismHeadroom && mode == 7) Array.Fill(motionBands, 1f);
        prismPeakMarkers.Update(motionBands, delta);
        historyTimer += delta;
        bool beatSnapshotDue = beatSnapshotClock.Update(delta, analyzer.TempoBpm, analyzer.TempoConfidence, analyzer.BeatPhase);
        if (mode == 30 ? beatSnapshotDue : historyTimer >= snapshotInterval)
        {
            historyTimer %= snapshotInterval;
            Array.Copy(spectralHistory, 0, spectralHistory, 32, 224);
            for (int h = 0; h < 32; h++)
                spectralHistory[h] = displayWaveform[h * (displayWaveform.Length - 1) / 31];
            snapshotCount = Math.Min(8, snapshotCount + 1);
            snapshotInterval = analyzer.TempoConfidence > 0.25f
                ? Math.Clamp(30f / Math.Max(55f, analyzer.TempoBpm), 0.15f, 0.4f) : 0.25f;
        }
        sceneTravel += delta * (0.10f + visualActivity * 0.85f + visualImpact * 0.55f);
        rhythmColor += delta * (0.025f + analyzer.MidPunch * 0.22f + analyzer.TrebleSpark * 0.30f);

        ShaderConstants constants = BuildConstants(delta);
        context.UpdateSubresource(in constants, constantBuffer, 0, 0, 0, null);

        int source = feedbackIndex;
        int destination = 1 - feedbackIndex;
        context.OMSetRenderTargets(feedbackViews[destination]!, null);
        context.RSSetViewport(new Viewport(0, 0, ClientSize.Width, ClientSize.Height));
        context.IASetPrimitiveTopology(PrimitiveTopology.TriangleList);
        context.VSSetShader(vertexShader);
        context.PSSetShader(scenePixelShaders[mode]);
        context.PSSetConstantBuffer(0, constantBuffer);
        context.PSSetSampler(0, sampler);
        context.PSSetShaderResource(0, feedbackResources[source]!);
        context.PSSetShaderResource(1, transitionResource);
        context.Draw(3, 0);

        context.PSUnsetShaderResource(0);
        context.PSUnsetShaderResource(1);
        context.UnsetRenderTargets();
        if (transitionShader != null)
        {
            context.OMSetRenderTargets(backBufferView!, null);
            context.PSSetShader(transitionShader);
            context.PSSetShaderResource(0, feedbackResources[destination]!);
            context.PSSetShaderResource(1, transitionResource);
            context.Draw(3, 0);
            context.PSUnsetShaderResource(0);
            context.PSUnsetShaderResource(1);
            context.UnsetRenderTargets();
        }
        else context.CopyResource(backBuffer, feedbackTextures[destination]!);
        // Flip-discard buffers are undefined after Present; retain our own visible frame.
        context.CopyResource(presentedTexture!, backBuffer);
        swapChain.Present(0, PresentFlags.None);
        feedbackIndex = destination;
        frameIndex++;
        if (recordingDirectory != null)
        {
            CaptureRender(presentedTexture!, Path.Combine(recordingDirectory, $"frame-{recordingFrame:D5}.png"));
            if (++recordingFrame >= 900)
            {
                recordingDirectory = null;
                BeginInvoke(new Action(Close));
            }
        }
        if (CapturePath != null && CaptureTransitionMode >= 0 && frameIndex == 60)
            BeginTransition(CaptureTransitionMode, (paletteIndex + 1) % palettes.Length, false);
        bool captureDue = CaptureAfterSeconds > 0
            ? time >= CaptureAfterSeconds + captureCount * 0.5f
            : frameIndex == 90 || frameIndex == 120;
        if (CapturePath != null && captureCount < 2 && captureDue)
        {
            CaptureRender(presentedTexture!, captureCount == 0 ? CapturePath : CapturePath + ".later.png");
            if (++captureCount == 2)
            {
                File.WriteAllText(CapturePath + ".camera.txt", FormattableString.Invariant(
                    $"Detected accents: {captureAccentCount}\nMaximum camera transform magnitude: {captureMaxCameraMotion:F6}\nCamera enabled: {accentCamera.Enabled}\n"));
                BeginInvoke(new Action(Close));
            }
        }

        if (now >= nextTitleUpdate)
        {
            Text = $"Windows Music Visualizer - Direct3D 11 - {fps:0} FPS - scene {mode + 1}/{ModeCount} - {(verticalSync ? "smooth" : "unlocked")} - {analyzer.SelectedSource.Name} - {analyzer.SourceStatus}";
            nextTitleUpdate = now + 0.35;
        }
    }

    private void CaptureRender(ID3D11Texture2D texture, string path)
    {
        var description = texture.Description;
        description.Usage = ResourceUsage.Staging;
        description.BindFlags = BindFlags.None;
        description.CPUAccessFlags = CpuAccessFlags.Read;
        using var staging = device!.CreateTexture2D(description);
        context!.CopyResource(staging, texture);
        context.Map(staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None, out MappedSubresource mapped).CheckError();
        try
        {
            using var bitmap = new Bitmap((int)description.Width, (int)description.Height);
            var data = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height),
                System.Drawing.Imaging.ImageLockMode.WriteOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            try
            {
                byte[] row = new byte[bitmap.Width * 4];
                for (int y = 0; y < bitmap.Height; y++)
                {
                    Marshal.Copy(mapped.DataPointer + y * (int)mapped.RowPitch, row, 0, row.Length);
                    for (int x = 0; x < row.Length; x += 4) (row[x], row[x + 2]) = (row[x + 2], row[x]);
                    Marshal.Copy(row, 0, data.Scan0 + y * data.Stride, row.Length);
                }
            }
            finally { bitmap.UnlockBits(data); }
            bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
        finally { context.Unmap(staging, 0); }
    }

    private ShaderConstants BuildConstants(float delta)
    {
        float easedTransition = transition * transition * (3f - 2f * transition);
        Vector4[] palette = BuildPalette(previousPaletteIndex, paletteIndex, easedTransition);
        float tempoNormalized = Math.Clamp((analyzer.TempoBpm - 55f) / 145f, 0f, 1f);
        float level = Math.Clamp(visualActivity * 0.88f + analyzer.Level * 0.12f, 0f, 1f);
        float bass = ShapeFeature(analyzer.Bass, visualActivity, visualImpact);
        float mid = ShapeFeature(analyzer.Mid, visualActivity, visualImpact);
        float treble = ShapeFeature(analyzer.Treble, visualActivity, visualImpact);
        float vocal = ShapeFeature(analyzer.Vocal, visualActivity, visualImpact);
        float air = ShapeFeature(analyzer.Air, visualActivity, visualImpact);
        float onset = ShapePulse(analyzer.Onset, visualActivity, visualImpact);
        float beatPulse = ShapePulse(analyzer.BeatPulse, visualActivity, visualImpact);
        float bassKick = ShapePulse(analyzer.BassKick, visualActivity, visualImpact);
        float midPunch = ShapePulse(analyzer.MidPunch, visualActivity, visualImpact);
        float trebleSpark = ShapePulse(analyzer.TrebleSpark, visualActivity, visualImpact);
        float spectralFlux = ShapeFeature(analyzer.SpectralFlux, visualActivity, visualImpact);
        if (UsesSelectiveMotion)
        {
            bass = MotionEnergy(0, 5);
            mid = MotionEnergy(5, 16);
            treble = MotionEnergy(16, 26);
            vocal = MotionEnergy(8, 20);
            air = MotionEnergy(26, 32);
            bassKick = bass;
            midPunch = mid;
            trebleSpark = treble;
            onset = Math.Max(bass, Math.Max(mid, treble));
        }
        // Crystal waves already have bounded displacement; retain local note dynamics.
        if (mode == 4)
        {
            bass = analyzer.Bass;
            vocal = analyzer.Vocal;
            midPunch = analyzer.MidPunch;
            treble = analyzer.Treble;
        }
        float transitionBloom = MathF.Sin(transition * MathF.PI) * (0.16f + beatPulse * 0.32f);

        analyzer.StereoSnapshot(stereoBands);
        return new ShaderConstants
        {
            ResolutionTime = new(ClientSize.Width, ClientSize.Height, time, delta),
            AudioA = new(level, bass, mid, treble),
            AudioB = new(vocal, air, onset, beatPulse),
            AudioC = new(bassKick, midPunch, trebleSpark, spectralFlux),
            Motion = new(analyzer.BeatPhase, tempoNormalized, easedTransition, musicalTime),
            Modes = new(previousMode, mode, currentSeed, colorPhase),
            Presets = new(previousSeed, currentSeed, symmetry, transitionBloom),
            Feedback = new(feedbackPersistence, warpStrength, hueRate, analyzer.Brightness),
            Dynamics = new(visualActivity, visualImpact, visualClarity, visualDensity),
            Stage = new(sceneTravel, rhythmColor, mode == 30 ? beatSnapshotClock.Progress : historyTimer / snapshotInterval, snapshotCount),
            Camera = accentCamera.Transform,
            Filter = sceneFilter.Packed,
            Stereo = analyzer.StereoState,
            StereoBands0 = new(stereoBands[0], stereoBands[1], stereoBands[2], stereoBands[3]),
            StereoBands1 = new(stereoBands[4], stereoBands[5], stereoBands[6], stereoBands[7]),
            StereoBands2 = new(stereoBands[8], stereoBands[9], stereoBands[10], stereoBands[11]),
            StereoBands3 = new(stereoBands[12], stereoBands[13], stereoBands[14], stereoBands[15]),
            History0 = new(spectralHistory[0], spectralHistory[1], spectralHistory[2], spectralHistory[3]),
            History1 = new(spectralHistory[4], spectralHistory[5], spectralHistory[6], spectralHistory[7]),
            History2 = new(spectralHistory[8], spectralHistory[9], spectralHistory[10], spectralHistory[11]),
            History3 = new(spectralHistory[12], spectralHistory[13], spectralHistory[14], spectralHistory[15]),
            History4 = new(spectralHistory[16], spectralHistory[17], spectralHistory[18], spectralHistory[19]),
            History5 = new(spectralHistory[20], spectralHistory[21], spectralHistory[22], spectralHistory[23]),
            History6 = new(spectralHistory[24], spectralHistory[25], spectralHistory[26], spectralHistory[27]),
            History7 = new(spectralHistory[28], spectralHistory[29], spectralHistory[30], spectralHistory[31]),
            History8 = new(spectralHistory[32], spectralHistory[33], spectralHistory[34], spectralHistory[35]),
            History9 = new(spectralHistory[36], spectralHistory[37], spectralHistory[38], spectralHistory[39]),
            History10 = new(spectralHistory[40], spectralHistory[41], spectralHistory[42], spectralHistory[43]),
            History11 = new(spectralHistory[44], spectralHistory[45], spectralHistory[46], spectralHistory[47]),
            History12 = new(spectralHistory[48], spectralHistory[49], spectralHistory[50], spectralHistory[51]),
            History13 = new(spectralHistory[52], spectralHistory[53], spectralHistory[54], spectralHistory[55]),
            History14 = new(spectralHistory[56], spectralHistory[57], spectralHistory[58], spectralHistory[59]),
            History15 = new(spectralHistory[60], spectralHistory[61], spectralHistory[62], spectralHistory[63]),
            History16 = new(spectralHistory[64], spectralHistory[65], spectralHistory[66], spectralHistory[67]),
            History17 = new(spectralHistory[68], spectralHistory[69], spectralHistory[70], spectralHistory[71]),
            History18 = new(spectralHistory[72], spectralHistory[73], spectralHistory[74], spectralHistory[75]),
            History19 = new(spectralHistory[76], spectralHistory[77], spectralHistory[78], spectralHistory[79]),
            History20 = new(spectralHistory[80], spectralHistory[81], spectralHistory[82], spectralHistory[83]),
            History21 = new(spectralHistory[84], spectralHistory[85], spectralHistory[86], spectralHistory[87]),
            History22 = new(spectralHistory[88], spectralHistory[89], spectralHistory[90], spectralHistory[91]),
            History23 = new(spectralHistory[92], spectralHistory[93], spectralHistory[94], spectralHistory[95]),
            History24 = new(spectralHistory[96], spectralHistory[97], spectralHistory[98], spectralHistory[99]),
            History25 = new(spectralHistory[100], spectralHistory[101], spectralHistory[102], spectralHistory[103]),
            History26 = new(spectralHistory[104], spectralHistory[105], spectralHistory[106], spectralHistory[107]),
            History27 = new(spectralHistory[108], spectralHistory[109], spectralHistory[110], spectralHistory[111]),
            History28 = new(spectralHistory[112], spectralHistory[113], spectralHistory[114], spectralHistory[115]),
            History29 = new(spectralHistory[116], spectralHistory[117], spectralHistory[118], spectralHistory[119]),
            History30 = new(spectralHistory[120], spectralHistory[121], spectralHistory[122], spectralHistory[123]),
            History31 = new(spectralHistory[124], spectralHistory[125], spectralHistory[126], spectralHistory[127]),
            History32 = new(spectralHistory[128], spectralHistory[129], spectralHistory[130], spectralHistory[131]),
            History33 = new(spectralHistory[132], spectralHistory[133], spectralHistory[134], spectralHistory[135]),
            History34 = new(spectralHistory[136], spectralHistory[137], spectralHistory[138], spectralHistory[139]),
            History35 = new(spectralHistory[140], spectralHistory[141], spectralHistory[142], spectralHistory[143]),
            History36 = new(spectralHistory[144], spectralHistory[145], spectralHistory[146], spectralHistory[147]),
            History37 = new(spectralHistory[148], spectralHistory[149], spectralHistory[150], spectralHistory[151]),
            History38 = new(spectralHistory[152], spectralHistory[153], spectralHistory[154], spectralHistory[155]),
            History39 = new(spectralHistory[156], spectralHistory[157], spectralHistory[158], spectralHistory[159]),
            History40 = new(spectralHistory[160], spectralHistory[161], spectralHistory[162], spectralHistory[163]),
            History41 = new(spectralHistory[164], spectralHistory[165], spectralHistory[166], spectralHistory[167]),
            History42 = new(spectralHistory[168], spectralHistory[169], spectralHistory[170], spectralHistory[171]),
            History43 = new(spectralHistory[172], spectralHistory[173], spectralHistory[174], spectralHistory[175]),
            History44 = new(spectralHistory[176], spectralHistory[177], spectralHistory[178], spectralHistory[179]),
            History45 = new(spectralHistory[180], spectralHistory[181], spectralHistory[182], spectralHistory[183]),
            History46 = new(spectralHistory[184], spectralHistory[185], spectralHistory[186], spectralHistory[187]),
            History47 = new(spectralHistory[188], spectralHistory[189], spectralHistory[190], spectralHistory[191]),
            History48 = new(spectralHistory[192], spectralHistory[193], spectralHistory[194], spectralHistory[195]),
            History49 = new(spectralHistory[196], spectralHistory[197], spectralHistory[198], spectralHistory[199]),
            History50 = new(spectralHistory[200], spectralHistory[201], spectralHistory[202], spectralHistory[203]),
            History51 = new(spectralHistory[204], spectralHistory[205], spectralHistory[206], spectralHistory[207]),
            History52 = new(spectralHistory[208], spectralHistory[209], spectralHistory[210], spectralHistory[211]),
            History53 = new(spectralHistory[212], spectralHistory[213], spectralHistory[214], spectralHistory[215]),
            History54 = new(spectralHistory[216], spectralHistory[217], spectralHistory[218], spectralHistory[219]),
            History55 = new(spectralHistory[220], spectralHistory[221], spectralHistory[222], spectralHistory[223]),
            History56 = new(spectralHistory[224], spectralHistory[225], spectralHistory[226], spectralHistory[227]),
            History57 = new(spectralHistory[228], spectralHistory[229], spectralHistory[230], spectralHistory[231]),
            History58 = new(spectralHistory[232], spectralHistory[233], spectralHistory[234], spectralHistory[235]),
            History59 = new(spectralHistory[236], spectralHistory[237], spectralHistory[238], spectralHistory[239]),
            History60 = new(spectralHistory[240], spectralHistory[241], spectralHistory[242], spectralHistory[243]),
            History61 = new(spectralHistory[244], spectralHistory[245], spectralHistory[246], spectralHistory[247]),
            History62 = new(spectralHistory[248], spectralHistory[249], spectralHistory[250], spectralHistory[251]),
            History63 = new(spectralHistory[252], spectralHistory[253], spectralHistory[254], spectralHistory[255]),
            Palette0 = palette[0],
            Palette1 = palette[1],
            Palette2 = palette[2],
            Palette3 = palette[3],
            Bands0 = PackBands(0),
            Bands1 = PackBands(4),
            Bands2 = PackBands(8),
            Bands3 = PackBands(12),
            Bands4 = PackBands(16),
            Bands5 = PackBands(20),
            Bands6 = PackBands(24),
            Bands7 = PackBands(28),
            Bands8 = PackBands(32),
            Bands9 = PackBands(36),
            Bands10 = PackBands(40),
            Bands11 = PackBands(44),
            Bands12 = PackBands(48),
            Bands13 = PackBands(52),
            Bands14 = PackBands(56),
            Bands15 = PackBands(60),
            Wave0 = PackWave(0),
            Wave1 = PackWave(4),
            Wave2 = PackWave(8),
            Wave3 = PackWave(12),
            Wave4 = PackWave(16),
            Wave5 = PackWave(20),
            Wave6 = PackWave(24),
            Wave7 = PackWave(28),
            Wave8 = PackWave(32),
            Wave9 = PackWave(36),
            Wave10 = PackWave(40),
            Wave11 = PackWave(44),
            Wave12 = PackWave(48),
            Wave13 = PackWave(52),
            Wave14 = PackWave(56),
            Wave15 = PackWave(60)
        };
    }

    private void UpdateDisplayBands(float delta)
    {
        motionSpectrum.Update(spectrum, delta);
        float attack = 1f - MathF.Exp(-delta * 28f);
        float release = 1f - MathF.Exp(-delta * 15f);
        for (int i = 0; i < SpectrumBands; i++)
        {
            int start = i * spectrum.Length / SpectrumBands;
            int end = Math.Max(start + 1, (i + 1) * spectrum.Length / SpectrumBands);
            float peak = 0f;
            float sum = 0f;
            for (int j = start; j < end; j++)
            {
                peak = Math.Max(peak, spectrum[j]);
                sum += spectrum[j];
            }
            float value = MathF.Pow(Math.Clamp((sum / (end - start)) * 0.72f + peak * 0.42f, 0f, 1f), 0.72f);
            float speed = value > displayBands[i] ? attack : release;
            displayBands[i] += (value - displayBands[i]) * speed;
        }

        Span<float> barTargets = stackalloc float[BarSpectrumBands];
        for (int i = 0; i < BarSpectrumBands; i++)
        {
            float position = (i + 0.5f) / BarSpectrumBands;
            float sourcePosition = MathF.Pow(position, 0.68f) * (spectrum.Length - 1) * 0.86f;
            int center = Math.Clamp((int)MathF.Floor(sourcePosition), 0, spectrum.Length - 1);
            int next = Math.Min(spectrum.Length - 1, center + 1);
            float centerValue = spectrum[center] + (spectrum[next] - spectrum[center]) * (sourcePosition - center);
            float left = spectrum[Math.Max(0, center - 1)];
            float right = spectrum[Math.Min(spectrum.Length - 1, next + 1)];
            float localPeak = Math.Max(centerValue, Math.Max(left, right));
            float frequencyLift = 0.88f + MathF.Pow(position, 0.60f) * 0.38f;
            float value = MathF.Pow(
                Math.Clamp((centerValue * 0.76f + (left + right) * 0.07f + localPeak * 0.10f) * frequencyLift, 0f, 1f),
                0.90f);
            barTargets[i] = value;
        }

        UpdateVisualDynamics(delta, barTargets);

        float peakDrive = Math.Max(
            analyzer.Onset * 1.18f,
            Math.Max(analyzer.BassKick, Math.Max(analyzer.MidPunch * 0.92f, analyzer.TrebleSpark * 0.78f)));
        float peakSupport = SmoothStep(0.10f, 0.46f, peakDrive);
        float barAttack = 1f - MathF.Exp(-delta * 36f);
        float barRelease = 1f - MathF.Exp(-delta * 55f);
        for (int i = 0; i < BarSpectrumBands; i++)
        {
            float value = barTargets[i];
            if (barPeakReferences[i] <= 0f)
            {
                barBaselines[i] = value * 0.68f;
                barPeakReferences[i] = Math.Max(0.38f, value);
            }

            float baselineRate = value > barBaselines[i] ? 1.55f : 0.30f;
            float baselineFollow = 1f - MathF.Exp(-delta * baselineRate);
            barBaselines[i] += (value - barBaselines[i]) * baselineFollow;

            float referenceRate = value > barPeakReferences[i] ? 8.5f : 0.92f;
            float referenceFollow = 1f - MathF.Exp(-delta * referenceRate);
            barPeakReferences[i] += (value - barPeakReferences[i]) * referenceFollow;

            float neighborValue = (
                barTargets[Math.Max(0, i - 2)] +
                barTargets[Math.Max(0, i - 1)] +
                barTargets[Math.Min(BarSpectrumBands - 1, i + 1)] +
                barTargets[Math.Min(BarSpectrumBands - 1, i + 2)]) * 0.25f;
            float localCrest = Math.Max(0f, value - neighborValue * 0.82f);
            float crestResponse = SmoothStep(0.035f, 0.24f, localCrest);

            float adaptiveFloor = barBaselines[i] * 1.02f + 0.035f;
            float adaptiveRange = Math.Max(0.18f, barPeakReferences[i] - adaptiveFloor + 0.07f);
            float relativePeak = Math.Clamp((value - adaptiveFloor) / adaptiveRange, 0f, 1f);
            float adaptivePeak = SmoothStep(0.055f, 0.90f, relativePeak);
            float selectivePeak = Math.Max(adaptivePeak * 0.84f, crestResponse * 0.92f);
            float target = MathF.Pow(selectivePeak, 1.10f) * (0.34f + peakSupport * 0.58f);
            float tonalBody = SmoothStep(0.70f, 0.96f, value) * (0.035f + peakSupport * 0.035f);
            target = Math.Max(target, tonalBody);
            if (target < 0.035f)
                target = 0f;

            float speed = target > barDisplayBands[i] ? barAttack : barRelease;
            barDisplayBands[i] += (target - barDisplayBands[i]) * speed;
            if (barDisplayBands[i] < 0.012f)
                barDisplayBands[i] = 0f;
        }

        float waveformFollow = 1f - MathF.Exp(-delta * 22f);
        for (int i = 0; i < WaveformSamples; i++)
        {
            int center = i * (waveform.Length - 1) / (WaveformSamples - 1);
            float value = waveform[center] * 0.5f;
            value += waveform[Math.Max(0, center - 2)] * 0.18f;
            value += waveform[Math.Min(waveform.Length - 1, center + 2)] * 0.18f;
            value += waveform[Math.Max(0, center - 5)] * 0.07f;
            value += waveform[Math.Min(waveform.Length - 1, center + 5)] * 0.07f;
            displayWaveform[i] += (Math.Clamp(value, -1f, 1f) - displayWaveform[i]) * waveformFollow;
        }
    }

    private bool UsesSelectiveMotion => mode is 0 or 1 or 2 or 3 or 6 or 7 or 8 or 10 or 12 or 18 or 19 or 20 or 21 or 22 or 23 or 24 or 25 or 26 or 27 or 28 or 29 or 31 or 32 or 33 or 34;

    private float MotionEnergy(int start, int end)
    {
        float sum = 0f;
        float peak = 0f;
        for (int i = start; i < end; i++)
        {
            sum += motionBands[i] * motionBands[i];
            peak = Math.Max(peak, motionBands[i]);
        }
        // A solo note should still articulate the region, without summing dense music to saturation.
        return MathF.Sqrt(sum / (end - start)) * 0.5f + peak * 0.5f;
    }

    private Vector4 PackBands(int start)
    {
        // Scene 8 uses the otherwise unused upper spectrum slots for world-space peak heights.
        if (mode == 7 && start >= 32 && start < 56)
        {
            float[] peaks = prismPeakMarkers.Heights;
            int i = start - 32;
            return new(peaks[i], peaks[i + 1], peaks[i + 2], peaks[i + 3]);
        }
        bool usesTransientBands = mode == 4 || mode == 14;
        if (!usesTransientBands && start >= SpectrumBands)
            return Vector4.Zero;
        if (UsesSelectiveMotion)
            return new(motionBands[start], motionBands[start + 1], motionBands[start + 2], motionBands[start + 3]);

        float[] source = usesTransientBands ? barDisplayBands : displayBands;
        if (usesTransientBands)
            return new(source[start], source[start + 1], source[start + 2], source[start + 3]);

        return new(
            ShapeBand(source[start]),
            ShapeBand(source[start + 1]),
            ShapeBand(source[start + 2]),
            ShapeBand(source[start + 3]));
    }

    private void UpdateVisualDynamics(float delta, ReadOnlySpan<float> bands)
    {
        float sum = 0f;
        float squareSum = 0f;
        float densitySum = 0f;
        for (int i = 0; i < bands.Length; i++)
        {
            float value = bands[i];
            sum += value;
            squareSum += value * value;
            densitySum += SmoothStep(0.16f, 0.62f, value);
        }

        float mean = sum / bands.Length;
        float rms = MathF.Sqrt(squareSum / bands.Length);
        float densityTarget = densitySum / bands.Length;
        float densitySpeed = 1f - MathF.Exp(-delta * (densityTarget > visualDensity ? 5.5f : 2.8f));
        visualDensity += (densityTarget - visualDensity) * densitySpeed;

        float broadMass = Math.Clamp(rms * 0.52f + mean * 0.16f + analyzer.Level * 0.20f + visualDensity * 0.12f, 0f, 1f);
        float floorSpeed = 1f - MathF.Exp(-delta * (broadMass < activityFloor ? 0.78f : 0.055f));
        float ceilingSpeed = 1f - MathF.Exp(-delta * (broadMass > activityCeiling ? 2.8f : 0.075f));
        activityFloor += (Math.Max(0.025f, broadMass * 0.82f) - activityFloor) * floorSpeed;
        activityCeiling += (Math.Max(activityFloor + 0.22f, broadMass) - activityCeiling) * ceilingSpeed;

        float relativeMass = Math.Clamp((broadMass - activityFloor) / Math.Max(0.22f, activityCeiling - activityFloor), 0f, 1f);
        float activityTarget = SmoothStep(0.04f, 0.92f, relativeMass * 0.76f + broadMass * 0.24f);
        float activitySpeed = 1f - MathF.Exp(-delta * (activityTarget > visualActivity ? 7.5f : 2.8f));
        visualActivity += (activityTarget - visualActivity) * activitySpeed;

        float onsetMass = Math.Max(analyzer.Onset, Math.Max(analyzer.BassKick, Math.Max(analyzer.MidPunch * 0.88f, analyzer.TrebleSpark * 0.70f)));
        float sustainedGate = SmoothStep(0.58f, 0.92f, visualActivity * 0.54f + visualDensity * 0.28f + broadMass * 0.18f);
        float noveltyGate = 0.24f + SmoothStep(0.30f, 0.86f, onsetMass) * 0.76f;
        float impactTarget = sustainedGate * noveltyGate;
        float impactSpeed = 1f - MathF.Exp(-delta * (impactTarget > visualImpact ? 11.0f : 4.2f));
        visualImpact += (impactTarget - visualImpact) * impactSpeed;

        float overload = SmoothStep(0.58f, 0.94f, visualDensity * 0.72f + visualActivity * 0.28f);
        float clarityTarget = 1f - overload * (0.22f - visualImpact * 0.06f);
        float claritySpeed = 1f - MathF.Exp(-delta * (clarityTarget < visualClarity ? 5.0f : 2.0f));
        visualClarity += (clarityTarget - visualClarity) * claritySpeed;
    }

    private float ShapeBand(float value)
    {
        float ceiling = 0.68f + visualImpact * 0.32f;
        float shaped = MathF.Pow(Math.Clamp(value, 0f, ceiling), 0.94f);
        return shaped * (0.72f + visualActivity * 0.28f);
    }

    private static float ShapeFeature(float value, float activity, float impact)
    {
        float normal = SmoothStep(0.06f, 0.90f, value) * 0.72f * (0.72f + activity * 0.28f);
        float extreme = SmoothStep(0.68f, 0.98f, value) * impact * 0.32f;
        return Math.Clamp(normal + extreme, 0f, 1f);
    }

    private static float ShapePulse(float value, float activity, float impact)
    {
        float normal = SmoothStep(0.08f, 0.78f, value) * (0.50f + activity * 0.18f);
        float extreme = SmoothStep(0.58f, 0.96f, value) * impact * 0.32f;
        return Math.Clamp(normal + extreme, 0f, 1f);
    }

    private static float SmoothStep(float edge0, float edge1, float value)
    {
        float amount = Math.Clamp((value - edge0) / Math.Max(0.0001f, edge1 - edge0), 0f, 1f);
        return amount * amount * (3f - 2f * amount);
    }

    private Vector4 PackWave(int start)
    {
        float waveScale = 0.68f + visualActivity * 0.10f + visualImpact * 0.22f;
        if (mode == 4) waveScale = 1f;
        return new(
            displayWaveform[start] * waveScale,
            displayWaveform[start + 1] * waveScale,
            displayWaveform[start + 2] * waveScale,
            displayWaveform[start + 3] * waveScale);
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
        int nextMode = NextModeFromDeck(first ? -1 : mode);
        int nextPalette = first ? random.Next(palettes.Length) : RandomDifferent(paletteIndex, palettes.Length);
        BeginTransition(nextMode, nextPalette, first);
        nextShuffle = DateTime.Now.AddSeconds(first ? 20 : random.Next(18, 38));
    }

    private int NextModeFromDeck(int current)
    {
        if (modeDeckIndex >= ModeCount)
        {
            for (int i = 0; i < ModeCount; i++) modeDeck[i] = i;
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
        EnsureSceneShader(nextMode);
        if (!first && context != null && transitionTexture != null && feedbackTextures[feedbackIndex] != null)
        {
            context.PSUnsetShaderResource(0);
            context.PSUnsetShaderResource(1);
            // Capture the visible blend too, so repeated manual skips stay continuous.
            context.CopyResource(transitionTexture, presentedTexture!);
            context.ClearRenderTargetView(feedbackViews[0]!, new Color4(0, 0, 0, 1));
            context.ClearRenderTargetView(feedbackViews[1]!, new Color4(0, 0, 0, 1));
            feedbackIndex = 0;
        }
        previousMode = first ? nextMode : mode;
        previousPaletteIndex = first ? nextPalette : paletteIndex;
        previousSeed = first ? currentSeed : currentSeed;
        mode = nextMode;
        sceneFilter.Reroll(random, mode);
        if (mode == 30 && (first || previousMode != mode))
        {
            Array.Clear(spectralHistory);
            snapshotCount = 0;
        }
        paletteIndex = nextPalette;
        currentSeed = (float)random.NextDouble() * 1000f;
        transition = first ? 1f : 0f;
        float beatSeconds = 60f / Math.Clamp(analyzer.TempoBpm, 55f, 200f);
        int transitionBeats = random.Next(4, 7);
        transitionDuration = Math.Clamp(beatSeconds * transitionBeats, 2.0f, 3.6f);
        feedbackPersistence = 0.885f + (float)random.NextDouble() * 0.075f;
        warpStrength = 0.72f + (float)random.NextDouble() * 0.92f;
        symmetry = random.Next(4, 10);
        hueRate = 0.68f + (float)random.NextDouble() * 1.05f;
        if (first || previousMode != mode) accentCamera.Reroll(random, mode);
    }

    private Vector4[] BuildPalette(int fromIndex, int toIndex, float amount)
    {
        Vector4[] result = new Vector4[4];
        Vector4[] from = palettes[Math.Clamp(fromIndex, 0, palettes.Length - 1)];
        Vector4[] to = palettes[Math.Clamp(toIndex, 0, palettes.Length - 1)];
        for (int i = 0; i < result.Length; i++)
            result[i] = Vector4.Lerp(from[i], to[i], amount);
        return result;
    }

    private static Vector4 Rgb(int hex) => new(((hex >> 16) & 255) / 255f, ((hex >> 8) & 255) / 255f, (hex & 255) / 255f, 1f);

    private int RandomDifferent(int current, int count)
    {
        if (count <= 1) return 0;
        int next = random.Next(count - 1);
        return next >= current ? next + 1 : next;
    }

    private void DisposeTargets()
    {
        presentedTexture?.Dispose();
        presentedTexture = null;
        backBufferView?.Dispose();
        backBufferView = null;
        backBuffer?.Dispose();
        backBuffer = null;
        for (int i = 0; i < 2; i++)
        {
            feedbackResources[i]?.Dispose();
            feedbackResources[i] = null;
            feedbackViews[i]?.Dispose();
            feedbackViews[i] = null;
            feedbackTextures[i]?.Dispose();
            feedbackTextures[i] = null;
        }
        transitionResource?.Dispose();
        transitionResource = null;
        transitionTexture?.Dispose();
        transitionTexture = null;
    }

    protected override void Dispose(bool disposing)
    {
        // Form.Close and the owner's using statement can both dispose the form.
        if (graphicsDisposed)
        {
            base.Dispose(disposing);
            return;
        }
        graphicsDisposed = true;
        Application.Idle -= OnApplicationIdle;
        if (context != null)
        {
            context.PSUnsetShaderResource(0);
            context.PSUnsetShaderResource(1);
            context.UnsetRenderTargets();
            context.Flush();
        }
        DisposeTargets();
        sampler?.Dispose();
        constantBuffer?.Dispose();
        for (int i = 0; i < scenePixelShaders.Length; i++)
        {
            scenePixelShaders[i]?.Dispose();
            scenePixelShaders[i] = null;
        }
        vertexShader?.Dispose();
        transitionShader?.Dispose();
        swapChain?.Dispose();
        context?.Dispose();
        device?.Dispose();
        factory?.Dispose();
        if (timerResolutionEnabled)
        {
            timeEndPeriod(1);
            timerResolutionEnabled = false;
        }
        base.Dispose(disposing);
    }

    private static bool IsApplicationIdle => !PeekMessage(out _, IntPtr.Zero, 0, 0, 0);

    [DllImport("user32.dll")]
    private static extern bool PeekMessage(out NativeMessage message, IntPtr hwnd, uint filterMin, uint filterMax, uint remove);

    [DllImport("winmm.dll")]
    private static extern uint timeBeginPeriod(uint period);

    [DllImport("winmm.dll")]
    private static extern uint timeEndPeriod(uint period);

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

    [StructLayout(LayoutKind.Sequential)]
    private struct ShaderConstants
    {
        public Vector4 ResolutionTime;
        public Vector4 AudioA;
        public Vector4 AudioB;
        public Vector4 AudioC;
        public Vector4 Motion;
        public Vector4 Modes;
        public Vector4 Presets;
        public Vector4 Feedback;
        public Vector4 Dynamics;
        public Vector4 Stage;
        public Vector4 Camera;
        public Vector4 Filter;
        public Vector4 Stereo;
        public Vector4 StereoBands0;
        public Vector4 StereoBands1;
        public Vector4 StereoBands2;
        public Vector4 StereoBands3;
        public Vector4 History0;
        public Vector4 History1;
        public Vector4 History2;
        public Vector4 History3;
        public Vector4 History4;
        public Vector4 History5;
        public Vector4 History6;
        public Vector4 History7;
        public Vector4 History8;
        public Vector4 History9;
        public Vector4 History10;
        public Vector4 History11;
        public Vector4 History12;
        public Vector4 History13;
        public Vector4 History14;
        public Vector4 History15;
        public Vector4 History16;
        public Vector4 History17;
        public Vector4 History18;
        public Vector4 History19;
        public Vector4 History20;
        public Vector4 History21;
        public Vector4 History22;
        public Vector4 History23;
        public Vector4 History24;
        public Vector4 History25;
        public Vector4 History26;
        public Vector4 History27;
        public Vector4 History28;
        public Vector4 History29;
        public Vector4 History30;
        public Vector4 History31;
        public Vector4 History32;
        public Vector4 History33;
        public Vector4 History34;
        public Vector4 History35;
        public Vector4 History36;
        public Vector4 History37;
        public Vector4 History38;
        public Vector4 History39;
        public Vector4 History40;
        public Vector4 History41;
        public Vector4 History42;
        public Vector4 History43;
        public Vector4 History44;
        public Vector4 History45;
        public Vector4 History46;
        public Vector4 History47;
        public Vector4 History48;
        public Vector4 History49;
        public Vector4 History50;
        public Vector4 History51;
        public Vector4 History52;
        public Vector4 History53;
        public Vector4 History54;
        public Vector4 History55;
        public Vector4 History56;
        public Vector4 History57;
        public Vector4 History58;
        public Vector4 History59;
        public Vector4 History60;
        public Vector4 History61;
        public Vector4 History62;
        public Vector4 History63;
        public Vector4 Palette0;
        public Vector4 Palette1;
        public Vector4 Palette2;
        public Vector4 Palette3;
        public Vector4 Bands0;
        public Vector4 Bands1;
        public Vector4 Bands2;
        public Vector4 Bands3;
        public Vector4 Bands4;
        public Vector4 Bands5;
        public Vector4 Bands6;
        public Vector4 Bands7;
        public Vector4 Bands8;
        public Vector4 Bands9;
        public Vector4 Bands10;
        public Vector4 Bands11;
        public Vector4 Bands12;
        public Vector4 Bands13;
        public Vector4 Bands14;
        public Vector4 Bands15;
        public Vector4 Wave0;
        public Vector4 Wave1;
        public Vector4 Wave2;
        public Vector4 Wave3;
        public Vector4 Wave4;
        public Vector4 Wave5;
        public Vector4 Wave6;
        public Vector4 Wave7;
        public Vector4 Wave8;
        public Vector4 Wave9;
        public Vector4 Wave10;
        public Vector4 Wave11;
        public Vector4 Wave12;
        public Vector4 Wave13;
        public Vector4 Wave14;
        public Vector4 Wave15;
    }
}
