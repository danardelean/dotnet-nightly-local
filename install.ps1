#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
install.ps1 (dotnet-nightly-local): a .NET nightly SDK and any of its workloads in a folder of your choice.
PowerShell 7 on Windows, macOS or Linux; the same options and behaviour as install.sh.

.DESCRIPTION
Nothing is written to the machine-wide .NET install: the SDK, its runtime, the workload manifests and packs all land
in one folder (default ./.dotnet), and a global.json in the current directory makes the regular `dotnet` command
pick that SDK up from there ("sdk.paths", a .NET 10 SDK host feature). Run it again to update: a newer daily is
installed next to the old one, the manifests are refreshed, global.json is re-pinned (-Prune drops the old SDKs).
-Clean removes the folder and the global.json that points at it.

Builds (`dotnet build`, the IDE) find the SDK, the workload manifests and the packs through global.json. The
`dotnet workload ...` commands do not: they look at the folder of the dotnet executable that runs them, so run them
as DIR/dotnet workload list (or put DIR first on PATH).

How it works
  1. SDK: the aka.ms link of the SDK archive (https://aka.ms/dotnet/<channel>/<quality>/dotnet-sdk-<rid>.zip|tar.gz)
     redirects to the build's own URL, which carries the version; the archive and its .sha512 are downloaded and the
     archive is extracted with tar into DIR. Microsoft's dotnet-install scripts are not used: the .ps1 one is
     Windows-only and the .sh one is Unix-only.
  2. Manifests: a daily SDK bundles stale baseline workload manifests (preview-era iOS / MAUI, in an older band folder
     that it falls back to). For every manifest id the SDK lists (KnownWorkloadManifests.txt) the newest package of the
     SDK's own version band (<id>.Manifest-<band>) is downloaded from the feeds and placed in sdk-manifests/<band>/,
     what dotnet/maui's own build does. Builds of the band's own prerelease lane (its rc.N or preview.N label) win
     over other lanes that publish into the band.
  3. Compat manifests: the *-net<previous> workloads (pulled in by maui, ios, android, wasm-tools for apps on the
     previous .NET) reference the previous runtime the SDK was built with, often a servicing release that reaches
     nuget.org only on Patch Tuesday. They are pointed at the newest public one instead; they are not used to build
     for the new .NET anyway.
  4. Packs: `dotnet workload install` with --skip-manifest-update (exactly the manifests placed above) from the same
     feeds plus nuget.org. `dotnet workload clean` drops packs of replaced manifests.

.PARAMETER Dir
Install folder (default: ./.dotnet).
.PARAMETER Channel
Daily-build channel, a release/* branch of dotnet/dotnet without the prefix (see -ListChannels); required unless
-Version or -SkipSdk is given.
.PARAMETER Quality
daily | preview | ga (default: daily).
.PARAMETER Version
An exact SDK version instead of the newest build of the channel.
.PARAMETER Workloads
Workloads to install, comma-separated: maui, ios, android, maui-android, maui-windows, wasm-tools, aspire ...
(default: none, the SDK and the refreshed manifests only).
.PARAMETER MauiBranch
dotnet/maui branch whose NuGet.config lists the feeds its build uses: release branches of dotnet/macios and
dotnet/android publish to isolated darc-pub-* feeds, and that file names them. "auto" (default) derives it from the SDK
band: release/<major>.0.1xx-<label> for a preview or rc band, net<major>.0 for a release band, main for an alpha, plus
the previous major's release branches for an alpha (their isolated feeds hold the compat packs the alpha's iOS and
Android workloads still need);
"none" to skip.
.PARAMETER Feeds
Extra NuGet v3 feeds to search for manifests and packs, comma-separated.
.PARAMETER NoDefaultFeeds
Do not search the default feeds: the dotnet<major> feed on dnceng and nuget.org.
.PARAMETER CompatRuntime
Runtime version for the previous major's compat manifests (default: newest on nuget.org).
.PARAMETER NoGlobalJson
Do not write global.json in the current directory.
.PARAMETER SkipSdk
Do not (re)install the SDK; use the newest one already in DIR.
.PARAMETER ManifestsOnly
Stop after placing the manifests (no workload install).
.PARAMETER Prune
Remove older SDK, runtime and host versions from DIR.
.PARAMETER ListChannels
Show the channels that currently have daily builds, with today's SDK version, and exit.
.PARAMETER ListWorkloads
Show the manifests of the channel's band on the feeds and the workload ids each defines, without downloading the SDK
(with -Channel or -Version), and exit.
.PARAMETER Clean
Remove DIR and, when it points at DIR, the global.json in the current directory, and exit.
.PARAMETER DefineOnly
Dot-source the script for its functions and do nothing (used by test.ps1).

.EXAMPLE
./install.ps1 -Channel 11.0.1xx-rc2 -Workloads maui
.EXAMPLE
./install.ps1 -ListChannels
#>
[CmdletBinding()]
param(
  [string]$Dir = './.dotnet',
  [string]$Channel = '',
  [ValidateSet('daily', 'preview', 'ga')][string]$Quality = 'daily',
  [string]$Version = '',
  [string]$Workloads = '',
  [string]$MauiBranch = 'auto',
  [string]$Feeds = '',
  [switch]$NoDefaultFeeds,
  [string]$CompatRuntime = '',
  [switch]$NoGlobalJson,
  [switch]$SkipSdk,
  [switch]$ManifestsOnly,
  [switch]$Prune,
  [switch]$ListChannels,
  [switch]$ListWorkloads,
  [switch]$Clean,
  [switch]$DefineOnly,
  [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$NugetOrg = 'https://api.nuget.org/v3/index.json'
$Dnceng = 'https://pkgs.dev.azure.com/dnceng/public/_packaging'
$BuildsTableUrl = 'https://raw.githubusercontent.com/dotnet/dotnet/main/docs/builds-table.md'
$AkamsChannelsUrl = 'https://raw.githubusercontent.com/dotnet/arcade/main/src/Microsoft.DotNet.Build.Tasks.Feed/src/model/PublishingConstants.cs'
$HttpTimeout = 60

function Write-Log([string]$Message) { Write-Host $Message }
function Fail([string]$Message) { throw "error: $Message" }

# Version band of an SDK version: the patch number rounded down to the hundred and the preview/rc/alpha label kept,
# the build number and an rtm/servicing label dropped (X.Y.Zpp-<label>.N.<build> -> X.Y.Z00-<label>.N)
function Get-Band([string]$SdkVersion) {
  $SdkVersion -replace '^(\d+\.\d+\.\d)\d\d(-(preview|rc|alpha)\.\d+)?.*$', '${1}00${2}'
}
# Prerelease label of a band (rc.N, preview.N, alpha.N), empty for a release band
function Get-Label([string]$Band) { if ($Band.Contains('-')) { $Band.Substring($Band.IndexOf('-') + 1) } else { '' } }
function Get-Major([string]$SdkVersion) { [int](($SdkVersion -split '\.')[0]) }
# The dotnet/maui branch that builds against a band: release/<major>.0.1xx-<label without the dot> for a preview or
# rc band, net<major>.0 for a release band, main for an alpha band
function Get-MauiBranchFor([string]$Band) {
  $major = Get-Major $Band; $label = Get-Label $Band
  if (-not $label) { return "net$major.0" }
  if ($label -like 'alpha.*') { return 'main' }
  "release/$major.0.1xx-$($label -replace '\.', '')"
}
# The dotnet/maui branches whose NuGet.config to read for a band: the band's own branch and, for an alpha band, the
# previous major's release branches too (net<prev>.0 and the newest release/<prev>.0.1xx-*). main has not branched for
# the new major yet, and the alpha's iOS and Android workloads carry compat packs of the previous major's unreleased
# servicing builds, which sit on the isolated feeds only those branches name.
function Get-MauiBranchesFor([string]$Band) {
  $primary = Get-MauiBranchFor $Band; $out = @($primary)
  if ($primary -ne 'main' -or -not (Get-Command git -ErrorAction SilentlyContinue)) { return $out }
  $prev = (Get-Major $Band) - 1
  $heads = @(& git ls-remote --heads https://github.com/dotnet/maui "refs/heads/net$prev.0" "refs/heads/release/$prev.0.1xx-*" 2>$null |
    ForEach-Object { ($_ -split 'refs/heads/')[1] })
  if ($heads -contains "net$prev.0") { $out += "net$prev.0" }
  # the newest release branch by its label's SemVer precedence (rc2 above preview7)
  $releases = @($heads | ForEach-Object {
    if ($_ -match '^release/\d+\.0\.1xx-([a-z]+)(\d+)$') { [pscustomobject]@{ Version = "$prev.0.100-$($Matches[1]).$($Matches[2])"; Branch = $_ } } })
  $best = Select-Highest $releases
  if ($best) { $out += $best.Branch }
  $out
}

# NuGet v3 flat container: <feed>/flat2/<id>/index.json lists the versions, <feed>/flat2/<id>/<v>/<id>.<v>.nupkg is the package.
function Get-FlatUrl([string]$Feed) {
  if ($Feed -eq $NugetOrg) { 'https://api.nuget.org/v3-flatcontainer' } else { ($Feed -replace '/index\.json$', '') + '/flat2' }
}
function Get-PackageVersions([string]$Feed, [string]$PackageId) {
  try { @((Invoke-RestMethod -Uri "$(Get-FlatUrl $Feed)/$PackageId/index.json" -TimeoutSec $HttpTimeout).versions) } catch { @() }
}
# Raw text of a URL (Invoke-RestMethod would parse XML such as NuGet.config into an object)
function Get-Text([string]$Url) {
  try { [string](Invoke-WebRequest -Uri $Url -TimeoutSec $HttpTimeout).Content } catch { '' }
}

# Semantic Versioning precedence: numeric core, a release above its prereleases, prerelease fields compared one by
# one, numeric < alphanumeric. Returns -1, 0 or 1.
function Compare-Version([string]$A, [string]$B) {
  $coreA, $preA = $A -split '-', 2; $coreB, $preB = $B -split '-', 2
  $numA = $coreA -split '\.'; $numB = $coreB -split '\.'
  for ($i = 0; $i -lt 3; $i++) {
    $x = if ($i -lt $numA.Count) { [long]$numA[$i] } else { 0 }
    $y = if ($i -lt $numB.Count) { [long]$numB[$i] } else { 0 }
    if ($x -ne $y) { return [Math]::Sign($x - $y) }
  }
  if (-not $preA -and -not $preB) { return 0 }
  if (-not $preA) { return 1 }
  if (-not $preB) { return -1 }
  $fieldsA = $preA -split '\.'; $fieldsB = $preB -split '\.'
  for ($i = 0; $i -lt [Math]::Max($fieldsA.Count, $fieldsB.Count); $i++) {
    if ($i -ge $fieldsA.Count) { return -1 }
    if ($i -ge $fieldsB.Count) { return 1 }
    $x = $fieldsA[$i]; $y = $fieldsB[$i]
    $xNum = $x -match '^\d+$'; $yNum = $y -match '^\d+$'
    $c = if ($xNum -and $yNum) { [Math]::Sign([long]$x - [long]$y) }
         elseif ($xNum) { -1 } elseif ($yNum) { 1 }
         else { [Math]::Sign([string]::CompareOrdinal($x, $y)) }
    if ($c -ne 0) { return $c }
  }
  0
}
# The candidate (an object with a Version property) with the highest version, or $null
function Select-Highest($Candidates) {
  $best = $null
  foreach ($c in @($Candidates)) { if ($null -eq $best -or (Compare-Version $c.Version $best.Version) -gt 0) { $best = $c } }
  $best
}
# Highest of a list of plain version strings
function Select-HighestVersion([string[]]$Versions) {
  $best = Select-Highest @($Versions | ForEach-Object { [pscustomobject]@{ Version = $_ } })
  if ($best) { $best.Version } else { '' }
}

# Newest released MAJOR.0.x runtime on nuget.org (Microsoft.NETCore.App.Ref)
function Get-NewestPublicRuntime([int]$Major) {
  Select-HighestVersion @(Get-PackageVersions $NugetOrg 'microsoft.netcore.app.ref' | Where-Object { $_ -match "^$Major\.0\.\d+$" })
}

# The compat manifests of the previous major (*.net<PREV>) under DIR: point their <PREV>.0.x pack versions at VERSION
function Update-CompatManifests([string]$InstallDir, [int]$Prev, [string]$RuntimeVersion) {
  $manifestsRoot = Join-Path $InstallDir 'sdk-manifests'
  if (-not (Test-Path $manifestsRoot)) { return }
  foreach ($id in "microsoft.net.workload.mono.toolchain.net$Prev", "microsoft.net.workload.emscripten.net$Prev") {
    foreach ($manifest in Get-ChildItem -Path $manifestsRoot -Recurse -Filter 'WorkloadManifest.json' -File |
        Where-Object { $_.Directory.Parent.Name -eq $id }) {
      $text = Get-Content -Raw -Path $manifest.FullName
      if ($text -match "`"version`"\s*:\s*`"($Prev\.0\.\d+)`"") {
        $current = $Matches[1]
        if ($current -ne $RuntimeVersion) {
          Write-Log "  compat manifest ${id}: .NET $current -> $RuntimeVersion"
          $text = $text -replace ('"' + [regex]::Escape($current) + '"'), "`"$RuntimeVersion`""
          Set-Content -Path $manifest.FullName -Value $text -NoNewline -Encoding utf8
        }
      }
    }
  }
}

# Highest version folder under PATH
function Get-NewestDir([string]$Path) {
  if (-not (Test-Path $Path)) { return '' }
  Select-HighestVersion @(Get-ChildItem -Path $Path -Directory | ForEach-Object Name)
}

# Follows redirects with a HEAD request and returns the final URL ('' on failure)
function Resolve-Url([string]$Url) {
  try {
    $r = Invoke-WebRequest -Uri $Url -Method Head -MaximumRedirection 10 -TimeoutSec $HttpTimeout -SkipHttpErrorCheck
    $r.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
  } catch { '' }
}

# Channels. A channel is an aka.ms name that Arcade's publishing constants (dotnet/arcade, PublishingConstants.cs)
# assign to a build channel: X.Y.1xx for the X.Y.1xx SDK channel, X.Y.1xx-rc2 for its RC 2, X.Y.1xx-preview3 ... The
# .NET builds table (dotnet/dotnet, docs/builds-table.md) links the actively built ones, but it lags behind a branding
# change: when main moves to the next major its column keeps the old name for a while, so the old name serves the new
# major's alphas until the new release branch takes it over. So the candidates are the table's channels plus every SDK
# channel name Arcade declares for those majors and the next one, and each is probed; only the ones that resolve are
# shown (the table's own always are, with ? when they do not).
# A channel's current SDK version is read from the redirect of its archive link, which carries the version
# (.../Sdk/<version>/dotnet-sdk-<version>-<rid>.tar.gz). An unknown aka.ms path does not 404 but lands on a Microsoft
# search page, hence the pattern check.
function Get-ChannelVersion([string]$ChannelName, [string]$QualityName = 'daily') {
  $q = if ($QualityName -eq 'ga') { '' } else { "/$QualityName" }
  $url = Resolve-Url "https://aka.ms/dotnet/$ChannelName$q/dotnet-sdk-linux-x64.tar.gz"
  if ($url -match '/dotnet-sdk-(.+)-linux-x64\.tar\.gz$') { $Matches[1] } else { '?' }
}
function Get-TableChannels {
  @([regex]::Matches((Get-Text $BuildsTableUrl), 'aka\.ms/dotnet/([^/)" ]*)/daily') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}
function Get-ChannelCandidates {
  $table = Get-TableChannels
  if ($table.Count -eq 0) { Fail "could not read the builds table at $BuildsTableUrl" }
  $majors = @($table | ForEach-Object { [int](($_ -split '\.')[0]) } | Sort-Object -Unique)
  $wanted = $majors + ($majors[-1] + 1)
  $names = @([regex]::Matches((Get-Text $AkamsChannelsUrl), '"(\d+\.\d+\.\dxx[^"]*)"') | ForEach-Object { $_.Groups[1].Value })
  @($table + ($names | Where-Object { $wanted -contains [int](($_ -split '\.')[0]) }) | Sort-Object -Unique)
}
function Show-Channels {
  $table = Get-TableChannels
  Write-Log ('{0,-20} {1}' -f 'channel', 'current daily SDK')
  foreach ($ch in Get-ChannelCandidates) {
    $v = Get-ChannelVersion $ch
    if ($v -eq '?' -and $table -notcontains $ch) { continue }
    Write-Log ('{0,-20} {1}' -f $ch, $v)
  }
}

# ---- feeds and manifests ------------------------------------------------------------------------------------------------
# Short name of a feed for the log: the dnceng feed name, or nuget.org
function Get-FeedName([string]$Feed) { if ($Feed -eq $NugetOrg) { 'nuget.org' } else { $Feed -replace '.*/_packaging/([^/]*)/.*', '$1' } }

# The feeds for a band: the dotnet<major> feed and nuget.org (a released preview or RC has its manifests there), then
# the feeds of dotnet/maui's branches (dotnet<major>-transport and the isolated darc-pub-* ones). Logs them.
function Get-FeedList([int]$Major, [string]$Band) {
  $feedList = [System.Collections.Generic.List[string]]::new()
  $add = { param($Feed) if ($Feed -and -not $feedList.Contains($Feed)) { $feedList.Add($Feed) } }
  if (-not $NoDefaultFeeds) { & $add "$Dnceng/dotnet$Major/nuget/v3/index.json"; & $add $NugetOrg }
  $branches = if ($MauiBranch -eq 'auto') { @(Get-MauiBranchesFor $Band) } else { @($MauiBranch) }
  if ($branches[0] -ne 'none') {
    $pattern = "dotnet$Major[^/]*|darc-pub-[^/]*"
    foreach ($branch in $branches) {
      $config = Get-Text "https://raw.githubusercontent.com/dotnet/maui/$branch/NuGet.config"
      foreach ($m in [regex]::Matches([string]$config, 'value="(https://pkgs\.dev\.azure\.com/dnceng/public/_packaging/[^"]*)"')) {
        $f = $m.Groups[1].Value
        if ($f -match "/($pattern)/nuget/v3/index\.json$") { & $add $f }
      }
      $pattern = 'darc-pub-[^/]*'   # a previous-major branch contributes its isolated feeds only
    }
  }
  foreach ($f in ($Feeds -split ',')) { & $add $f.Trim() }
  if ($feedList.Count -eq 0) { Fail 'no feeds to search (see -Feeds)' }
  Write-Log 'Feeds:'
  if ($branches[0] -ne 'none') { Write-Log "  (from dotnet/maui NuGet.config: $($branches -join ' '))" }
  foreach ($f in $feedList) { Write-Log "  $f" }
  return ,$feedList
}

# The newest build of manifest package PKG across the feeds ({ Version; Feed } or $null). Builds of the band's own
# prerelease lane come first: other lanes publish into the band too, and a preview build from main can outrank the
# band's rc build by version alone.
function Select-ManifestVersion([string]$Pkg, $FeedList, [string]$Label) {
  $candidates = @()
  foreach ($f in $FeedList) { foreach ($v in Get-PackageVersions $f $Pkg) { $candidates += [pscustomobject]@{ Version = [string]$v; Feed = $f } } }
  if ($Label) {
    $lane = @($candidates | Where-Object { $_.Version.Contains($Label) })
    if ($lane.Count -gt 0) { $candidates = $lane }
  }
  Select-Highest $candidates
}

# The manifest ids to look for on the feeds, lowercase: every *.Manifest-<band> package the dnceng feeds list through
# their package search (a substring query), plus the ids an SDK of this major lists in its KnownWorkloadManifests.txt
# (nuget.org's search does not return these packages, its flat index does; each id is then probed on every feed and
# the absent ones are skipped).
function Find-ManifestIds($FeedList, [string]$Band, [int]$Major) {
  $names = @()
  foreach ($f in $FeedList) {
    if (-not $f.StartsWith($Dnceng)) { continue }
    try {
      $name = Get-FeedName $f
      $r = Invoke-RestMethod -Uri "https://feeds.dev.azure.com/dnceng/public/_apis/packaging/feeds/$name/packages?packageNameQuery=manifest-$Band&api-version=7.1&`$top=500" -TimeoutSec $HttpTimeout
      $names += @($r.value | ForEach-Object name)
    } catch { }
  }
  $suffix = ".manifest-$Band"
  $ids = @($names | ForEach-Object { $_.ToLowerInvariant() } | Where-Object { $_.EndsWith($suffix) -and -not $_.Contains('.msi.') } |
    ForEach-Object { $_.Substring(0, $_.Length - $suffix.Length) })
  $ids += @('android', 'ios', 'maccatalyst', 'macos', 'tvos', 'maui' | ForEach-Object { "microsoft.net.sdk.$_" })
  foreach ($n in @('current') + @(6..($Major - 1) | ForEach-Object { "net$_" })) {
    $ids += "microsoft.net.workload.mono.toolchain.$n"; $ids += "microsoft.net.workload.emscripten.$n"
  }
  @($ids | Sort-Object -Unique)
}

# The workload ids a WorkloadManifest.json defines, abstract ones excluded (ConvertFrom-Json takes the files' comments
# and trailing commas)
function Get-ManifestWorkloads([string]$Path) {
  $d = Get-Content -Raw $Path | ConvertFrom-Json
  if (-not $d.PSObject.Properties['workloads']) { return @() }
  @($d.workloads.PSObject.Properties | Where-Object { -not ($_.Value.PSObject.Properties['abstract'] -and $_.Value.abstract) } | ForEach-Object Name | Sort-Object)
}

# -ListWorkloads: the manifests of a channel's band on the feeds and the workload ids each defines, without downloading
# the SDK. The SDK version comes from the channel's archive link (or -Version), the band from it, the feeds as for an
# install.
function Show-Workloads {
  if (-not $Channel -and -not $Version) { Fail 'choose a channel with -Channel (or an exact SDK with -Version) to list its workloads' }
  $sdkVersion = $Version
  if (-not $sdkVersion) {
    $sdkVersion = Get-ChannelVersion $Channel $Quality
    if ($sdkVersion -eq '?') { Fail "no SDK archive behind https://aka.ms/dotnet/$Channel (see -ListChannels)" }
  }
  $band = Get-Band $sdkVersion; $label = Get-Label $band; $major = Get-Major $sdkVersion
  Write-Log "SDK $sdkVersion (band $band)$(if ($Channel) { ", channel $Channel" })"
  $feedList = Get-FeedList $major $band
  Write-Log "Manifests ($band) and the workloads each defines:"
  $ids = @(Find-ManifestIds $feedList $band $major)
  if ($ids.Count -eq 0) { Fail "no *.manifest-$band package on any of the feeds" }
  $work = Join-Path ([IO.Path]::GetTempPath()) ("dotnet-nightly-" + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  $found = @()
  try {
    foreach ($id in $ids) {
      $pkg = "$id.manifest-$band"
      $best = Select-ManifestVersion $pkg $feedList $label
      if ($null -eq $best) { continue }
      $zip = Join-Path $work "$pkg.zip"
      Invoke-WebRequest -Uri "$(Get-FlatUrl $best.Feed)/$pkg/$($best.Version)/$pkg.$($best.Version).nupkg" -OutFile $zip -TimeoutSec $HttpTimeout
      $extract = Join-Path $work $pkg
      Expand-Archive -Path $zip -DestinationPath $extract -Force
      Write-Log "  ${id}: $($best.Version)  ($(Get-FeedName $best.Feed))"
      $manifest = Join-Path (Join-Path $extract 'data') 'WorkloadManifest.json'
      $workloads = @(if (Test-Path $manifest) { Get-ManifestWorkloads $manifest })
      Write-Log "      $(if ($workloads.Count -gt 0) { $workloads -join ' ' } else { '(abstract workloads only: extended by others)' })"
      $found += $id
    }
  } finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
  }
  # the ids an SDK with the mobile workloads knows, so that a lane that lacks one says so
  $missing = @(@('microsoft.net.sdk.android', 'microsoft.net.sdk.ios', 'microsoft.net.sdk.maccatalyst', 'microsoft.net.sdk.macos', 'microsoft.net.sdk.tvos', 'microsoft.net.sdk.maui') | Where-Object { $found -notcontains $_ })
  if ($missing.Count -gt 0) { Write-Log "Not on any of the feeds for this band: $($missing -join ' ')" }
  Write-Log "Install: $PSCommandPath $(if ($Channel) { "-Channel $Channel " })$(if ($Version) { "-Version $Version " })-Workloads <id,id,...>"
}

# ---- SDK --------------------------------------------------------------------------------------------------------------
function Get-Rid {
  $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
  $os = if ($IsWindows) { 'win' } elseif ($IsMacOS) { 'osx' } else { 'linux' }
  "$os-$arch"
}
function Get-DotnetExe([string]$InstallDir) {
  if ($IsWindows) {
    foreach ($name in 'dotnet.exe', 'dotnet.cmd', 'dotnet.bat') { $p = Join-Path $InstallDir $name; if (Test-Path $p) { return $p } }
    return Join-Path $InstallDir 'dotnet.exe'
  }
  Join-Path $InstallDir 'dotnet'
}
function Install-Sdk([string]$InstallDir, [string]$ChannelName, [string]$QualityName, [string]$ExactVersion, [string]$Work) {
  $rid = Get-Rid; $ext = if ($IsWindows) { 'zip' } else { 'tar.gz' }
  if ($ExactVersion) {
    # released builds live on builds.dotnet.microsoft.com, dailies on ci.dot.net/public
    $url = ''
    foreach ($base in 'https://builds.dotnet.microsoft.com/dotnet', 'https://ci.dot.net/public') {
      $candidate = "$base/Sdk/$ExactVersion/dotnet-sdk-$ExactVersion-$rid.$ext"
      try {
        $r = Invoke-WebRequest -Uri $candidate -Method Head -TimeoutSec $HttpTimeout -SkipHttpErrorCheck
        if ($r.StatusCode -eq 200) { $url = $candidate; break }
      } catch { }
    }
    if (-not $url) { Fail "SDK $ExactVersion for $rid was not found on builds.dotnet.microsoft.com or ci.dot.net" }
  } else {
    $q = if ($QualityName -eq 'ga') { '' } else { "/$QualityName" }
    $url = Resolve-Url "https://aka.ms/dotnet/$ChannelName$q/dotnet-sdk-$rid.$ext"
  }
  if ($url -notmatch ('/dotnet-sdk-(.+)-' + [regex]::Escape("$rid.$ext") + '$')) { Fail "no SDK archive behind https://aka.ms/dotnet/$ChannelName (see -ListChannels)" }
  $sdkVersion = $Matches[1]
  if (Test-Path (Join-Path (Join-Path $InstallDir 'sdk') $sdkVersion)) { Write-Log "SDK $sdkVersion is already installed."; return }
  Write-Log "Downloading SDK $sdkVersion ($rid) from $url"
  $archive = Join-Path $Work "dotnet-sdk.$ext"
  Invoke-WebRequest -Uri $url -OutFile $archive -TimeoutSec 1800
  $expected = (Get-Text "$url.sha512") -split '\s+' | Select-Object -First 1
  if ($expected) {
    $actual = (Get-FileHash -Path $archive -Algorithm SHA512).Hash
    if ($actual -ne $expected.ToUpperInvariant()) { Fail "checksum mismatch for $url" }
  } else { Write-Log "  (no .sha512 next to the archive: checksum not verified)" }
  if (-not (Get-Command tar -ErrorAction SilentlyContinue)) { Fail 'tar is required to extract the SDK archive' }
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  & tar -xf $archive -C $InstallDir
  if ($LASTEXITCODE -ne 0) { Fail "tar failed to extract $archive" }
}

# ---- main -------------------------------------------------------------------------------------------------------------
function Invoke-Main {
  if ($Clean) {
    if (-not (Test-Path $Dir)) { Fail "$Dir does not exist" }
    $dirAbs = (Resolve-Path $Dir).Path
    # only a folder this script could have made: a dotnet executable or an sdk/ folder inside
    $looksLikeDotnet = (Test-Path (Join-Path $dirAbs 'dotnet')) -or (Test-Path (Join-Path $dirAbs 'dotnet.exe')) -or (Test-Path (Join-Path $dirAbs 'sdk'))
    if (-not $looksLikeDotnet) { Fail "$dirAbs does not look like a .NET folder (no dotnet executable, no sdk/): not removing it" }
    Remove-Item -Recurse -Force $dirAbs
    Write-Log "Removed $dirAbs"
    $cwd = (Get-Location).Path
    $rel = $dirAbs
    if ($dirAbs.StartsWith($cwd + [IO.Path]::DirectorySeparatorChar)) { $rel = $dirAbs.Substring($cwd.Length + 1) }
    $rel = $rel -replace '\\', '/'
    $globalJson = Join-Path $cwd 'global.json'
    if ((Test-Path $globalJson) -and ([string](Get-Content -Raw $globalJson)).Contains("`"$rel`"")) {
      Remove-Item -Force $globalJson
      Write-Log "Removed global.json (it pointed at $rel)"
    }
    return
  }
  if (-not $SkipSdk -and -not $Channel -and -not $Version) {
    Fail "choose a daily-build channel with -Channel (or an exact SDK with -Version). The channels with dailies: $PSCommandPath -ListChannels"
  }
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  $dirAbs = (Resolve-Path $Dir).Path
  $work = Join-Path ([IO.Path]::GetTempPath()) ("dotnet-nightly-" + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  try {
    # ---- 1. SDK ------------------------------------------------------------------------------------------------------
    if (-not $SkipSdk) { Install-Sdk $dirAbs $Channel $Quality $Version $work }
    $dotnetExe = Get-DotnetExe $dirAbs
    if (-not (Test-Path $dotnetExe)) { Fail "no dotnet in $dirAbs" }
    # The newest SDK in the folder, from the folder itself: `dotnet --version` would obey a global.json pinned to an older one
    $sdkVersion = Get-NewestDir (Join-Path $dirAbs 'sdk')
    if (-not $sdkVersion) { Fail "no SDK in $dirAbs/sdk" }
    $band = Get-Band $sdkVersion; $label = Get-Label $band; $major = Get-Major $sdkVersion; $prev = $major - 1
    $manifestsDir = Join-Path (Join-Path $dirAbs 'sdk-manifests') $band
    Write-Log "SDK $sdkVersion (band $band) in $dirAbs"
    New-Item -ItemType Directory -Force -Path $manifestsDir | Out-Null
    # dotnet commands run from an empty directory: a global.json up the tree would select another SDK
    $runDir = Join-Path $work 'run'; New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    function Invoke-Dotnet([string[]]$Arguments, [switch]$IgnoreFailure) {
      Push-Location $runDir
      try {
        $env:DOTNET_ROOT = $dirAbs; $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_NOLOGO = '1'
        & $dotnetExe @Arguments
        if ($LASTEXITCODE -ne 0 -and -not $IgnoreFailure) { Fail "dotnet $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
      } finally { Pop-Location }
    }

    # ---- 2. Feeds ----------------------------------------------------------------------------------------------------
    $feedList = Get-FeedList $major $band

    # ---- 3. Manifests of this band -----------------------------------------------------------------------------------
    $manifestsChanged = $false
    $sdkDir = Join-Path (Join-Path $dirAbs 'sdk') $sdkVersion
    $ids = @()
    foreach ($name in 'KnownWorkloadManifests.txt', 'IncludedWorkloadManifests.txt') {
      $p = Join-Path $sdkDir $name
      if (Test-Path $p) { $ids = @(Get-Content $p); break }
    }
    if ($ids.Count -eq 0) {
      $ids = @(Get-ChildItem -Path (Join-Path $dirAbs 'sdk-manifests') -Directory | Get-ChildItem -Directory | ForEach-Object Name | Where-Object { $_ -ne 'workloadsets' } | Sort-Object -Unique)
    }
    Write-Log "Manifests ($band):"
    foreach ($rawId in $ids) {
      $id = $rawId.Trim().ToLowerInvariant()
      if (-not $id) { continue }
      $pkg = "$id.manifest-$band"
      $best = Select-ManifestVersion $pkg $feedList $label
      if ($null -eq $best) {
        $have = @(Get-ChildItem -Path (Join-Path $dirAbs 'sdk-manifests') -Directory -ErrorAction SilentlyContinue |
          ForEach-Object { Join-Path $_.FullName $id } | Where-Object { Test-Path $_ } |
          ForEach-Object { Get-ChildItem $_ -Directory | ForEach-Object FullName }) | Select-Object -Last 1
        Write-Log "  ${id}: no $pkg on any feed, keeping the SDK's $(if ($have) { $have } else { '<none>' })"
        continue
      }
      $target = Join-Path $manifestsDir $id
      if (Test-Path (Join-Path $target $best.Version)) { Write-Log "  ${id}: $($best.Version) (present)"; continue }
      Write-Log "  ${id}: $($best.Version)  ($(Get-FeedName $best.Feed))"
      $zip = Join-Path $work "$pkg.zip"
      Invoke-WebRequest -Uri "$(Get-FlatUrl $best.Feed)/$pkg/$($best.Version)/$pkg.$($best.Version).nupkg" -OutFile $zip -TimeoutSec $HttpTimeout
      $extract = Join-Path $work 'pkg'
      if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
      Expand-Archive -Path $zip -DestinationPath $extract
      if (Test-Path $target) { Remove-Item -Recurse -Force $target }
      $dest = Join-Path $target $best.Version
      New-Item -ItemType Directory -Force -Path $dest | Out-Null
      Copy-Item -Path (Join-Path (Join-Path $extract 'data') '*') -Destination $dest -Recurse -Force
      $manifestsChanged = $true
    }
    # manifest versions pinned by an earlier install would override the folders above
    $pin = Join-Path $dirAbs "metadata/workloads/$band/InstallState/default.json"
    if (Test-Path $pin) { Remove-Item -Force $pin }

    # ---- 4. Compat manifests of the previous major -------------------------------------------------------------------
    $compat = if ($CompatRuntime) { $CompatRuntime } else { Get-NewestPublicRuntime $prev }
    if ($compat) { Update-CompatManifests $dirAbs $prev $compat }
    else { Write-Log "  (no public .NET $prev runtime found on nuget.org: compat manifests left as they are)" }

    # ---- 5. Packs ----------------------------------------------------------------------------------------------------
    if (-not $feedList.Contains($NugetOrg)) { $feedList.Add($NugetOrg) }   # packs of released runtimes and tools
    $sources = @(); foreach ($f in $feedList) { $sources += '--source'; $sources += $f }
    $workloadList = @(($Workloads -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    # a workload no manifest of the band defines (no maui on an alpha yet) is skipped: the installer would otherwise
    # take it from the SDK's older bundled manifest
    if ($workloadList.Count -gt 0) {
      $known = @(Get-ChildItem -Path $manifestsDir -Recurse -Filter 'WorkloadManifest.json' -File | ForEach-Object { Get-ManifestWorkloads $_.FullName })
      $workloadList = @($workloadList | Where-Object {
        if ($known -contains $_) { $true } else { Write-Log "  workload ${_}: no manifest of band $band defines it, skipped (see -ListWorkloads)"; $false } })
    }
    if ($ManifestsOnly -or $workloadList.Count -eq 0) {
      if (-not $Workloads) { Write-Log "No workloads requested (-Workloads). Later: $dotnetExe workload install <id> --skip-manifest-update --skip-sign-check $($sources -join ' ')" }
    } else {
      Invoke-Dotnet (@('workload', 'install') + $workloadList + @('--skip-manifest-update', '--skip-sign-check') + $sources)
      Invoke-Dotnet @('workload', 'clean') -IgnoreFailure | Out-Null
      Invoke-Dotnet @('workload', 'list')
    }
    # MSBuild nodes and compiler servers started by this SDK outlive a build and keep the manifests they loaded: a
    # build after a refresh would still import the targets of a manifest version that is gone
    if ($manifestsChanged -or (-not $ManifestsOnly -and $workloadList.Count -gt 0)) {
      Invoke-Dotnet @('build-server', 'shutdown') -IgnoreFailure | Out-Null
    }

    # ---- 6. Prune ----------------------------------------------------------------------------------------------------
    if ($Prune) {
      foreach ($sub in 'sdk', 'shared/Microsoft.NETCore.App', 'shared/Microsoft.AspNetCore.App', 'host/fxr') {
        $p = Join-Path $dirAbs $sub
        if (-not (Test-Path $p)) { continue }
        $keep = Get-NewestDir $p
        foreach ($d in Get-ChildItem -Path $p -Directory) {
          if ($d.Name -ne $keep) { Write-Log "  pruning $sub/$($d.Name)"; Remove-Item -Recurse -Force $d.FullName }
        }
      }
    }

    # ---- 7. global.json ----------------------------------------------------------------------------------------------
    if (-not $NoGlobalJson) {
      $cwd = (Get-Location).Path
      $rel = $dirAbs
      if ($dirAbs.StartsWith($cwd + [IO.Path]::DirectorySeparatorChar)) { $rel = $dirAbs.Substring($cwd.Length + 1) }
      $rel = $rel -replace '\\', '/'
      $json = @"
{
  "sdk": {
    "version": "$sdkVersion",
    "paths": [ "$rel", "`$host`$" ],
    "errorMessage": "The .NET SDK $sdkVersion was not found in ${rel}: run the install script again."
  }
}
"@
      Set-Content -Path (Join-Path $cwd 'global.json') -Value $json -Encoding utf8
      Write-Log "global.json: SDK $sdkVersion from $rel"
    }
    Write-Log "Manifests in ${manifestsDir}:"
    foreach ($d in Get-ChildItem -Path $manifestsDir -Directory) {
      if ($d.Name -eq 'workloadsets') { continue }
      Write-Log "  $($d.Name): $(((Get-ChildItem $d.FullName -Directory | ForEach-Object Name) -join ' ')) "
    }
    Write-Log "Workload commands look at the folder of the dotnet that runs them: use $dotnetExe workload list (builds need nothing)."
    Write-Log "If a restore fails with NU1102 on packages of this SDK's version, list its feed in a NuGet.config next to the project: $Dnceng/dotnet$major/nuget/v3/index.json"
  } finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
  }
}

if ($DefineOnly) { return }
if ($Help) { Get-Help $PSCommandPath -Detailed | Out-String | Write-Host; return }
if ($ListChannels) { Show-Channels; return }
if ($ListWorkloads) { Show-Workloads; return }
Invoke-Main
