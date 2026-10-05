using System.Numerics;
using System.Collections.Concurrent;
using System.Diagnostics;

namespace WindowsMusicVisualizerGpu;

public sealed class AudioAnalyzer : IDisposable
{
    private const int FftSize = 2048;
    private const int WaveformSize = 768;
    private readonly object sync = new();
    private readonly float[] spectrum = new float[96];
    private readonly float[] waveform = new float[WaveformSize];
    private readonly float[] fftBuffer = new float[FftSize];
    private readonly float[] window = new float[FftSize];
    private readonly float[] bandReferences = new float[96];
    private readonly float[] previousSpectrum = new float[96];
    private readonly float[] onsetHistory = new float[768];
    private Thread? thread;
    private volatile bool running;
    private float level;
    private float bass;
    private float mid;
    private float treble;
    private float vocal;
    private float air;
    private float beat;
    private float bassKick;
    private float midPunch;
    private float trebleSpark;
    private float spectralFlux;
    private float brightness;
    private float onset;
    private float onsetAverage = 0.08f;
    private float tempoBpm = 120f;
    private float tempoConfidence;
    private float beatPhase;
    private float beatPulse;
    private int sampleRate = 48000;
    private int onsetHistoryIndex;
    private int onsetHistoryCount;
    private double analysisClock;
    private double lastTempoAnalysis;
    private double lastBeatAnchor;
    private float inputReference = 0.035f;
    private float spectrumReference = 0.32f;
    private float reactivityReference = 0.36f;
    private float reactivityGain = 1f;
    private float beatAverage = 0.15f;
    private float displayGain = 18f;
    private readonly CameraAccentDetector cameraDetector = new();
    private readonly ConcurrentQueue<(CameraAccent Accent, long Timestamp)> cameraAccents = new();
    private long lastCameraAnalysis;
    private AudioSource selectedSource = AudioSource.SystemDefault;
    private volatile string sourceStatus = "Connecting";
    private readonly StereoAnalysis stereo = new();
    private readonly float[] stereoBalance = new float[16];
    public AudioSource SelectedSource => Volatile.Read(ref selectedSource);
    public string SourceStatus => sourceStatus;
    public void SelectSource(AudioSource source) => Volatile.Write(ref selectedSource, source);
    public Vector4 StereoState { get { lock (sync) { var s = stereo.State; return new(Math.Clamp(s.X * displayGain, 0, 1), Math.Clamp(s.Y * displayGain, 0, 1), s.Z, s.W); } } }
    public void StereoSnapshot(float[] output) { lock (sync) Array.Copy(stereoBalance, output, Math.Min(output.Length, stereoBalance.Length)); }
    internal void AnalyzeStereoTest(float[] left, float[] right) => AnalyzeBlock(left, right);

    internal void AnalyzePortfolioFrame(float time)
    {
        var left = new float[FftSize];
        var right = new float[FftSize];
        for (int i = 0; i < FftSize; i++)
        {
            float t = time + i / 48000f;
            float kick = MathF.Exp(-(t * 2 % 1) * 16);
            float percussion = MathF.Exp(-(t * 4 % 1) * 22);
            float phrase = 0.35f + 0.65f * MathF.Pow(0.5f + 0.5f * MathF.Sin(t * 0.8f), 2);
            for (int voice = 0; voice < 12; voice++)
            {
                float frequency = 55 * MathF.Pow(1.48f, voice);
                float envelope = voice < 2 ? kick : voice > 8 ? percussion : phrase * (0.5f + 0.5f * MathF.Sin(t * (1 + voice * 0.18f) + voice));
                float value = MathF.Sin(t * frequency * MathF.Tau) * envelope * (voice < 2 ? 0.09f : 0.025f);
                float pan = 0.5f + 0.35f * MathF.Sin(t * 0.55f + voice);
                left[i] += value * MathF.Sqrt(1 - pan);
                right[i] += value * MathF.Sqrt(pan);
            }
        }
        sourceStatus = "Generated portfolio demo";
        lock (sync) stereo.Process(left, right, 48000);
        AnalyzeBlock(left, right);
        for (int i = 0; i < left.Length; i++) left[i] = (left[i] + right[i]) * 0.5f;
        PushWaveform(left, left.Length);
    }

