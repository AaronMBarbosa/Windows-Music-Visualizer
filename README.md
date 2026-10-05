# Windows Music Visualizer

**Version 1.0.0 | Private / proprietary | Windows x64**

A real-time desktop music visualizer inspired by classic media-player visuals,
built with C#, WASAPI audio capture and Direct3D 11 shaders.

![Shuffled visualizer demonstration](portfolio/visualizer-preview.gif)

[High-quality GIF](portfolio/visualizer-showcase.gif) · [720p video](portfolio/visualizer-showcase.mp4) · [Portfolio embed](portfolio/embed.html)

## Features

- 35 visual families with a shuffled, no-repeat rotation: plasma, kaleidoscopes,
  volumetric tunnels, reflective 3D bars, ferrofluid, waveform histories and more.
- Stereo energy and frequency-local motion, adaptive normalization, onset detection
  and estimated beat timing. These are audio features, not isolated instrument stems.
- 14 randomized filters, evolving palettes, three transition styles and five camera-accent styles.
- Readable peak markers, silence settling and a default 60 FPS cap with optional unlocked rendering.
- Playback-device picker; app-only capture on compatible Windows versions.

## Run

For a packaged release, extract the entire private Windows x64 ZIP and open
`WindowsMusicVisualizerGpu.exe`. The self-contained package includes .NET.

For development, install the **.NET 10 SDK** on Windows, then double-click
`Run GPU Visualizer.cmd`, or run:

```powershell
dotnet run --project WindowsMusicVisualizerGpu -c Release
```

Requires a Direct3D 11-capable graphics device and Windows audio playback.
Press **A** or right-click for audio selection; **Space** shuffles; **F** toggles
fullscreen; **V** unlocks FPS; **K/G** toggle camera/filter effects; **Esc** exits.
See [Quick Start](docs/QUICK_START.md) for all controls and troubleshooting.

App-only capture requires Windows build 20348 or newer. Windows 10 build 19045
supports device capture only. App isolation remains unverified on the development
machine; a dedicated output can isolate playback on older Windows.

## Architecture

`WasapiLoopbackCapture` reads local stereo samples. `AudioAnalyzer` extracts
spectral, energy and rhythm features. `MotionSpectrum`, `CameraAccentDetector`
and peak/snapshot helpers shape those into stable visual controls. The Direct3D
renderer passes them to HLSL scenes, maintains feedback textures, and applies
transitions and filters as a separate presentation pass.

Audio is processed locally, not uploaded or saved during normal operation.
The portfolio recording uses generated test audio features, not commercial music.

## Build, Verify and Release

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Release.ps1
```

Produces a self-contained ZIP and SHA-256 checksum in ignored `dist/`.
See [Release Guide](RELEASE.md), [Changelog](CHANGELOG.md), and
[Technical Notes](TECHNICAL_NOTES.md). GitHub Actions validates and packages on
Windows without automatically publishing a release.

The older CPU/PowerShell fallback remains in `WindowsMusicVisualizer.ps1`,
`Audio/` and `Rendering/`. It is not the recommended GPU release.

## Portfolio and Ownership

The [portfolio folder](portfolio/README.md) contains public-facing media and
copy that can be used without exposing the source. Keep the Git repository and
binary releases **private**. Repository visibility must be configured on your
Git host; this file does not enforce it.

Original project work is proprietary; see [LICENSE](LICENSE). Third-party
components retain their own terms; see [notices](THIRD_PARTY_NOTICES.md).
No affiliation with Microsoft or classic visualization vendors is implied.

Moving/flashing visuals may be uncomfortable for sensitive viewers. The portfolio
embed respects reduced-motion preferences and provides a pause control.
