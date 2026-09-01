<div align="center">

# Lilt

### A native YouTube Music player for macOS

[**Features**](#features) · [**Build**](#build) · [**Disclaimer**](#disclaimer) · [**License**](#license)

</div>

> [!WARNING]
> Lilt is an independent, unofficial third-party client. It is not affiliated with, endorsed by, sponsored by, or connected to Google LLC, YouTube, or YouTube Music in any way. Use it at your own discretion.

<div align="center">

<img src="docs/lilt-home.jpeg" alt="Lilt running on macOS" width="100%" />

</div>

## Features

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>Playback &amp; library</h3>
      <ul>
        <li>YouTube Music sign-in with personalized Home, Explore, Search and Library.</li>
        <li>Direct playback with a persistent queue, media keys and macOS Now Playing integration.</li>
        <li>Gapless handoff, crossfade, shuffle, repeat and optional AutoPlay radio.</li>
        <li>Offline downloads and automatic reuse of cached audio.</li>
        <li>Local files and recursively indexed music folders.</li>
        <li>Per-network quality profiles and optional alternative audio sources.</li>
      </ul>

      <h3>Audio &amp; controls</h3>
      <ul>
        <li>Ten-band equalizer, preamp and Spatial Audio processing.</li>
        <li>Optional Automix with beat analysis and tempo-matched transitions.</li>
        <li>Playback speed, skip silence, sleep timer and full-width volume control.</li>
        <li>Stats for Nerds with measured codec, bitrate and sample-rate details.</li>
      </ul>
    </td>
    <td width="50%" valign="top">
      <h3>Experience</h3>
      <ul>
        <li>Native SwiftUI interface designed for macOS.</li>
        <li>System, light and dark appearances with artwork-driven player colors.</li>
        <li>Full-screen Now Playing with line- and word-synced lyrics.</li>
        <li>Animated artwork from supported Canvas providers.</li>
        <li>Private on-device Replay statistics, charts and stories.</li>
        <li>Universal Apple Silicon and Intel builds.</li>
      </ul>

      <h3>Accounts &amp; privacy</h3>
      <ul>
        <li>Optional Last.fm and ListenBrainz scrobbling.</li>
        <li>Credentials and sessions stored in macOS Keychain.</li>
        <li>Listening statistics kept locally on the Mac.</li>
        <li>Portable JSON backup for settings, Replay and search history.</li>
        <li>No Discord integration or Rich Presence.</li>
      </ul>
    </td>
  </tr>
</table>

See [the macOS documentation](macOS/README.md) for the complete feature list.

## Build

Requirements:

- macOS 13 or newer
- Xcode 16 or newer

Open [`macOS/BitChordMac.xcodeproj`](macOS/BitChordMac.xcodeproj) and run the
**Lilt** scheme, or build from Terminal:

```sh
xcodebuild \
  -project macOS/BitChordMac.xcodeproj \
  -scheme Lilt \
  -configuration Debug \
  -derivedDataPath macOS/DerivedData \
  build
```

To create a universal personal archive for another Mac:

```sh
macOS/package-personal-release.sh
```

The archive is written to `macOS/Distribution/Lilt-personal-universal.zip`.
The packaging script bundles the playback helpers and uses the best signing
identity available in Keychain. Distribution without a Gatekeeper warning
requires a Developer ID certificate and Apple notarization.

## Tests

```sh
xcodebuild \
  -project macOS/BitChordMac.xcodeproj \
  -scheme Lilt \
  -configuration Debug \
  -derivedDataPath macOS/DerivedData \
  test
```

## Disclaimer

Lilt is an independent client intended for personal and educational use. It
does not host, upload or distribute music. Media is played from local files or
retrieved from third-party services requested by the user. Availability may
change when those services update their APIs, authentication or playback
requirements. Users are responsible for complying with applicable laws and
the terms of the services they access.

YouTube, YouTube Music and Google are trademarks of Google LLC. Their names
are used only to describe interoperability; no affiliation or endorsement is
implied.

## Repository layout

- `macOS/` — native SwiftUI application, packaging scripts and tests.
- `native/analyzer/` — C++ audio analysis and resampling used by Automix.

Lilt began as a macOS port of
[BitChord by Kushagra Singh](https://github.com/kushagrasinghx/BitChord).

## License

Licensed under the [GNU General Public License v3.0](LICENSE).
