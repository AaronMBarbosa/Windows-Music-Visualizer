# Portfolio Media

These assets show the actual Direct3D renderer, not a recreation or mockup.
The 30-second silent demonstration shuffles six selected scenes; scene order and
capture details are in recording.json. It uses a generated stereo analysis signal,
not captured commercial music. Presentation filters are disabled for clarity;
scene transitions, camera accents, geometry and trails remain active.

- `visualizer-showcase.mp4`: 1280 x 720, 30 FPS. Preferred website asset.
- `visualizer-showcase.gif`: 960 x 540, 15 FPS, 12-second looping montage.
- `visualizer-preview.gif`: 640 x 360, 10 FPS, smaller 12-second looping montage.
- `visualizer-poster.jpg`: static fallback for loading and reduced motion.
- `embed.html`: self-contained local preview and reusable responsive embed.
- `project.json`: portfolio title, short description, stack and release metadata.

Upload only these media/portfolio files to the public site, not the source or
release ZIP. Point the embed's relative media paths to your site's asset folder.
GIFs cannot be paused reliably, so the HTML uses MP4 with a play/pause button and
honors reduced-motion preferences. No external scripts, fonts, or trackers.
The GIFs retain two seconds from each scene at normal speed; the full MP4 includes
the complete 30-second sequence with blended scene transitions.

To recreate: build the app, run it with `--record-portfolio artifacts/portfolio-frames`,
then run `scripts/Encode-Portfolio.ps1 -Ffmpeg <path-to-ffmpeg.exe>`.
FFmpeg is an authoring dependency only and is not bundled with the app.

Suggested portfolio copy:

**Windows Music Visualizer** is a custom Windows desktop visualizer combining
real-time stereo analysis with 35 GPU-rendered scenes. Frequency-driven geometry,
beat-aware camera motion, evolving palettes and blended transitions reinterpret
the energy of classic media-player visualizations using C#, WASAPI and Direct3D 11.
