# Windows Music Visualizer

A nostalgic fullscreen audio visualizer inspired by old Windows Media Player visuals. It captures the default Windows playback device in loopback mode, so Spotify, YouTube, games, browsers, and other audio routed to your headphones can drive the animation.

For the newer hardware-accelerated version, use:

```text
Run GPU Visualizer.cmd
```

That GPU build is the recommended version. It uses Direct3D 11 feedback shaders and samples bass, percussion, mids, vocals, treble detail, a live waveform, spectral movement, and track brightness separately. It also estimates BPM, beat phase, onset strength, and tempo confidence so motion and scene changes can follow musical time instead of raw volume alone.

Thirty-five visual families are active, including waves, tunnels, plasma, the disco floor, radial scenes, the helix, orbital shards, gyroscope and chrome torus. The newer scenes add spinning panels, a rotating sand plate, a resonance tunnel, a full-screen interference prism, a chromatic ribbon loom, rippling blooms, expanding and curling bead branches, waveform snapshots, ferrofluid and flowing silk trails. Their travel speed responds smoothly to musical activity. A shuffled deck shows every active family before any repeat.

Scene 28's Chromatic Loom replaces the orbiting irises with screen-spanning shaded ribbons whose width and curvature follow separate frequency bands. Scene 26 adds outward-moving light packets, scene 30 adds rotating magnetic paths, scene 31 adds a scrolling perspective grid without changing beat-synced snapshots, and scene 32 adds traveling field pulses around the ferrofluid dish. These background details stay subordinate to the main effects and soften when audio is quiet.

Three Geiss-inspired retro scenes add a sweeping raster curtain, a frequency-driven radial light fan, and expanding phosphor echoes. Only these scenes use a stable 360-line virtual pixel grid and stepped color shading; existing scenes retain their native-resolution appearance. They are scenes 33, 34, and 35 for the `--mode` option.

For render diagnostics, `--test-audio --capture-render output.png` exports two GPU frames (the second has a `.later.png` suffix) and exits. Use `--test-silence` instead of `--test-audio` to check the silent state. Add `--capture-after 4` to let four seconds of animation develop before capturing, with the second frame half a second later. Capture runs use a fixed preset seed for comparison. It does not capture the desktop.

Scene changes use full-screen light-space blends with three transition styles: directional color carry, a gentle twist, and flowing prismatic separation. Musical activity adds restrained color flares. The blend is separate from scene feedback, avoiding accumulated transition blur; skipping again mid-blend continues from the visible frame. Add `--capture-transition 23` to a render diagnostic to capture a handoff into scene 23.

The interference prism replaces the fabric panel with sharp moving light contours, without pixelation or accumulated haze. Scene 23 replaces the fountain with Geiss-inspired silk: two live audio filaments leave colored trails that expand and curl across the screen. Its feedback fades in elapsed time and cannot accumulate into white haze. Scene 29 replaces the prismatic beams with a WMP-inspired ripple bloom: a luminous audio-shaped membrane, broad colored rings, and expanding echoes. Both settle into darkness without audio.

The tunnel (scene 3) and mirrored wings (scene 13) map restrained motion-band envelopes into a larger, bounded displacement range. Bass changes their shape, middle frequencies bend contours, and treble adds detail. The wings retain space between their contours and mirror their waveform continuously across the center. These scene-specific controls do not raise sensitivity for other visualizers.

The waveform waterfall (scene 31) holds eight snapshots, capturing one new line per estimated beat: 60 BPM gives one per second, 120 BPM gives two, and 180 BPM gives three. Timing follows tempo changes smoothly and gently aligns to the detected beat phase when confidence is high; uncertain passages keep the smoothed tempo instead of switching to a fixed refresh rate. Older shapes recede unchanged, without screen-feedback blur. Other snapshot scenes keep their existing half-beat cadence. Run `--validate-snapshots` to check beat timing, tempo changes, and confidence recovery.

The resonance tunnel (scene 26) uses tilted waveform rings and a perspective trail of captured audio, inspired by early Windows Media Player ring effects. Its bass expansion, midrange bending, and treble highlights are separate. It and the bead branches render without accumulated haze.

