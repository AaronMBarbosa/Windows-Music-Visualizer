# Changelog

## 1.0.0 - 2026-10-05

First packaged private release.

- 35 Direct3D 11 visual scenes with a shuffled, no-repeat scene deck.
- Stereo loopback capture, playback-device picker and capture status.
- Process-tree audio capture on supported Windows builds; explicit unsupported-version status.
- Adaptive audio normalization, frequency-local motion, onset-driven camera accents and estimated beat timing.
- 14 randomized presentation filters, palette variation and blended transitions.
- Prism Concerto with falling peak plates, extended peak headroom and adaptive framing.
- Beat-synchronized waveform snapshots and separate silence behavior.
- 60 FPS default with optional unlocked rendering.
- Portable Windows x64 distribution, validation tools and portfolio media exports.

### Known Limitations

- Windows 10 build 19045 cannot use app-only capture; use a dedicated playback output instead.
- Process capture needs Windows build 20348+ and was not verified on the development PC.
- Tempo and frequency features are estimates, not instrument/stem separation.
- Release binaries are unsigned; Windows may display a reputation warning.
- GPU load depends on scene, resolution and filters. No minimum performance guarantee is claimed.
