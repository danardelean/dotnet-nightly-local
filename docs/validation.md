# Validation runs

What the automated suites (`test.sh`, `test.ps1`) cannot cover because they need Microsoft's download hosts, a real
`dotnet`, or another operating system. Run each block as written (no inline comments: zsh passes a `#` to the command),
compare with the expected lines, and keep the output: the article quotes real runs.

Results so far, October 9, 2026, macOS:

| Block | Result |
|---|---|
| 1. Update in place | OK: `maui 11.0.0-rc.2.26505.5/11.0.100-rc.2`, manifest set refreshed |
| 2. RC1 in another folder | OK: SDK `11.0.100-rc.1.26425.128`, maui `11.0.0-rc.1.26451.6`; `--clean` removed `.dotnet` and `global.json`, folder left empty |
| 3a. `test.ps1` on macOS | OK: `passed: 91  failed: 0` (`test.sh`: 89/0) after a second harness fix (`Resolve-Path` keeps the `/var` symlink, the child process sees `/private/var`); `-ListChannels` same as `install.sh`; real install of `11.0.100-rc.2.26473.112` + `maui`, `workload list` shows `maui 11.0.0-rc.2.26505.5/11.0.100-rc.2`, `-Clean` left the folder empty |
| 3b. Windows | not run yet |
| 6. RTM lane (`11.0.1xx`) | `maui` installs (maui `11.0.0-rc.2.26508.7`, android `37.2.6` from an isolated feed), but no iOS manifest for band `11.0.100` exists on any public feed: the SDK's bundled Preview 6 iOS (Xcode 26) stays. Not usable for iOS today |
| 10. Update in place, .NET 12 | `--version 12.0.100-alpha.1.26508.114 --workloads android` then `--channel 12.0.1xx --workloads android --prune`: 65 s, SDK `26509.101` installed next to the old one, all manifests `(present)`, `Workload(s) 'android' are already installed.`, four `pruning` lines, `global.json` re-pinned, folder's `dotnet --version` = `26509.101` |
| 9. Unknown workload skipped | `--workloads android,maui-android,not-a-workload` on the fake RC1 SDK: the third is skipped with `no manifest of band 11.0.100-rc.1 defines it`, the install call carries the other two (test in both suites) |
| 8. `--list-workloads` | OK on both scripts: `12.0.1xx` (77 s, 13 feeds), `11.0.1xx-rc2` (46 s), `11.0.1xx` (26 s), `-c 11.0 -q preview` (RC1, 34 s); nuget.org's search does not return the manifest packages, so the ids an SDK knows are probed instead |
| 7. .NET 12 lane (`12.0.1xx`) | OK in a clean folder: SDK `12.0.100-alpha.1.26509.101`, `ios 27.0.12277-net12-p1`, `android 37.99.0-preview.1.135`, `mobile-librarybuilder-net11`; console app runs, `dotnet new ios` and `dotnet new android` build (with a `NuGet.config` naming `dotnet12`). No `maui` manifest for the band. Four script changes on the way, listed in block 7 |
| 4. Lane check | `11.0.1xx` = RTM branch, `11.0.1xx-rc2` = `26473.112` unchanged since Sept 23, `12.0.1xx` = alpha |

## 1. Update in place (macOS, the Maui.NativeStyles clone)

```bash
cd ~/Projects/Maui.NativeStyles
git pull
./scripts/install-dotnet11-nightly.sh --prune
./.dotnet/dotnet --version
./.dotnet/dotnet workload list
```

Expected:

- Either `SDK <version> is already installed.` or a download of a newer `11.0.100-rc.2.*` daily. In the second case a
  line `pruning sdk/<old version>` near the end, and `./.dotnet/dotnet --version` prints the new one.
- `Manifests (11.0.100-rc.2):` with every line ending in `(present)` when nothing changed on the feeds, or a new
  version with the feed it came from when something did. iOS stays `27.0.*-net11-rc.2`, Android `37.2.*-rc.2.*`.
- `maui` in `workload list` with manifest `11.0.0-rc.2.*/11.0.100-rc.2`.

## 2. A released preview in another folder, then clean (macOS)

Quality `preview` on channel `11.0` is the newest released preview or RC, RC1 at the time of writing. Its manifests
are on nuget.org, one of the default manifest sources.

```bash
git -C ~/Projects/dotnet-nightly-local pull
mkdir -p ~/tmp/net11-preview && cd ~/tmp/net11-preview
~/Projects/dotnet-nightly-local/install.sh --channel 11.0 --quality preview --workloads maui
cat global.json
./.dotnet/dotnet --version
./.dotnet/dotnet workload list
dotnet --version
cd ~ && dotnet --version
cd ~/tmp/net11-preview
~/Projects/dotnet-nightly-local/install.sh --clean
ls -la
```

