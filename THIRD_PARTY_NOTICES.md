# Third-Party Notices

Original project code is proprietary. Dependency licenses remain independent.

- Vortice.Windows packages (including Direct3D11, Direct2D1 and D3DCompiler), version 3.8.3: upstream https://github.com/amerkoleci/Vortice.Windows
- Vortice.Mathematics 2.1.0: upstream https://github.com/amerkoleci/Vortice.Mathematics
- SharpGen.Runtime and other transitive NuGet dependencies: the release script includes package metadata and available license/notice files from the restored package cache.
- Microsoft .NET runtime: self-contained releases include the runtime's license and third-party notices. https://github.com/dotnet/runtime
- Windows system graphics/audio libraries are supplied by Windows, not this project.

The binary distribution's `licenses/` folder contains dependency notices and an
inventory generated from the actual restored packages. Review those files before
redistributing a release. Dependency names alone are not a substitute for their
license texts.
MIT license texts and copyright notices for Vortice and SharpGen are also included
in `docs/DEPENDENCY_LICENSES.txt` and copied into the binary distribution.

FFmpeg is used only as a local media-authoring tool; it is not included in the
application or source bundle. Portfolio files contain generated demo analysis,
not commercial music, third-party video, or desktop recordings. Visual references
to classic media-player aesthetics do not imply affiliation or endorsement.
