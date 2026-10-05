param([string]$Version = '1.0.0')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$env:DOTNET_CLI_HOME = Join-Path $root '.dotnet-home'
$env:NUGET_PACKAGES = Join-Path $root '.nuget-packages'
$env:APPDATA = Join-Path $root '.appdata'
$project = Join-Path $root 'WindowsMusicVisualizerGpu/WindowsMusicVisualizerGpu.csproj'
if ($Version -ne '1.0.0') { throw 'Update the project version and release documentation together before packaging a new version.' }
dotnet build $project -c Release --nologo
if ($LASTEXITCODE) { throw 'Build failed' }
$dll = Join-Path $root 'WindowsMusicVisualizerGpu/bin/Release/net10.0-windows/WindowsMusicVisualizerGpu.dll'
foreach ($test in @('--validate-audio','--validate-camera','--validate-motion','--validate-filters','--validate-prism-peaks','--validate-snapshots','--validate-shaders')) {
    dotnet $dll $test
    if ($LASTEXITCODE) { throw "Validation failed: $test" }
}
$name = "WindowsMusicVisualizer-$Version-win-x64"
# A fresh staging directory prevents stale files from leaking into the distribution.
$stage = Join-Path $root ("artifacts/release-" + [guid]::NewGuid().ToString('N'))
$publish = Join-Path $stage $name
dotnet publish $project -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false -p:PublishTrimmed=false -o $publish --nologo
if ($LASTEXITCODE) { throw 'Publish failed' }
foreach ($file in @('LICENSE','THIRD_PARTY_NOTICES.md','CHANGELOG.md')) { Copy-Item -LiteralPath (Join-Path $root $file) -Destination $publish }
Copy-Item -LiteralPath (Join-Path $root 'docs/QUICK_START.md') -Destination (Join-Path $publish 'README.md')
$licenses = Join-Path $publish 'licenses'
New-Item -ItemType Directory -Path $licenses -Force | Out-Null
$assets = Get-Content (Join-Path $root 'WindowsMusicVisualizerGpu/obj/project.assets.json') -Raw | ConvertFrom-Json
$inventory = @()
foreach ($library in $assets.libraries.PSObject.Properties) {
    if ($library.Value.type -ne 'package') { continue }
    $path = Join-Path $env:NUGET_PACKAGES $library.Value.path
    $destination = Join-Path $licenses ($library.Name.Replace('/','-'))
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $notices = @(Get-ChildItem -LiteralPath $path -File -Recurse | Where-Object { $_.Name -match '(?i)license|notice|\.nuspec$' })
    foreach ($notice in $notices) { Copy-Item -LiteralPath $notice.FullName -Destination $destination -Force }
    $inventory += [pscustomobject]@{ package = $library.Name; sha512 = $library.Value.sha512; notices = @($notices.Name) }
}
$inventory | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $licenses 'packages.json') -Encoding utf8
Copy-Item (Join-Path $root 'docs/DEPENDENCY_LICENSES.txt') $licenses
$runtime = Get-Content (Join-Path $publish 'WindowsMusicVisualizerGpu.runtimeconfig.json') -Raw | ConvertFrom-Json
foreach ($framework in $runtime.runtimeOptions.includedFrameworks) {
    $package = $framework.name.ToLowerInvariant() + '.runtime.win-x64'
    $runtimePath = Join-Path $env:NUGET_PACKAGES "$package/$($framework.version)"
    $destination = Join-Path $licenses "$package-$($framework.version)"
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $notices = @(Get-ChildItem -LiteralPath $runtimePath -File | Where-Object Name -Match 'LICENSE|NOTICE')
    if ($notices.Count -eq 0) { throw "Missing runtime license: $package" }
    foreach ($notice in $notices) { Copy-Item -LiteralPath $notice.FullName -Destination $destination }
}
if (-not (Test-Path (Join-Path $publish 'Visualizer.hlsl'))) { throw 'Shader missing from release' }
New-Item -ItemType Directory -Path (Join-Path $root 'dist') -Force | Out-Null
$zip = Join-Path $root "dist/$name.zip"
Compress-Archive -Path $publish -DestinationPath $zip -Force
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $name.zip" | Set-Content "$zip.sha256" -Encoding ascii
Write-Output "Release: $zip"
Write-Output "Staging: $publish"
