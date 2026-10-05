param(
    [int]$Screen = 1,
    [double]$RenderScale = 0.70,
    [switch]$CompileOnly,
    [switch]$AudioTest
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace NostalgicVisualizer
{
    public static class Entry
    {
        [STAThread]
        public static void Run(int screenNumber, double renderScale)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            using (var analyzer = new AudioAnalyzer())
            using (var form = new VisualizerForm(analyzer, screenNumber, renderScale))
            {
                analyzer.Start();
                Application.Run(form);
            }
        }
    }

    public static class AudioProbe
    {
        public static string Test()
        {
            using (var capture = new WasapiLoopbackCapture())
            {
                var buffer = new float[4096];
                int total = 0;
                float peak = 0;
                var until = DateTime.UtcNow.AddMilliseconds(900);
                while (DateTime.UtcNow < until)
                {
                    int read = capture.Read(buffer, buffer.Length);
                    total += read;
                    for (int i = 0; i < read; i++)
                        peak = Math.Max(peak, Math.Abs(buffer[i]));
                    Thread.Sleep(10);
                }
                return "Loopback opened; samples=" + total + "; peak=" + peak.ToString("0.0000");
            }
        }
    }

    public sealed class AudioAnalyzer : IDisposable
    {
        private const int FftSize = 2048;
        private const int WaveformSize = 768;
        private readonly object sync = new object();
        private readonly float[] spectrum = new float[96];
        private readonly float[] waveform = new float[WaveformSize];
        private readonly float[] fftBuffer = new float[FftSize];
        private readonly float[] window = new float[FftSize];
        private Thread thread;
        private volatile bool running;
        private volatile bool demoMode;
        private float level;
        private float bass;
        private float mid;
        private float treble;
        private float beat;
        private float inputReference = 0.035f;
        private float spectrumReference = 0.32f;
        private readonly float[] bandReferences = new float[96];
        private float beatAverage = 0.15f;
        private float displayGain = 18f;
        private string status = "Starting audio capture...";

        public AudioAnalyzer()
        {
            for (int i = 0; i < FftSize; i++)
                window[i] = 0.5f - 0.5f * (float)Math.Cos((2.0 * Math.PI * i) / (FftSize - 1));
        }

        public float Level { get { return level; } }
        public float Bass { get { return bass; } }
        public float Mid { get { return mid; } }
        public float Treble { get { return treble; } }
        public float Beat { get { return beat; } }
        public bool DemoMode { get { return demoMode; } }
        public string Status { get { return status; } }

        public void Start()
        {
            if (running) return;
            running = true;
            thread = new Thread(CaptureLoop);
            thread.IsBackground = true;
            thread.Name = "Windows audio loopback capture";
            thread.Start();
        }

        public void Snapshot(float[] spectrumOut, float[] waveformOut)
        {
            lock (sync)
            {
                Array.Copy(spectrum, spectrumOut, Math.Min(spectrum.Length, spectrumOut.Length));
                Array.Copy(waveform, waveformOut, Math.Min(waveform.Length, waveformOut.Length));
            }
        }

        private void CaptureLoop()
        {
            try
            {
                using (var capture = new WasapiLoopbackCapture())
                {
                    status = "Listening to default playback device";
                    demoMode = false;
                    var collected = new List<float>(FftSize * 2);
                    var scratch = new float[4096];

                    while (running)
                    {
                        int count = capture.Read(scratch, scratch.Length);
                        if (count == 0)
                        {
                            Decay();
                            Thread.Sleep(8);
                            continue;
                        }

                        PushWaveform(scratch, count);
                        for (int i = 0; i < count; i++)
                            collected.Add(scratch[i]);

                        while (collected.Count >= FftSize)
                        {
                            for (int i = 0; i < FftSize; i++)
                                fftBuffer[i] = collected[i] * window[i];
                            collected.RemoveRange(0, FftSize / 2);
                            AnalyzeBlock(fftBuffer);
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                status = "Audio capture unavailable: " + ex.Message;
                demoMode = true;
                DemoLoop();
            }
        }

        private void DemoLoop()
        {
            var sw = Stopwatch.StartNew();
            var rnd = new Random();
            while (running)
            {
                float t = (float)sw.Elapsed.TotalSeconds;
                float pulse = 0.25f + 0.75f * Math.Max(0, (float)Math.Sin(t * 2.1f));
                lock (sync)
                {
                    for (int i = 0; i < waveform.Length; i++)
                    {
                        float x = i / (float)waveform.Length;
                        waveform[i] = (float)(Math.Sin((x * 8 + t * 1.7) * Math.PI) * 0.45 + Math.Sin((x * 31 - t * 3.4) * Math.PI) * 0.12);
                    }
                    for (int i = 0; i < spectrum.Length; i++)
                    {
                        float x = i / (float)spectrum.Length;
                        spectrum[i] = Clamp01((float)(Math.Pow(Math.Sin(x * Math.PI), 1.5) * pulse + rnd.NextDouble() * 0.08));
                    }
                }
                level = pulse * 0.6f;
                bass = pulse;
                mid = 0.55f + 0.25f * (float)Math.Sin(t * 1.3f);
                treble = 0.45f + 0.25f * (float)Math.Sin(t * 3.7f);
                beat = Math.Max(0, (float)Math.Sin(t * 2.1f));
                Thread.Sleep(16);
            }
        }

        private void PushWaveform(float[] samples, int count)
        {
            lock (sync)
            {
                int copy = Math.Min(count, waveform.Length);
                Array.Copy(waveform, copy, waveform, 0, waveform.Length - copy);
                float gain = displayGain;
                for (int i = 0; i < copy; i++)
                    waveform[waveform.Length - copy + i] = SoftClip(samples[count - copy + i] * gain);
            }
        }

        private void AnalyzeBlock(float[] samples)
        {
            Complex[] bins = new Complex[FftSize];
            float rms = 0;
            float peak = 0;
            for (int i = 0; i < FftSize; i++)
            {
                float raw = samples[i];
                float abs = Math.Abs(raw);
                if (abs > peak) peak = abs;
                rms += raw * raw;
            }
            rms = (float)Math.Sqrt(rms / FftSize);

            float targetReference = Math.Max(0.0018f, Math.Max(peak * 0.72f, rms * 2.8f));
            float referenceSpeed = targetReference > inputReference ? 0.16f : 0.012f;
            inputReference = Smooth(inputReference, targetReference, referenceSpeed);
            displayGain = Clamp(0.78f / inputReference, 1.0f, 95f);

            float normalizedRms = 0;
            for (int i = 0; i < FftSize; i++)
            {
                float normalized = SoftClip(samples[i] * displayGain);
                bins[i] = new Complex(normalized * window[i], 0);
                normalizedRms += normalized * normalized;
            }
            Fft(bins, false);
            normalizedRms = (float)Math.Sqrt(normalizedRms / FftSize);

            float[] next = new float[spectrum.Length];
            float bandPeak = 0;
            for (int i = 0; i < next.Length; i++)
            {
                double start = Math.Pow(i / (double)next.Length, 2.0) * (FftSize / 2 - 1);
                double end = Math.Pow((i + 1) / (double)next.Length, 2.0) * (FftSize / 2 - 1);
                int a = Math.Max(1, (int)start);
                int b = Math.Max(a + 1, (int)end);
                double total = 0;
                for (int j = a; j < b; j++)
                    total += bins[j].Magnitude;
                double mag = total / Math.Max(1, b - a);
                next[i] = (float)Math.Log10(1 + mag * 7.5);
                if (next[i] > bandPeak) bandPeak = next[i];
            }

            float targetSpectrum = Math.Max(0.08f, bandPeak * 0.82f);
            float spectrumSpeed = targetSpectrum > spectrumReference ? 0.20f : 0.018f;
            spectrumReference = Smooth(spectrumReference, targetSpectrum, spectrumSpeed);
            for (int i = 0; i < next.Length; i++)
            {
                float regionTrim = i < 18 ? 0.58f + i * 0.018f : 1.0f;
                float referenceTarget = Math.Max(0.055f, next[i] * (i < 18 ? 1.28f : 1.0f));
                float bandReferenceSpeed = referenceTarget > bandReferences[i] ? 0.28f : 0.018f;
                bandReferences[i] = Smooth(bandReferences[i] <= 0 ? referenceTarget : bandReferences[i], referenceTarget, bandReferenceSpeed);
                float normalizedBand = next[i] / Math.Max(0.055f, bandReferences[i] * 1.16f);
                float compressedBand = 1f - (float)Math.Exp(-normalizedBand * 1.12f);
                next[i] = Clamp01((float)Math.Pow(compressedBand, 0.82) * regionTrim);
            }

            float newBass = BassLimit(Average(next, 1, 14));
            float newMid = Average(next, 15, 48);
            float newTreble = Average(next, 49, next.Length - 1);
            float energy = Clamp01(normalizedRms * 1.05f + newBass * 0.28f + newMid * 0.18f);
            beatAverage = Smooth(beatAverage, energy, energy > beatAverage ? 0.05f : 0.008f);
            float newBeat = Clamp01((energy - beatAverage) * 3.3f + Math.Max(0, newBass - bass) * 1.7f);

            lock (sync)
            {
                for (int i = 0; i < spectrum.Length; i++)
                    spectrum[i] = Math.Max(next[i], spectrum[i] * 0.82f);
            }

            level = Smooth(level, energy, 0.22f);
            bass = Smooth(bass, newBass, 0.25f);
            mid = Smooth(mid, newMid, 0.22f);
            treble = Smooth(treble, newTreble, 0.20f);
            beat = Math.Max(newBeat, beat * 0.82f);
        }

        private void Decay()
        {
            level *= 0.96f;
            bass *= 0.95f;
            mid *= 0.95f;
            treble *= 0.95f;
            beat *= 0.88f;
            lock (sync)
            {
                for (int i = 0; i < spectrum.Length; i++)
                    spectrum[i] *= 0.94f;
                for (int i = 0; i < waveform.Length; i++)
                    waveform[i] *= 0.985f;
            }
        }

        private static float Average(float[] values, int start, int end)
        {
            start = Math.Max(0, start);
            end = Math.Min(values.Length - 1, end);
            float total = 0;
            int count = 0;
            for (int i = start; i <= end; i++)
            {
                total += values[i];
                count++;
            }
            return count == 0 ? 0 : total / count;
        }

        private static float Smooth(float oldValue, float newValue, float amount)
        {
            return oldValue + (newValue - oldValue) * amount;
        }

        private static float SoftClip(float value)
        {
            return (float)Math.Tanh(value * 1.35f);
        }

        private static float BassLimit(float value)
        {
            return 0.78f * (1f - (float)Math.Exp(-value * 1.65f));
        }

        private static float Clamp(float value, float min, float max)
        {
            if (value < min) return min;
            if (value > max) return max;
            return value;
        }

        private static float Clamp01(float value)
        {
            if (value < 0) return 0;
            if (value > 1) return 1;
            return value;
        }

        private static void Fft(Complex[] buffer, bool inverse)
        {
            int n = buffer.Length;
            for (int i = 1, j = 0; i < n; i++)
            {
                int bit = n >> 1;
                for (; (j & bit) != 0; bit >>= 1)
                    j ^= bit;
                j ^= bit;
                if (i < j)
                {
                    Complex temp = buffer[i];
                    buffer[i] = buffer[j];
                    buffer[j] = temp;
                }
            }

            for (int len = 2; len <= n; len <<= 1)
            {
                double angle = 2 * Math.PI / len * (inverse ? 1 : -1);
                Complex wlen = new Complex(Math.Cos(angle), Math.Sin(angle));
                for (int i = 0; i < n; i += len)
                {
                    Complex w = Complex.One;
                    for (int j = 0; j < len / 2; j++)
                    {
                        Complex u = buffer[i + j];
                        Complex v = buffer[i + j + len / 2] * w;
                        buffer[i + j] = u + v;
                        buffer[i + j + len / 2] = u - v;
                        w *= wlen;
                    }
                }
            }

            if (inverse)
            {
                for (int i = 0; i < n; i++)
                    buffer[i] /= n;
            }
        }

        public void Dispose()
        {
            running = false;
            if (thread != null && thread.IsAlive)
                thread.Join(350);
        }
    }

    public sealed class VisualizerForm : Form
    {
        private readonly AudioAnalyzer analyzer;
        private readonly System.Windows.Forms.Timer timer;
        private readonly Random random = new Random();
        private readonly float[] spectrum = new float[96];
        private readonly float[] waveform = new float[768];
        private readonly List<Spark> sparks = new List<Spark>();
        private readonly Stopwatch frameClock = Stopwatch.StartNew();
        private Bitmap canvas;
        private float time;
        private double lastFrameSeconds;
        private float measuredFps = 60f;
        private int mode;
        private int previousMode;
        private int paletteIndex;
        private int previousPaletteIndex;
        private float transitionProgress = 1f;
        private bool showHelp = true;
        private bool fullscreen = true;
        private DateTime nextShuffle;
        private DateTime lastBeatShuffle = DateTime.MinValue;
        private Rectangle windowedBounds;
        private FormBorderStyle windowedBorder;

        private readonly Color[][] palettes = new Color[][]
        {
            new [] { Color.FromArgb(255, 55, 0), Color.FromArgb(255, 236, 46), Color.FromArgb(0, 239, 255), Color.FromArgb(255, 0, 200) },
            new [] { Color.FromArgb(50, 255, 80), Color.FromArgb(0, 185, 255), Color.FromArgb(184, 77, 255), Color.FromArgb(255, 255, 255) },
            new [] { Color.FromArgb(255, 0, 72), Color.FromArgb(255, 140, 0), Color.FromArgb(255, 234, 0), Color.FromArgb(74, 255, 200) },
            new [] { Color.FromArgb(64, 255, 255), Color.FromArgb(40, 90, 255), Color.FromArgb(255, 70, 220), Color.FromArgb(255, 255, 255) },
            new [] { Color.FromArgb(120, 255, 70), Color.FromArgb(255, 40, 40), Color.FromArgb(255, 215, 0), Color.FromArgb(30, 30, 30) },
            new [] { Color.FromArgb(255, 90, 180), Color.FromArgb(80, 255, 230), Color.FromArgb(120, 150, 255), Color.FromArgb(255, 255, 180) },
            new [] { Color.FromArgb(55, 255, 115), Color.FromArgb(255, 255, 255), Color.FromArgb(255, 70, 35), Color.FromArgb(0, 150, 255) },
            new [] { Color.FromArgb(255, 200, 0), Color.FromArgb(255, 40, 135), Color.FromArgb(70, 255, 255), Color.FromArgb(80, 30, 255) },
            new [] { Color.FromArgb(255, 20, 20), Color.FromArgb(70, 0, 0), Color.FromArgb(255, 170, 0), Color.FromArgb(8, 8, 8) },
            new [] { Color.FromArgb(120, 255, 120), Color.FromArgb(210, 255, 210), Color.FromArgb(40, 130, 40), Color.FromArgb(5, 20, 5) },
            new [] { Color.FromArgb(30, 160, 255), Color.FromArgb(60, 255, 255), Color.FromArgb(20, 60, 255), Color.FromArgb(255, 255, 255) },
            new [] { Color.FromArgb(255, 0, 230), Color.FromArgb(160, 40, 255), Color.FromArgb(255, 120, 255), Color.FromArgb(40, 0, 80) }
        };

        private const int ModeCount = 16;
        private const double TargetFrameSeconds = 1.0 / 60.0;
        private const int WaveDrawPoints = 320;

        private float renderScale;

        public VisualizerForm(AudioAnalyzer analyzer, int screenNumber, double requestedRenderScale)
        {
            this.analyzer = analyzer;
            renderScale = Math.Max(0.40f, Math.Min(1.0f, (float)requestedRenderScale));
            Text = "Windows Music Visualizer";
            BackColor = Color.Black;
            KeyPreview = true;
            DoubleBuffered = true;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);

            SelectScreen(screenNumber);
            RandomizePreset(true);

            timer = new System.Windows.Forms.Timer();
            timer.Interval = 1;
            timer.Tick += delegate
            {
                double now = frameClock.Elapsed.TotalSeconds;
                double delta = now - lastFrameSeconds;
                if (delta < TargetFrameSeconds)
                    return;
                if (delta > 0.05)
                    delta = 0.05;
                lastFrameSeconds = now;

                time += (float)delta;
                measuredFps = measuredFps * 0.92f + (float)(1.0 / delta) * 0.08f;
                transitionProgress = Math.Min(1f, transitionProgress + (float)(delta * 0.88 + analyzer.Beat * delta * 0.42));
                MaybeShuffle();
                RenderFrame();
                Invalidate();
            };
            timer.Start();
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

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            RebuildCanvas();
        }

        private void RebuildCanvas()
        {
            if (ClientSize.Width <= 0 || ClientSize.Height <= 0) return;
            if (canvas != null) canvas.Dispose();
            int renderWidth = Math.Max(320, (int)(ClientSize.Width * renderScale));
            int renderHeight = Math.Max(200, (int)(ClientSize.Height * renderScale));
            canvas = new Bitmap(renderWidth, renderHeight);
            using (Graphics g = Graphics.FromImage(canvas))
                g.Clear(Color.Black);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (e.KeyCode == Keys.Escape) Close();
            if (e.KeyCode == Keys.Space) RandomizePreset(false);
            if (e.KeyCode == Keys.M) BeginTransition((mode + 1) % ModeCount, paletteIndex, false);
            if (e.KeyCode == Keys.C) BeginTransition(mode, (paletteIndex + 1) % palettes.Length, false);
            if (e.KeyCode == Keys.H) showHelp = !showHelp;
            if (e.KeyCode == Keys.F) ToggleFullscreen();
            if (e.KeyCode == Keys.Oemplus || e.KeyCode == Keys.Add) SetRenderScale(renderScale + 0.08f);
            if (e.KeyCode == Keys.OemMinus || e.KeyCode == Keys.Subtract) SetRenderScale(renderScale - 0.08f);
        }

        private void ToggleFullscreen()
        {
            if (fullscreen)
            {
                windowedBounds = Bounds;
                windowedBorder = FormBorderStyle;
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

        private void SetRenderScale(float nextScale)
        {
            renderScale = Math.Max(0.40f, Math.Min(1.0f, nextScale));
            RebuildCanvas();
        }

        private void MaybeShuffle()
        {
            if (DateTime.Now >= nextShuffle)
                RandomizePreset(false);

            if (analyzer.Beat > 0.83f && (DateTime.Now - lastBeatShuffle).TotalSeconds > 10)
            {
                if (random.NextDouble() < 0.24)
                {
                    BeginTransition(RandomDifferent(mode, ModeCount), RandomDifferent(paletteIndex, palettes.Length), false);
                    lastBeatShuffle = DateTime.Now;
                }
            }
        }

        private void RandomizePreset(bool first)
        {
            int nextMode = first ? random.Next(ModeCount) : RandomDifferent(mode, ModeCount);
            int nextPalette = first ? random.Next(palettes.Length) : RandomDifferent(paletteIndex, palettes.Length);
            BeginTransition(nextMode, nextPalette, first);
            nextShuffle = DateTime.Now.AddSeconds(first ? 25 : random.Next(18, 42));
        }

        private void BeginTransition(int nextMode, int nextPalette, bool first)
        {
            previousMode = first ? nextMode : mode;
            previousPaletteIndex = first ? nextPalette : paletteIndex;
            mode = nextMode;
            paletteIndex = nextPalette;
            transitionProgress = first ? 1f : 0f;
            AddSparkBurst(ClientSize.Width / 2f, ClientSize.Height / 2f, 18);
        }

        private int RandomDifferent(int current, int count)
        {
            if (count <= 1) return 0;
            int next = random.Next(count - 1);
            return next >= current ? next + 1 : next;
        }

        private void RenderFrame()
        {
            if (canvas == null) return;
            analyzer.Snapshot(spectrum, waveform);
            using (Graphics g = Graphics.FromImage(canvas))
            {
                g.ScaleTransform(renderScale, renderScale);
                g.CompositingQuality = CompositingQuality.HighSpeed;
                Fade(g);

                float eased = Ease(transitionProgress);
                Color[] pal = BuildPalette(previousPaletteIndex, paletteIndex, eased);
                if (transitionProgress < 1f && previousMode != mode)
                {
                    int visibleMode = eased < 0.38f ? previousMode : mode;
                    Color[] visiblePalette = BuildPalette(previousPaletteIndex, paletteIndex, eased);
                    RenderMode(g, visibleMode, visiblePalette);
                    RenderTransitionBridge(g, eased, pal);
                    DrawTransitionVeil(g, eased, pal);
                }
                else
                {
                    RenderMode(g, mode, pal);
                    if (transitionProgress < 1f)
                        DrawTransitionVeil(g, eased, pal);
                }

                RenderSparks(g);
                if (showHelp) RenderOverlay(g);
            }
        }

        private void RenderMode(Graphics g, int modeToRender, Color[] pal)
        {
            g.SmoothingMode = IsDenseLineMode(modeToRender) ? SmoothingMode.HighSpeed : SmoothingMode.AntiAlias;
            switch (modeToRender)
            {
                case 0: RenderClassicBars(g, pal); break;
                case 1: RenderTunnel(g, pal); break;
                case 2: RenderPlasmaCloud(g, pal); break;
                case 3: RenderWaveLightning(g, pal); break;
                case 4: RenderStarBurst(g, pal); break;
                case 5: RenderFlowerScope(g, pal); break;
                case 6: RenderOrbitRibbons(g, pal); break;
                case 7: RenderOscilloscopeGrid(g, pal); break;
                case 8: RenderKaleidoscopeFans(g, pal); break;
                case 9: RenderSpectrumRain(g, pal); break;
                case 10: RenderMagentaVortex(g, pal); break;
                case 11: RenderRedPinwheel(g, pal); break;
                case 12: RenderElectricWeb(g, pal); break;
                case 13: RenderRainbowShardBurst(g, pal); break;
                case 14: RenderBlueNebula(g, pal); break;
                default: RenderSmokeTunnel(g, pal); break;
            }
        }

        private static bool IsDenseLineMode(int modeToRender)
        {
            return modeToRender == 3 || modeToRender == 5 || modeToRender == 6 || modeToRender == 7 || modeToRender == 10 || modeToRender == 12 || modeToRender == 15;
        }

        private void Fade(Graphics g)
        {
            int alpha = 18 + (int)(22 * analyzer.Treble);
            using (var brush = new SolidBrush(Color.FromArgb(alpha, 0, 0, 0)))
                g.FillRectangle(brush, ClientRectangle);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (canvas != null)
            {
                e.Graphics.InterpolationMode = InterpolationMode.Bilinear;
                e.Graphics.PixelOffsetMode = PixelOffsetMode.Half;
                e.Graphics.DrawImage(canvas, ClientRectangle);
            }
        }

        private void RenderClassicBars(Graphics g, Color[] pal)
        {
            int w = ClientSize.Width;
            int h = ClientSize.Height;
            int count = spectrum.Length;
            float barWidth = Math.Max(5, w / (float)(count + 10));
            float baseline = h * 0.82f;

            for (int i = 0; i < count; i++)
            {
                float value = spectrum[i];
                float height = BassAwareHeight(i, value) * h * 0.46f;
                float x = i * barWidth + barWidth * 4;
                Color c = Blend(pal[i % pal.Length], pal[(i + 1) % pal.Length], value);
                using (var brush = new LinearGradientBrush(new RectangleF(x, baseline - height, barWidth * 0.78f, Math.Max(1, height)), Color.White, c, 90f))
                    g.FillRectangle(brush, x, baseline - height, barWidth * 0.72f, height);
                using (var pen = new Pen(Color.FromArgb(150, c), 1))
                    g.DrawLine(pen, x, baseline - height - 18 * analyzer.Beat, x + barWidth * 0.72f, baseline - height - 18 * analyzer.Beat);
            }

            using (var pen = new Pen(Color.FromArgb(95, 80, 190, 255), 2))
                g.DrawLine(pen, 0, baseline, w, baseline);
        }

        private void RenderTunnel(Graphics g, Color[] pal)
        {
            int w = ClientSize.Width;
            int h = ClientSize.Height;
            float cx = w / 2f;
            float cy = h / 2f;
            float baseRadius = Math.Min(w, h) * (0.07f + analyzer.Bass * 0.04f);

            for (int ring = 0; ring < 24; ring++)
            {
                float t = ring / 24f;
                float radius = baseRadius + t * Math.Max(w, h) * 0.74f;
                int points = 56;
                PointF[] pts = new PointF[points];
                for (int i = 0; i < points; i++)
                {
                    float angle = (float)(i * Math.PI * 2 / points + time * (0.25 + t) + ring * 0.18);
                    float spec = spectrum[(i + ring * 3) % spectrum.Length];
                    float warp = (float)Math.Sin(angle * 5 + time * 1.8f) * 12f + spec * 120f * (0.25f + t);
                    pts[i] = new PointF(cx + (float)Math.Cos(angle) * (radius + warp), cy + (float)Math.Sin(angle) * (radius + warp));
                }
                Color c = Color.FromArgb((int)(170 * (1 - t)), Blend(pal[ring % pal.Length], pal[(ring + 2) % pal.Length], analyzer.Mid));
                using (var pen = new Pen(c, 1.1f + analyzer.Beat * 1.5f))
                    g.DrawPolygon(pen, pts);
            }
        }

        private void RenderPlasmaCloud(Graphics g, Color[] pal)
        {
            int w = ClientSize.Width;
            int h = ClientSize.Height;

            for (int i = 0; i < 90; i++)
            {
                float spec = spectrum[(i * 7) % spectrum.Length];
                float x = w * (0.5f + 0.48f * (float)Math.Sin(time * 0.23f + i * 1.31f + analyzer.Mid));
                float y = h * (0.5f + 0.45f * (float)Math.Cos(time * 0.19f + i * 0.77f));
                float size = 36 + spec * 260 + analyzer.Bass * 80;
                Color c = Color.FromArgb(18 + (int)(80 * spec), pal[i % pal.Length]);
                using (var brush = new SolidBrush(c))
                    g.FillEllipse(brush, x - size / 2, y - size / 2, size, size);
            }

            for (int y = 0; y < h; y += 34)
            {
                using (var pen = new Pen(Color.FromArgb(30, pal[(y / 34) % pal.Length]), 1))
                {
                    PointF[] line = new PointF[48];
                    for (int i = 0; i < line.Length; i++)
                    {
                        float x = i * w / (float)(line.Length - 1);
                        float wave = (float)Math.Sin(i * 0.7f + y * 0.02f + time * 2.0f) * 20 * analyzer.Mid;
                        line[i] = new PointF(x, y + wave);
                    }
                    g.DrawCurve(pen, line, 0.5f);
                }
            }
        }

        private void RenderWaveLightning(Graphics g, Color[] pal)
        {
            int w = ClientSize.Width;
            int h = ClientSize.Height;
            float center = h / 2f;
            int layers = 4;
            for (int layer = 0; layer < layers; layer++)
            {
                PointF[] pts = new PointF[WaveDrawPoints];
                for (int i = 0; i < pts.Length; i++)
                {
                    int wi = i * (waveform.Length - 1) / (pts.Length - 1);
                    float x = i * w / (float)(pts.Length - 1);
                    float amp = h * (0.15f + analyzer.Bass * 0.12f);
                    float y = center + waveform[wi] * amp + (float)Math.Sin(i * 0.075f + time * (2 + layer)) * 16 * analyzer.Mid;
                    pts[i] = new PointF(x, y + (layer - 1.5f) * 22);
                }
                Color c = Color.FromArgb(70 + layer * 34, pal[layer % pal.Length]);
                using (var pen = new Pen(c, 1.1f + layer * 0.45f + analyzer.Beat * 1.7f))
                    g.DrawLines(pen, pts);
            }

            if (analyzer.Beat > 0.7f)
                AddSparkBurst(random.Next(ClientSize.Width), random.Next(ClientSize.Height), 5);
        }

        private void RenderStarBurst(Graphics g, Color[] pal)
        {
            int w = ClientSize.Width;
            int h = ClientSize.Height;
            float cx = w / 2f + (float)Math.Sin(time * 0.7f) * w * 0.08f;
            float cy = h / 2f + (float)Math.Cos(time * 0.53f) * h * 0.08f;

            for (int i = 0; i < 144; i++)
            {
                float spec = spectrum[i % spectrum.Length];
                float angle = (float)(i * Math.PI * 2 / 144 + time * (0.45f + analyzer.Treble * 0.5f));
                float length = Math.Min(w, h) * (0.08f + spec * 0.68f + analyzer.Bass * 0.18f);
                float bend = (float)Math.Sin(time * 2 + i) * 0.26f;
                PointF p1 = new PointF(cx + (float)Math.Cos(angle) * 22, cy + (float)Math.Sin(angle) * 22);
                PointF p2 = new PointF(cx + (float)Math.Cos(angle + bend) * length, cy + (float)Math.Sin(angle + bend) * length);
                Color c = Color.FromArgb(35 + (int)(190 * spec), pal[i % pal.Length]);
                using (var pen = new Pen(c, 1 + spec * 5))
                    g.DrawLine(pen, p1, p2);
            }
        }

        private void RenderFlowerScope(Graphics g, Color[] pal)
        {
            int w = ClientSize.Width;
            int h = ClientSize.Height;
            float cx = w / 2f;
            float cy = h / 2f;
            for (int layer = 0; layer < 4; layer++)
            {
                int points = 220;
                PointF[] pts = new PointF[points];
                for (int i = 0; i < points; i++)
                {
                    float a = (float)(i * Math.PI * 2 / points);
                    float wave = waveform[(i * waveform.Length / points + layer * 37) % waveform.Length];
                    float spec = spectrum[(i * spectrum.Length / points + layer * 9) % spectrum.Length];
                    float petals = (float)Math.Sin(a * (3 + layer) + time * (0.8f + layer * 0.12f));
                    float r = Math.Min(w, h) * (0.17f + layer * 0.052f + spec * 0.18f + wave * 0.09f + petals * 0.035f);
                    pts[i] = new PointF(cx + (float)Math.Cos(a + time * 0.1f * layer) * r, cy + (float)Math.Sin(a + time * 0.1f * layer) * r);
                }
                using (var pen = new Pen(Color.FromArgb(95 + layer * 32, pal[layer % pal.Length]), 1.1f + analyzer.Beat * 1.5f))
                    g.DrawPolygon(pen, pts);
            }
        }

        private void RenderOrbitRibbons(Graphics g, Color[] pal)
        {
            int w = ClientSize.Width;
            int h = ClientSize.Height;
            float cx = w / 2f;
            float cy = h / 2f;
            float scale = Math.Min(w, h) * (0.18f + analyzer.Level * 0.08f);

            for (int ribbon = 0; ribbon < 5; ribbon++)
            {
                PointF[] pts = new PointF[170];
                float phase = time * (0.45f + ribbon * 0.05f) + ribbon * 0.9f;
                for (int i = 0; i < pts.Length; i++)
                {
                    float p = i / (float)(pts.Length - 1);
                    float a = (float)(p * Math.PI * 2.0 * (1.6 + ribbon * 0.16) + phase);
                    float spec = spectrum[(i * 3 + ribbon * 11) % spectrum.Length];
                    float r = scale * (0.85f + ribbon * 0.13f + spec * 0.58f);
                    float wobble = (float)Math.Sin(p * Math.PI * 12 + time * 2.2f + ribbon) * scale * 0.13f * analyzer.Mid;
                    pts[i] = new PointF(
                        cx + (float)Math.Cos(a) * (r + wobble),
                        cy + (float)Math.Sin(a * 0.72f + phase * 0.25f) * (r * 0.58f + wobble));
                }
                using (var pen = new Pen(Color.FromArgb(86 + ribbon * 24, pal[ribbon % pal.Length]), 1.6f + analyzer.Beat * 2.1f))
                    g.DrawLines(pen, pts);
            }
        }

        private void RenderOscilloscopeGrid(Graphics g, Color[] pal)
        {
            int w = ClientSize.Width;
            int h = ClientSize.Height;
            int step = Math.Max(42, Math.Min(w, h) / 13);
            using (var gridPen = new Pen(Color.FromArgb(34, pal[1 % pal.Length]), 1))
            {
                for (int x = 0; x < w; x += step) g.DrawLine(gridPen, x, 0, x, h);
                for (int y = 0; y < h; y += step) g.DrawLine(gridPen, 0, y, w, y);
            }

            for (int layer = 0; layer < 3; layer++)
            {
                PointF[] pts = new PointF[WaveDrawPoints];
                for (int i = 0; i < pts.Length; i++)
                {
                    int wi = i * (waveform.Length - 1) / (pts.Length - 1);
                    float x = i * w / (float)(pts.Length - 1);
                    float spec = spectrum[(i * spectrum.Length / pts.Length + layer * 13) % spectrum.Length];
                    float y = h * (0.5f + (layer - 1.5f) * 0.09f)
                        + waveform[wi] * h * (0.17f + analyzer.Bass * 0.10f)
                        + (float)Math.Sin(i * 0.06f + time * (1.5f + layer)) * spec * h * 0.04f;
                    pts[i] = new PointF(x, y);
                }
                using (var pen = new Pen(Color.FromArgb(170, pal[(layer + 1) % pal.Length]), 1.1f + analyzer.Beat * 1.25f))
                    g.DrawLines(pen, pts);
            }
        }

        private void RenderKaleidoscopeFans(Graphics g, Color[] pal)
        {
            int w = ClientSize.Width;
            int h = ClientSize.Height;
            float cx = w / 2f;
            float cy = h / 2f;
            int blades = 18;
            float radius = Math.Max(w, h) * 0.72f;

            for (int i = 0; i < blades; i++)
            {
                float a = (float)(i * Math.PI * 2 / blades + time * (0.18f + analyzer.Treble * 0.16f));
                float spec = spectrum[(i * spectrum.Length / blades) % spectrum.Length];
                float width = 0.055f + spec * 0.13f;
                PointF p1 = new PointF(cx, cy);
                PointF p2 = new PointF(cx + (float)Math.Cos(a - width) * radius, cy + (float)Math.Sin(a - width) * radius);
                PointF p3 = new PointF(cx + (float)Math.Cos(a + width) * radius, cy + (float)Math.Sin(a + width) * radius);
                Color c = Color.FromArgb(18 + (int)(120 * spec), Blend(pal[i % pal.Length], pal[(i + 2) % pal.Length], analyzer.Mid));
                using (var brush = new SolidBrush(c))
                    g.FillPolygon(brush, new [] { p1, p2, p3 });
                using (var pen = new Pen(Color.FromArgb(90 + (int)(100 * spec), pal[(i + 1) % pal.Length]), 1 + spec * 3))
                    g.DrawLine(pen, p1, p3);
            }
        }

        private void RenderSpectrumRain(Graphics g, Color[] pal)
        {
            int w = ClientSize.Width;
            int h = ClientSize.Height;
            int columns = 72;
            float colW = w / (float)columns;
            for (int i = 0; i < columns; i++)
            {
                float spec = spectrum[i * spectrum.Length / columns];
                float phase = (time * (70 + analyzer.Bass * 90) + i * 37) % (h + 160);
                float height = 40 + spec * h * 0.48f;
                float x = i * colW + colW * 0.12f;
                Color c = Blend(pal[i % pal.Length], pal[(i + 3) % pal.Length], spec);
                using (var brush = new LinearGradientBrush(new RectangleF(x, phase - height, colW * 0.76f, height), Color.FromArgb(0, c), Color.FromArgb(190, c), 90f))
                    g.FillRectangle(brush, x, phase - height, colW * 0.76f, height);
                using (var pen = new Pen(Color.FromArgb(70 + (int)(140 * spec), Color.White), 1))
                    g.DrawLine(pen, x, phase, x + colW * 0.76f, phase);
            }
        }

        private void RenderMagentaVortex(Graphics g, Color[] pal)
        {
            int w = ClientSize.Width;
            int h = ClientSize.Height;
            float cx = w / 2f;
            float cy = h / 2f;
            float maxR = Math.Max(w, h) * 0.68f;
            int arms = 13;
            int points = 82;

            for (int arm = 0; arm < arms; arm++)
            {
                PointF[] pts = new PointF[points];
                float armPhase = arm * (float)Math.PI * 2f / arms;
                for (int i = 0; i < points; i++)
                {
                    float t = i / (float)(points - 1);
                    float spec = spectrum[(i * 2 + arm * 5) % spectrum.Length];
                    float swirl = time * (0.72f + analyzer.Treble * 0.28f) + t * 8.4f + armPhase;
                    float r = maxR * t * (0.18f + 0.86f * t) + spec * 75f;
                    float squeeze = 0.62f + 0.16f * (float)Math.Sin(time + arm);
                    pts[i] = new PointF(cx + (float)Math.Cos(swirl) * r, cy + (float)Math.Sin(swirl) * r * squeeze);
                }
                Color c = Blend(pal[arm % pal.Length], Color.White, analyzer.Beat * 0.35f);
                using (var pen = new Pen(Color.FromArgb(54 + arm * 8, c), 1.1f + analyzer.Beat * 2.0f))
                    g.DrawLines(pen, pts);
            }
        }

        private void RenderRedPinwheel(Graphics g, Color[] pal)
        {
            int w = ClientSize.Width;
            int h = ClientSize.Height;
            float cx = w / 2f;
            float cy = h / 2f;
            int blades = 18;
            float radius = Math.Max(w, h) * 0.84f;
            float twist = time * (0.55f + analyzer.Bass * 0.25f);

            for (int i = 0; i < blades; i++)
            {
                float a = (float)(i * Math.PI * 2 / blades + twist);
                float spec = spectrum[(i * 5) % spectrum.Length];
                float width = 0.09f + spec * 0.12f;
                float inner = Math.Min(w, h) * (0.025f + analyzer.Beat * 0.035f);
                PointF p1 = new PointF(cx + (float)Math.Cos(a - width) * inner, cy + (float)Math.Sin(a - width) * inner);
                PointF p2 = new PointF(cx + (float)Math.Cos(a + width) * radius, cy + (float)Math.Sin(a + width) * radius);
                PointF p3 = new PointF(cx + (float)Math.Cos(a + width * 2.6f) * radius * 0.72f, cy + (float)Math.Sin(a + width * 2.6f) * radius * 0.72f);
                Color fill = i % 2 == 0 ? pal[0] : pal[1];
                using (var brush = new SolidBrush(Color.FromArgb(42 + (int)(76 * spec), fill)))
                    g.FillPolygon(brush, new [] { p1, p2, p3 });
                using (var pen = new Pen(Color.FromArgb(105 + (int)(95 * spec), pal[(i + 2) % pal.Length]), 1.0f + spec * 2.3f))
                    g.DrawLine(pen, p1, p2);
            }
        }

        private void RenderElectricWeb(Graphics g, Color[] pal)
        {
            int w = ClientSize.Width;
            int h = ClientSize.Height;
            float cx = w * (0.52f + 0.08f * (float)Math.Sin(time * 0.31f));
            float cy = h * (0.49f + 0.06f * (float)Math.Cos(time * 0.27f));
            int strands = 62;

            for (int s = 0; s < strands; s++)
            {
                int points = 18;
                PointF[] pts = new PointF[points];
                float a = (float)(s * Math.PI * 2 / strands + Math.Sin(time * 0.36 + s) * 0.25);
                float reach = Math.Max(w, h) * (0.18f + 0.55f * spectrum[(s * 3) % spectrum.Length]);
                for (int i = 0; i < points; i++)
                {
                    float t = i / (float)(points - 1);
                    float kink = (float)Math.Sin(t * 14f + time * 2.2f + s) * (18f + analyzer.Treble * 28f);
                    float r = reach * t + analyzer.Bass * 34f * (float)Math.Sin(t * Math.PI);
                    pts[i] = new PointF(
                        cx + (float)Math.Cos(a) * r + (float)Math.Cos(a + Math.PI / 2) * kink,
                        cy + (float)Math.Sin(a) * r + (float)Math.Sin(a + Math.PI / 2) * kink);
                }
                using (var pen = new Pen(Color.FromArgb(40 + (int)(125 * spectrum[s % spectrum.Length]), pal[s % pal.Length]), 1.0f + analyzer.Beat * 1.1f))
                    g.DrawLines(pen, pts);
            }
        }

        private void RenderRainbowShardBurst(Graphics g, Color[] pal)
        {
            int w = ClientSize.Width;
            int h = ClientSize.Height;
            float cx = w * (0.48f + 0.05f * (float)Math.Sin(time * 0.52f));
            float cy = h * (0.50f + 0.05f * (float)Math.Cos(time * 0.45f));
            int shards = 84;

            for (int i = 0; i < shards; i++)
            {
                float spec = spectrum[(i * 7) % spectrum.Length];
                float a = (float)(i * Math.PI * 2 / shards + time * (0.22f + analyzer.Treble * 0.18f));
                float start = Math.Min(w, h) * (0.025f + analyzer.Beat * 0.035f);
                float length = Math.Max(w, h) * (0.12f + spec * 0.52f);
                float width = 0.014f + spec * 0.035f;
                PointF p1 = new PointF(cx + (float)Math.Cos(a) * start, cy + (float)Math.Sin(a) * start);
                PointF p2 = new PointF(cx + (float)Math.Cos(a - width) * (start + length), cy + (float)Math.Sin(a - width) * (start + length));
                PointF p3 = new PointF(cx + (float)Math.Cos(a + width) * (start + length * 0.85f), cy + (float)Math.Sin(a + width) * (start + length * 0.85f));
                Color c = HsvToColor((i * 360f / shards + time * 28f) % 360f, 0.92f, 1f);
                c = Blend(c, pal[i % pal.Length], 0.32f);
                using (var brush = new SolidBrush(Color.FromArgb(22 + (int)(130 * spec), c)))
                    g.FillPolygon(brush, new [] { p1, p2, p3 });
            }
        }

        private void RenderBlueNebula(Graphics g, Color[] pal)
        {
            int w = ClientSize.Width;
            int h = ClientSize.Height;
            for (int i = 0; i < 58; i++)
            {
                float spec = spectrum[(i * 11) % spectrum.Length];
                float x = w * (0.5f + 0.45f * (float)Math.Sin(i * 1.7f + time * 0.24f));
                float y = h * (0.5f + 0.38f * (float)Math.Cos(i * 1.19f - time * 0.20f));
                float size = 45f + spec * 210f + analyzer.Bass * 52f;
                Color c = Blend(pal[i % pal.Length], Color.White, spec * 0.25f);
                using (var brush = new SolidBrush(Color.FromArgb(12 + (int)(52 * spec), c)))
                    g.FillEllipse(brush, x - size / 2f, y - size / 2f, size, size);
            }

            for (int bolt = 0; bolt < 12; bolt++)
            {
                int points = 16;
                PointF[] pts = new PointF[points];
                float yBase = h * (0.25f + bolt * 0.045f + 0.18f * (float)Math.Sin(time * 0.33f + bolt));
                for (int i = 0; i < points; i++)
                {
                    float x = i * w / (float)(points - 1);
                    float spec = spectrum[(i * 9 + bolt * 4) % spectrum.Length];
                    float y = yBase + (float)Math.Sin(i * 1.1f + time * 3.1f + bolt) * (18 + spec * 70);
                    pts[i] = new PointF(x, y);
                }
                using (var pen = new Pen(Color.FromArgb(50 + (int)(90 * analyzer.Treble), pal[(bolt + 1) % pal.Length]), 1.0f + analyzer.Beat * 1.6f))
                    g.DrawLines(pen, pts);
            }
        }

        private void RenderSmokeTunnel(Graphics g, Color[] pal)
        {
            int w = ClientSize.Width;
            int h = ClientSize.Height;
            float cx = w / 2f;
            float cy = h / 2f;
            for (int i = 0; i < 42; i++)
            {
                float t = i / 41f;
                float spec = spectrum[(i * 5) % spectrum.Length];
                float a = time * 0.34f + i * 0.58f;
                float x = cx + (float)Math.Cos(a) * Math.Max(w, h) * t * 0.34f;
                float y = cy + (float)Math.Sin(a * 0.82f) * Math.Min(w, h) * t * 0.25f;
                float size = Math.Min(w, h) * (0.05f + t * 0.18f + spec * 0.08f);
                Color c = Blend(pal[i % pal.Length], pal[(i + 2) % pal.Length], t);
                using (var brush = new SolidBrush(Color.FromArgb((int)(42 * (1f - t) + 18 * spec), c)))
                    g.FillEllipse(brush, x - size / 2f, y - size / 2f, size, size * (0.58f + t * 0.5f));
            }
        }

        private void AddSparkBurst(float x, float y, int count)
        {
            for (int i = 0; i < count; i++)
            {
                double a = random.NextDouble() * Math.PI * 2;
                float speed = 1.5f + (float)random.NextDouble() * 8f;
                sparks.Add(new Spark
                {
                    X = x,
                    Y = y,
                    Vx = (float)Math.Cos(a) * speed,
                    Vy = (float)Math.Sin(a) * speed,
                    Life = 0.75f + (float)random.NextDouble() * 0.9f,
                    Color = palettes[paletteIndex][random.Next(palettes[paletteIndex].Length)]
                });
            }
        }

        private void RenderSparks(Graphics g)
        {
            for (int i = sparks.Count - 1; i >= 0; i--)
            {
                var s = sparks[i];
                s.X += s.Vx * (1 + analyzer.Beat);
                s.Y += s.Vy * (1 + analyzer.Beat);
                s.Vx *= 0.986f;
                s.Vy *= 0.986f;
                s.Life -= 0.018f;
                if (s.Life <= 0)
                {
                    sparks.RemoveAt(i);
                    continue;
                }
                sparks[i] = s;
                using (var brush = new SolidBrush(Color.FromArgb((int)(220 * Math.Min(1, s.Life)), s.Color)))
                    g.FillEllipse(brush, s.X - 2, s.Y - 2, 4 + analyzer.Beat * 5, 4 + analyzer.Beat * 5);
            }
            if (sparks.Count > 420)
                sparks.RemoveRange(0, sparks.Count - 420);
        }

        private void RenderOverlay(Graphics g)
        {
            string line = analyzer.DemoMode
                ? analyzer.Status + "  |  +/- quality, Space randomizes, M form, C color, F fullscreen, Esc quit"
                : "Device audio visualizer  |  " + measuredFps.ToString("0") + " FPS  |  " + (renderScale * 100f).ToString("0") + "% quality  |  normalized bass  |  +/- quality, Space randomizes, M form, C color, F fullscreen, Esc quit";
            using (var font = new Font("Segoe UI", 10, FontStyle.Regular))
            using (var brush = new SolidBrush(Color.FromArgb(150, 235, 245, 255)))
                g.DrawString(line, font, brush, 18, 16);
        }

        private Color[] BuildPalette(int fromIndex, int toIndex, float amount)
        {
            amount = Clamp01(amount);
            Color[] from = palettes[Math.Max(0, Math.Min(palettes.Length - 1, fromIndex))];
            Color[] to = palettes[Math.Max(0, Math.Min(palettes.Length - 1, toIndex))];
            int count = Math.Min(from.Length, to.Length);
            Color[] result = new Color[count];
            for (int i = 0; i < count; i++)
                result[i] = Blend(from[i], to[i], amount);
            return result;
        }

        private void DrawTransitionVeil(Graphics g, float amount, Color[] pal)
        {
            float wave = (float)Math.Sin(amount * Math.PI);
            if (wave <= 0.001f) return;
            int w = ClientSize.Width;
            int h = ClientSize.Height;
            float sweepX = -w * 0.2f + w * 1.4f * amount;
            using (var pen = new Pen(Color.FromArgb((int)(130 * wave), pal[0]), 3 + wave * 18))
                g.DrawLine(pen, sweepX, 0, sweepX - w * 0.28f, h);
            using (var brush = new SolidBrush(Color.FromArgb((int)(24 * wave), pal[2 % pal.Length])))
                g.FillRectangle(brush, 0, 0, w, h);
        }

        private void RenderTransitionBridge(Graphics g, float amount, Color[] pal)
        {
            float wave = (float)Math.Sin(amount * Math.PI);
            if (wave <= 0.001f) return;

            int w = ClientSize.Width;
            int h = ClientSize.Height;
            float cx = w / 2f;
            float cy = h / 2f;
            float maxR = Math.Max(w, h) * (0.18f + 0.45f * amount + analyzer.Bass * 0.12f);
            int spokes = 32;
            for (int i = 0; i < spokes; i++)
            {
                float spec = spectrum[(i * spectrum.Length / spokes) % spectrum.Length];
                float a = (float)(i * Math.PI * 2 / spokes + time * (0.6f + analyzer.Treble * 0.4f));
                float inner = maxR * (0.14f + amount * 0.22f);
                float outer = maxR * (0.45f + spec * 0.55f);
                Color c = Color.FromArgb((int)(150 * wave * (0.35f + spec * 0.65f)), pal[i % pal.Length]);
                using (var pen = new Pen(c, 1.4f + wave * 4.0f))
                {
                    g.DrawLine(
                        pen,
                        cx + (float)Math.Cos(a) * inner,
                        cy + (float)Math.Sin(a) * inner,
                        cx + (float)Math.Cos(a + wave * 0.18f) * outer,
                        cy + (float)Math.Sin(a + wave * 0.18f) * outer);
                }
            }
        }

        private static float BassAwareHeight(int band, float value)
        {
            float shaped = (float)Math.Pow(Clamp01(value), 1.02);
            if (band < 18)
            {
                float lowEndBlend = band / 18f;
                float ceiling = 0.62f + lowEndBlend * 0.22f;
                shaped = ceiling * (1f - (float)Math.Exp(-shaped * 1.85f));
            }
            return Clamp01(shaped);
        }

        private static float Ease(float value)
        {
            value = Clamp01(value);
            return value * value * (3f - 2f * value);
        }

        private static float Clamp01(float value)
        {
            if (value < 0) return 0;
            if (value > 1) return 1;
            return value;
        }

        private static Color Blend(Color a, Color b, float amount)
        {
            amount = Math.Max(0, Math.Min(1, amount));
            return Color.FromArgb(
                (int)(a.R + (b.R - a.R) * amount),
                (int)(a.G + (b.G - a.G) * amount),
                (int)(a.B + (b.B - a.B) * amount));
        }

        private static Color HsvToColor(float hue, float saturation, float value)
        {
            hue = hue % 360f;
            if (hue < 0) hue += 360f;
            saturation = Clamp01(saturation);
            value = Clamp01(value);

            float c = value * saturation;
            float x = c * (1f - Math.Abs((hue / 60f) % 2f - 1f));
            float m = value - c;
            float r = 0, g = 0, b = 0;

            if (hue < 60) { r = c; g = x; }
            else if (hue < 120) { r = x; g = c; }
            else if (hue < 180) { g = c; b = x; }
            else if (hue < 240) { g = x; b = c; }
            else if (hue < 300) { r = x; b = c; }
            else { r = c; b = x; }

            return Color.FromArgb(
                (int)((r + m) * 255f),
                (int)((g + m) * 255f),
                (int)((b + m) * 255f));
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (timer != null) timer.Dispose();
                if (canvas != null) canvas.Dispose();
            }
            base.Dispose(disposing);
        }

        private struct Spark
        {
            public float X;
            public float Y;
            public float Vx;
            public float Vy;
            public float Life;
            public Color Color;
        }
    }

    public sealed class WasapiLoopbackCapture : IDisposable
    {
        private const int AUDCLNT_STREAMFLAGS_LOOPBACK = 0x00020000;
        private const int CLSCTX_ALL = 23;
        private static readonly Guid IAudioClientGuid = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
        private static readonly Guid IAudioCaptureClientGuid = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
        private readonly IAudioClient audioClient;
        private readonly IAudioCaptureClient captureClient;
        private readonly IntPtr mixFormatPtr;
        private readonly int channels;
        private readonly int bitsPerSample;
        private readonly int blockAlign;
        private readonly bool isFloat;

        public WasapiLoopbackCapture()
        {
            var enumerator = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
            IMMDevice device;
            Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, ERole.eMultimedia, out device));

            object clientObject;
            Guid audioClientId = IAudioClientGuid;
            Marshal.ThrowExceptionForHR(device.Activate(ref audioClientId, CLSCTX_ALL, IntPtr.Zero, out clientObject));
            audioClient = (IAudioClient)clientObject;

            Marshal.ThrowExceptionForHR(audioClient.GetMixFormat(out mixFormatPtr));
            var format = (WaveFormatEx)Marshal.PtrToStructure(mixFormatPtr, typeof(WaveFormatEx));
            channels = format.nChannels;
            bitsPerSample = format.wBitsPerSample;
            blockAlign = format.nBlockAlign;
            isFloat = format.wFormatTag == 3;

            if (format.wFormatTag == 65534)
            {
                var extensible = (WaveFormatExtensible)Marshal.PtrToStructure(mixFormatPtr, typeof(WaveFormatExtensible));
                isFloat = extensible.SubFormat == new Guid("00000003-0000-0010-8000-00aa00389b71");
            }

            Marshal.ThrowExceptionForHR(audioClient.Initialize(AudioClientShareMode.Shared, AUDCLNT_STREAMFLAGS_LOOPBACK, 10000000, 0, mixFormatPtr, Guid.Empty));

            object captureObject;
            Guid captureId = IAudioCaptureClientGuid;
            Marshal.ThrowExceptionForHR(audioClient.GetService(ref captureId, out captureObject));
            captureClient = (IAudioCaptureClient)captureObject;
            Marshal.ThrowExceptionForHR(audioClient.Start());
        }

        public int Read(float[] buffer, int maxSamples)
        {
            int written = 0;
            int packetFrames;
            Marshal.ThrowExceptionForHR(captureClient.GetNextPacketSize(out packetFrames));
            while (packetFrames > 0 && written < maxSamples)
            {
                IntPtr data;
                int frames;
                AudioClientBufferFlags flags;
                long devicePosition;
                long qpcPosition;
                Marshal.ThrowExceptionForHR(captureClient.GetBuffer(out data, out frames, out flags, out devicePosition, out qpcPosition));

                int samplesToWrite = Math.Min(frames, maxSamples - written);
                if ((flags & AudioClientBufferFlags.Silent) != 0)
                {
                    for (int i = 0; i < samplesToWrite; i++) buffer[written++] = 0;
                }
                else
                {
                    for (int frame = 0; frame < samplesToWrite; frame++)
                    {
                        float sum = 0;
                        for (int ch = 0; ch < channels; ch++)
                            sum += ReadSample(data, frame, ch);
                        buffer[written++] = sum / Math.Max(1, channels);
                    }
                }

                Marshal.ThrowExceptionForHR(captureClient.ReleaseBuffer(frames));
                Marshal.ThrowExceptionForHR(captureClient.GetNextPacketSize(out packetFrames));
            }
            return written;
        }

        private float ReadSample(IntPtr data, int frame, int channel)
        {
            int offset = frame * blockAlign + channel * (bitsPerSample / 8);
            if (isFloat && bitsPerSample == 32)
            {
                byte[] bytes = new byte[4];
                Marshal.Copy(IntPtr.Add(data, offset), bytes, 0, 4);
                return BitConverter.ToSingle(bytes, 0);
            }
            if (bitsPerSample == 16)
                return Marshal.ReadInt16(data, offset) / 32768f;
            if (bitsPerSample == 24)
            {
                int b0 = Marshal.ReadByte(data, offset);
                int b1 = Marshal.ReadByte(data, offset + 1);
                int b2 = Marshal.ReadByte(data, offset + 2);
                int sample = b0 | (b1 << 8) | (b2 << 16);
                if ((sample & 0x800000) != 0) sample |= unchecked((int)0xff000000);
                return sample / 8388608f;
            }
            if (bitsPerSample == 32)
                return Marshal.ReadInt32(data, offset) / 2147483648f;
            return 0;
        }

        public void Dispose()
        {
            try { audioClient.Stop(); } catch { }
            if (mixFormatPtr != IntPtr.Zero) Marshal.FreeCoTaskMem(mixFormatPtr);
            if (captureClient != null) Marshal.ReleaseComObject(captureClient);
            if (audioClient != null) Marshal.ReleaseComObject(audioClient);
        }
    }

    [ComImport]
    [Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    internal class MMDeviceEnumeratorComObject { }

    internal enum EDataFlow { eRender, eCapture, eAll }
    internal enum ERole { eConsole, eMultimedia, eCommunications }
    internal enum AudioClientShareMode { Shared, Exclusive }

    [Flags]
    internal enum AudioClientBufferFlags
    {
        None = 0,
        DataDiscontinuity = 1,
        Silent = 2,
        TimestampError = 4
    }

    [ComImport]
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(EDataFlow dataFlow, int dwStateMask, out IntPtr ppDevices);
        int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice ppEndpoint);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string pwstrId, out IMMDevice ppDevice);
        int RegisterEndpointNotificationCallback(IntPtr pClient);
        int UnregisterEndpointNotificationCallback(IntPtr pClient);
    }

    [ComImport]
    [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.Interface)] out object ppInterface);
        int OpenPropertyStore(int stgmAccess, out IntPtr ppProperties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
        int GetState(out int pdwState);
    }

    [ComImport]
    [Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioClient
    {
        int Initialize(AudioClientShareMode shareMode, int streamFlags, long hnsBufferDuration, long hnsPeriodicity, IntPtr pFormat, Guid audioSessionGuid);
        int GetBufferSize(out int pNumBufferFrames);
        int GetStreamLatency(out long phnsLatency);
        int GetCurrentPadding(out int pNumPaddingFrames);
        int IsFormatSupported(AudioClientShareMode shareMode, IntPtr pFormat, out IntPtr ppClosestMatch);
        int GetMixFormat(out IntPtr ppDeviceFormat);
        int GetDevicePeriod(out long phnsDefaultDevicePeriod, out long phnsMinimumDevicePeriod);
        int Start();
        int Stop();
        int Reset();
        int SetEventHandle(IntPtr eventHandle);
        int GetService(ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object ppv);
    }

    [ComImport]
    [Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioCaptureClient
    {
        int GetBuffer(out IntPtr ppData, out int pNumFramesToRead, out AudioClientBufferFlags pdwFlags, out long pu64DevicePosition, out long pu64QPCPosition);
        int ReleaseBuffer(int numFramesRead);
        int GetNextPacketSize(out int pNumFramesInNextPacket);
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    internal struct WaveFormatEx
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    internal struct WaveFormatExtensible
    {
        public WaveFormatEx Format;
        public ushort wValidBitsPerSample;
        public uint dwChannelMask;
        public Guid SubFormat;
    }
}
'@

Add-Type -TypeDefinition $source -ReferencedAssemblies @(
    "System.Windows.Forms.dll",
    "System.Drawing.dll",
    "System.Numerics.dll"
)

if ($AudioTest) {
    [NostalgicVisualizer.AudioProbe]::Test()
}
elseif (-not $CompileOnly) {
    [NostalgicVisualizer.Entry]::Run($Screen, $RenderScale)
}
