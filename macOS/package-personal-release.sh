#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_path="$script_dir/BitChordMac.xcodeproj"
derived_data="$script_dir/DerivedData-Universal"
app_path="$derived_data/Build/Products/Release/Lilt.app"
helper_cache="$derived_data/HelperCache"
distribution_dir="$script_dir/Distribution"
archive_path="$distribution_dir/Lilt-personal-universal.zip"
install_guide="$distribution_dir/INSTALL.txt"
temporary_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/lilt-release.XXXXXX")
staging_dir="$temporary_root/Lilt personal release"
temporary_archive="$temporary_root/Lilt-personal-universal.zip"
yt_dlp_archive="$helper_cache/yt-dlp_macos-2026.08.19.zip"
deno_arm_archive="$helper_cache/deno-aarch64-2.9.6.zip"
deno_intel_archive="$helper_cache/deno-x86_64-2.9.6.zip"

verify_checksum() {
  local file_path=$1
  local expected=$2
  [[ -f "$file_path" ]] || return 1
  local actual=$(/usr/bin/shasum -a 256 "$file_path" | /usr/bin/awk '{print $1}')
  [[ "$actual" == "$expected" ]]
}

fetch_verified() {
  local url=$1
  local destination=$2
  local expected=$3
  local temporary_download="$temporary_root/${destination:t}.download"

  if verify_checksum "$destination" "$expected"; then
    return
  fi
  /usr/bin/curl -fL --retry 2 --output "$temporary_download" "$url"
  if ! verify_checksum "$temporary_download" "$expected"; then
    print -u2 "Checksum mismatch for $url"
    exit 1
  fi
  /bin/mv -f "$temporary_download" "$destination"
}

resolve_signing_identity() {
  if [[ -n "${LILT_SIGNING_IDENTITY:-}" ]]; then
    print -r -- "$LILT_SIGNING_IDENTITY"
    return
  fi

  local identity
  identity=$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -F '"' '/Developer ID Application:/ { print $2; exit }')
  if [[ -z "$identity" ]]; then
    identity=$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -F '"' '/Apple Development:/ { print $2; exit }')
  fi
  print -r -- "$identity"
}

sign_helper() {
  local path=$1
  if [[ "$signing_identity" == Developer\ ID\ Application:* ]]; then
    /usr/bin/codesign --force --timestamp --sign "$signing_identity" "$path"
  else
    /usr/bin/codesign --force --timestamp=none --sign "$signing_identity" "$path"
  fi
}

sign_app() {
  local path=$1
  if [[ "$signing_identity" == Developer\ ID\ Application:* ]]; then
    /usr/bin/codesign --force --options runtime --timestamp --sign "$signing_identity" "$path"
  else
    /usr/bin/codesign --force --options runtime --timestamp=none --sign "$signing_identity" "$path"
  fi
}

cleanup() {
  /bin/rm -rf -- "$temporary_root"
}
trap cleanup EXIT

/bin/mkdir -p "$distribution_dir"
/bin/mkdir -p "$helper_cache"
/bin/mkdir -p "$staging_dir"

signing_identity=$(resolve_signing_identity)
if [[ -z "$signing_identity" ]]; then
  print -u2 "No Apple code-signing identity found. Add one in Xcode or set LILT_SIGNING_IDENTITY."
  exit 1
fi

fetch_verified \
  "https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_macos.zip" \
  "$yt_dlp_archive" \
  "07e54b0865303c864006925913bce2604f8ee8cc6f18699bac9c309f9328a6d8"
fetch_verified \
  "https://github.com/denoland/deno/releases/download/v2.9.6/deno-aarch64-apple-darwin.zip" \
  "$deno_arm_archive" \
  "213a2f304f04d3c9cb5220669afad138f60a5aab1fe80962abdeb8f35807a472"
fetch_verified \
  "https://github.com/denoland/deno/releases/download/v2.9.6/deno-x86_64-apple-darwin.zip" \
  "$deno_intel_archive" \
  "7d4524b82bcc557fe020a1a5b56956ed42b992ae5b28026e8ad5d17329533f5f"

/usr/bin/xcodebuild \
  -project "$project_path" \
  -scheme Lilt \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

/usr/bin/ditto "$app_path" "$staging_dir/Lilt.app"
packaged_app="$staging_dir/Lilt.app"
helpers_dir="$packaged_app/Contents/Resources/PlaybackHelpers"
yt_dlp_unpack="$temporary_root/yt-dlp"
deno_arm_unpack="$temporary_root/deno-arm64"
deno_intel_unpack="$temporary_root/deno-x86_64"
/bin/mkdir -p "$helpers_dir/yt-dlp" "$yt_dlp_unpack" "$deno_arm_unpack" "$deno_intel_unpack"
/usr/bin/ditto -x -k "$yt_dlp_archive" "$yt_dlp_unpack"
/usr/bin/ditto -x -k "$deno_arm_archive" "$deno_arm_unpack"
/usr/bin/ditto -x -k "$deno_intel_archive" "$deno_intel_unpack"
/usr/bin/ditto "$yt_dlp_unpack/_internal" "$helpers_dir/yt-dlp/_internal"
/bin/cp "$yt_dlp_unpack/yt-dlp_macos" "$helpers_dir/yt-dlp/yt-dlp"
/usr/bin/lipo -create \
  "$deno_arm_unpack/deno" \
  "$deno_intel_unpack/deno" \
  -output "$helpers_dir/deno"
/bin/chmod 755 "$helpers_dir/yt-dlp/yt-dlp" "$helpers_dir/deno"

sign_helper "$helpers_dir/yt-dlp/yt-dlp"
sign_helper "$helpers_dir/deno"
sign_app "$packaged_app"
/usr/bin/codesign --verify --strict --verbose=2 "$packaged_app"
/usr/bin/codesign --verify --strict --verbose=2 "$helpers_dir/yt-dlp/yt-dlp"
/usr/bin/codesign --verify --strict --verbose=2 "$helpers_dir/deno"

architectures=$(/usr/bin/lipo -archs "$packaged_app/Contents/MacOS/Lilt")
if [[ "$architectures" != *arm64* || "$architectures" != *x86_64* ]]; then
  print -u2 "Expected a universal arm64/x86_64 binary, got: $architectures"
  exit 1
fi
for helper in "$helpers_dir/yt-dlp/yt-dlp" "$helpers_dir/deno"; do
  helper_architectures=$(/usr/bin/lipo -archs "$helper")
  if [[ "$helper_architectures" != *arm64* || "$helper_architectures" != *x86_64* ]]; then
    print -u2 "Expected a universal helper, got $helper_architectures: $helper"
    exit 1
  fi
done
PATH=/usr/bin:/bin "$helpers_dir/yt-dlp/yt-dlp" --version
PATH=/usr/bin:/bin "$helpers_dir/deno" --version | /usr/bin/head -1

/bin/cp "$install_guide" "$staging_dir/INSTALL.txt"
/usr/bin/ditto -c -k --sequesterRsrc "$staging_dir" "$temporary_archive"
/bin/mv -f "$temporary_archive" "$archive_path"

print "Created: $archive_path"
print "Architectures: $architectures"
print "Playback helpers: bundled yt-dlp 2026.08.19 + Deno 2.9.6"
print "Signing identity: $signing_identity"
print "Notarization: not performed (see INSTALL.txt for Gatekeeper details)"
