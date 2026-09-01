# Lilt

Lilt is a native SwiftUI music player for macOS built around a personal
YouTube Music account. It keeps the library, playback and discovery behavior
of the Android BitChord app while using a Mac-native interface and media
pipeline.

The app is intended for personal use. It is not affiliated with or endorsed by
YouTube or Google.

## Highlights

- YouTube Music sign-in, personalized Home, Explore, Search and Library.
- Native queue, media keys, Now Playing, gapless playback and crossfade.
- Local files, indexed folders and offline downloads.
- Replay listening statistics, synced lyrics and optional scrobbling.
- Universal Apple Silicon and Intel release builds.
- Bundled `yt-dlp` and Deno playback helpers for portable builds.

See [the macOS documentation](macOS/README.md) for the complete feature list.

## Run in Xcode

Requirements:

- macOS 13 or newer
- Xcode 16 or newer

Open [`macOS/BitChordMac.xcodeproj`](macOS/BitChordMac.xcodeproj) and run the
**Lilt** scheme, or use:

```sh
xcodebuild \
  -project macOS/BitChordMac.xcodeproj \
  -scheme Lilt \
  -configuration Debug \
  -derivedDataPath macOS/DerivedData \
  build
```

## Tests

```sh
xcodebuild \
  -project macOS/BitChordMac.xcodeproj \
  -scheme Lilt \
  -configuration Debug \
  -derivedDataPath macOS/DerivedData \
  test
```

## Personal universal build

```sh
macOS/package-personal-release.sh
```

The script creates `macOS/Distribution/Lilt-personal-universal.zip`. Release
archives are ignored by Git and are not stored in this repository.

The script uses the best signing identity available in Keychain, preferring a
`Developer ID Application` certificate. Distribution without a Gatekeeper
warning additionally requires Apple notarization.

## Repository layout

- `macOS/` — the native SwiftUI macOS application and tests.
- `native/analyzer/` — the C++ audio analysis and resampling code used by
  Automix.

Lilt began as a macOS port of
[BitChord by Kushagra Singh](https://github.com/kushagrasinghx/BitChord).

## License

Licensed under the [GNU General Public License v3.0](LICENSE).
