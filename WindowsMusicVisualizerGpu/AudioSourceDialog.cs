namespace WindowsMusicVisualizerGpu;

internal sealed class AudioSourceDialog : Form
{
    private readonly AudioAnalyzer analyzer;
    private readonly ListBox sources = new() { Dock = DockStyle.Fill, IntegralHeight = false };
    private readonly Label status = new() { Dock = DockStyle.Bottom, Height = 50, AutoEllipsis = true };
    private readonly System.Windows.Forms.Timer statusTimer = new() { Interval = 300 };

    public AudioSourceDialog(AudioAnalyzer analyzer)
    {
        this.analyzer = analyzer;
        Text = "Audio Source";
        StartPosition = FormStartPosition.CenterParent;
        ClientSize = new Size(560, 430);
        MinimumSize = new Size(420, 330);
        MaximizeBox = false; MinimizeBox = false;
        Padding = new Padding(14);
        var actions = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 42, FlowDirection = FlowDirection.RightToLeft };
        var cancel = new Button { Text = "Close", AutoSize = true, DialogResult = DialogResult.Cancel };
        var apply = new Button { Text = "Apply", AutoSize = true };
        var refresh = new Button { Text = "Refresh", AutoSize = true };
        apply.Click += (_, _) => { if (sources.SelectedItem is AudioSource source) analyzer.SelectSource(source); };
        refresh.Click += (_, _) => RefreshSources();
        sources.DoubleClick += (_, _) => apply.PerformClick();
        actions.Controls.AddRange([cancel, apply, refresh]);
        Controls.Add(sources); Controls.Add(status); Controls.Add(actions);
        if (!WasapiLoopbackCapture.SupportsApplicationCapture)
        {
            Controls.Add(new Label { Dock = DockStyle.Top, Height = 42, Text = "App-only capture unavailable on this Windows version.\nRequires Windows build 20348 or newer (Windows 11 supported)." });
        }
        AcceptButton = apply; CancelButton = cancel;
        statusTimer.Tick += (_, _) => status.Text = $"{analyzer.SelectedSource.Name}\n{analyzer.SourceStatus}";
        statusTimer.Start();
        RefreshSources();
    }

    private void RefreshSources()
    {
        AudioSource selected = sources.SelectedItem as AudioSource ?? analyzer.SelectedSource;
        var choices = new List<AudioSource> { AudioSource.SystemDefault };
        try { choices.AddRange(WasapiLoopbackCapture.Devices()); }
        catch (Exception ex) { status.Text = ex.Message; }
        if (WasapiLoopbackCapture.SupportsApplicationCapture) choices.AddRange(AudioSource.Applications());
        if (!choices.Contains(selected)) choices.Add(selected);
        sources.DataSource = choices;
        sources.SelectedItem = selected;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) statusTimer.Dispose();
        base.Dispose(disposing);
    }
}
