#!/usr/bin/env bash
# install.sh (dotnet-nightly-local): a .NET nightly SDK and any of its workloads in a folder of your choice.
#
# Nothing is written to the machine-wide .NET install: the SDK, its runtime, the workload manifests and packs all land
# in one folder (default ./.dotnet), and a global.json in the current directory makes the regular `dotnet` command
# pick that SDK up from there ("sdk.paths", a .NET 10 SDK host feature). Run it again to update: a newer daily is
# installed next to the old one, the manifests are refreshed, global.json is re-pinned (--prune drops the old SDKs).
# --clean removes the folder and the global.json that points at it.
#
# Builds (`dotnet build`, the IDE) find the SDK, the workload manifests and the packs through global.json. The
# `dotnet workload ...` commands do not: they look at the folder of the dotnet executable that runs them, so run them
# as DIR/dotnet workload list (or put DIR first on PATH).
#
# Usage: install.sh [options]
#   -d, --dir DIR             install folder (default: ./.dotnet)
#   -c, --channel CHANNEL     daily-build channel, a release/* branch of dotnet/dotnet without the prefix (see
#                             --list-channels); required unless --version or --skip-sdk is given
#       --list-workloads      show the manifests of the channel's band on the feeds and the workload ids each defines,
#                             without downloading the SDK (with --channel or --version), and exit
#   -q, --quality QUALITY     daily | preview | ga (default: daily)
#   -v, --version VERSION     an exact SDK version instead of the newest build of the channel
#   -w, --workloads LIST      workloads to install, comma-separated: maui, ios, android, maui-android, wasm-tools,
#                             aspire ... (default: none, the SDK and the refreshed manifests only)
#   -b, --maui-branch BRANCH  dotnet/maui branch whose NuGet.config lists the feeds its build uses: release branches of
#                             dotnet/macios and dotnet/android publish to isolated darc-pub-* feeds, and that file names
#                             them. "auto" (default) derives it from the SDK band: release/<major>.0.1xx-<label> for
#                             a preview or rc band, net<major>.0 for a release band, main for an alpha, plus the
#                             previous major's release branches for an alpha (their isolated feeds hold the compat
#                             packs the alpha's iOS and Android workloads still need); "none" to skip
#   -f, --feeds LIST          extra NuGet v3 feeds to search for manifests and packs, comma-separated
#       --no-default-feeds    do not search the default feeds: the dotnet<major> feed on dnceng and nuget.org
#       --compat-runtime VER  runtime version for the previous major's compat manifests (default: newest on nuget.org)
#       --no-global-json      do not write global.json in the current directory
#       --skip-sdk            do not (re)install the SDK; use the newest one already in DIR
#       --manifests-only      stop after placing the manifests (no workload install)
#       --prune               remove older SDK, runtime and host versions from DIR
#       --list-channels       show the channels that currently have daily builds, with today's SDK version, and exit
#       --clean               remove DIR and, when it points at DIR, the global.json in the current directory, and exit
#   -h, --help
#
# Requires: bash 3.2+, curl, unzip, perl. macOS or Linux (Apple workloads need macOS).
#
# How it works
#   1. SDK: the official dotnet-install script, --install-dir DIR, nothing on PATH.
#   2. Manifests: a daily SDK bundles stale baseline workload manifests (preview-era iOS / MAUI, in an older band folder
#      that it falls back to). For every manifest id the SDK lists (KnownWorkloadManifests.txt) the newest package of the
#      SDK's own version band (<id>.Manifest-<band>) is downloaded from the feeds and placed in sdk-manifests/<band>/,
#      what dotnet/maui's own build does. Builds of the band's own prerelease lane (its rc.N or preview.N label) win
#      over other lanes that publish into the band.
#   3. Compat manifests: the *-net<previous> workloads (pulled in by maui, ios, android, wasm-tools for apps on the
#      previous .NET) reference the previous runtime the SDK was built with, often a servicing release that reaches
#      nuget.org only on Patch Tuesday. They are pointed at the newest public one instead; they are not used to build
#      for the new .NET anyway.
#   4. Packs: `dotnet workload install` with --skip-manifest-update (exactly the manifests placed above) from the same
#      feeds plus nuget.org. `dotnet workload clean` drops packs of replaced manifests.
set -euo pipefail

