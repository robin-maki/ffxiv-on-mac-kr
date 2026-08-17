#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
cd "$root_dir"

if [[ "$(uname -m)" != "arm64" ]]; then
  print -u2 "This package script must run on an Apple Silicon host (arm64)."
  exit 1
fi

helper_manifest="$root_dir/Tools/zipatch-helper/Cargo.toml"
if ! command -v cargo >/dev/null 2>&1; then
  print -u2 "cargo is required to package the ZiPatch helper (Rust 1.85+)."
  exit 1
fi
cargo build --release --locked --manifest-path "$helper_manifest"
helper_binary="$root_dir/Tools/zipatch-helper/target/release/zipatch-helper"
if [[ ! -x "$helper_binary" ]]; then
  print -u2 "ZiPatch helper was not built: $helper_binary"
  exit 1
fi

swift build --disable-sandbox -c release
bin_dir="$(swift build --disable-sandbox -c release --show-bin-path)"
binary="$bin_dir/XIVKRLauncher"
if [[ ! -x "$binary" ]]; then
  print -u2 "release executable was not built: $binary"
  exit 1
fi

app_dir="$root_dir/out/XIV KR Launcher.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary" "$app_dir/Contents/MacOS/XIVKRLauncher"
chmod 755 "$app_dir/Contents/MacOS/XIVKRLauncher"
cp "$helper_binary" "$app_dir/Contents/Resources/zipatch-helper"
chmod 755 "$app_dir/Contents/Resources/zipatch-helper"

cp "$root_dir/THIRD_PARTY_NOTICES.md" "$app_dir/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$root_dir/LICENSE" "$app_dir/Contents/Resources/LICENSE"
cp -R "$root_dir/LICENSES" "$app_dir/Contents/Resources/LICENSES"

info="$app_dir/Contents/Info.plist"
/usr/bin/plutil -create xml1 "$info"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string XIVKRLauncher" "$info"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string land.jiyu.xivkrlauncher" "$info"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string XIV KR Launcher" "$info"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string XIV KR Launcher" "$info"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$info"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.1.0" "$info"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$info"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 13.0" "$info"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$info"
/usr/libexec/PlistBuddy -c "Add :LSMultipleInstancesProhibited bool true" "$info"
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$info"
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSExceptionDomains dict" "$info"
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSExceptionDomains:ngamever-live.ff14.co.kr dict" "$info"
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSExceptionDomains:ngamever-live.ff14.co.kr:NSExceptionAllowsInsecureHTTPLoads bool true" "$info"

print "Created $app_dir"
