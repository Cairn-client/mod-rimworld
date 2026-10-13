# Copyright (C) 2026 the Cairn contributors. SPDX-License-Identifier: MIT (as the project it is part of)
<#
.SYNOPSIS
    Builds the Cairn mod pack for RimWorld (Multiplayer): release\Cairn-Pack-rimworld-<version>.zip and release\pack-index.json
    (what the Cairn launcher reads to see a newer pack exists).

.DESCRIPTION
    An *external* pack that goes into the game's own folder (docs in the launcher repository: docs/PACKS.md, installDir ".").
    RimWorld mods live in the Mods folder of the game, so the pack carries two of them:

      mod\Mods\Multiplayer\   this repository's mod, built (Source\) and laid out the way workshop_bundler.sh does for RimWorld 1.6
      mod\Mods\Prepatcher\    the library mod Multiplayer needs (zetrith/Prepatcher, MIT; it carries the Harmony it uses): the folder
                              of the pinned commit the release workflow checked out, without its sources
      pack.json      the contract with the launcher
      manifest.txt   MOD|<path>|<size>|<sha256>, one line per file

    The pack's version is the VERSION file (strict X.Y.Z, this project's own); the Multiplayer version (Source\Common\Version.cs) is the pack's
    "upstream". RimWorld lists the mods in its Mods folder but a mod is switched on by the player in the game's Mods screen.
    A file of the game's with the same name and other bytes is never overwritten by the launcher.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PrepatcherDir   # a checkout of zetrith/Prepatcher at the commit the workflow pinned
)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$version = (Get-Content (Join-Path $root 'VERSION') -TotalCount 1).Trim()
if ($version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw "VERSION must be strict X.Y.Z, got '$version'" }
$mpVersion = [regex]::Match((Get-Content (Join-Path $root 'Source\Common\Version.cs') -Raw), 'SimpleVersion = "([0-9.]+)"').Groups[1].Value
if (-not $mpVersion) { throw 'could not read the Multiplayer version from Source\Common\Version.cs' }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$release = Join-Path $root 'release'
$stage = Join-Path $release 'pack-stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
$mod = Join-Path $stage 'mod'
$mp = Join-Path $mod 'Mods\Multiplayer'
$pp = Join-Path $mod 'Mods\Prepatcher'
New-Item -ItemType Directory -Force -Path (Join-Path $mp '1.6'), $pp | Out-Null

# Multiplayer, as workshop_bundler.sh lays out the 1.6 mod (About and Textures shared, the rest under 1.6)
Copy-Item (Join-Path $root 'About') $mp -Recurse
Copy-Item (Join-Path $root 'Textures') $mp -Recurse
foreach ($d in 'Assemblies', 'AssembliesCustom', 'Defs', 'Languages') {
    $src = Join-Path $root $d
    if (-not (Test-Path $src)) { throw "the build did not make $d" }
    Copy-Item $src (Join-Path $mp '1.6') -Recurse
}
foreach ($n in '.git', 'LICENSE', 'README.md') { Remove-Item (Join-Path $mp "1.6\Languages\$n") -Force -ErrorAction SilentlyContinue }
Copy-Item (Join-Path $root 'LICENSE') (Join-Path $mp 'LICENSE')
[IO.File]::WriteAllText((Join-Path $mp 'LoadFolders.xml'), "<loadFolders>`n  <v1.6>`n    <li>/</li>`n    <li>1.6</li>`n  </v1.6>`n</loadFolders>`n", (New-Object System.Text.UTF8Encoding($false)))
$about = Join-Path $mp 'About\About.xml'
$aboutText = [IO.File]::ReadAllText($about)
$aboutText = [regex]::Replace($aboutText, '<modVersion>.*?</modVersion>', "<modVersion>$mpVersion (Cairn $version)</modVersion>")
[IO.File]::WriteAllText($about, $aboutText, (New-Object System.Text.UTF8Encoding($false)))

# Prepatcher: the mod folder of the pinned commit, not its sources or the folders of older RimWorld versions
foreach ($n in 'About', 'Assemblies', 'LoadFolders.xml', 'LICENSE') {
    $src = Join-Path $PrepatcherDir $n
    if (-not (Test-Path $src)) { throw "Prepatcher has no $n" }
    Copy-Item $src $pp -Recurse
}

foreach ($n in @('Mods\Multiplayer\About\About.xml', 'Mods\Multiplayer\1.6\Assemblies\Multiplayer.dll', 'Mods\Multiplayer\LoadFolders.xml', 'Mods\Prepatcher\Assemblies\PrepatcherImpl.dll', 'Mods\Prepatcher\About\About.xml')) {
    if (-not (Test-Path (Join-Path $mod $n))) { throw "the pack is missing $n" }
}

function Get-Sha256([string] $Path) { (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

$launcherMin = '0.3.22'
$packJson = [ordered]@{
    schema      = 2
    id          = 'rimworld'
    game        = 'rimworld'
    version     = $version
    upstream    = $mpVersion
    kind        = 'external'
    installDir  = '.'
    launcherMin = $launcherMin
}
[IO.File]::WriteAllText((Join-Path $stage 'pack.json'), (($packJson | ConvertTo-Json) + "`n"), (New-Object System.Text.UTF8Encoding($false)))

$lines = New-Object System.Collections.Generic.List[string]
foreach ($f in Get-ChildItem $mod -Recurse -File | Sort-Object FullName) {
    $rel = $f.FullName.Substring($mod.Length + 1)
    $lines.Add(('MOD|{0}|{1}|{2}' -f $rel, $f.Length, (Get-Sha256 $f.FullName)))
}
[IO.File]::WriteAllText((Join-Path $stage 'manifest.txt'), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

$zipName = "Cairn-Pack-rimworld-$version.zip"
$zipPath = Join-Path $release $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
$fs = [IO.File]::Open($zipPath, 'Create')
try {
    $z = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in Get-ChildItem $stage -Recurse -File) {
            $rel = $f.FullName.Substring($stage.Length + 1) -replace '\\', '/'
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $f.FullName, $rel, [System.IO.Compression.CompressionLevel]::Optimal)
        }
    } finally { $z.Dispose() }
} finally { $fs.Dispose() }

$index = [ordered]@{
    schema      = 2
    id          = 'rimworld'
    game        = 'rimworld'
    version     = $version
    upstream    = $mpVersion
    kind        = 'external'
    file        = $zipName
    sha256      = Get-Sha256 $zipPath
    size        = (Get-Item $zipPath).Length
    launcherMin = $launcherMin
}
[IO.File]::WriteAllText((Join-Path $release 'pack-index.json'), (($index | ConvertTo-Json) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "pack: $zipPath ($([math]::Round((Get-Item $zipPath).Length / 1MB, 1)) MB), version $version, Multiplayer $mpVersion, $($lines.Count) files"