    internal bool TryTakeCameraAccent(out CameraAccent accent)
    {
        while (cameraAccents.TryDequeue(out var item))
        {
            if (Stopwatch.GetElapsedTime(item.Timestamp).TotalSeconds > 0.18) continue;
            accent = item.Accent;
            return true;
        }
        accent = default;
        return false;
    }

    public AudioAnalyzer()
    {
        for (int i = 0; i < FftSize; i++)
            window[i] = 0.5f - 0.5f * MathF.Cos((2.0f * MathF.PI * i) / (FftSize - 1));
    }

    public float Level => level;
    public float Bass => bass;
    public float Mid => mid;
    public float Treble => treble;
    public float Vocal => vocal;
    public float Air => air;
    public float Beat => beat;
    public float BassKick => bassKick;
    public float MidPunch => midPunch;
    public float TrebleSpark => trebleSpark;
    public float SpectralFlux => spectralFlux;
    public float Brightness => brightness;
    public float Onset => onset;
    public float TempoBpm => tempoBpm;
    public float TempoConfidence => tempoConfidence;
    public float BeatPhase => beatPhase;
    public float BeatPulse => beatPulse;

    public void Start()
    {
        if (running) return;
        running = true;
        thread = new Thread(CaptureLoop) { IsBackground = true, Name = "WASAPI loopback capture" };
        thread.Start();
    }

    internal void StartTestSignal(bool stereoTest = false)
    {
        sourceStatus = "Diagnostic audio";
        running = true;
        thread = new Thread(() =>
        {
            var samples = new float[FftSize];
            var right = new float[FftSize];
            long sampleOffset = 0;
            while (running)
            {
                for (int i = 0; i < samples.Length; i++)
                {
                    float t = (sampleOffset + i) / 48000f;
                    float kick = MathF.Exp(-(t * 2f % 1f) * 12f);
                    samples[i] = 0.16f * kick * MathF.Sin(t * 60f * 2f * MathF.PI)
                        + 0.06f * (0.5f + 0.5f * MathF.Sin(t * 4f)) * MathF.Sin(t * 440f * 2f * MathF.PI)
                        + 0.025f * MathF.Exp(-(t * 4f % 1f) * 16f) * MathF.Sin(t * 3400f * 2f * MathF.PI);
                    right[i] = stereoTest ? samples[i] * (0.5f + 0.5f * MathF.Sin(t * 1.7f)) : samples[i];
                }
                lock (sync) stereo.Process(samples, right, 48000);
                AnalyzeBlock(samples, right);
                PushWaveform(samples, FftSize / 2);
                sampleOffset += FftSize / 2;
                Thread.Sleep(21);
            }
        }) { IsBackground = true, Name = "Diagnostic audio" };
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
        while (running)
        {
            AudioSource source = SelectedSource;
            try
            {
            ResetSourceAnalysis();
            using var process = source.ProcessName == null ? null : source.FindProcess();
            if (source.ProcessName != null && process == null) throw new InvalidOperationException("Waiting for app to start");
            sourceStatus = "Connecting";
            using var capture = new WasapiLoopbackCapture(source, process?.Id ?? 0);
            sourceStatus = "Stereo";
            sampleRate = Math.Max(8000, capture.SampleRate);
            var collected = new List<float>(FftSize * 2);
            var collectedRight = new List<float>(FftSize * 2);
            var scratch = new float[4096];
            var right = new float[4096];
            var mono = new float[4096];
            var rightBlock = new float[FftSize];
            long lastData = Stopwatch.GetTimestamp();
            long lastDeviceCheck = lastData;
            while (running && ReferenceEquals(source, SelectedSource))
            {
                if (process?.HasExited == true) throw new InvalidOperationException("Waiting for app to restart");
                if (source.ProcessName == null && source.DeviceId == null && Stopwatch.GetElapsedTime(lastDeviceCheck).TotalSeconds >= 1)
                {
                    lastDeviceCheck = Stopwatch.GetTimestamp();
                    if (WasapiLoopbackCapture.DefaultEndpointId() != capture.EndpointId) break;
                }
                int count = capture.Read(scratch, right);
                if (count == 0)
                {
                    if (Stopwatch.GetElapsedTime(lastData).TotalSeconds > 0.08) { Decay(); sourceStatus = "Waiting for audio"; }
                    Thread.Sleep(8);
                    continue;
                }
                lastData = Stopwatch.GetTimestamp();
                lock (sync) stereo.Process(scratch.AsSpan(0, count), right.AsSpan(0, count), sampleRate);
                sourceStatus = stereo.State.X + stereo.State.Y > 0.0001f ? "Stereo" : "Waiting for audio";
                for (int i = 0; i < count; i++)
                {
                    collected.Add(scratch[i]);
                    collectedRight.Add(right[i]);
                    mono[i] = stereo.Correlation < -0.5f ? (scratch[i] - right[i]) * 0.5f : (scratch[i] + right[i]) * 0.5f;
                }
                PushWaveform(mono, count);

                while (collected.Count >= FftSize)
                {
                    for (int i = 0; i < FftSize; i++)
                    { fftBuffer[i] = collected[i]; rightBlock[i] = collectedRight[i]; }
                    collected.RemoveRange(0, FftSize / 2);
                    collectedRight.RemoveRange(0, FftSize / 2);
                    AnalyzeBlock(fftBuffer, rightBlock);
                }
            }
            }
            catch (Exception ex)
            {
                sourceStatus = ex.GetBaseException().Message;
                // Never substitute another app or simulated music when isolation fails.
                for (int i = 0; i < 100 && running && ReferenceEquals(source, SelectedSource); i++) { Decay(); Thread.Sleep(10); }
            }
        }
    }