INSTALL_SCRIPT_URL="https://builds.dotnet.microsoft.com/dotnet/scripts/v1/dotnet-install.sh"
NUGET_ORG="https://api.nuget.org/v3/index.json"
DNCENG="https://pkgs.dev.azure.com/dnceng/public/_packaging"
BUILDS_TABLE_URL="https://raw.githubusercontent.com/dotnet/dotnet/main/docs/builds-table.md"
AKAMS_CHANNELS_URL="https://raw.githubusercontent.com/dotnet/arcade/main/src/Microsoft.DotNet.Build.Tasks.Feed/src/model/PublishingConstants.cs"
CURL=(curl -sSL --max-time 60)

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Version band of an SDK version: the patch number rounded down to the hundred and the preview/rc/alpha label kept,
# the build number and an rtm/servicing label dropped (X.Y.Zpp-<label>.N.<build> -> X.Y.Z00-<label>.N)
band_of() { echo "$1" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9])[0-9][0-9](-(preview|rc|alpha)\.[0-9]+)?.*$/\100\2/'; }
# Prerelease label of a band (rc.N, preview.N, alpha.N), empty for a release band
label_of() { case "$1" in *-*) echo "${1#*-}" ;; *) echo "" ;; esac; }
major_of() { echo "${1%%.*}"; }
# The dotnet/maui branch that builds against a band: release/<major>.0.1xx-<label without the dot> for a preview or
# rc band, net<major>.0 for a release band, main for an alpha band
maui_branch_for() {
  local major label; major="$(major_of "$1")"; label="$(label_of "$1")"
  case "$label" in
    "") echo "net$major.0" ;;
    alpha.*) echo "main" ;;
    *) echo "release/$major.0.1xx-$(echo "$label" | tr -d .)" ;;
  esac
}
# The dotnet/maui branches whose NuGet.config to read for a band, one per line: the band's own branch and, for an alpha
# band, the previous major's release branches too (net<prev>.0 and the newest release/<prev>.0.1xx-*). main has not
# branched for the new major yet, and the alpha's iOS and Android workloads carry compat packs of the previous major's
# unreleased servicing builds, which sit on the isolated feeds only those branches name.
maui_branches_for() {
  local band="$1" primary prev heads; primary="$(maui_branch_for "$band")"; echo "$primary"
  [ "$primary" = main ] && command -v git > /dev/null 2>&1 || return 0
  prev=$(( $(major_of "$band") - 1 ))
  heads="$(git ls-remote --heads https://github.com/dotnet/maui "refs/heads/net$prev.0" "refs/heads/release/$prev.0.1xx-*" 2>/dev/null \
    | sed 's#.*refs/heads/##' || true)"
  echo "$heads" | grep -x "net$prev.0" || true
  # the newest release branch by its label's SemVer precedence (rc2 above preview7), through pick_highest
  echo "$heads" | grep '^release/' | sed -E "s#^release/[0-9]+\.0\.1xx-([a-z]+)([0-9]+)\$#$prev.0.100-\1.\2\t&#" | pick_highest | cut -f2
}

# NuGet v3 flat container: <feed>/flat2/<id>/index.json lists the versions, <feed>/flat2/<id>/<v>/<id>.<v>.nupkg is the package.
flat() {
  case "$1" in
    "$NUGET_ORG") echo "https://api.nuget.org/v3-flatcontainer" ;;
    *) echo "${1%/index.json}/flat2" ;;
  esac
}
versions() { "${CURL[@]}" -f "$(flat "$1")/$2/index.json" 2>/dev/null | tr -d ' \n' | grep -o '"versions":\[[^]]*\]' | grep -o '"[^"]*"' | tr -d '"' || true; }

