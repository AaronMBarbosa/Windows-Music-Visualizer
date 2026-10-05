# Private v1.0.0 Release

## Build and Package

On Windows x64 with the .NET 10 SDK:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Release.ps1
```

The script validates the application, publishes a self-contained Windows x64
folder, gathers dependency notices, and creates a ZIP plus SHA-256 checksum in
`dist/`. The recipient does not need the SDK or a separately installed .NET runtime.
Extract the complete ZIP before opening `WindowsMusicVisualizerGpu.exe`.

After generating the portfolio assets, run `scripts/Source-Bundle.ps1` to create
the private-source ZIP and a separate portfolio-only ZIP, each with a checksum.
The source archive excludes build caches, personal IDE settings and debug captures.

## Before Sharing

- Keep the repository private. A LICENSE file or README cannot enforce hosting visibility.
- Confirm the copyright owner wording in LICENSE suits your ownership arrangement.
- Review the dependency notices and the generated package inventory.
- Test normal music, silence, stereo, source switching, fullscreen, all scenes and transitions on the recipient's Windows/GPU setup.
- App-only capture still needs testing on a supported Windows 11 machine.
- Sign binaries with your own code-signing certificate if reputation/identity assurance is required. No certificate is bundled.
- Keep source ZIPs and binaries private; publish only the chosen portfolio media.

## Private Git Repository

Create an EMPTY **private** repository in your Git host first. Then, from this folder:

```powershell
git init -b main
git add .
git status --short
git commit -m "Release Windows Music Visualizer 1.0.0"
git remote add origin <YOUR_PRIVATE_REPOSITORY_URL>
git push -u origin main
git tag -a v1.0.0 -m "Private release 1.0.0"
git push origin v1.0.0
```

Inspect staged files before committing. `.gitignore` excludes package caches,
credentials, personal IDE state, debug captures, tool downloads and binary output.
Configure your remote URL locally; account credentials must not be committed.
If a repository already exists, skip initialization and use its established branch.

The included GitHub Actions workflow builds and validates on Windows. Its artifacts
inherit your repository's access controls; choose a private repository before pushing.
It does not create a public release or publish the application automatically.

## Portfolio

See `portfolio/README.md`. Media and an HTML embed are separate from source and
binary archives. GIF is compatible but heavy; muted MP4 is recommended on websites.