    private void ResetSourceAnalysis()
    {
        lock (sync) { Array.Clear(spectrum); Array.Clear(waveform); Array.Clear(stereoBalance); stereo.Reset(); }
        Array.Clear(bandReferences); Array.Clear(previousSpectrum); Array.Clear(onsetHistory);
        level = bass = mid = treble = vocal = air = beat = bassKick = midPunch = trebleSpark = spectralFlux = onset = beatPulse = brightness = 0;
        tempoConfidence = beatPhase = 0; tempoBpm = 120;
        onsetHistoryIndex = onsetHistoryCount = 0;
        analysisClock = lastTempoAnalysis = lastBeatAnchor = 0;
        inputReference = 0.035f; spectrumReference = 0.32f; reactivityReference = 0.36f;
        reactivityGain = 1; beatAverage = 0.15f; onsetAverage = 0.08f; displayGain = 18;
        cameraDetector.ResetAfterGap(); cameraAccents.Clear(); lastCameraAnalysis = 0;
    }

    private void DemoLoop()
    {
        var started = Environment.TickCount64;
        while (running)
        {
            float t = (Environment.TickCount64 - started) / 1000f;
            lock (sync)
            {
                for (int i = 0; i < waveform.Length; i++)
                {
                    float x = i / (float)waveform.Length;
                    waveform[i] = MathF.Sin((x * 8 + t * 1.7f) * MathF.PI) * 0.45f + MathF.Sin((x * 31 - t * 3.4f) * MathF.PI) * 0.12f;
                }

                for (int i = 0; i < spectrum.Length; i++)
                {
                    float x = i / (float)spectrum.Length;
                    spectrum[i] = Clamp01(MathF.Pow(MathF.Sin(x * MathF.PI), 1.5f) * (0.4f + 0.6f * MathF.Sin(t * 2.1f)));
                }
            }

            level = 0.55f;
            bass = 0.55f + 0.35f * MathF.Sin(t * 2.1f);
            mid = 0.55f + 0.25f * MathF.Sin(t * 1.3f);
            treble = 0.45f + 0.25f * MathF.Sin(t * 3.7f);
            vocal = 0.50f + 0.24f * MathF.Sin(t * 1.9f);
            air = 0.38f + 0.22f * MathF.Sin(t * 4.3f);
            beat = Math.Max(0, MathF.Sin(t * 2.1f));
            tempoBpm = 126f;
            tempoConfidence = 0.85f;
            beatPhase = Wrap01(t * tempoBpm / 60f);
            beatPulse = MathF.Pow(Math.Max(0, 1f - beatPhase * 5f), 2f);
            onset = beatPulse;
            Thread.Sleep(16);
        }
    }

