# Windows Music Visualizer GPU

This is the Direct3D 11 hardware-accelerated version of the visualizer. It captures the default Windows playback device and keeps all fullscreen feedback, blur, warping, color, and scene rendering on the GPU.

The audio sampler separates bass kicks, midrange punches, vocals, air, treble sparks, spectral movement, waveform shape, and overall brightness. The 17-scene shuffled deck mixes fluid, mirrored, perspective, architectural, mosaic, waveform, woven, and climbing forms. Live waveform scenes include a traveling comet with ghost trails, layered oscilloscopes, a vocal loom, and stacked bass terrain.

Each scene has its own compact pixel shader. The active scene loads first and the rest are cached in the background, keeping startup and transitions responsive. Rendering starts in smooth mode, explicitly paced at 60 FPS; press `V` to switch to unlocked rendering, or press it again to restore the cap.

## Run

From the parent folder, double-click:

```text
Run GPU Visualizer.cmd
```

Or run:

```powershell
.\Run GPU Visualizer.cmd --screen 1
```

The launcher builds the app in Release mode and then runs the compiled executable directly.

If an older copy is already running, close it with `Esc` before launching again so Windows can replace the executable with the newest build.

## Controls

- `Esc` closes the app.
- `Space` randomizes the visual preset.
- `M` changes visual mode.
- `C` changes color palette.
- `F` toggles fullscreen.
- `V` toggles smooth 60 FPS and unlocked rendering.
- `K` toggles accent-driven camera motion. Start with `--no-camera` to disable it initially.
- `G` toggles fourteen randomized scene filters: double exposure, chunky pixel mosaic, color bleed, chromatic split, CRT phosphor, iridescent highlights, etched neon edges, radial zoom echoes, full-color dot-matrix, strong film grain, red/cyan anaglyph, VHS tracking, lenticular ridges, and a drifting liquid-glass magnifier. Each visit rolls a different filter and varied parameters, applied after feedback to retain clarity.

The camera follows detected musical attacks across bass, midrange, and treble, with five motion styles rerolled on scene changes. It does not use the predicted beat clock or sustained loudness as a shake trigger. Its bounded, damped movement is applied after feedback to preserve trail clarity. `--validate-camera` runs the audio and motion regression checks; see the parent README for details.

In windowed mode, the title shows an FPS estimate and the current scene number.
