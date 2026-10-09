#!/usr/bin/env pwsh
#Requires -Version 7.0
# Tests for install.ps1 that need no Microsoft download: the pure functions, then end-to-end runs on a fake SDK folder
# (a fake `dotnet` that logs its calls) with the real RC1-band manifests from nuget.org, and the feed discovery from
# dotnet/maui's NuGet.config. Needs PowerShell 7 and access to nuget.org and GitHub. Windows, macOS or Linux.
#   ./test.ps1
param([string]$Script = (Join-Path $PSScriptRoot 'install.ps1'))
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Script = (Resolve-Path $Script).Path
$pwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$script:pass = 0; $script:fail = 0

function Ok([string]$Name) { $script:pass++; Write-Host "  ok   $Name" }
function Bad([string]$Name, $Got) { $script:fail++; Write-Host "  FAIL $Name`n       got: $Got" }
function Check([string]$Name, $Expected, $Actual) {
  if ("$Expected" -eq "$Actual") { Ok $Name } else { Bad "$Name (expected: $Expected)" $Actual }
}
# Runs install.ps1 in a child pwsh (real exit code, real stdout/stderr) from a working directory
function Run([string]$WorkingDirectory, [string[]]$Arguments) {
  $out = New-TemporaryFile; $err = New-TemporaryFile
  $p = Start-Process -FilePath $pwsh -ArgumentList (@('-NoProfile', '-NonInteractive', '-File', $Script) + $Arguments) `
    -WorkingDirectory $WorkingDirectory -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -Wait -NoNewWindow
  $lines = @(Get-Content $out) + @(Get-Content $err)
  Remove-Item $out, $err -Force
  [pscustomobject]@{ Lines = $lines; Text = ($lines -join "`n"); ExitCode = $p.ExitCode }
}
function CountMatching($Lines, [string]$Pattern) { @($Lines | Where-Object { $_ -match $Pattern }).Count }
# The path a child process started in $Path reports as its working directory. On macOS /var/folders is a symlink to
# /private/var/folders: the OS resolves it for the child, Resolve-Path does not.
function PhysicalPath([string]$Path) {
  $prev = [IO.Directory]::GetCurrentDirectory()
  try { [IO.Directory]::SetCurrentDirectory($Path); [IO.Directory]::GetCurrentDirectory() }
  finally { [IO.Directory]::SetCurrentDirectory($prev) }
}
$nuget = 'https://api.nuget.org/v3/index.json'