    private void PushWaveform(float[] samples, int count)
    {
        lock (sync)
        {
            int copy = Math.Min(count, waveform.Length);
            Array.Copy(waveform, copy, waveform, 0, waveform.Length - copy);
            float waveformGain = MathF.Sqrt(reactivityGain);
            for (int i = 0; i < copy; i++)
                waveform[waveform.Length - copy + i] = SoftClip(samples[count - copy + i] * displayGain * waveformGain);
        }
    }

    private void AnalyzeBlock(float[] samples, float[]? rightSamples = null)
    {
        rightSamples ??= samples;
        var accentSamples = new float[FftSize];
        double cross = 0;
        for (int i = 0; i < FftSize; i++) cross += samples[i] * rightSamples[i];
        for (int i = 0; i < FftSize; i++)
            accentSamples[i] = (samples[i] + (cross < 0 ? -rightSamples[i] : rightSamples[i])) * 0.5f;
        long now = Stopwatch.GetTimestamp();
        if (lastCameraAnalysis != 0 && Stopwatch.GetElapsedTime(lastCameraAnalysis, now).TotalSeconds > 0.15)
            cameraDetector.ResetAfterGap();
        lastCameraAnalysis = now;
        CameraAccent? cameraAccent = cameraDetector.Process(accentSamples, sampleRate);
        if (cameraAccent.HasValue)
        {
            cameraAccents.Enqueue((cameraAccent.Value, now));
            while (cameraAccents.Count > 16) cameraAccents.TryDequeue(out _);
        }
        var bins = new Complex[FftSize];
        var rightBins = new Complex[FftSize];
        float rms = 0;
        float peak = 0;
        for (int i = 0; i < FftSize; i++)
        {
            float raw = samples[i];
            float abs = Math.Max(Math.Abs(raw), Math.Abs(rightSamples[i]));
            if (abs > peak) peak = abs;
            rms += (raw * raw + rightSamples[i] * rightSamples[i]) * 0.5f;
        }
        rms = MathF.Sqrt(rms / FftSize);

        float targetReference = Math.Max(0.0018f, Math.Max(peak * 0.72f, rms * 2.8f));
        float referenceSpeed = targetReference > inputReference ? 0.16f : 0.012f;
        inputReference = Smooth(inputReference, targetReference, referenceSpeed);
        displayGain = Clamp(0.78f / inputReference, 1.0f, 95f);

        float normalizedRms = 0;
        for (int i = 0; i < FftSize; i++)
        {
            float normalized = SoftClip(samples[i] * displayGain);
            bins[i] = new Complex(normalized * window[i], 0);
            float normalizedRight = SoftClip(rightSamples[i] * displayGain);
            rightBins[i] = new Complex(normalizedRight * window[i], 0);
            normalizedRms += (normalized * normalized + normalizedRight * normalizedRight) * 0.5f;
        }
        Fft(bins);
        Fft(rightBins);
        lock (sync)
        {
            for (int band = 0; band < stereoBalance.Length; band++)
            {
                // Match the quadratic frequency layout of the main spectrum/motion bands.
                int a = Math.Max(1, (int)(Math.Pow(band / 16.0, 2) * (FftSize / 2 - 1)));
                int b = Math.Min(FftSize / 2, Math.Max(a + 1, (int)(Math.Pow((band + 1) / 16.0, 2) * (FftSize / 2 - 1))));
                double l = 0, r = 0;
                for (int j = a; j < b; j++) { l += bins[j].Magnitude; r += rightBins[j].Magnitude; }
                float pan = l + r < 0.01 ? 0 : (float)((r - l) / (r + l));
                stereoBalance[band] = Smooth(stereoBalance[band], pan, 0.25f);
            }
        }
        normalizedRms = MathF.Sqrt(normalizedRms / FftSize);

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
                total += Math.Sqrt((bins[j].Magnitude * bins[j].Magnitude + rightBins[j].Magnitude * rightBins[j].Magnitude) * 0.5);
            double mag = total / Math.Max(1, b - a);
            next[i] = MathF.Log10(1 + (float)mag * 7.5f);
            if (next[i] > bandPeak) bandPeak = next[i];
        }

