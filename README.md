# dotnet-nightly-local

A .NET nightly SDK and any of its workloads in a folder of your repository, nothing installed system-wide.

`install.sh` (bash, macOS and Linux) and `install.ps1` (PowerShell 7, Windows, macOS and Linux) install a daily
build of the .NET SDK into a directory of your choice (default `./.dotnet`), place the newest workload manifests of
that SDK's version band next to it, install the workloads you ask for into the same directory, and write a
`global.json` so that the regular `dotnet` command picks that SDK up inside your project. Your machine-wide .NET
install is not touched. `--clean` deletes the folder and the `global.json` that points at it.

It exists because a nightly SDK alone is not enough to try, say, .NET 11 RC2 with Xcode 27 before RC2 ships: the SDK
bundles stale workload manifests, the real ones live on several feeds, and some packages they reference are not public
yet. The script works around each of these the way the dotnet/maui and dotnet/macios repositories do in their own
builds.

## Quick start

```bash
curl -sSL -o ~/install.sh https://raw.githubusercontent.com/danardelean/dotnet-nightly-local/main/install.sh
chmod +x ~/install.sh
cd ~/Projects/MyApp

~/install.sh --list-channels                       # which channels have daily builds right now
# the .NET 12 alpha, SDK only: enough for console, library and web projects
~/install.sh --channel 12.0.1xx
# the same with the iOS and Android workloads (see "Multiple lanes" below for why the third one)
~/install.sh --channel 12.0.1xx --workloads ios,android,mobile-librarybuilder-net11
# .NET 11 RC2 daily with the maui workload (iOS, Android, Mac Catalyst)
~/install.sh --channel 11.0.1xx-rc2 --workloads maui

dotnet --version                 # the nightly, through global.json, only inside this folder
./.dotnet/dotnet workload list   # workload commands must run through the folder's dotnet (see below)
```

A workload that no manifest of the lane's band defines (no `maui` for .NET 12 as of October 2026) is skipped with a
message, so that the installer does not take it from the SDK's older bundled manifest; `--list-workloads` shows what a
lane has before you ask. The SDK itself is usable without any workload.

Read the script before running it. It downloads the official `dotnet-install.sh`, writes into the folder you name and
into `global.json` in the current directory, and nothing else.

Run it again to update: a newer daily is installed next to the old one, the manifests are refreshed, `global.json` is
re-pinned. Add `--prune` to drop the older SDK, runtime and host versions. When you are done, `--clean` removes the
folder and the `global.json`; it refuses a folder that holds neither a `dotnet` executable nor an `sdk/` directory,
so a mistyped `--dir` cannot delete something else.

Add the folder and `global.json` to `.gitignore`:

```
.dotnet/
global.json
```

## Options

```
install.sh [options]
  -d, --dir DIR             install folder (default: ./.dotnet)
  -c, --channel CHANNEL     daily-build channel, a release/* branch of dotnet/dotnet without the prefix (see
                            --list-channels); required unless --version or --skip-sdk is given
  -q, --quality QUALITY     daily | preview | ga (default: daily)
  -v, --version VERSION     an exact SDK version instead of the newest build of the channel
  -w, --workloads LIST      workloads to install, comma-separated: maui, ios, android, maui-android, wasm-tools,
                            aspire ... (default: none, the SDK and the refreshed manifests only)
  -b, --maui-branch BRANCH  dotnet/maui branch whose NuGet.config lists the feeds its build uses (default: auto,
                            derived from the SDK band; "none" to skip)
  -f, --feeds LIST          extra NuGet v3 feeds to search for manifests and packs, comma-separated
      --no-default-feeds    do not search the default feeds: the dotnet<major> feed on dnceng and nuget.org
      --compat-runtime VER  runtime version for the previous major's compat manifests (default: newest on nuget.org)
      --no-global-json      do not write global.json in the current directory
      --skip-sdk            do not (re)install the SDK; use the newest one already in DIR
      --manifests-only      stop after placing the manifests (no workload install)
      --prune               remove older SDK, runtime and host versions from DIR
      --list-channels       show the channels that currently have daily builds, with today's SDK version, and exit
      --list-workloads      show the manifests of the channel's band on the feeds and the workload ids each defines,
                            without downloading the SDK (with --channel or --version), and exit
      --clean               remove DIR and, when it points at DIR, the global.json in the current directory, and exit
  -h, --help
```

### Finding a channel

