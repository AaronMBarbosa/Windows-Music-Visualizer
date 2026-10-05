param([string]$Version = '1.0.0')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if ($Version -ne '1.0.0') { throw 'Update release metadata before changing the version.' }
$stage = Join-Path $root ('artifacts/source-' + [guid]::NewGuid().ToString('N'))
$name = "WindowsMusicVisualizer-$Version-private-source"
$source = Join-Path $stage $name
New-Item -ItemType Directory -Path $source -Force | Out-Null
# Allowlist project files, never package the workspace wholesale.
$rootFiles = @('.gitignore','.gitattributes','README.md','TECHNICAL_NOTES.md','RELEASE.md','CHANGELOG.md','LICENSE','THIRD_PARTY_NOTICES.md','WindowsMusicVisualizer.ps1','Run Visualizer.cmd','Run GPU Visualizer.cmd')
foreach ($file in $rootFiles) { Copy-Item -LiteralPath (Join-Path $root $file) -Destination $source }
foreach ($folder in @('Audio','Rendering','WindowsMusicVisualizerGpu','scripts','docs','.github','portfolio')) {
    $base = Join-Path $root $folder
    foreach ($file in Get-ChildItem -LiteralPath $base -File -Recurse) {
        $relative = $file.FullName.Substring($root.Length + 1)
        if ($relative -match '[\\/](bin|obj)[\\/]' -or $file.Name -match '\.(user|suo)$') { continue }
        if ($file.Extension -notin @('.cs','.csproj','.hlsl','.config','.ps1','.md','.txt','.yml','.html','.json','.gif','.mp4','.jpg')) { continue }
        $target = Join-Path $source $relative
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
    }
}
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
foreach ($bundle in @(@($source,$name), @((Join-Path $root 'portfolio'),"WindowsMusicVisualizer-$Version-portfolio"))) {
    $zip = Join-Path $dist ($bundle[1] + '.zip')
    Compress-Archive -LiteralPath $bundle[0] -DestinationPath $zip -Force
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $($bundle[1]).zip" | Set-Content "$zip.sha256" -Encoding ascii
    Write-Output $zip
}