        float targetSpectrum = Math.Max(0.08f, bandPeak * 0.82f);
        float spectrumSpeed = targetSpectrum > spectrumReference ? 0.20f : 0.018f;
        spectrumReference = Smooth(spectrumReference, targetSpectrum, spectrumSpeed);
        for (int i = 0; i < next.Length; i++)
        {
            float trim = i < 18 ? 0.58f + i * 0.018f : 1.0f;
            float refTarget = Math.Max(0.055f, next[i] * (i < 18 ? 1.28f : 1.0f));
            float refSpeed = refTarget > bandReferences[i] ? 0.28f : 0.018f;
            bandReferences[i] = Smooth(bandReferences[i] <= 0 ? refTarget : bandReferences[i], refTarget, refSpeed);
            float adaptiveReference = bandReferences[i] * 0.58f + spectrumReference * 0.42f;
            float normalizedBand = next[i] / Math.Max(0.055f, adaptiveReference * 1.12f);
            next[i] = Clamp01(MathF.Pow(1f - MathF.Exp(-normalizedBand * 1.12f), 0.82f) * trim);
        }

        // A light spectral blur keeps line-based modes fluid without hiding transients.
        float[] rawBands = (float[])next.Clone();
        for (int i = 0; i < next.Length; i++)
        {
            float left = rawBands[Math.Max(0, i - 1)];
            float right = rawBands[Math.Min(rawBands.Length - 1, i + 1)];
            next[i] = rawBands[i] * 0.58f + (left + right) * 0.21f;
        }

        float rawBass = BassLimit(Average(next, 1, 14));
        float rawMid = Average(next, 15, 48);
        float rawActivity = Clamp01(normalizedRms * 0.72f + rawBass * 0.20f + rawMid * 0.08f);
        float reactivityReferenceSpeed = analysisClock < 3.0
            ? 0.08f
            : rawActivity > reactivityReference ? 0.018f : 0.004f;
        reactivityReference = Smooth(reactivityReference, Math.Max(0.08f, rawActivity), reactivityReferenceSpeed);
        float targetReactivityGain = Clamp(0.46f / Math.Max(0.10f, reactivityReference), 0.72f, 2.40f);
        float gainSpeed = targetReactivityGain < reactivityGain ? 0.075f : 0.022f;
        reactivityGain = Smooth(reactivityGain, targetReactivityGain, gainSpeed);

        normalizedRms = Clamp01(normalizedRms * reactivityGain);
        for (int i = 0; i < next.Length; i++)
            next[i] = Clamp01(next[i] * reactivityGain);

        float newBass = BassLimit(Average(next, 1, 14));
        float newMid = Average(next, 15, 48);
        float newTreble = Average(next, 49, next.Length - 1);
        float newVocal = Average(next, 25, 61);
        float newAir = Average(next, 62, next.Length - 1);
        float fluxTotal = 0;
        float centroidTotal = 0;
        float centroidWeight = 0;
        for (int i = 0; i < next.Length; i++)
        {
            fluxTotal += Math.Max(0, next[i] - previousSpectrum[i]);
            centroidTotal += next[i] * i;
            centroidWeight += next[i];
            previousSpectrum[i] = next[i];
        }
        float nextFlux = Clamp01(fluxTotal / next.Length * 5.5f);
        float nextBrightness = centroidWeight <= 0.0001f ? 0 : Clamp01(centroidTotal / centroidWeight / (next.Length - 1));
        float energy = Clamp01(normalizedRms * 1.05f + newBass * 0.28f + newMid * 0.18f);
        beatAverage = Smooth(beatAverage, energy, energy > beatAverage ? 0.05f : 0.008f);
        float newBeat = Clamp01((energy - beatAverage) * 3.3f + Math.Max(0, newBass - bass) * 1.7f);
        float bassRise = Math.Max(0, newBass - bass);
        float midRise = Math.Max(0, newMid - mid);
        float trebleRise = Math.Max(0, newTreble - treble);
        float onsetEnergy = Clamp01(
            bassRise * 3.8f
            + midRise * 2.3f
            + trebleRise * 0.7f
            + nextFlux * 0.95f
            + Math.Max(0, energy - beatAverage) * 1.6f);
        UpdateRhythm(onsetEnergy);