Write-Host '== functions'
. $Script -DefineOnly
Check 'band rc.2'        '11.0.100-rc.2'      (Get-Band '11.0.100-rc.2.26504.105')
Check 'band rtm'         '11.0.100'           (Get-Band '11.0.100-rtm.26480.113')
Check 'band preview'     '11.0.100-preview.7' (Get-Band '11.0.100-preview.7.26380.1')
Check 'band alpha 12'    '12.0.100-alpha.1'   (Get-Band '12.0.100-alpha.1.26480.102')
Check 'band release'     '11.0.100'           (Get-Band '11.0.100')
Check 'band 2xx'         '11.0.200-rc.1'      (Get-Band '11.0.201-rc.1.26500.1')
Check 'label rc.2'       'rc.2'               (Get-Label '11.0.100-rc.2')
Check 'label none'       ''                   (Get-Label '11.0.100')
Check 'major'            '11'                 (Get-Major '11.0.100-rc.2.26504.105')
Check 'maui branch rc.2'    'release/11.0.1xx-rc2'      (Get-MauiBranchFor '11.0.100-rc.2')
Check 'maui branch preview' 'release/11.0.1xx-preview7' (Get-MauiBranchFor '11.0.100-preview.7')
Check 'maui branch release' 'net11.0'                   (Get-MauiBranchFor '11.0.100')
Check 'maui branch alpha'   'main'                      (Get-MauiBranchFor '12.0.100-alpha.1')
# an alpha band also reads the previous major's release branches (network: git ls-remote dotnet/maui); the newest
# release branch is pinned to what exists today
Check 'maui branches rc.2: the band''s branch only' 'release/11.0.1xx-rc2' ((Get-MauiBranchesFor '11.0.100-rc.2') -join ' ')
Check 'maui branches alpha: main + previous major'  'main net11.0 release/11.0.1xx-rc2' ((Get-MauiBranchesFor '12.0.100-alpha.1') -join ' ')
Check 'flat nuget.org'   'https://api.nuget.org/v3-flatcontainer' (Get-FlatUrl $nuget)
Check 'flat dnceng'      'https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet11/nuget/v3/flat2' (Get-FlatUrl 'https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet11/nuget/v3/index.json')
Check 'pick rc over preview' '11.0.0-rc.2.26504.105' (Select-HighestVersion @('11.0.0-preview.7.26471.7', '11.0.0-rc.2.26504.105', '11.0.0-rc.2.26480.1'))
Check 'pick core'        '27.0.12211-net11-rc.2' (Select-HighestVersion @('26.5.12253-net11-rc.2', '27.0.12211-net11-rc.2', '27.0.12195-net11-rc.2'))
Check 'pick release > rc' '11.0.0'            (Select-HighestVersion @('11.0.0-rc.2.26504.105', '11.0.0'))
Check 'pick build number' '11.0.100-rc.2.26502.119' (Select-HighestVersion @('11.0.100-rc.2.26425.128', '11.0.100-rc.2.26502.119'))
Check 'pick empty'       ''                   (Select-HighestVersion @())
Check 'pick keeps the feed' 'B' (Select-Highest @([pscustomobject]@{ Version = '1.0.0-rc.1'; Feed = 'A' }, [pscustomobject]@{ Version = '1.0.0-rc.2'; Feed = 'B' })).Feed
$newest10 = Get-NewestPublicRuntime 10
Check 'newest public .NET 10 runtime (nuget.org)' '10.0.' $newest10.Substring(0, 5)
Check 'newest public .NET 10 runtime is a release' $false $newest10.Contains('-')
Check 'no public .NET 99 runtime: empty, no error' '' (Get-NewestPublicRuntime 99)

Write-Host '== channels from the builds table (network: GitHub; aka.ms versions may be unreachable)'
$channels = Run (Get-Location).Path @('-ListChannels')
$channels.Lines | ForEach-Object { Write-Host "     | $_" }
Check 'exit code'          '0' $channels.ExitCode
Check 'header'             ('{0,-20} {1}' -f 'channel', 'current daily SDK') $channels.Lines[0]
Check 'rc2 channel listed'  '1' (CountMatching $channels.Lines '^11\.0\.1xx-rc2 ')
Check 'main channel listed' '1' (CountMatching $channels.Lines '^11\.0\.1xx ')
Check 'channel names look like channels' '0' (CountMatching ($channels.Lines | Select-Object -Skip 1 | ForEach-Object { ($_ -split ' +')[0] }) '^(?!\d+\.\d+\.\dxx(-[a-z0-9]+)?$)')
Check 'versions are versions or ?, never a web page' '0' (CountMatching ($channels.Lines | Select-Object -Skip 1 | ForEach-Object { ($_ -split ' +')[1] }) '^(?!(\?|\d+\.\d+\.\d+(-[A-Za-z0-9.]+)?)$)')
Check 'channel_version: unknown channel gives ?' '?' (Get-ChannelVersion 'no.such.channel')
$candidates = @(Get-ChannelCandidates)
Check 'candidates: table channel'           '1' (CountMatching $candidates '^11\.0\.1xx-rc2$')
Check 'candidates: Arcade name, next major' '1' (CountMatching $candidates '^12\.0\.1xx$')
Check 'candidates: Arcade name, preview'    '1' (CountMatching $candidates '^11\.0\.1xx-preview7$')
Check 'candidates: no old majors'           '0' (CountMatching $candidates '^\d\.')

Write-Host '== channel required'
$r = Run (Get-Location).Path @('-NoGlobalJson')
Check 'no channel: exit 1' '1' $r.ExitCode
Check 'no channel: points at -ListChannels' $true (($r.Text -replace '\s+', ' ') -match '-Channel .*-ListChannels')
Check 'no dated default anywhere' '0' (CountMatching (Get-Content $Script) '\d+\.\d+\.\d{3}[-.][a-z0-9.]*\d{5}')