# stdin: "version<TAB>anything" lines; stdout: the line with the highest version by Semantic Versioning precedence
# (numeric core, a release above its prereleases, prerelease fields compared one by one, numeric < alphanumeric).
pick_highest() {
  perl -e '
    sub cmpv {
      my ($v1, $v2) = @_;
      my ($c1, $p1) = split /-/, $v1, 2; my ($c2, $p2) = split /-/, $v2, 2;
      my @n1 = split /\./, $c1; my @n2 = split /\./, $c2;
      for my $i (0..2) { my $c = ($n1[$i] // 0) <=> ($n2[$i] // 0); return $c if $c; }
      return 0 if !defined $p1 && !defined $p2; return 1 if !defined $p1; return -1 if !defined $p2;
      my @f1 = split /\./, $p1; my @f2 = split /\./, $p2;
      for my $i (0..($#f1 > $#f2 ? $#f1 : $#f2)) {
        my ($x, $y) = ($f1[$i], $f2[$i]);
        return -1 if !defined $x; return 1 if !defined $y;
        my $c = ($x =~ /^\d+$/ && $y =~ /^\d+$/) ? $x <=> $y : ($x =~ /^\d+$/ ? -1 : ($y =~ /^\d+$/ ? 1 : $x cmp $y));
        return $c if $c;
      }
      return 0;
    }
    my @lines = grep { /\S/ } map { chomp; $_ } <STDIN>;
    my ($best) = sort { cmpv((split /\t/, $b)[0], (split /\t/, $a)[0]) } @lines;
    print "$best\n" if defined $best;'
}

# Newest released MAJOR.0.x runtime on nuget.org (Microsoft.NETCore.App.Ref)
newest_public_runtime() {
  # no match is a result (the previous major may have no release yet), not a failure under pipefail
  versions "$NUGET_ORG" microsoft.netcore.app.ref | { grep -E "^$1\.0\.[0-9]+\$" || true; } | sed 's/$/	/' | pick_highest | cut -f1
}

# The compat manifests of the previous major (*.net<PREV>) under DIR: point their <PREV>.0.x pack versions at VERSION
patch_compat_manifests() {
  local dir="${1:?}" prev="${2:?}" version="${3:?}" manifest current
  for manifest in "$dir"/sdk-manifests/*/microsoft.net.workload.mono.toolchain.net"$prev"/*/WorkloadManifest.json \
                  "$dir"/sdk-manifests/*/microsoft.net.workload.emscripten.net"$prev"/*/WorkloadManifest.json; do
    [ -f "$manifest" ] || continue
    current="$(grep -o "\"version\" *: *\"$prev\.0\.[0-9]*\"" "$manifest" | head -1 | grep -o "$prev\.0\.[0-9]*" || true)"
    if [ -n "$current" ] && [ "$current" != "$version" ]; then
      log "  compat manifest $(basename "$(dirname "$(dirname "$manifest")")"): .NET $current -> $version"
      perl -pi -e "s/\"\Q$current\E\"/\"$version\"/g" "$manifest"
    fi
  done
}

# Channels. A channel is an aka.ms name that Arcade's publishing constants (dotnet/arcade, PublishingConstants.cs)
# assign to a build channel: X.Y.1xx for the X.Y.1xx SDK channel, X.Y.1xx-rc2 for its RC 2, X.Y.1xx-preview3 ... The
# .NET builds table (dotnet/dotnet, docs/builds-table.md) links the actively built ones, but it lags behind a branding
# change: when main moves to the next major its column keeps the old name for a while, so the old name serves the new
# major's alphas until the new release branch takes it over. So the candidates are the table's channels plus every SDK
# channel name Arcade declares for those majors and the next one, and each is probed; only the ones that resolve are
# shown (the table's own always are, with ? when they do not).
# A channel's current SDK version is read the way dotnet-install does it: the aka.ms link of the SDK archive redirects
# to the build's own URL, which carries the version (.../Sdk/<version>/dotnet-sdk-<version>-<rid>.tar.gz); a HEAD
# request follows it without downloading. An unknown aka.ms path does not 404 but lands on a Microsoft search page,
# hence the pattern check.
channel_version() {
  local url path="$1/${2:-daily}"
  [ "${2:-daily}" = ga ] && path="$1"
  url="$(curl -sSIL --max-time 60 -o /dev/null -w '%{url_effective}' "https://aka.ms/dotnet/$path/dotnet-sdk-linux-x64.tar.gz" 2>/dev/null || true)"
  case "$url" in
    *dotnet-sdk-*-linux-x64.tar.gz) echo "$url" | sed -E 's#.*/dotnet-sdk-(.+)-linux-x64\.tar\.gz$#\1#' ;;
    *) echo "?" ;;
  esac
}
table_channels() {
  "${CURL[@]}" -f "$BUILDS_TABLE_URL" | grep -o 'aka\.ms/dotnet/[^/)" ]*/daily' | sed 's#aka\.ms/dotnet/##; s#/daily##' | sort -u
}
channel_candidates() {
  local table majors next names m
  table="$(table_channels)"
  [ -n "$table" ] || die "could not read the builds table at $BUILDS_TABLE_URL"
  majors="$(echo "$table" | cut -d. -f1 | sort -un)"
  next=$(( $(echo "$majors" | tail -1) + 1 ))
  names="$("${CURL[@]}" -f "$AKAMS_CHANNELS_URL" 2>/dev/null | grep -o -E '"[0-9]+\.[0-9]+\.[0-9]xx[^"]*"' | tr -d '"' || true)"
  { echo "$table"; for m in $majors $next; do echo "$names" | grep -E "^$m\." || true; done; } | sort -u
}
list_channels() {
  local table ch version
  table="$(table_channels)"
  printf '%-20s %s\n' "channel" "current daily SDK"
  for ch in $(channel_candidates); do
    version="$(channel_version "$ch")"
    if [ "$version" = "?" ]; then echo "$table" | grep -q -x -F "$ch" || continue; fi
    printf '%-20s %s\n' "$ch" "$version"
  done
}

# Highest version folder under DIR/<sub>
newest_dir() { ls -d "${1:?}"/*/ 2>/dev/null | xargs -n1 basename | sed 's/$/	/' | pick_highest | cut -f1; }

# Short name of a feed for the log: the dnceng feed name, or nuget.org
feed_name() { echo "$1" | sed -E 's#.*/_packaging/([^/]*)/.*#\1#; s#https://api.nuget.org.*#nuget.org#'; }

# The feeds for a band, into the caller's `feeds` array: the dotnet<major> feed and nuget.org (a released preview or
# RC has its manifests there), then the feeds of dotnet/maui's branches (dotnet<major>-transport and the isolated
# darc-pub-* ones). Reads major, band, maui_branch, extra_feeds, default_feeds from the caller.
collect_feeds() {
  local f b pattern="dotnet$major[^/]*|darc-pub-[^/]*"
  feeds=()
  add_feed() { for f in "${feeds[@]+"${feeds[@]}"}"; do [ "$f" = "$1" ] && return 0; done; feeds+=("$1"); }
  if [ "$default_feeds" = 1 ]; then add_feed "$DNCENG/dotnet$major/nuget/v3/index.json"; add_feed "$NUGET_ORG"; fi
  [ "$maui_branch" = "auto" ] && maui_branch="$(maui_branches_for "$band" | tr '\n' ' ' | sed 's/ $//')"
  if [ "$maui_branch" != "none" ]; then
    for b in $maui_branch; do
      for f in $("${CURL[@]}" -f "https://raw.githubusercontent.com/dotnet/maui/$b/NuGet.config" 2>/dev/null \
          | grep -o 'value="https://pkgs.dev.azure.com/dnceng/public/_packaging/[^"]*"' | cut -d'"' -f2 \
          | grep -E "/($pattern)/nuget/v3/index.json\$" || true); do add_feed "$f"; done
      pattern="darc-pub-[^/]*"   # a previous-major branch contributes its isolated feeds only
    done
  fi
  for f in $(echo "$extra_feeds" | tr ',' ' '); do add_feed "$f"; done
  [ ${#feeds[@]} -gt 0 ] || die "no feeds to search (see --feeds)"
  log "Feeds:"; [ "$maui_branch" = "none" ] || log "  (from dotnet/maui NuGet.config: $maui_branch)"
  for f in "${feeds[@]}"; do log "  $f"; done
}

# The newest build of manifest package PKG across the feeds, as "version<TAB>feed" (empty when none). Builds of the
# band's own prerelease lane come first: other lanes publish into the band too, and a preview build from main can
# outrank the band's rc build by version alone. Reads feeds, label, work from the caller.
select_manifest() {
  local pkg="$1" f v
  : > "$work/candidates"
  for f in "${feeds[@]}"; do
    for v in $(versions "$f" "$pkg"); do printf '%s\t%s\n' "$v" "$f" >> "$work/candidates"; done
  done
  if [ -n "$label" ] && grep -q -F -- "$label" "$work/candidates"; then
    grep -F -- "$label" "$work/candidates" > "$work/candidates.lane" && mv "$work/candidates.lane" "$work/candidates"
  fi
  pick_highest < "$work/candidates"
}

# The manifest ids to look for on the feeds, lowercase, one per line: every *.manifest-<band> package the dnceng feeds
# list through their package search (a substring query), plus the ids an SDK of this major lists in its
# KnownWorkloadManifests.txt (nuget.org's search does not return these packages, its flat index does; each id is then
# probed on every feed and the absent ones are skipped). Reads feeds, band, major from the caller.
discover_manifest_ids() {
  local f name n
  {
    for f in "${feeds[@]}"; do
      case "$f" in
        "$DNCENG"/*)
          name="$(feed_name "$f")"
          "${CURL[@]}" -f "https://feeds.dev.azure.com/dnceng/public/_apis/packaging/feeds/$name/packages?packageNameQuery=manifest-$band&api-version=7.1&\$top=500" 2>/dev/null \
            | tr -d '\n' | grep -o '"name": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' || true ;;
      esac
    done | tr '[:upper:]' '[:lower:]' | grep -E "\.manifest-$band\$" | grep -v '\.msi\.' | sed "s/\.manifest-$band\$//" || true
    for n in android ios maccatalyst macos tvos maui; do echo "microsoft.net.sdk.$n"; done
    for n in current $(seq 6 $((major - 1)) | sed 's/^/net/'); do
      echo "microsoft.net.workload.mono.toolchain.$n"; echo "microsoft.net.workload.emscripten.$n"
    done
  } | sort -u
}

# The workload ids a WorkloadManifest.json defines, abstract ones excluded, one per line (the files carry // comments
# and trailing commas, which JSON::PP rejects)
manifest_workloads() {
  perl -MJSON::PP -0777 -ne 's/^\s*\/\/[^\n]*//mg; s/,(\s*[}\]])/$1/g; my $d = eval { decode_json($_) } or exit 0;
    for my $w (sort keys %{ $d->{workloads} || {} }) { print "$w\n" unless $d->{workloads}{$w}{abstract} }' "$1"
}

# --list-workloads: the manifests of a channel's band on the feeds and the workload ids each defines, without
# downloading the SDK. The SDK version comes from the channel's archive link (or --version), the band from it, the
# feeds as for an install. Reads channel, quality, version, maui_branch, extra_feeds, default_feeds, work from main.
show_workloads() {
  local sdk_version="$version" band label major feeds=() ids id pkg chosen best best_feed workloads found="" missing=""
  if [ -z "$sdk_version" ]; then
    sdk_version="$(channel_version "$channel" "$quality")"
    [ "$sdk_version" != "?" ] || die "no SDK archive behind https://aka.ms/dotnet/$channel (see --list-channels)"
  fi
  band="$(band_of "$sdk_version")"; label="$(label_of "$band")"; major="$(major_of "$sdk_version")"
  log "SDK $sdk_version (band $band)${channel:+, channel $channel}"
  collect_feeds
  log "Manifests ($band) and the workloads each defines:"
  ids="$(discover_manifest_ids)"
  [ -n "$ids" ] || die "no *.manifest-$band package on any of the feeds"
  for id in $ids; do
    pkg="$id.manifest-$band"
    chosen="$(select_manifest "$pkg")"
    [ -n "$chosen" ] || continue
    best="$(echo "$chosen" | cut -f1)"; best_feed="$(echo "$chosen" | cut -f2)"
    "${CURL[@]}" -f "$(flat "$best_feed")/$pkg/$best/$pkg.$best.nupkg" -o "$work/$pkg.nupkg"
    unzip -p "$work/$pkg.nupkg" data/WorkloadManifest.json > "$work/wm.json" 2>/dev/null || : > "$work/wm.json"
    log "  $id: $best  ($(feed_name "$best_feed"))"
    workloads="$(manifest_workloads "$work/wm.json" | tr '\n' ' ' | sed 's/ $//')"
    log "      ${workloads:-(abstract workloads only: extended by others)}"
    found="$found $id"
  done
  # the ids an SDK with the mobile workloads knows, so that a lane that lacks one says so
  for id in microsoft.net.sdk.android microsoft.net.sdk.ios microsoft.net.sdk.maccatalyst microsoft.net.sdk.macos microsoft.net.sdk.tvos microsoft.net.sdk.maui; do
    case " $found " in *" $id "*) ;; *) missing="$missing $id" ;; esac
  done
  [ -z "$missing" ] || log "Not on any of the feeds for this band:$missing"
  log "Install: $0 ${channel:+--channel $channel }${version:+--version $version }--workloads <id,id,...>"
}

main() {
  local dir="./.dotnet" channel="" quality="daily" version="" workloads="" maui_branch="auto"
  local extra_feeds="" default_feeds=1 compat_runtime="" global_json=1 skip_sdk=0 manifests_only=0 prune=0 clean=0 list_workloads=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -d|--dir) dir="$2"; shift 2 ;;
      -c|--channel) channel="$2"; shift 2 ;;
      -q|--quality) quality="$2"; shift 2 ;;
      -v|--version) version="$2"; shift 2 ;;
      -w|--workloads) workloads="$2"; shift 2 ;;
      -b|--maui-branch) maui_branch="$2"; shift 2 ;;
      -f|--feeds) extra_feeds="$2"; shift 2 ;;
      --no-default-feeds) default_feeds=0; shift ;;
      --compat-runtime) compat_runtime="$2"; shift 2 ;;
      --no-global-json) global_json=0; shift ;;
      --skip-sdk) skip_sdk=1; shift ;;
      --manifests-only) manifests_only=1; shift ;;
      --prune) prune=1; shift ;;
      --list-channels) list_channels; return 0 ;;
      --list-workloads) list_workloads=1; shift ;;
      --clean) clean=1; shift ;;
      -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; return 0 ;;
      *) die "unknown option $1 (see --help)" ;;
    esac
  done
  if [ "$clean" = 1 ]; then
    [ -d "$dir" ] || die "$dir does not exist"
    dir="$(cd "$dir" && pwd)"
    # only a folder this script could have made: a dotnet executable or an sdk/ folder inside
    if [ ! -x "$dir/dotnet" ] && [ ! -f "$dir/dotnet.exe" ] && [ ! -d "$dir/sdk" ]; then
      die "$dir does not look like a .NET folder (no dotnet executable, no sdk/): not removing it"
    fi
    rm -rf "${dir:?}"
    log "Removed $dir"
    local rel="$dir"
    case "$dir" in "$PWD"/*) rel="${dir#"$PWD"/}" ;; esac
    if [ -f global.json ] && grep -q -F -- "\"$rel\"" global.json; then
      rm -f global.json
      log "Removed global.json (it pointed at $rel)"
    fi
    return 0
  fi
  if [ "$list_workloads" = 1 ]; then
    [ -n "$channel$version" ] || die "choose a channel with --channel (or an exact SDK with --version) to list its workloads"
    work="$(mktemp -d)"
    trap 'rm -rf "${work:?}"' EXIT
    for tool in curl unzip perl; do command -v "$tool" >/dev/null || die "$tool is required"; done
    show_workloads
    return 0
  fi
  if [ "$skip_sdk" = 0 ] && [ -z "$channel" ] && [ -z "$version" ]; then
    die "choose a daily-build channel with --channel (or an exact SDK with --version). The channels with dailies: $0 --list-channels"
  fi
  mkdir -p "$dir"
  dir="$(cd "$dir" && pwd)"
  work="$(mktemp -d)"   # not local: the EXIT trap runs after main returns
  trap 'rm -rf "${work:?}"' EXIT
  for tool in curl unzip perl; do command -v "$tool" >/dev/null || die "$tool is required"; done

  # ---- 1. SDK ----------------------------------------------------------------------------------------------------------
  if [ "$skip_sdk" = 0 ]; then
    "${CURL[@]}" "$INSTALL_SCRIPT_URL" -o "$work/dotnet-install.sh"
    if [ -n "$version" ]; then
      # --version and --quality are mutually exclusive; dailies are served from ci.dot.net/public, one of the script's feeds
      bash "$work/dotnet-install.sh" --version "$version" --install-dir "$dir" --no-path
    else
      # resolves https://aka.ms/dotnet/<channel>/<quality>/dotnet-sdk-<os>-<arch>.tar.gz
      bash "$work/dotnet-install.sh" --channel "$channel" --quality "$quality" --install-dir "$dir" --no-path
    fi
  fi
  [ -x "$dir/dotnet" ] || die "no dotnet in $dir"
  # The newest SDK in the folder, from the folder itself: `dotnet --version` would obey a global.json pinned to an older one
  local sdk_version; sdk_version="$(newest_dir "$dir/sdk")"
  [ -n "$sdk_version" ] || die "no SDK in $dir/sdk"
  local band label major prev
  band="$(band_of "$sdk_version")"; label="$(label_of "$band")"; major="$(major_of "$sdk_version")"; prev=$((major - 1))
  local manifests_dir="$dir/sdk-manifests/$band"
  log "SDK $sdk_version (band $band) in $dir"
  mkdir -p "$manifests_dir"
  # dotnet commands run from an empty directory: a global.json up the tree would select another SDK
  local run_dir="$work/run"; mkdir -p "$run_dir"
  dotnet() { (cd "$run_dir" && DOTNET_ROOT="$dir" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 "$dir/dotnet" "$@"); }

  # ---- 2. Feeds --------------------------------------------------------------------------------------------------------
  local feeds=() f
  collect_feeds

  # ---- 3. Manifests of this band -----------------------------------------------------------------------------------------
  local ids="$work/manifest-ids.txt"
  if [ -f "$dir/sdk/$sdk_version/KnownWorkloadManifests.txt" ]; then
    cp "$dir/sdk/$sdk_version/KnownWorkloadManifests.txt" "$ids"
  elif [ -f "$dir/sdk/$sdk_version/IncludedWorkloadManifests.txt" ]; then
    cp "$dir/sdk/$sdk_version/IncludedWorkloadManifests.txt" "$ids"
  else
    ls -d "$dir"/sdk-manifests/*/*/ | xargs -n1 basename | grep -v '^workloadsets$' | sort -u > "$ids"
  fi
  log "Manifests ($band):"
  local id pkg v chosen best best_feed have target manifests_changed=0
  while IFS= read -r id || [ -n "$id" ]; do
    id="$(echo "$id" | tr -d '\r' | tr '[:upper:]' '[:lower:]')"
    [ -z "$id" ] && continue
    pkg="$id.manifest-$band"
    chosen="$(select_manifest "$pkg")"
    best="${chosen%%	*}"; best_feed="${chosen#*	}"
    if [ -z "$best" ]; then
      have="$(ls -d "$dir"/sdk-manifests/*/"$id"/*/ 2>/dev/null | tail -1 || true)"
      log "  $id: no $pkg on any feed, keeping the SDK's ${have:-<none>}"
      continue
    fi
    target="${manifests_dir:?}/${id:?}"
    if [ -d "$target/$best" ]; then
      log "  $id: $best (present)"
      continue
    fi
    log "  $id: $best  ($(feed_name "$best_feed"))"
    "${CURL[@]}" -f "$(flat "$best_feed")/$pkg/$best/$pkg.$best.nupkg" -o "$work/$pkg.nupkg"
    rm -rf "${work:?}/data" && unzip -q -o "$work/$pkg.nupkg" 'data/*' -d "$work"
    rm -rf "${target:?}" && mkdir -p "$target/$best" && cp -R "$work/data/." "$target/$best/"
    manifests_changed=1
  done < "$ids"
  # manifest versions pinned by an earlier install would override the folders above
  rm -f "$dir/metadata/workloads/$band/InstallState/default.json"

  # ---- 4. Compat manifests of the previous major ---------------------------------------------------------------------------
  [ -n "$compat_runtime" ] || compat_runtime="$(newest_public_runtime "$prev")"
  if [ -n "$compat_runtime" ]; then
    patch_compat_manifests "$dir" "$prev" "$compat_runtime"
  else
    log "  (no public .NET $prev runtime found on nuget.org: compat manifests left as they are)"
  fi

  # ---- 5. Packs ----------------------------------------------------------------------------------------------------------
  local sources=()
  add_feed "$NUGET_ORG"   # packs of released runtimes and tools
  for f in "${feeds[@]}"; do sources+=(--source "$f"); done
  # a workload no manifest of the band defines (no maui on an alpha yet) is skipped: the installer would otherwise take
  # it from the SDK's older bundled manifest
  local requested="$workloads" w m known=""
  if [ -n "$workloads" ]; then
    known="$(for m in "$manifests_dir"/*/*/WorkloadManifest.json; do if [ -f "$m" ]; then manifest_workloads "$m"; fi; done)"
    workloads=""
    for w in $(echo "$requested" | tr ',' ' '); do
      if echo "$known" | grep -q -x -- "$w"; then workloads="${workloads:+$workloads,}$w"
      else log "  workload $w: no manifest of band $band defines it, skipped (see --list-workloads)"; fi
    done
  fi
  if [ "$manifests_only" = 1 ] || [ -z "$workloads" ]; then
    [ -n "$requested" ] || log "No workloads requested (-w). Later: $dir/dotnet workload install <id> --skip-manifest-update --skip-sign-check ${sources[*]}"
  else
    # shellcheck disable=SC2046
    dotnet workload install $(echo "$workloads" | tr ',' ' ') --skip-manifest-update --skip-sign-check "${sources[@]}"
    dotnet workload clean >/dev/null 2>&1 || true
    dotnet workload list
  fi
  # MSBuild nodes and compiler servers started by this SDK outlive a build and keep the manifests they loaded: a build
  # after a refresh would still import the targets of a manifest version that is gone
  if [ "$manifests_changed" = 1 ] || { [ "$manifests_only" != 1 ] && [ -n "$workloads" ]; }; then
    dotnet build-server shutdown > /dev/null 2>&1 || true
  fi

  # ---- 6. Prune ----------------------------------------------------------------------------------------------------------
  if [ "$prune" = 1 ]; then
    local sub keep d
    for sub in sdk shared/Microsoft.NETCore.App shared/Microsoft.AspNetCore.App host/fxr; do
      [ -d "$dir/$sub" ] || continue
      keep="$(newest_dir "$dir/$sub")"
      for d in "${dir:?}/${sub:?}"/*/; do
        [ "$(basename "$d")" = "$keep" ] || { log "  pruning $sub/$(basename "$d")"; rm -rf "${d:?}"; }
      done
    done
  fi

  # ---- 7. global.json ----------------------------------------------------------------------------------------------------
  if [ "$global_json" = 1 ]; then
    local rel="$dir"
    case "$dir" in "$PWD"/*) rel="${dir#"$PWD"/}" ;; esac
    cat > global.json <<JSON
{
  "sdk": {
    "version": "$sdk_version",
    "paths": [ "$rel", "\$host\$" ],
    "errorMessage": "The .NET SDK $sdk_version was not found in $rel: run the install script again."
  }
}
JSON
    log "global.json: SDK $sdk_version from $rel"
  fi
  log "Manifests in $manifests_dir:"
  for d in "$manifests_dir"/*/; do [ "$(basename "$d")" = "workloadsets" ] || log "  $(basename "$d"): $(ls "$d" | tr '\n' ' ')"; done
  log "Workload commands look at the folder of the dotnet that runs them: use $dir/dotnet workload list (builds need nothing)."
  log "If a restore fails with NU1102 on packages of this SDK's version, list its feed in a NuGet.config next to the project: $DNCENG/dotnet$major/nuget/v3/index.json"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