        lock (sync)
        {
            for (int i = 0; i < spectrum.Length; i++)
            {
                float speed = next[i] > spectrum[i] ? 0.52f : 0.15f;
                spectrum[i] = Smooth(spectrum[i], next[i], speed);
            }
        }

        level = Smooth(level, energy, 0.22f);
        bass = Smooth(bass, newBass, 0.25f);
        mid = Smooth(mid, newMid, 0.22f);
        treble = Smooth(treble, newTreble, 0.20f);
        vocal = Smooth(vocal, newVocal, 0.18f);
        air = Smooth(air, newAir, 0.17f);
        beat = Math.Max(newBeat, beat * 0.82f);
        bassKick = Math.Max(Clamp01(bassRise * 4.8f + newBeat * 0.45f), bassKick * 0.78f);
        midPunch = Math.Max(Clamp01(midRise * 4.2f + nextFlux * 0.45f), midPunch * 0.80f);
        trebleSpark = Math.Max(Clamp01(trebleRise * 5.8f + nextFlux * 0.55f), trebleSpark * 0.74f);
        spectralFlux = Smooth(spectralFlux, nextFlux, nextFlux > spectralFlux ? 0.45f : 0.10f);
        brightness = Smooth(brightness, nextBrightness, 0.20f);
    }

    private void Decay()
    {
        lock (sync)
        {
            stereo.Decay();
            for (int i = 0; i < stereoBalance.Length; i++) stereoBalance[i] *= 0.88f;
            for (int i = 0; i < spectrum.Length; i++)
                spectrum[i] *= 0.84f;
            for (int i = 0; i < waveform.Length; i++)
                waveform[i] *= 0.78f;
        }
        level *= 0.96f;
        bass *= 0.95f;
        mid *= 0.95f;
        treble *= 0.95f;
        vocal *= 0.95f;
        air *= 0.94f;
        beat *= 0.88f;
        bassKick *= 0.82f;
        midPunch *= 0.84f;
        trebleSpark *= 0.80f;
        spectralFlux *= 0.88f;
        onset *= 0.78f;
        beatPulse *= 0.82f;
    }

    private void UpdateRhythm(float onsetEnergy)
    {
        float hopSeconds = (FftSize / 2f) / sampleRate;
        analysisClock += hopSeconds;
        onsetAverage = Smooth(onsetAverage, onsetEnergy, onsetEnergy > onsetAverage ? 0.055f : 0.018f);
        float novelty = Clamp01((onsetEnergy - onsetAverage * 0.88f) * 3.4f);
        onset = Math.Max(novelty, onset * 0.66f);

        onsetHistory[onsetHistoryIndex] = novelty;
        onsetHistoryIndex = (onsetHistoryIndex + 1) % onsetHistory.Length;
        onsetHistoryCount = Math.Min(onsetHistory.Length, onsetHistoryCount + 1);

        if (analysisClock - lastTempoAnalysis >= 0.65 && onsetHistoryCount > 180)
        {
            EstimateTempo(hopSeconds);
            lastTempoAnalysis = analysisClock;
        }

        double beatSeconds = 60.0 / Math.Clamp(tempoBpm, 60f, 200f);
        double sinceAnchor = analysisClock - lastBeatAnchor;
        float predictedPhase = (float)(sinceAnchor / beatSeconds - Math.Floor(sinceAnchor / beatSeconds));
        bool nearPredictedBeat = predictedPhase < 0.20f || predictedPhase > 0.82f;
        if (novelty > 0.19f && analysisClock - lastBeatAnchor > 0.18 && (tempoConfidence < 0.18f || nearPredictedBeat))
        {
            lastBeatAnchor = analysisClock;
            predictedPhase = 0f;
        }

        beatPhase = predictedPhase;
        float clockPulse = MathF.Pow(Math.Max(0, 1f - beatPhase * 5.5f), 2.2f) * tempoConfidence;
        beatPulse = Math.Max(Math.Max(clockPulse, novelty), beatPulse * 0.72f);
    }

    private void EstimateTempo(float hopSeconds)
    {
        int minLag = Math.Max(1, (int)MathF.Round(60f / 190f / hopSeconds));
        int maxLag = Math.Min(onsetHistoryCount - 2, (int)MathF.Round(60f / 68f / hopSeconds));
        float bestScore = 0;
        int bestLag = 0;
        for (int lag = minLag; lag <= maxLag; lag++)
        {
            int comparisons = Math.Min(onsetHistoryCount - lag, 420);
            float score = 0;
            for (int i = 0; i < comparisons; i++)
                score += RecentOnset(i) * RecentOnset(i + lag);
            score /= Math.Max(1, comparisons);

            int doubleLag = lag * 2;
            if (doubleLag <= maxLag)
            {
                int harmonicComparisons = Math.Min(onsetHistoryCount - doubleLag, 420);
                float harmonic = 0;
                for (int i = 0; i < harmonicComparisons; i++)
                    harmonic += RecentOnset(i) * RecentOnset(i + doubleLag);
                score += harmonic / Math.Max(1, harmonicComparisons) * 0.35f;
            }

            if (score > bestScore)
            {
                bestScore = score;
                bestLag = lag;
            }
        }

        if (bestLag == 0)
            return;

        float candidate = 60f / (bestLag * hopSeconds);
        if (candidate < 82f && candidate * 2f <= 190f)
            candidate *= 2f;
        float confidence = Clamp01(bestScore * 24f);
        float tempoSpeed = 0.035f + confidence * 0.12f;
        tempoBpm = Smooth(tempoBpm, candidate, tempoSpeed);
        tempoConfidence = Smooth(tempoConfidence, confidence, confidence > tempoConfidence ? 0.18f : 0.06f);
    }

    private float RecentOnset(int offset)
    {
        int index = onsetHistoryIndex - 1 - offset;
        while (index < 0)
            index += onsetHistory.Length;
        return onsetHistory[index % onsetHistory.Length];
    }

    private static float Average(float[] values, int start, int end)
    {
        float total = 0;
        int count = 0;
        for (int i = Math.Max(0, start); i <= Math.Min(values.Length - 1, end); i++)
        {
            total += values[i];
            count++;
        }
        return count == 0 ? 0 : total / count;
    }

    internal static void Fft(Complex[] buffer)
    {
        int n = buffer.Length;
        for (int i = 1, j = 0; i < n; i++)
        {
            int bit = n >> 1;
            for (; (j & bit) != 0; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) (buffer[i], buffer[j]) = (buffer[j], buffer[i]);
        }

        for (int len = 2; len <= n; len <<= 1)
        {
            double angle = -2 * Math.PI / len;
            Complex wlen = new(Math.Cos(angle), Math.Sin(angle));
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
    }

    private static float Smooth(float oldValue, float newValue, float amount) => oldValue + (newValue - oldValue) * amount;
    private static float SoftClip(float value) => MathF.Tanh(value * 1.35f);
    private static float BassLimit(float value) => 0.78f * (1f - MathF.Exp(-value * 1.65f));
    private static float Clamp(float value, float min, float max) => Math.Min(max, Math.Max(min, value));
    private static float Wrap01(float value) => value - MathF.Floor(value);
    private static float Clamp01(float value) => Clamp(value, 0, 1);

    public void Dispose()
    {
        running = false;
        if (thread is { IsAlive: true })
            thread.Join(350);
    }
}