Write-Host '== compat manifest patch'
$t = Join-Path ([IO.Path]::GetTempPath()) ("nightly-test-" + [Guid]::NewGuid().ToString('N'))
$m = Join-Path $t 'sdk-manifests/11.0.100-rc.2/microsoft.net.workload.mono.toolchain.net10/11.0.100-rc.2.1'
New-Item -ItemType Directory -Force -Path $m | Out-Null
Set-Content -Path (Join-Path $m 'WorkloadManifest.json') -Value '{ "version": "10.0.99", "packs": { "Microsoft.NETCore.App.Runtime.Mono.android-x64": { "kind": "framework", "version": "10.0.99" }, "Microsoft.NET.Runtime.MonoAOTCompiler.Task": { "kind": "Sdk", "version": "10.0.99" } } }' -NoNewline
$patchLog = @(Update-CompatManifests $t 10 '10.0.12' 6>&1 | ForEach-Object { "$_" })
Check 'patch logs'       '  compat manifest microsoft.net.workload.mono.toolchain.net10: .NET 10.0.99 -> 10.0.12' ($patchLog -join "`n")
$patched = Get-Content -Raw (Join-Path $m 'WorkloadManifest.json')
Check 'patch applied'    '0' ([regex]::Matches($patched, '10\.0\.99').Count)
Check 'patch count'      '3' ([regex]::Matches($patched, '10\.0\.12').Count)
Check 'patch idempotent' '' (@(Update-CompatManifests $t 10 '10.0.12' 6>&1) -join '')
Remove-Item -Recurse -Force $t

