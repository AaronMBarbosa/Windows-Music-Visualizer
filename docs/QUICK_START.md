# Windows Music Visualizer 1.0.0

Private, proprietary Windows x64 release. Extract the complete ZIP to a writable
folder and run `WindowsMusicVisualizerGpu.exe`. Keep Visualizer.hlsl and all DLLs
beside the executable. No .NET installation is required for this portable package.

Requirements: Windows x64, Direct3D 11 graphics support, a working playback device.
Windows 10 device capture is supported. App-only capture requires build 20348+;
it is unavailable on Windows 10 build 19045. Start music playback, then press A
to select an output. The program never changes your system output routing.

| Key | Action |
| --- | --- |
| A / right-click | Audio source picker |
| Space | Shuffle preset |
| Right / M / PageDown | Next scene |
| Left / PageUp | Previous scene |
| C | Change palette |
| F | Toggle fullscreen |
| V | Toggle 60 FPS / unlocked |
| K | Toggle camera accents |
| G | Toggle filters |
| Esc | Exit |

Use `--screen 1` or `--screen 2` to choose a display. Display order is determined
by Windows. `--mode 8` starts at a particular scene (1-35). No internet account
is needed. Audio is analyzed locally and not saved during normal use.

Flashing/moving visuals may be uncomfortable for sensitive viewers. Camera and
filter toggles reduce some effects but are not a photosensitivity-safe mode.

If there is no response, check the selected output and the title's capture status.
If app capture is unavailable, route the desired app to a dedicated output in
Windows settings and select that output. Other apps on that output remain included.

Binaries are unsigned. Obtain releases only from the project owner; compare the
provided SHA-256 checksum before use. See LICENSE and THIRD_PARTY_NOTICES.md.