Expected:

- `SDK 11.0.100-rc.1.<build> (band 11.0.100-rc.1) in /Users/<you>/tmp/net11-preview/.dotnet`.
- `Manifests (11.0.100-rc.1):` with iOS `26.5.*-net11-rc.1` (RC1 was built for Xcode 26.6: this run checks the
  install, not iOS builds).
- The two `dotnet --version` lines: the RC1 version inside the folder, the system SDK (`10.0.4xx`) from `~`.
- `--clean` prints `Removed .../.dotnet` and `Removed global.json (it pointed at .dotnet)`, and `ls -la` shows an
  empty folder.

## 3a. PowerShell on macOS

```bash
brew install powershell
cd ~/Projects/dotnet-nightly-local && git pull
pwsh ./test.ps1
pwsh ./install.ps1 -ListChannels
mkdir -p ~/tmp/net11-pwsh && cd ~/tmp/net11-pwsh
pwsh ~/Projects/dotnet-nightly-local/install.ps1 -Channel 11.0.1xx-rc2 -Workloads maui
./.dotnet/dotnet workload list
pwsh ~/Projects/dotnet-nightly-local/install.ps1 -Clean
```

Expected: `test.ps1` ends with `passed: 91  failed: 0`; the install prints the same lines as `install.sh` would, from
`Downloading SDK 11.0.100-rc.2.<build> (osx-arm64) from https://ci.dot.net/public/Sdk/...tar.gz` to the workload
list with `maui`.

## 3b. Windows (PowerShell 7)

```powershell
git clone https://github.com/danardelean/dotnet-nightly-local.git
cd dotnet-nightly-local
.\test.ps1
.\install.ps1 -ListChannels
mkdir C:\tmp\net11 ; cd C:\tmp\net11
& $HOME\dotnet-nightly-local\install.ps1 -Channel 11.0.1xx-rc2 -Workloads maui
.\.dotnet\dotnet.exe workload list
dotnet --version
& $HOME\dotnet-nightly-local\install.ps1 -Clean
```

The script path assumes the clone is in `$HOME`; adjust it otherwise. Expected:

- `test.ps1` ends with `passed: 91  failed: 0`.
- `Downloading SDK 11.0.100-rc.2.<build> (win-x64) from https://ci.dot.net/public/Sdk/...zip`, then the manifests,
  then the workload install: on Windows `maui` is `maui-windows` plus Android, so expect `Microsoft.Maui.Sdk.net11`,
  the Windows App SDK packs and the Android packs, no iOS.
- `workload list` shows `maui`; `dotnet --version` inside `C:\tmp\net11` shows the nightly.

Parts of `install.ps1` that have not run on Windows yet and deserve a look if something fails: the `.zip` download and
`tar -xf` extraction, `dotnet.exe` running the workload install from a folder, the `.cmd` fake in `test.ps1`.

## 4. `--list-channels` lane check (any OS)

```bash
./install.sh --list-channels
```

Observed on October 9, 2026:

```
channel              current daily SDK
10.0.1xx             10.0.114
10.0.1xx-rc2         10.0.101
10.0.2xx             10.0.203
10.0.3xx             10.0.303
10.0.4xx             10.0.403
11.0.1xx             11.0.100-rtm.26480.113
11.0.1xx-preview1    11.0.100-preview.1.26104.118
11.0.1xx-preview2    11.0.100-preview.2.final
11.0.1xx-preview3    11.0.100-preview.3.26219.104
11.0.1xx-preview4    11.0.100-preview.4.26257.104
11.0.1xx-preview5    11.0.100-preview.5.26312.104
11.0.1xx-preview6    11.0.100-preview.6.26359.118
11.0.1xx-preview7    11.0.100-rc.1.26413.103
11.0.1xx-rc1         11.0.100-rc.1.26431.118
11.0.1xx-rc2         11.0.100-rc.2.26473.112
11.0.2xx             11.0.100-rc.2.26508.107
12.0.1xx             12.0.100-alpha.1.26508.114
```

`11.0.1xx` is the RTM release branch, `12.0.1xx` is `main`, and the RC2 lane has not produced a newer build since
September 23 (`26473`), consistent with a release candidate about to ship.

## 5. Feed facts checked on October 9 (for pitfalls 2 to 4)