Write-Host '== end to end on a fake SDK folder (manifests from nuget.org, RC1 band)'
$root = Join-Path ([IO.Path]::GetTempPath()) ("nightly-e2e-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$root = PhysicalPath $root   # the script runs from $root and prints the paths it sees there
$dotnetDir = Join-Path $root '.dotnet'
$SDKV = '11.0.100-rc.1.26451.107'
foreach ($d in "sdk/$SDKV", 'sdk/11.0.100-preview.7.26380.1', 'shared/Microsoft.NETCore.App/11.0.0-rc.1.1', 'shared/Microsoft.NETCore.App/11.0.0-preview.7.1', 'host/fxr/11.0.0-rc.1.1',
    'sdk-manifests/11.0.100-preview.6/microsoft.net.sdk.ios/26.5.11720-net11-p6', 'metadata/workloads/11.0.100-rc.1/InstallState') {
  New-Item -ItemType Directory -Force -Path (Join-Path $dotnetDir $d) | Out-Null
}
Set-Content -Path (Join-Path $dotnetDir "sdk/$SDKV/KnownWorkloadManifests.txt") -Value "Microsoft.NET.Sdk.Android`nMicrosoft.NET.Sdk.iOS`nMicrosoft.NET.Sdk.Maui`nMicrosoft.NET.Workload.Mono.ToolChain.Current`nMicrosoft.NET.Workload.Mono.ToolChain.net10`nnot.a.real.manifest"
# stale baseline manifest in an older band folder, as a daily SDK ships it; a pin left by an earlier install
Set-Content -Path (Join-Path $dotnetDir 'sdk-manifests/11.0.100-preview.6/microsoft.net.sdk.ios/26.5.11720-net11-p6/WorkloadManifest.json') -Value '{ "version": "26.5.11720-net11-p6" }'
Set-Content -Path (Join-Path $dotnetDir 'metadata/workloads/11.0.100-rc.1/InstallState/default.json') -Value '{}'
# an older version of a manifest in the band folder, as a previous run leaves it: the update must replace it
New-Item -ItemType Directory -Force -Path (Join-Path $dotnetDir 'sdk-manifests/11.0.100-rc.1/microsoft.net.sdk.ios/26.5.12000-net11-rc.1') | Out-Null
Set-Content -Path (Join-Path $dotnetDir 'sdk-manifests/11.0.100-rc.1/microsoft.net.sdk.ios/26.5.12000-net11-rc.1/WorkloadManifest.json') -Value '{ "version": "26.5.12000-net11-rc.1" }'
# fake dotnet: logs every call, answers `workload list`
$fakeLog = Join-Path $root 'dotnet-calls.log'
$env:FAKE_LOG = $fakeLog
if ($IsWindows) {
  $fakeDotnet = Join-Path $dotnetDir 'dotnet.cmd'
  Set-Content -Path $fakeDotnet -Value "@echo off`r`necho %CD% :: %*>> `"%FAKE_LOG%`"`r`nif `"%1 %2`"==`"workload list`" (echo Installed Workload Id    Manifest Version& echo maui-android             fake)`r`n" -Encoding ascii
} else {
  $fakeDotnet = Join-Path $dotnetDir 'dotnet'
  Set-Content -Path $fakeDotnet -Value "#!/usr/bin/env bash`necho `"`$PWD :: `$*`" >> `"`$FAKE_LOG`"`ncase `"`$1 `$2`" in `"workload list`") echo `"Installed Workload Id    Manifest Version`"; echo `"maui-android             fake`" ;; esac`n"
  & chmod +x $fakeDotnet
}
New-Item -ItemType File -Force -Path $fakeLog | Out-Null
# an old global.json pinning another version, which must not disturb the run
Set-Content -Path (Join-Path $root 'global.json') -Value '{ "sdk": { "version": "11.0.100-preview.7.26380.1", "paths": [ ".dotnet", "$host$" ] } }'

$run1 = Run $root @('-SkipSdk', '-NoDefaultFeeds', '-MauiBranch', 'none', '-Feeds', $nuget, '-Workloads', 'android,maui-android,not-a-workload')
$run1.Lines | ForEach-Object { Write-Host "     | $_" }
$bandDir = Join-Path $dotnetDir 'sdk-manifests/11.0.100-rc.1'
Check 'exit code'            '0' $run1.ExitCode
Check 'SDK picked (newest in folder, not the pinned one)' "SDK $SDKV (band 11.0.100-rc.1) in $dotnetDir" (@($run1.Lines | Where-Object { $_ -like 'SDK *' }) -join '')
Check 'ios manifest placed'  '26.5.12194-net11-rc.1' ((Get-ChildItem (Join-Path $bandDir 'microsoft.net.sdk.ios') -Directory | ForEach-Object Name) -join ' ')
Check 'older ios manifest version replaced (update)' '1' @(Get-ChildItem (Join-Path $bandDir 'microsoft.net.sdk.ios') -Directory).Count
Check 'ios manifest files'   'WorkloadManifest.json WorkloadManifest.targets' ((Get-ChildItem (Join-Path $bandDir 'microsoft.net.sdk.ios/26.5.12194-net11-rc.1') -File | ForEach-Object Name | Where-Object { $_ -notlike '*Dependencies*' } | Sort-Object) -join ' ')
Check 'android manifest placed' '37.0.0-rc.1.2257' ((Get-ChildItem (Join-Path $bandDir 'microsoft.net.sdk.android') -Directory | ForEach-Object Name) -join ' ')
Check 'maui manifest placed' '11.0.0-rc.1.26451.6' ((Get-ChildItem (Join-Path $bandDir 'microsoft.net.sdk.maui') -Directory | ForEach-Object Name) -join ' ')
Check 'toolchain manifest placed' '11.0.100-rc.1.26425.128' ((Get-ChildItem (Join-Path $bandDir 'microsoft.net.workload.mono.toolchain.current') -Directory | ForEach-Object Name) -join ' ')
Check 'unknown manifest reported' '1' (CountMatching $run1.Lines 'not\.a\.real\.manifest: no not\.a\.real\.manifest\.manifest-11\.0\.100-rc\.1 on any feed')
Check 'stale baseline untouched' '26.5.11720-net11-p6' ((Get-ChildItem (Join-Path $dotnetDir 'sdk-manifests/11.0.100-preview.6/microsoft.net.sdk.ios') -Directory | ForEach-Object Name) -join ' ')
Check 'install state pin removed' $false (Test-Path (Join-Path $dotnetDir 'metadata/workloads/11.0.100-rc.1/InstallState/default.json'))
Check 'net10 compat manifest is public already (no patch line)' '0' (CountMatching $run1.Lines 'compat manifest')
$net10 = Get-Content -Raw (Get-ChildItem (Join-Path $bandDir 'microsoft.net.workload.mono.toolchain.net10') -Recurse -Filter WorkloadManifest.json | Select-Object -First 1).FullName | ConvertFrom-Json
Check 'net10 compat packs all at the newest public runtime' $newest10 (($net10.packs.PSObject.Properties.Value.version | Sort-Object -Unique) -join ' ')
$calls = @(Get-Content $fakeLog)
Check 'workload install call' "workload install android maui-android --skip-manifest-update --skip-sign-check --source $nuget" (@($calls | Where-Object { $_ -match 'workload install' } | ForEach-Object { ($_ -split ' :: ', 2)[1] }) -join '')
Check 'workload no manifest defines is skipped' '1' (CountMatching $run1.Lines 'workload not-a-workload: no manifest of band 11\.0\.100-rc\.1 defines it, skipped')
Check 'dotnet ran outside the repo dir' '0' (CountMatching $calls ('^' + [regex]::Escape($root) + ' ::'))
Check 'workload clean + list called' '2' (CountMatching $calls 'workload (clean|list)')
Check 'build servers shut down after a refresh' '1' (CountMatching $calls 'build-server shutdown')
Check 'global.json re-pinned' $SDKV ([regex]::Match((Get-Content -Raw (Join-Path $root 'global.json')), '11\.0\.100[^"]*').Value)
Check 'global.json relative path' '"paths": [ ".dotnet", "$host$" ],' (@(Get-Content (Join-Path $root 'global.json') | Where-Object { $_ -match 'paths' } | ForEach-Object { $_.Trim() }) -join '')
Check 'old SDK not pruned without -Prune' '2' @(Get-ChildItem (Join-Path $dotnetDir 'sdk') -Directory).Count
Check 'workload command hint' '1' (CountMatching $run1.Lines ([regex]::Escape("use $fakeDotnet workload list")))

Write-Host '== second run: idempotent, -ManifestsOnly, -NoGlobalJson, -Prune'
Remove-Item (Join-Path $root 'global.json') -Force
Set-Content -Path $fakeLog -Value '' -NoNewline
$run2 = Run $root @('-SkipSdk', '-NoDefaultFeeds', '-MauiBranch', 'none', '-Feeds', $nuget, '-ManifestsOnly', '-NoGlobalJson', '-Prune')
Check 'exit code'            '0' $run2.ExitCode
Check 'manifests present, not re-downloaded' '5' (CountMatching $run2.Lines '\(present\)')
Check 'no dotnet call'       '' ("$(Get-Content -Raw $fakeLog)".Trim())
Check 'no global.json'       $false (Test-Path (Join-Path $root 'global.json'))
Check 'pruned old sdk'       $SDKV ((Get-ChildItem (Join-Path $dotnetDir 'sdk') -Directory | ForEach-Object Name) -join ' ')
Check 'pruned old runtime'   '11.0.0-rc.1.1' ((Get-ChildItem (Join-Path $dotnetDir 'shared/Microsoft.NETCore.App') -Directory | ForEach-Object Name) -join ' ')
Check 'prune logged'         '2' (CountMatching $run2.Lines 'pruning')
$run2b = Run $root @('-SkipSdk', '-NoDefaultFeeds', '-MauiBranch', 'none', '-Feeds', $nuget, '-NoGlobalJson')
Check 'no workloads: hint instead of install' '1' (CountMatching $run2b.Lines ('No workloads requested \(-Workloads\)\. Later: .*workload install <id> --skip-manifest-update --skip-sign-check --source ' + [regex]::Escape($nuget)))
Check 'no workloads: still no dotnet call' '' ("$(Get-Content -Raw $fakeLog)".Trim())

Write-Host '== update: a newer SDK appears in the folder'
$NEWV = '11.0.100-rc.1.26470.101'
New-Item -ItemType Directory -Force -Path (Join-Path $dotnetDir "sdk/$NEWV") | Out-Null
Copy-Item (Join-Path $dotnetDir "sdk/$SDKV/KnownWorkloadManifests.txt") (Join-Path $dotnetDir "sdk/$NEWV/")
$run2c = Run $root @('-SkipSdk', '-NoDefaultFeeds', '-MauiBranch', 'none', '-Feeds', $nuget, '-ManifestsOnly', '-Prune')
Check 'exit code'            '0' $run2c.ExitCode
Check 'newer SDK picked'     "SDK $NEWV (band 11.0.100-rc.1) in $dotnetDir" (@($run2c.Lines | Where-Object { $_ -like 'SDK *' }) -join '')
Check 'same band: manifests kept' '5' (CountMatching $run2c.Lines '\(present\)')
Check 'older SDK pruned'     $NEWV ((Get-ChildItem (Join-Path $dotnetDir 'sdk') -Directory | ForEach-Object Name) -join ' ')
Check 'global.json re-pinned to the newer SDK' $NEWV ([regex]::Match((Get-Content -Raw (Join-Path $root 'global.json')), '11\.0\.100[^"]*').Value)
$SDKV = $NEWV

Write-Host '== -Dir outside cwd, -CompatRuntime override'
$other = Join-Path ([IO.Path]::GetTempPath()) ("nightly-other-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $other "sdk/$SDKV") | Out-Null
$other = (Resolve-Path $other).Path
Copy-Item $fakeDotnet (Join-Path $other (Split-Path $fakeDotnet -Leaf))
Set-Content -Path (Join-Path $other "sdk/$SDKV/KnownWorkloadManifests.txt") -Value 'Microsoft.NET.Workload.Mono.ToolChain.net10'
$run3 = Run $root @('-SkipSdk', '-Dir', $other, '-NoDefaultFeeds', '-MauiBranch', 'none', '-Feeds', $nuget, '-ManifestsOnly', '-CompatRuntime', '10.0.5')
Check 'exit code'            '0' $run3.ExitCode
Check 'compat override applied' '1' (CountMatching $run3.Lines '-> 10\.0\.5')
Check 'global.json absolute path' ('"paths": [ "' + ($other -replace '\\', '/') + '", "$host$" ],') (@(Get-Content (Join-Path $root 'global.json') | Where-Object { $_ -match 'paths' } | ForEach-Object { $_.Trim() }) -join '')
Remove-Item -Recurse -Force $other

Write-Host "== feeds from dotnet/maui's NuGet.config, branch derived from the band (network: GitHub)"
$run4 = Run $root @('-SkipSdk', '-NoDefaultFeeds', '-ManifestsOnly', '-NoGlobalJson', '-MauiBranch', 'release/11.0.1xx-rc2')
$feedLines = @($run4.Lines | Where-Object { $_ -match '^  https://' })
$feedLines | ForEach-Object { Write-Host "     | $_" }
Check 'darc-pub macios feed found' '1' (CountMatching $feedLines 'darc-pub-dotnet-macios')
Check 'dotnet11 feed found via NuGet.config' '1' (CountMatching $feedLines '/dotnet11/nuget')
Check 'no dotnet10 feed' '0' (CountMatching $feedLines '/dotnet10')
$run5 = Run $root @('-SkipSdk', '-ManifestsOnly', '-NoGlobalJson')
Check 'auto branch (release/11.0.1xx-rc1) + default feed: exit code' '0' $run5.ExitCode

Write-Host '== -ListWorkloads (manifests discovered on nuget.org, RC1 band, no SDK download)'
$wm = Join-Path ([IO.Path]::GetTempPath()) ("nightly-wm-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $wm | Out-Null
Set-Content -Path (Join-Path $wm 'WorkloadManifest.json') -Value "{`n  // a comment`n  `"workloads`": {`n    `"maui`": { `"packs`": [ `"a`", ], },`n    `"runtimes-x`": { `"abstract`": true, },`n  },`n}"
Check 'manifest workload ids: comments, trailing commas, abstract skipped' 'maui' ((Get-ManifestWorkloads (Join-Path $wm 'WorkloadManifest.json')) -join ' ')
Remove-Item -Recurse -Force $wm
Clear-Content $fakeLog
$run6 = Run $root @('-ListWorkloads', '-Version', '11.0.100-rc.1.26425.128', '-NoDefaultFeeds', '-Feeds', $nuget, '-MauiBranch', 'none')
$run6.Lines | ForEach-Object { Write-Host "     | $_" }
Check 'list-workloads: exit code' '0' $run6.ExitCode
Check 'list-workloads: band from the version' 'SDK 11.0.100-rc.1.26425.128 (band 11.0.100-rc.1)' (@($run6.Lines | Where-Object { $_ -like 'SDK *' }) -join '')
Check 'list-workloads: maui manifest found on nuget.org' '  microsoft.net.sdk.maui: 11.0.0-rc.1.26451.6  (nuget.org)' (@($run6.Lines | Where-Object { $_ -like '  microsoft.net.sdk.maui:*' }) -join '')
$i = [array]::IndexOf($run6.Lines, '  microsoft.net.sdk.maui: 11.0.0-rc.1.26451.6  (nuget.org)')
Check 'list-workloads: maui workloads listed' $true ($i -ge 0 -and ($run6.Lines[$i + 1] -split ' ') -contains 'maui')
$j = -1; for ($k = 0; $k -lt $run6.Lines.Count; $k++) { if ($run6.Lines[$k] -like '  microsoft.net.workload.emscripten.current:*') { $j = $k; break } }
Check 'list-workloads: abstract-only manifest says so' $true ($j -ge 0 -and $run6.Lines[$j + 1].Contains('abstract workloads only'))
Check 'list-workloads: no dotnet call' '0' @(Get-Content $fakeLog -ErrorAction SilentlyContinue).Count
$run7 = Run $root @('-ListWorkloads')
Check 'list-workloads without a channel: exit 1' '1' $run7.ExitCode
Check 'auto branch: dotnet11 default feed present' '1' (CountMatching $run5.Lines '^  https://.*/dotnet11/nuget')

Write-Host '== -Clean'
Set-Content -Path (Join-Path $root 'global.json') -Value '{ "sdk": { "version": "x", "paths": [ ".dotnet", "$host$" ] } }'
$c1 = Run $root @('-Clean')
Check 'exit code'            '0' $c1.ExitCode
Check 'folder removed'       $false (Test-Path $dotnetDir)
Check 'global.json pointing at it removed' $false (Test-Path (Join-Path $root 'global.json'))
Check 'clean logs both'      '2' (CountMatching $c1.Lines '^Removed ')
New-Item -ItemType Directory -Force -Path (Join-Path $root 'notdotnet/stuff') | Out-Null
Set-Content -Path (Join-Path $root 'notdotnet/stuff/file') -Value ''
$c2 = Run $root @('-Clean', '-Dir', 'notdotnet')
Check 'refuses a folder that is not a .NET folder: exit 1' '1' $c2.ExitCode
Check 'refuses: folder untouched' $true (Test-Path (Join-Path $root 'notdotnet/stuff/file'))
New-Item -ItemType Directory -Force -Path (Join-Path $root 'other-sdk/sdk/1.0.0') | Out-Null
Set-Content -Path (Join-Path $root 'global.json') -Value '{ "sdk": { "paths": [ ".elsewhere", "$host$" ] } }'
$c3 = Run $root @('-Clean', '-Dir', 'other-sdk')
Check 'clean by sdk/ marker: exit 0' '0' $c3.ExitCode
Check 'unrelated global.json kept' $true (Test-Path (Join-Path $root 'global.json'))

Remove-Item -Recurse -Force $root
Write-Host ''
Write-Host "passed: $script:pass  failed: $script:fail"
if ($script:fail -ne 0) { exit 1 }