A channel is an aka.ms name that Arcade's publishing constants
([PublishingConstants.cs](https://github.com/dotnet/arcade/blob/main/src/Microsoft.DotNet.Build.Tasks.Feed/src/model/PublishingConstants.cs))
assign to a build channel: `11.0.1xx` for the 11.0.1xx SDK channel, `11.0.1xx-rc2` for its RC 2, `11.0.1xx-preview7`,
`12.0.1xx` for the next major. Roughly, a `release/*` branch of [dotnet/dotnet](https://github.com/dotnet/dotnet)
without the prefix, with `main` publishing under the channel of the major it is being branded for.

The [.NET builds table](https://github.com/dotnet/dotnet/blob/main/docs/builds-table.md) links the actively built
channels, but it lags behind a branding change: in October 2026 its "main" column still said `11.0.1xx` while
`main` was already branded 12.0 and publishing under `12.0.1xx`, a name the table did not list, and `11.0.1xx` had
become the RTM release branch. `--list-channels` therefore takes the table's channels plus every SDK channel name
Arcade declares for those majors and the next one, probes each, and shows the ones that resolve with their current
SDK version. Read the version column, not the name, to know which lane you are looking at. On October 9, 2026
(abridged):

```
$ ./install.sh --list-channels
channel              current daily SDK
10.0.4xx             10.0.403
11.0.1xx             11.0.100-rtm.26480.113
11.0.1xx-rc1         11.0.100-rc.1.26431.118
11.0.1xx-rc2         11.0.100-rc.2.26473.112
12.0.1xx             12.0.100-alpha.1.26508.114
```

Older release branches keep their channel name (`10.0.1xx`, `9.0.1xx`) but no longer produce dailies; use them with
`-q preview` or `-q ga` to get the released SDK. Any channel can be probed by hand the way the script does it: the
archive link redirects to a URL that carries the version, and an unknown channel lands on a Microsoft search page
instead of a 404:

```bash
curl -sIL -o /dev/null -w '%{url_effective}\n' https://aka.ms/dotnet/11.0.1xx-rc2/daily/dotnet-sdk-osx-arm64.tar.gz
```

### Which workloads a channel has today

`--list-workloads` resolves the channel's SDK version the same way, derives the band, assembles the feeds as an
install would, and lists every `*.Manifest-<band>` package found on them (the dnceng feeds through their package
search, nuget.org by probing the ids an SDK knows) with the workload ids each manifest defines. Nothing is
downloaded but the manifest packages, a few kilobytes each. On October 9, 2026 (abridged):

```
$ ./install.sh --list-workloads --channel 12.0.1xx
SDK 12.0.100-alpha.1.26509.101 (band 12.0.100-alpha.1), channel 12.0.1xx
Feeds:
  (from dotnet/maui NuGet.config: main net11.0 release/11.0.1xx-rc2)
  ...
Manifests (12.0.100-alpha.1) and the workloads each defines:
  microsoft.net.sdk.android: 37.99.0-preview.1.135  (dotnet12)
      android
  microsoft.net.sdk.ios: 27.0.12277-net12-p1  (dotnet12)
      ios
  ...
  microsoft.net.workload.mono.toolchain.current: 12.0.100-alpha.1.26509.101  (dotnet12)
      mobile-librarybuilder wasi-experimental wasm-experimental wasm-tools
  microsoft.net.workload.mono.toolchain.net11: 12.0.100-alpha.1.26509.101  (dotnet12)
      mobile-librarybuilder-net11 wasi-experimental-net11 wasm-experimental-net11 wasm-tools-net11
  ...
Not on any of the feeds for this band: microsoft.net.sdk.maui
Install: ./install.sh --channel 12.0.1xx --workloads <id,id,...>
```

The same for `11.0.1xx-rc2` lists `maui` (with `maui-android`, `maui-ios`, `maui-windows` ...) and iOS
`27.0.12212-net11-rc.2`; for `11.0.1xx` (RTM) it lists `maui` and `android` and reports the four Apple manifests as not
on any feed. A manifest whose workloads are all abstract (the emscripten ones, extended by `wasm-tools`) says so.
`--quality preview` or `ga` with a release channel (`-c 11.0`) lists the released preview's manifests, from nuget.org.

Examples:

```bash
install.sh --list-workloads -c 12.0.1xx              # what the .NET 12 lane offers today, no download
install.sh -c 11.0.1xx-rc2 -w maui                   # RC2 lane, MAUI
install.sh -c 11.0.1xx -w wasm-tools                 # RTM release branch, WebAssembly tools
install.sh -c 12.0.1xx -w android --dir ~/sdks/net12 # a .NET 12 alpha, Android only, outside the project
install.sh -v 11.0.100-rc.2.26473.112 -w ios         # an exact daily (only builds on the public host work)
install.sh --skip-sdk --prune                        # refresh manifests and drop older SDKs, no download
install.sh -c 11.0 -q preview -w maui                # the newest released preview / RC instead of a daily
install.sh --clean                                   # remove ./.dotnet and the global.json that points at it
```

Requirements, `install.sh`: bash 3.2 or newer (macOS ships 3.2), curl, unzip, perl; macOS or Linux. The Apple
workloads need macOS on either script.

### Windows, or PowerShell anywhere: `install.ps1`

`install.ps1` is the same tool for PowerShell 7, with the same options spelled the PowerShell way, and it is what to
use on Windows:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/danardelean/dotnet-nightly-local/main/install.ps1 -OutFile $HOME\install.ps1
cd C:\Projects\MyApp
& $HOME\install.ps1 -ListChannels
& $HOME\install.ps1 -Channel 11.0.1xx-rc2 -Workloads maui   # on Windows: maui-windows plus Android
dotnet --version
.\.dotnet\dotnet.exe workload list
```

| install.sh | install.ps1 |
|---|---|
| `-d, --dir` | `-Dir` |
| `-c, --channel` | `-Channel` |
| `-q, --quality` | `-Quality` |
| `-v, --version` | `-Version` |
| `-w, --workloads` | `-Workloads` |
| `-b, --maui-branch` | `-MauiBranch` |
| `-f, --feeds` | `-Feeds` |
| `--no-default-feeds` | `-NoDefaultFeeds` |
| `--compat-runtime` | `-CompatRuntime` |
| `--no-global-json` | `-NoGlobalJson` |
| `--skip-sdk` | `-SkipSdk` |
| `--manifests-only` | `-ManifestsOnly` |
| `--prune` | `-Prune` |
| `--list-channels` | `-ListChannels` |
| `--clean` | `-Clean` |
| `-h, --help` | `-Help` |

Two differences in the mechanics. It does not call Microsoft's `dotnet-install` scripts, since the `.ps1` one is
Windows-only and the `.sh` one is Unix-only: it follows the aka.ms redirect of the SDK archive itself, downloads the
`.zip` (Windows) or `.tar.gz`, checks the `.sha512` published next to it and extracts with `tar`, which Windows 10
and later ship too. And manifest packages are unpacked with `Expand-Archive` instead of `unzip`. Everything else,
feeds, lane selection, compat patch, `--skip-manifest-update`, `global.json`, is the same code path in another
language, and `test.ps1` runs the same checks as `test.sh`.

Requirements: PowerShell 7.0 or newer (`pwsh`), `tar`. On macOS and Linux pwsh is an extra install
(`brew install powershell`), which is why `install.sh` stays the default there. On Windows, the workloads of a
`dotnet.exe` run from a folder are installed by the SDK's file-based installer, so nothing goes through MSI or the
registry.

## How it works

1. **SDK.** The official `dotnet-install.sh` with `--install-dir DIR --no-path`. With `--quality daily` it resolves
   `https://aka.ms/dotnet/<channel>/daily/dotnet-sdk-<os>-<arch>.tar.gz`; with `--version` it fetches that exact build.

2. **Manifests.** A daily SDK bundles baseline workload manifests that can be months old, in a band folder it falls
   back to (the newest RC2 daily of October 2026 still carried July's Preview 6 iOS and MAUI manifests). The usual fix, letting
   `dotnet workload install` update them, runs into step 3. So, for every manifest id the SDK lists in
   `sdk/<version>/KnownWorkloadManifests.txt`, the script downloads the newest `<id>.Manifest-<band>` package from the
   feeds and extracts its `data/` folder into `sdk-manifests/<band>/<id>/<version>/`. That is what dotnet/maui's own
   build does. Versions are compared with Semantic Versioning precedence, and builds of the band's prerelease lane
   (`rc.2`) win over other lanes that publish into the same band.

   The feeds: `dotnet<major>` on dnceng and nuget.org (a released preview or RC has its manifests there), plus
   whatever the dotnet/maui branch for that band lists in its `NuGet.config`. Release branches of dotnet/macios and
   dotnet/android publish fixed-version builds, which land on isolated `darc-pub-*` feeds that only that file names;
   the iOS and Android workloads carry packs of the previous .NET from such builds (a .NET 10 servicing build not on
   nuget.org until it ships). For an alpha band, whose dotnet/maui branch is `main` and has not moved to the new
   major, the script also reads the previous major's release branches (`net<prev>.0` and the newest
   `release/<prev>.0.1xx-*`, found with `git ls-remote`) for their isolated feeds. Everything is read at run time, so
   a rotated feed id does not break anything.

3. **Compat manifests.** The `*-net<previous>` workloads (pulled in by `maui`, `ios`, `android`, `wasm-tools` so the
   new SDK can still build apps for the previous .NET) reference the previous runtime the SDK was built with, often a
   servicing release that reaches nuget.org only on Patch Tuesday. The script points them at the newest public one. They
   are not used when you build for the new .NET. It is a local edit of a throwaway SDK, and it is the one real hack here.

4. **Packs.** `dotnet workload install <ids> --skip-manifest-update --skip-sign-check`, from the folder's own `dotnet`,
   with the same feeds plus nuget.org. `--skip-manifest-update` means "use exactly the manifests placed in step 2".
   `dotnet workload clean` afterwards drops packs of manifests that were replaced. Then `dotnet build-server shutdown`:
   MSBuild nodes and the compiler server started by this SDK outlive a build and keep the manifests they loaded, and a
   build after a refresh would otherwise import the targets of a manifest version that is gone.

5. **global.json.** Since the .NET 10 SDK host, `global.json` accepts `sdk.paths`:

   ```json
   { "sdk": { "version": "12.0.100-alpha.1.26508.114", "paths": [ ".dotnet", "$host$" ] } }
   ```

   Inside the project the system `dotnet` resolves to the SDK in `.dotnet`; anywhere else `$host$` means the system
   install and nothing changes. The script reads the SDK version from the folder rather than from `dotnet --version`,
   which would obey a `global.json` pinned to the previous build, and runs every `dotnet` command from an empty
   temporary directory for the same reason.

## Things to know

- **`dotnet workload list` through the system `dotnet` shows nothing.** The `dotnet workload` commands take their root
  from the folder of the `dotnet` executable that runs them, so through the system one they look at the system
  install, where the nightly band does not exist (workload version `...manifests.e3b0c442`, the hash of nothing). Builds
  are fine: the MSBuild resolver derives the root from the SDK directory. Run workload commands as
  `./.dotnet/dotnet workload ...`, or put the folder first on `PATH`.
- **Multiple lanes.** `11.0.1xx-rc2` is the RC2 release branch, `11.0.1xx` the RTM release branch, `12.0.1xx` main.
  What each lane had on October 9, 2026: RC2 everything, with iOS built for Xcode 27; RTM `maui` and `android`, but
  no iOS manifest for its band on any public feed (the SDK's bundled Preview 6 one stays, and the script says so);
  .NET 12 `ios` (Xcode 27) and `android`, no `maui` yet because dotnet/maui has not moved to .NET 12. Check what the
  script prints under `Manifests`.
- **An alpha SDK is skewed.** Its templates still produce `net11.0-ios` and `net11.0-android` projects, its `ios`
  workload (from dotnet/macios `main`) still treats .NET 11 as current, but the SDK's own compat manifest already
  files .NET 11 as previous, so those projects need the `.net11` Mono packs that `ios` and `android` do not install.
  The build says which workload to add (`mobile-librarybuilder-net11` covers both); pass it to `--workloads`.
- **Restore needs the feed too.** A project built with a nightly SDK restores runtime packages of that nightly's version
  (`Microsoft.NETCore.App.Ref`, `ILLink.Tasks`, the runtime packs), which are on the `dotnet<major>` feed and not on
  nuget.org: restore fails with NU1102 until a `NuGet.config` next to the project lists that feed. The script prints the
  URL at the end.
- `--skip-sign-check` and hand-placed manifests bypass the installer's own checks, as the dotnet/maui build does.
- `global.json` and the install folder belong in your `.gitignore` (see Quick start).
- When the release you are chasing ships, `-q preview -c 11.0` (or `-q ga`) gives you the released SDK instead, and the
  released workloads come from nuget.org without any of this.

## Tests

```bash
./test.sh      # bash
./test.ps1     # PowerShell 7
```

About ninety checks each, the same list in both, that need no Microsoft download: the version-band and SemVer
functions, the compat patch, end-to-end runs on a fake SDK folder (with a fake `dotnet` that logs its calls) using
the real RC1-band manifests from nuget.org, an idempotent second run, an update with a newer SDK in the folder,
`--prune`, `--clean`, and the feed discovery from dotnet/maui's `NuGet.config`. `test.sh` needs curl, unzip, perl,
python3; both need access to nuget.org and GitHub. The PowerShell suite has been run on Linux and macOS; Windows,
where the SDK download and the `dotnet.exe` path differ, still wants a first real run.

## Manual validation

[docs/validation.md](docs/validation.md) lists the runs the suites cannot do (real downloads, a real `dotnet`,
Windows) with their expected output: update in place, a released preview in another folder and `--clean`, the
Windows path, the lane check.

## Background

Written while moving [Maui.NativeStyles](https://github.com/danardelean/Maui.NativeStyles) to .NET 11 ahead of RC2,
on a Mac that already had Xcode 27. The accompanying write-up on dev.to goes through each pitfall in order. Both the
scripts and the write-up were written together with Claude, Anthropic's AI assistant, in Claude Code.

## License

MIT.
