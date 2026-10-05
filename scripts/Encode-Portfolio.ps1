param([Parameter(Mandatory=$true)][string]$Ffmpeg, [switch]$GifsOnly)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$inputPattern = Join-Path $root 'artifacts/portfolio-frames/frame-%05d.png'
$output = Join-Path $root 'portfolio'
New-Item -ItemType Directory -Path $output -Force | Out-Null
$frames = @(Get-ChildItem (Join-Path $root 'artifacts/portfolio-frames') -Filter 'frame-*.png')
if ($frames.Count -ne 900) { throw "Expected 900 frames, found $($frames.Count)" }
$fade = 'fade=t=in:st=0:d=0.35,fade=t=out:st=29.65:d=0.35'
if (-not $GifsOnly) {
    & $Ffmpeg -y -hide_banner -loglevel warning -framerate 30 -i $inputPattern -vf $fade -c:v libx264 -crf 19 -preset slow -pix_fmt yuv420p -movflags +faststart -an (Join-Path $output 'visualizer-showcase.mp4')
    if ($LASTEXITCODE) { throw 'MP4 encoding failed' }
}
# Retain two seconds from each scene at real speed; the MP4 keeps all transitions.
foreach ($variant in @(@('visualizer-showcase.gif',960,15,128), @('visualizer-preview.gif',640,10,96))) {
    $filter = "select='gte(mod(n,150),45)*lt(mod(n,150),105)',setpts=N/30/TB,fps=$($variant[2]),scale=$($variant[1]):-1:flags=lanczos,fade=t=in:st=0:d=0.25,fade=t=out:st=11.75:d=0.25,split[a][b];[a]palettegen=max_colors=$($variant[3]):stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle"
    & $Ffmpeg -y -hide_banner -loglevel warning -framerate 30 -i $inputPattern -filter_complex $filter -loop 0 (Join-Path $output $variant[0])
    if ($LASTEXITCODE) { throw 'GIF encoding failed' }
}
& $Ffmpeg -y -hide_banner -loglevel warning -i (Join-Path $root 'artifacts/portfolio-frames/frame-00220.png') -frames:v 1 -update 1 -q:v 2 (Join-Path $output 'visualizer-poster.jpg')
if ($LASTEXITCODE) { throw 'Poster encoding failed' }
Copy-Item (Join-Path $root 'artifacts/portfolio-frames/recording.json') (Join-Path $output 'recording.json') -Force
Get-ChildItem $output -File | Where-Object Extension -in '.mp4','.gif','.jpg' | Select-Object Name,Length
