#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Archives Aoshingo for one distribution channel, uploads it to App Store Connect and tags the
# commit with a signed tag (docs/release.md). Runs on a Mac with Xcode, signing set up in
# Config/Local.xcconfig, and a GPG key for `git tag -s`.
#
#   Tools/release/release.sh testflight [--dry-run] [--no-upload] [--internal-only] [--build N]
#   Tools/release/release.sh appstore   [--dry-run] [--no-upload] [--build N]
#
#   --dry-run        only print the version, build number and tag
#   --no-upload      archive and check the archive; no tag, no upload
#   --internal-only  TestFlight internal testing only: App Store Connect refuses to submit the build
#                    for App Store review or external testing
#   --build N        use build number N instead of the next one after the tags (it must be higher)
#
# Version:      MARKETING_VERSION in Config/Base.xcconfig (three numbers).
# Build number: one more than the highest build number in the tags `v*` (the `-tf.N` of a
#               TestFlight tag, or the `Build: N` line of any tag message).
# Tag:          vX.Y.Z-tf.N for TestFlight, vX.Y.Z for the App Store. Pushed once the upload succeeds.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

usage() {
    sed -n '/^#   Tools\/release/,/^#   --build/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

channel=""
dry_run=0
upload=1
internal_only=0
build_override=""

while [ $# -gt 0 ]; do
    case "$1" in
        testflight|appstore) [ -z "$channel" ] || usage; channel="$1" ;;
        --dry-run) dry_run=1 ;;
        --no-upload) upload=0 ;;
        --internal-only) internal_only=1 ;;
        --build) shift; [ $# -gt 0 ] || usage; build_override="$1" ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
    shift
done
[ -n "$channel" ] || usage
if [ "$internal_only" = 1 ] && [ "$channel" != testflight ]; then
    die "--internal-only is for testflight builds only"
fi

cd "$(git rev-parse --show-toplevel)"

# --- Source: a clean, pushed main or release/* branch ---------------------------------------

branch="$(git symbolic-ref --quiet --short HEAD)" || die "HEAD is detached; check out main or a release/* branch"
case "$branch" in
    main|release/*) ;;
    *) die "release from main or a release/* branch, not $branch" ;;
esac
[ -z "$(git status --porcelain)" ] || die "the working tree has changes; commit or stash them first"

echo "Fetching origin..."
git fetch --quiet --tags origin "$branch"
[ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$branch")" ] \
    || die "HEAD is not origin/$branch; pull or push first so that the tag points at a published commit"
commit="$(git rev-parse --short HEAD)"

# --- Version, build number and tag ------------------------------------------------------------

version="$(sed -n 's/^MARKETING_VERSION *= *\([^ ]*\) *$/\1/p' Config/Base.xcconfig)"
echo "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
    || die "MARKETING_VERSION in Config/Base.xcconfig must be three numbers like 1.2.0, not '$version'"
if [ -f Config/Local.xcconfig ] && grep -Eq '^ *(MARKETING_VERSION|CURRENT_PROJECT_VERSION|AOSHINGO_CHANNEL) *=' Config/Local.xcconfig; then
    die "Config/Local.xcconfig sets MARKETING_VERSION, CURRENT_PROJECT_VERSION or AOSHINGO_CHANNEL; remove it for a release"
fi

if git rev-parse --quiet --verify "refs/tags/v$version" >/dev/null; then
    die "v$version is already released to the App Store; raise MARKETING_VERSION first"
fi

highest=0
for n in $(git tag -l 'v*' | sed -n 's/^v.*-tf\.\([0-9][0-9]*\)$/\1/p') \
         $(git for-each-ref 'refs/tags/v*' --format='%(contents)' | sed -n 's/^Build: *\([0-9][0-9]*\) *$/\1/p'); do
    if [ "$n" -gt "$highest" ]; then highest="$n"; fi
done
if [ -n "$build_override" ]; then
    echo "$build_override" | grep -Eq '^[1-9][0-9]*$' || die "--build takes a positive integer"
    [ "$build_override" -gt "$highest" ] || die "--build $build_override is not higher than build $highest of the tags"
    build="$build_override"
else
    build=$((highest + 1))
fi

case "$channel" in
    testflight) tag="v$version-tf.$build"; title="TestFlight 版 $version（ビルド $build）" ;;
    appstore)   tag="v$version";           title="App Store 版 $version（ビルド $build）" ;;
esac
git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null && die "tag $tag already exists"

echo
echo "  channel  $channel"
echo "  version  $version"
echo "  build    $build (highest in the tags: $highest)"
echo "  tag      $tag"
echo "  commit   $commit on $branch"
echo
[ "$dry_run" = 1 ] && exit 0

# --- Archive ---------------------------------------------------------------------------------

work="build/release/$tag"
rm -rf "$work"
mkdir -p "$work"
archive="$work/Aoshingo.xcarchive"

echo "Archiving (log: $work/archive.log)..."
xcodebuild archive \
    -project Aoshingo.xcodeproj \
    -scheme Aoshingo \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive" \
    -allowProvisioningUpdates \
    CURRENT_PROJECT_VERSION="$build" \
    AOSHINGO_CHANNEL="$channel" \
    >"$work/archive.log" 2>&1 || die "xcodebuild archive failed; see $work/archive.log"

plist="$archive/Products/Applications/Aoshingo.app/Info.plist"
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }
[ "$(read_plist CFBundleShortVersionString)" = "$version" ] || die "the archive is not version $version"
[ "$(read_plist CFBundleVersion)" = "$build" ] || die "the archive is not build $build"
[ "$(read_plist AoshingoChannel)" = "$channel" ] || die "the archive is not the $channel channel"
[ -n "$(read_plist AoshingoReportHost)" ] || die "AOSHINGO_REPORT_HOST is empty: this build would never upload field data"
echo "Archive checked: $archive"
team="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:Team' "$archive/Info.plist" 2>/dev/null || true)"

if [ "$upload" = 0 ]; then
    echo "--no-upload: not tagged and not uploaded."
    exit 0
fi

# --- Tag, upload, push -----------------------------------------------------------------------

# Signed before the upload, so that a missing key stops the release before the build number is used.
git tag -s "$tag" -m "$title

Version: $version
Build: $build
Channel: $channel"
git tag -v "$tag" >/dev/null 2>&1 || { git tag -d "$tag" >/dev/null; die "could not verify the signature of $tag"; }

testflight_only=false
[ "$internal_only" = 1 ] && testflight_only=true
cat >"$work/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>testFlightInternalTestingOnly</key><$testflight_only/>
</dict>
</plist>
PLIST

echo "Uploading build $build to App Store Connect (log: $work/upload.log)..."
if ! xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportOptionsPlist "$work/ExportOptions.plist" \
    -exportPath "$work/export" \
    -allowProvisioningUpdates \
    >"$work/upload.log" 2>&1; then
    git tag -d "$tag" >/dev/null
    die "the upload failed and $tag was deleted; see $work/upload.log"
fi

# Keep the archive where Xcode's Organizer lists it.
archives="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
mkdir -p "$archives"
mv "$archive" "$archives/Aoshingo ${tag#v} ($build).xcarchive" || echo "warning: the archive stays in $work" >&2

echo "Pushing $tag..."
git push origin "refs/tags/$tag" || die "uploaded, but pushing $tag failed; push it with: git push origin refs/tags/$tag"

echo
echo "Done: $tag ($commit) is uploaded as $version ($build)."
case "$channel" in
    testflight)
        echo "Next: when App Store Connect has processed it, add it to the TestFlight groups and write 'What to Test'."
        ;;
    appstore)
        echo "Next: install it from TestFlight and check that it behaves as the App Store build; then, in App Store"
        echo "Connect, create version $version, choose build $build (never a -tf build) and submit it for review."
        echo "After the release: gh release create $tag --verify-tag --title '$version', and raise MARKETING_VERSION."
        ;;
esac