- `11.0.100-rc.2.26504.105` (pinned by dotnet/maui's `release/11.0.1xx-rc2` `global.json`) and
  `11.0.100-rc.2.26507.101`: 404 on ci.dot.net and builds.dotnet.microsoft.com. The public RC2 SDK is `26473.112`.
- The `26473.112` archive bundles `sdk-manifests/11.0.100-preview.6/` with android `37.0.0-preview.6.59`, ios
  `26.5.11720-net11-p6`, maui `11.0.0-preview.6.26360.8`.
- Its bundled `mono.toolchain.net10` manifest references .NET `10.0.13`; the feed's builds from `26502.*` (October 3)
  on reference `10.0.12`, so a fresh install today prints no `compat manifest` line.
- The RC2 iOS (`27.0.12212-net11-rc.2`, since September 30) and Android (`37.2.0-rc.2.84`) manifests and packs are on
  `dotnet11`. `darc-pub-dotnet-macios-fd471cba` holds the .NET 10 macios build `26.5.10322`,
  `darc-pub-dotnet-android-db080b91` holds `Microsoft.Android.Sdk.Darwin 36.1.118`.
- The RC2 Android manifest references `Microsoft.Android.Sdk.Darwin 36.1.118` (the `net10` pack), not on nuget.org.
  `install.sh --channel 11.0.1xx-rc2 --maui-branch none --workloads android` fails with
  `Versione 36.1.118 del pacchetto microsoft.android.sdk.darwin non è stato trovato nei feed NuGet`; with the default
  feeds it succeeds.
- Daily SDK archives on ci.dot.net have no `.sha512` (404); released ones on builds.dotnet.microsoft.com do.


## 6. The RTM lane: `11.0.1xx` with `maui` (macOS, October 9)

```bash
mkdir -p ~/tmp/net11rtm && cd ~/tmp/net11rtm
~/Projects/dotnet-nightly-local/install.sh --channel 11.0.1xx --workloads maui
```

Result: SDK `11.0.100-rtm.26480.113`, band `11.0.100`. `maui 11.0.0-rc.2.26508.7` and `android 37.2.6` (the latter from
`darc-pub-dotnet-android-b4100484`, listed by dotnet/maui's `net11.0` branch) were found; for `ios`, `maccatalyst`,
`macos` and `tvos` no `*.Manifest-11.0.100` exists on dotnet11, nuget.org or the macios feed of that branch
(`darc-pub-dotnet-macios-bfdc82e5` holds .NET 10 builds only), so the SDK's bundled Preview 6 manifests
(`26.5.11720-net11-p6`, Xcode 26) stayed and `workload install maui` used them. The lane is not usable for iOS 27
builds today; the RC2 lane is.

## 7. The .NET 12 lane: `12.0.1xx` with `ios,android` (macOS, October 9)

```bash
mkdir -p ~/tmp/net12 && cd ~/tmp/net12
~/Projects/dotnet-nightly-local/install.sh --channel 12.0.1xx --workloads ios,android,mobile-librarybuilder-net11
dotnet new console -o HelloConsole && cd HelloConsole && dotnet run && cd ..
dotnet new ios -o HelloIos && cd HelloIos && dotnet build && cd ..
dotnet new android -o HelloDroid && cd HelloDroid && dotnet build && cd ..
```

Facts found on the way, each one now covered by a test or a code path:

- `main` of dotnet/dotnet is branded 12.0 and publishes under `12.0.1xx` (SDK `12.0.100-alpha.1.26508.114`); the
  `dotnet12` feed exists. dotnet/macios `main` already pins that SDK; dotnet/maui `main` still pins .NET 10
  (`10.0.113-servicing`), so there is no `Microsoft.NET.Sdk.Maui.Manifest-12.0.100-alpha.1` anywhere: no `maui`
  workload for .NET 12 yet. iOS (`27.0.12277-net12-p1`) and Android (`37.99.0-preview.1.129`) manifests are on
  `dotnet12`.
- Bug 1: `install.sh` exited 1 silently after the manifests. `newest_public_runtime 11` found no released 11.0.x on
  nuget.org, its empty `grep` failed the pipeline under `set -eo pipefail`, and the "no public runtime" branch was
  never reached. Fixed (`|| true`), test added to both suites.
- Bug 2: the .NET 12 iOS and Android workloads still carry .NET 10 compat packs from unreleased servicing builds
  (`Microsoft.iOS.Sdk.net10.0_26.5 26.5.10322`, `Microsoft.Android.Sdk.Darwin 36.1.118`), published only on the
  isolated feeds that dotnet/maui's .NET 11 branches list (`darc-pub-dotnet-macios-fd471cba`,
  `darc-pub-dotnet-android-db080b91`); `main`'s NuGet.config, a .NET 10 branch, does not name them. Both scripts now
  also read `net<prev>.0` and the newest `release/<prev>.0.1xx-*` branch for an alpha band (darc-pub feeds only), found
  with `git ls-remote`. Tests added; `ios android` then installed cleanly (3.7 GB folder, 3.3 GB of packs).
- The templates of the alpha still generate `net11.0`, `net11.0-ios` and `net11.0-android` projects. The console app
  runs on the 12.0 alpha runtime (`Hello, World!`). The iOS and Android builds first failed with NETSDK1147 asking for
  `mobile-librarybuilder-net11` and `wasm-tools-net11`: the `ios` workload of dotnet/macios `main` extends
  `microsoft-net-runtime-ios` and `-net10` (it still sees net11.0 as current), while the SDK's compat manifest
  `mono.toolchain.net11` already files .NET 11 as previous, so a `net11.0-ios` build imports `.net11` packs
  (`Microsoft.NET.Runtime.MonoTargets.Sdk.net11`, `AOT.Cross.net11.ios-*`, `11.0.0-rc.1.26453.118`, on `dotnet12`)
  that nothing installed. `mobile-librarybuilder-net11` extends the iOS and the Android `.net11` runtime workloads,
  so adding it to `--workloads` covers both apps.
- Restore then failed with NU1102: a `net11.0-ios` project built by this SDK references `Microsoft.NETCore.App.Ref
  11.0.0-rc.1.26453.118`, `Microsoft.NET.ILLink.Tasks 12.0.0-alpha.1.*`, the iOS simulator runtime pack and crossgen2
  at the alpha version, all on `dotnet12` and not on nuget.org. A `NuGet.config` next to the project (or in a parent
  folder) listing that feed fixes it; both scripts now print the feed URL as their last line.
- Bug 3: after the manifests had been refreshed by a second run (android `.129` to `.133`, toolchain `26508.114` to
  `26509.101`), the Android build still asked for the `.129` pack and the iOS build imported
  `mono.toolchain.current/12.0.100-alpha.1.26508.114/WorkloadTelemetry.targets`, a folder that no longer existed: the
  MSBuild node and the VBCSCompiler server started by the first build were still alive and held the old manifests.
  `./.dotnet/dotnet build-server shutdown` fixed both builds. Both scripts now run it whenever they replaced a manifest
  or installed packs; test added to both suites (`test.sh` 93/0, `test.ps1` 95/0).
- Clean-room run with the final scripts (`~/tmp/net12b`, 17:07): install 3 min 26 s (SDK `26509.101`, android
  `.135`), `dotnet --version` is the alpha in the folder and `10.0.401` in `$HOME`, console `Hello, World!`, iOS build
  23 s (`Helloios.app`, iossimulator-arm64), Android build 21 s (`com.companyname.Helloandroid-Signed.apk`). The
  folder is 7.0 GB with the three workloads.

## 8. `--list-workloads` (any OS, October 9)

```bash
./install.sh --list-workloads --channel 12.0.1xx
./install.sh --list-workloads --channel 11.0.1xx-rc2
./install.sh --list-workloads --channel 11.0.1xx
./install.sh --list-workloads --channel 11.0 --quality preview
pwsh ./install.ps1 -ListWorkloads -Channel 11.0.1xx-rc2
```

Observed: `12.0.1xx` lists android `37.99.0-preview.1.135`, ios/maccatalyst/macos/tvos `27.0.12277-net12-p1`, the
toolchain and emscripten manifests at `26509.101`, and reports `microsoft.net.sdk.maui` as not on any feed. The RC2
lane lists all six SDK manifests (maui `11.0.0-rc.2.26505.5`: maui maui-android maui-desktop maui-ios maui-maccatalyst
maui-mobile maui-tizen maui-windows). The RTM lane lists android `37.2.6` (darc-pub) and maui `11.0.0-rc.2.26509.4`
and reports the four Apple manifests as absent. `-c 11.0 -q preview` resolves RC1 (`11.0.100-rc.1.26425.128`) and
lists its manifests from dotnet11. Emscripten manifests print `(abstract workloads only: extended by others)`. The
PowerShell run matches line for line. Discovery: the dnceng package search takes a substring query
(`packageNameQuery=manifest-<band>`); nuget.org's search returns none of these packages although they are listed
(registration `listed: true`), so for nuget.org the ids an SDK lists in `KnownWorkloadManifests.txt` are probed
through the flat index, which serves them.