Scene 8 is Prism Concerto, replacing the drifting noise ridges with 24 independently reacting 3D light prisms. Separate frequency slices control height, depth, and yaw, with shaded faces, illuminated edges, floor reflections, and restrained colored light pools. It renders without accumulated feedback. Scene 5's scrolling waveforms now interpolate continuously across their last/first sample join rather than jumping at the wrap, with anti-aliasing on steep sections.

Abstract geometry uses local frequency contrast with separate attack and release envelopes. Sustained tones settle instead of pinning the whole scene at maximum. Ferrofluid assigns its seven poles to distinct frequency slices, with matching field contours around the dish. The waterfall has amplified snapshot displacement, camera sway, and a compact glow.

Selective motion retains a restrained held-note envelope instead of suppressing sustained music. Regional controls combine local peaks with average energy so isolated notes remain visible; wing contours also bend independently with their frequency slices.

The kaleidoscope (scene 2) uses vivid liquid-mandala bands with separate low-note swelling, midrange twisting, and high-frequency contour ripples. It renders without accumulated feedback haze and settles to subdued contours in silence.

Run with `--validate-motion` to check frequency isolation, transient attack, sustained-tone settling, and release into silence; the result is written to `motion-validation.txt` beside the executable.

Camera accents use a separate, pre-normalization audio analysis path. Thirty-two frequency regions compete by audible positive spectral change, with local pitch-change suppression, adaptive thresholds, and a short retrigger guard. A sustained sound or predicted BPM pulse does not keep shaking the screen. Strong bass, percussion, or midrange/vocal-range attacks can lead the motion; this is not instrument or vocal separation. The approach draws on [maximum-filter spectral-flux onset detection](https://librosa.org/doc/0.11.0/generated/librosa.onset.onset_strength.html).

Each scene change rerolls one of five camera styles: lateral recoil, vertical bounce, diagonal sway, alternating handheld arcs, or small roll/zoom punches. Faster detected accents shorten the return movement. Damped motion settles between hits, is bounded, and is gentler on charts and the disco floor. It is applied once after scene feedback, so it does not blur trails. Automatic edge coverage prevents exposed or mirrored borders. Press `K` to toggle it, or start with `--no-camera` for no added camera motion.

Camera accents have an exaggerated response curve, with roughly 2-3 times the previous displacement and stronger roll/zoom. Detection thresholds and timing are unchanged, so stronger motion does not mean more false beat triggers.

Run `--validate-camera` for synthetic-audio checks of timing, frequency selection, volume scaling, steady noise/vibrato rejection, fast accents, silence settling, viewport coverage, and 60/144 Hz consistency. Results are written to `camera-validation.txt` beside the executable.
Render captures also write a `.camera.txt` diagnostic with the detected accent count and maximum camera movement, for comparing music, silence, and `--no-camera` runs.

The DVD scene has been replaced by a shaded ferrofluid pool: individual frequency slices raise separate spikes and reflected strip lights reveal their changing shape. The effects interpret audio features; they do not separate instrument stems.

The newer scenes have individual background treatments: reflective caustics, moving curtains of light, relief patterns, and flowing pigment. Trails retain bright moving details rather than dim background color, and shorten during dense audio and silence to preserve clarity.

The visualizer automatically normalizes incoming audio, so quiet tracks still move and loud tracks should no longer flatten every effect into a full-height wall.

The renderer keeps the previous frame on the GPU for trails and liquid motion. Transitions blend the complete outgoing and incoming scenes in light space, with directional, twisting, or prismatic color carry. Automatic changes wait for a useful musical cue when possible and span a whole number of beats.

Each visual is compiled as its own shader. The active visual opens first while the remaining shader cache warms in the background, avoiding the long black startup and transition stalls caused by one oversized shader. Rendering starts capped at 60 FPS. Press `V` to unlock rendering for high-refresh displays, or press it again to restore the 60 FPS cap.

## Run the GPU version

Double-click:

```text
Run GPU Visualizer.cmd
```

To choose a monitor from PowerShell:

```powershell
.\Run GPU Visualizer.cmd --screen 1
```

Monitor `1` is the first display reported by Windows. On the current two-monitor setup it is the non-primary display.

## GPU controls

- `Esc` closes the visualizer.
- `Space` changes to a fully randomized preset.
- `M`, `Right`, or `PageDown` selects the next visual form.
- `Left` or `PageUp` selects the previous visual form.
- `C` changes the color palette.
- `F` toggles fullscreen.
- `V` toggles smooth 60 FPS and unlocked rendering.
- `K` toggles accent-driven camera motion.
- `G` toggles the randomized scene filter layer.

Each scene visit chooses a new filter with randomized strength, direction, and color tint: double exposure with a softened echo, chunky pixel mosaic, directional color bleed, chromatic lens split, CRT phosphor, iridescent highlights, etched neon edges, radial zoom echoes, or dot-matrix ink. Pixel mosaic uses crisp square tiles with fine seams; dot-matrix uses fixed round pins and subtle nine-pin print-head banding. The same scene will not reuse its previous filter, and adjacent visits cannot pick the same filter. Filters blend with scene transitions and are applied after scene feedback, so they do not accumulate into blurry trails. Rendering still starts at 60 FPS.

Dot-matrix preserves the scene's full colors rather than applying monochrome ink. Five additional animated filters bring the total to fourteen: strong 24 Hz film grain, red/cyan anaglyph-style double exposure, VHS tracking with delayed color, moving lenticular ridges, and a drifting liquid-glass magnifier. The anaglyph is a visual treatment, not true stereoscopic rendering. Motion is time-based and does not accelerate with unlocked frame rates.

For diagnostic captures, `--filter 1` through `--filter 14` selects a specific filter. `--validate-filters` checks selection variety, strength bounds, and bypass behavior.

## Older fallback

The original PowerShell version is still available through `Run Visualizer.cmd`. It is useful as a compatibility fallback, but it is CPU-rendered and intentionally runs at a reduced internal resolution.

From PowerShell:

```powershell
.\WindowsMusicVisualizer.ps1
```

For more speed in the fallback:

```powershell
.\WindowsMusicVisualizer.ps1 -RenderScale 0.55
```

## Monitor Selection

The PowerShell fallback also defaults to monitor `1`. To start it on another display, pass `-Screen`:

```powershell
.\WindowsMusicVisualizer.ps1 -Screen 2
```

The first monitor is `1`, second is `2`, and so on.

## Audio Setup

Press `A` to open Audio Source. Select the default system output, a specific playback device, or (on supported Windows versions) a running application, then Apply. Refresh updates the available sources. The title and picker show the active source and capture status. No Python environment is required.

Left and right channels are now retained. Shared normalization preserves the stereo balance; spectrum energy is combined without cancelling out-of-phase audio. Crystal Mirror spreads and weights its waves by stereo energy, Prism Concerto gives individual frequencies stereo-driven depth, Resonance Tunnel follows balance/width, and Magnetic Sculpture bends its branches by frequency-specific panning. Mono stays centered. Existing beat analysis and the default 60 FPS cap remain.

Application isolation uses Microsoft's process-tree loopback API, which requires Windows build 20348 or newer (including Windows 11). On older Windows 10 builds, the picker offers device capture and displays the limitation. App capture includes the selected executable's oldest accessible instance and its descendants, and reconnects by executable path when it restarts. Separate independent instances are not combined. Protected audio may not be capturable. It never silently falls back to system audio or simulated music on failure.

On unsupported Windows versions, route Spotify to a separate playback output in Windows' app volume/device settings, then select that output here. A virtual audio cable is another option but is not installed by this program. Other apps using that same output will still be included.

Diagnostics: `--validate-audio` tests stereo analysis; `--validate-capture` checks real output-device capture and process capture where supported; `--test-stereo` supplies a panning diagnostic signal for render checks.

If the visualizer moves but does not follow music:

- In Windows sound settings, set your headphones as the default output device.
- Start music playback before launching the visualizer.
- If using Bluetooth headphones, reconnect them and relaunch the visualizer after Windows makes them the active device.

No Python or Anaconda setup is needed. The GPU build is self-contained after its first successful build and uses Windows WASAPI loopback audio plus Direct3D 11 hardware rendering.
