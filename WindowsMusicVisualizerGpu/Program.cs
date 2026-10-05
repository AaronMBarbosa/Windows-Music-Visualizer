namespace WindowsMusicVisualizerGpu;

static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        if (args.Contains("--validate-audio")) { AudioValidation.Validate(); return; }
        if (args.Contains("--validate-capture")) { AudioValidation.ValidateCapture(); return; }
        if (args.Contains("--capture-audio-picker"))
        {
            ApplicationConfiguration.Initialize();
            using var audio = new AudioAnalyzer();
            using var picker = new AudioSourceDialog(audio);
            picker.StartPosition = FormStartPosition.Manual;
            picker.Location = new Point(-10000, -10000);
            picker.Show();
            Application.DoEvents();
            using var bitmap = new Bitmap(picker.Width, picker.Height);
            picker.DrawToBitmap(bitmap, new Rectangle(Point.Empty, picker.Size));
            bitmap.Save("audio-picker-qa.png");
            picker.Close();
            return;
        }
        if (args.Contains("--validate-filters"))
        {
            SceneFilter.Validate();
            return;
        }
        if (args.Contains("--validate-prism-peaks"))
        {
            PrismPeakMarkers.Validate();
            return;
        }
        if (args.Contains("--validate-snapshots"))
        {
            BeatSnapshotClock.Validate();
            return;
        }
        if (args.Contains("--validate-camera"))
        {
            CameraValidation.Validate();
            return;
        }
        if (args.Contains("--validate-motion"))
        {
            MotionSpectrum.Validate();
            return;
        }
        if (args.Contains("--validate-shaders"))
        {
            Direct3DVisualizerForm.ValidateShaders();
            return;
        }
        int screen = 1;
        int mode = -1;
        for (int i = 0; i < args.Length - 1; i++)
        {
            if ((args[i] == "--screen" || args[i] == "-screen") && int.TryParse(args[i + 1], out int parsed))
                screen = parsed;
            if (args[i] == "--mode" && int.TryParse(args[i + 1], out int parsedMode))
                mode = parsedMode - 1;
        }

        ApplicationConfiguration.Initialize();
        using var analyzer = new AudioAnalyzer();
        int captureIndex = Array.IndexOf(args, "--capture-render");
        int recordingIndex = Array.IndexOf(args, "--record-portfolio");
        using var form = new Direct3DVisualizerForm(analyzer, screen, mode, captureIndex >= 0 ? 1977 : null);
        form.SetCameraEnabled(!args.Contains("--no-camera"));
        form.TestPrismHeadroom = args.Contains("--test-prism-headroom");
        int filterIndex = Array.IndexOf(args, "--filter");
        if (filterIndex >= 0 && filterIndex + 1 < args.Length && int.TryParse(args[filterIndex + 1], out int filter))
            form.SetFilterOverride(filter - 1);
        if (captureIndex >= 0 && captureIndex + 1 < args.Length)
            form.CapturePath = Path.GetFullPath(args[captureIndex + 1]);
        int delayIndex = Array.IndexOf(args, "--capture-after");
        if (delayIndex >= 0 && delayIndex + 1 < args.Length &&
            float.TryParse(args[delayIndex + 1], System.Globalization.CultureInfo.InvariantCulture, out float delay) && float.IsFinite(delay))
            form.CaptureAfterSeconds = Math.Clamp(delay, 0.1f, 20f);
        int transitionIndex = Array.IndexOf(args, "--capture-transition");
        if (transitionIndex >= 0 && transitionIndex + 1 < args.Length && int.TryParse(args[transitionIndex + 1], out int targetMode))
            form.CaptureTransitionMode = Math.Clamp(targetMode - 1, 0, 34);
        if (recordingIndex >= 0 && recordingIndex + 1 < args.Length) form.ConfigurePortfolioRecording(args[recordingIndex + 1]);
        else if (args.Contains("--test-audio") || args.Contains("--test-stereo")) analyzer.StartTestSignal(args.Contains("--test-stereo"));
        else if (!args.Contains("--test-silence")) analyzer.Start();
        Application.Run(form);
    }    
}
