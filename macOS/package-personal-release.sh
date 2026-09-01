#!/bin/zsh

set -euo pipefail

mode=${1:-notarize}
if [[ "$mode" != notarize && "$mode" != organizer ]]; then
  print -u2 "Usage: ${0:t} [notarize|organizer]"
  exit 2
fi

script_dir=${0:A:h}
project_path="$script_dir/BitChordMac.xcodeproj"
derived_data="$script_dir/DerivedData-Universal"
app_path="$derived_data/Build/Products/Release/Lilt.app"
helper_cache="$derived_data/HelperCache"
distribution_dir="$script_dir/Distribution"
archive_path="$distribution_dir/Lilt-personal-universal.zip"
install_guide="$distribution_dir/INSTALL.txt"
deno_entitlements="$script_dir/Signing/Deno.entitlements"
notary_profile="${LILT_NOTARY_PROFILE:-lilt-notary}"
temporary_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/lilt-release.XXXXXX")
staging_dir="$temporary_root/Lilt personal release"
temporary_archive="$temporary_root/Lilt-personal-universal.zip"
notary_archive="$temporary_root/Lilt-notary-submission.zip"
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
  print -r -- "$identity"
}

sign_code() {
  local path=$1
  /usr/bin/codesign --force --options runtime --timestamp --sign "$signing_identity" "$path"
}

sign_deno() {
  local path=$1
  /usr/bin/codesign --force --options runtime --timestamp \
    --entitlements "$deno_entitlements" \
    --sign "$signing_identity" \
    "$path"
}

sign_app() {
  local path=$1
  /usr/bin/codesign --force --options runtime --timestamp --sign "$signing_identity" "$path"
}

