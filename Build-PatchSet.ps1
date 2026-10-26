<#
.SYNOPSIS
Packages a release tag plus every fix branch for Windows and installs the package.

.DESCRIPTION
1. Checks out the merged commit (printed by Update-PatchSet.ps1 as merged=<commit>) detached
   in the build worktree, <repo>/.worktrees/build. The merge is a dangling commit; the build
   worktree's HEAD keeps it.
2. Runs RMUX's own scripts/package-windows.ps1 there. It builds the full helper and the
   daemon, then the tiny dispatcher (feature tiny-cli), all with a static CRT, and writes
   rmux-<version>-windows-x86_64.zip under <build>/target/dist (or $env:CARGO_TARGET_DIR).
   The repository pins its toolchain in rust-toolchain.toml; -Toolchain overrides it through
   RUSTUP_TOOLCHAIN when the pinned one is not installed.
3. Expands the zip into a new versioned folder under -InstallRoot, named
   <version>+<merged commit>, and points -InstallRoot/current at it with a directory
   junction. The three binaries (rmux.exe, libexec/rmux/rmux.exe, rmux-daemon.exe) ship
   together and stay together.
4. With -TmuxName, also writes -InstallRoot/<version folder>/tmux-bin/tmux.exe as a copy of
   the full helper, for callers that run "tmux".

With -KeepCurrent, -InstallRoot/current stays where it is, so a new build can be tried from
its own folder before callers move to it.

Older version folders are kept; move them away by hand when no server runs from them.

.EXAMPLE
pwsh Build-PatchSet.ps1 -Merged 1a2b3c4d -InstallRoot D:\tools\rmux -Toolchain stable -TmuxName
#>
#Requires -Version 7.4
param(
    [Parameter(Mandatory)]
    [string] $Merged,
    [Parameter(Mandatory)]
    [string] $InstallRoot,
    [string] $Toolchain = '',
    [int] $Jobs = 4,
    [switch] $TmuxName,
    [switch] $KeepCurrent
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$repo = git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir | Split-Path -Parent
$build = Join-Path $repo '.worktrees/build'
$commit = git -C $repo rev-parse "$Merged^{commit}"
if (Test-Path $build) { git -C $build checkout --quiet --detach $commit }
else { git -C $repo worktree add --quiet --detach $build $commit }

if ($Toolchain) { $env:RUSTUP_TOOLCHAIN = $Toolchain }
$env:CARGO_BUILD_JOBS = "$Jobs"
Push-Location $build
try {
    $output = & pwsh -NoProfile -File scripts/package-windows.ps1 -Configuration release
    if ($LASTEXITCODE -ne 0) { throw "scripts/package-windows.ps1 failed." }
}
finally { Pop-Location }
$package = ($output | Where-Object { $_ -like 'package=*' } | Select-Object -First 1).Substring(8)

$version = (Split-Path $package -LeafBase) -replace '^rmux-(.+)-windows-.+$', '$1'
$folder = Join-Path $InstallRoot "$version+$($commit.Substring(0, 8))"
if (Test-Path $folder) { throw "$folder exists. Move it away first." }
$expanded = Join-Path $InstallRoot (Split-Path $package -LeafBase)
if (Test-Path $expanded) { throw "$expanded exists. Move it away first." }
Expand-Archive -LiteralPath $package -DestinationPath $InstallRoot
Move-Item $expanded $folder
if ($TmuxName) {
    New-Item -ItemType Directory (Join-Path $folder 'tmux-bin') | Out-Null
    Copy-Item (Join-Path $folder 'libexec/rmux/rmux.exe') (Join-Path $folder 'tmux-bin/tmux.exe')
}
$current = Join-Path $InstallRoot 'current'
if (-not $KeepCurrent) {
    if (Test-Path $current) {
        Move-Item $current (Join-Path $InstallRoot "previous-$(Get-Date -Format yyyyMMddHHmmss)")
    }
    New-Item -ItemType Junction -Path $current -Target $folder | Out-Null
}

Write-Output "installed=$folder"
Write-Output "current=$((Get-Item $current -ErrorAction SilentlyContinue).Target)"
$output | Where-Object { $_ -match '^(package|sha256|binary_sha256|helper_binary_sha256|daemon_binary_sha256)=' }
