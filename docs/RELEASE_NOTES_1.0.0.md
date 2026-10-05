# Windows Music Visualizer 1.0.0

First private release of the Windows desktop music visualizer.

- 35 shuffled Direct3D 11 visual scenes, including reflective spectrum bars,
  ferrofluid, plasma, kaleidoscopes, waveform histories and tunnels.
- Stereo audio analysis, frequency-specific motion, beat timing and camera accents.
- 14 presentation filters, changing palettes and blended transitions.
- Falling spectrum peak markers and a default 60 FPS cap with an unlocked option.
- Playback-device selection and app-only capture on supported Windows versions.

## Download and Run

Download `WindowsMusicVisualizer-1.0.0-win-x64.zip`, extract the entire archive,
and launch `WindowsMusicVisualizerGpu.exe`. The Windows x64 package includes .NET.
The accompanying `.sha256` file records the archive's SHA-256 checksum.

Press **A** or right-click to select audio, **Space** to shuffle visualizers,
**F** for fullscreen, **V** to unlock frame rate, and **Esc** to exit.
See the included README for all controls.

## Release Notes

The executable is unsigned. App-only audio capture requires Windows build 20348
or newer and remains unverified on the development machine. Device loopback
capture is available on older supported Windows systems.

Original project work is proprietary. This repository and its releases are
private; third-party dependencies retain the licenses included in the package.