sign_nested_mach_o() {
  local root=$1
  local path
  while IFS= read -r -d '' path; do
    if [[ "$path" == *.framework/* ]]; then
      continue
    fi
    if /usr/bin/file -b "$path" | /usr/bin/grep -q 'Mach-O'; then
      sign_code "$path"
    fi
  done < <(/usr/bin/find "$root" -type f -print0)

  while IFS= read -r -d '' path; do
    sign_code "$path"
  done < <(/usr/bin/find "$root" -type d -name '*.framework' -print0)
}

normalize_python_framework() {
  local framework=$1
  [[ -d "$framework/Versions/3.14" ]] || return

  # The upstream ZIP stores what should be framework symlinks as duplicate
  # files/directories. Restore the canonical macOS framework layout so that
  # codesign and Apple's notary service treat it as one bundle.
  /bin/unlink "$framework/Python"
  /bin/unlink "$framework/Resources/Info.plist"
  /bin/rmdir "$framework/Resources"
  /bin/unlink "$framework/Versions/Current/Python"
  /bin/unlink "$framework/Versions/Current/Resources/Info.plist"
  /bin/rmdir "$framework/Versions/Current/Resources"
  /bin/rmdir "$framework/Versions/Current"
  /bin/ln -s Versions/Current/Python "$framework/Python"
  /bin/ln -s Versions/Current/Resources "$framework/Resources"
  /bin/ln -s 3.14 "$framework/Versions/Current"
}

notarize_app() {
  local path=$1
  local -a authentication
  local result
  local status
  /usr/bin/ditto -c -k --keepParent "$path" "$notary_archive"

  if [[ -n "${LILT_NOTARY_KEY_PATH:-}" || -n "${LILT_NOTARY_KEY_ID:-}" || -n "${LILT_NOTARY_ISSUER:-}" ]]; then
    if [[ -z "${LILT_NOTARY_KEY_PATH:-}" || -z "${LILT_NOTARY_KEY_ID:-}" || -z "${LILT_NOTARY_ISSUER:-}" ]]; then
      print -u2 "Set LILT_NOTARY_KEY_PATH, LILT_NOTARY_KEY_ID and LILT_NOTARY_ISSUER together."
      exit 1
    fi
    authentication=(
      --key "${LILT_NOTARY_KEY_PATH}" \
      --key-id "${LILT_NOTARY_KEY_ID}" \
      --issuer "${LILT_NOTARY_ISSUER}"
    )
  else
    authentication=(--keychain-profile "$notary_profile")
  fi

  if ! result=$(/usr/bin/xcrun notarytool submit "$notary_archive" \
    "${authentication[@]}" \
    --wait \
    --output-format json); then
    print -r -- "$result"
    print -u2 "Apple notarization submission failed."
    exit 1
  fi
  print -r -- "$result"
  status=$(print -r -- "$result" | /usr/bin/plutil -extract status raw -o - -)
  if [[ "$status" != Accepted ]]; then
    print -u2 "Apple notarization was not accepted (status: $status)."
    exit 1
  fi

  /usr/bin/xcrun stapler staple "$path"
  /usr/bin/xcrun stapler validate "$path"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$path"
}

create_xcode_archive() {
  local path=$1
  local archives_root="$HOME/Library/Developer/Xcode/Archives/$(/bin/date +%Y-%m-%d)"
  local archive_name="Lilt Prepared $(/bin/date +%Y-%m-%d\ %H.%M.%S).xcarchive"
  local archive="$archives_root/$archive_name"
  local archive_app="$archive/Products/Applications/Lilt.app"
  local info="$archive/Info.plist"
  local version
  local build

  version=$(/usr/bin/defaults read "$path/Contents/Info" CFBundleShortVersionString)
  build=$(/usr/bin/defaults read "$path/Contents/Info" CFBundleVersion)
  /bin/mkdir -p "$archive/Products/Applications" "$archive/dSYMs"
  /usr/bin/ditto "$path" "$archive_app"
  if [[ -d "$derived_data/Build/Products/Release/Lilt.app.dSYM" ]]; then
    /usr/bin/ditto "$derived_data/Build/Products/Release/Lilt.app.dSYM" "$archive/dSYMs/Lilt.app.dSYM"
  fi

  /usr/bin/plutil -create xml1 "$info"
  /usr/bin/plutil -insert ArchiveVersion -integer 2 "$info"
  /usr/bin/plutil -insert CreationDate -date "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$info"
  /usr/bin/plutil -insert Name -string 'Lilt Prepared' "$info"
  /usr/bin/plutil -insert SchemeName -string Lilt "$info"
  /usr/bin/plutil -insert ApplicationProperties -dictionary "$info"
  /usr/bin/plutil -insert ApplicationProperties.ApplicationPath -string Applications/Lilt.app "$info"
  /usr/bin/plutil -insert ApplicationProperties.Architectures -json '["arm64","x86_64"]' "$info"
  /usr/bin/plutil -insert ApplicationProperties.CFBundleIdentifier -string com.pogozhev.lilt "$info"
  /usr/bin/plutil -insert ApplicationProperties.CFBundleShortVersionString -string "$version" "$info"
  /usr/bin/plutil -insert ApplicationProperties.CFBundleVersion -string "$build" "$info"
  /usr/bin/plutil -insert ApplicationProperties.SigningIdentity -string "$signing_identity" "$info"
  /usr/bin/plutil -insert ApplicationProperties.Team -string 54K55SFZ83 "$info"

  print "Created Xcode archive: $archive"
  /usr/bin/open "$archive"
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
  print -u2 "No Developer ID Application identity found. Install one or set LILT_SIGNING_IDENTITY."
  exit 1
fi
if [[ "$signing_identity" != Developer\ ID\ Application:* ]]; then
  print -u2 "A warning-free release requires a Developer ID Application certificate."
  print -u2 "Found instead: $signing_identity"
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
normalize_python_framework "$helpers_dir/yt-dlp/_internal/Python.framework"
/usr/bin/lipo -create \
  "$deno_arm_unpack/deno" \
  "$deno_intel_unpack/deno" \
  -output "$helpers_dir/deno"
/bin/chmod 755 "$helpers_dir/yt-dlp/yt-dlp" "$helpers_dir/deno"

sign_nested_mach_o "$helpers_dir"
sign_deno "$helpers_dir/deno"
sign_app "$packaged_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$packaged_app"
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

if [[ "$mode" == organizer ]]; then
  create_xcode_archive "$packaged_app"
  print "Next: Distribute App → Developer ID → Upload"
  exit 0
fi

notarize_app "$packaged_app"

/bin/cp "$install_guide" "$staging_dir/INSTALL.txt"
/usr/bin/ditto -c -k --sequesterRsrc "$staging_dir" "$temporary_archive"
/bin/mv -f "$temporary_archive" "$archive_path"

print "Created: $archive_path"
print "Architectures: $architectures"
print "Playback helpers: bundled yt-dlp 2026.08.19 + Deno 2.9.6"
print "Signing identity: $signing_identity"
print "Notarization: accepted and stapled"
