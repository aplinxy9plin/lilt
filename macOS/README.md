# Lilt for macOS

Lilt is the native SwiftUI rewrite of BitChord for personal use on macOS 13 or newer.

## Open and run

Open `BitChordMac.xcodeproj` in Xcode and run the **Lilt** scheme. The same build can be run from the repository root:

```sh
xcodebuild \
  -project macOS/BitChordMac.xcodeproj \
  -scheme Lilt \
  -configuration Debug \
  -sdk macosx \
  -derivedDataPath macOS/DerivedData \
  build
```

Development builds can use Homebrew `yt-dlp`, Deno and `ffmpeg`. The personal-release archive bundles official universal `yt-dlp` and Deno helpers, so playback works on another Mac without Homebrew; `ffmpeg` remains optional for download/transcode features:

```sh
brew install yt-dlp deno ffmpeg
```

## Personal release for another Mac

Build a universal Apple Silicon + Intel archive with:

```sh
macOS/package-personal-release.sh
```

To let Xcode use the Apple Account already signed in to Organizer instead of configuring `notarytool` credentials, run:

```sh
macOS/package-personal-release.sh organizer
```

The script opens a prepared archive containing the bundled playback helpers. In Organizer choose **Distribute App → Developer ID → Upload**; after Apple accepts it, export the notarized app from Organizer.

The archive is written to `macOS/Distribution/Lilt-personal-universal.zip` and includes `INSTALL.txt`, official universal `yt-dlp` and Deno helpers. Release packaging requires an Apple Developer Program membership and a `Developer ID Application` certificate. It signs all nested Mach-O code with the hardened runtime (preserving Deno's required JIT entitlements), submits the app to Apple notarization, staples the ticket and verifies the finished app with Gatekeeper before creating the archive. A downloaded copy can therefore be opened normally on another Mac without **Open Anyway**.

Create a one-time Keychain profile for notarization (use an app-specific password from appleid.apple.com):

```sh
xcrun notarytool store-credentials "lilt-notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID" \
  --password "YOUR_APP_SPECIFIC_PASSWORD"
```

Then run the packaging script. It uses the `lilt-notary` profile by default. To use a differently named profile, set `LILT_NOTARY_PROFILE`; App Store Connect API credentials are also supported with `LILT_NOTARY_KEY_PATH`, `LILT_NOTARY_KEY_ID` and `LILT_NOTARY_ISSUER`.

An `Apple Development` certificate is suitable for local Xcode builds but cannot create a warning-free downloadable release. Xcode can create the required certificate from **Settings → Accounts → Manage Certificates → + → Developer ID Application** after the Apple Developer Program membership is active.

## Included in the native app

- Apple Music-inspired native SwiftUI layout with sidebar, personalized Home shelves, Android-compatible Explore/Charts, search, real YouTube Music library and downloads sections. Explore merges both YouTube Music feeds in stable order, keeps artist-only chart rows, removes video-only dead ends and starts songs as radio seeds. The Android-compatible System / Light / Dark theme switches live and uses adaptive macOS surfaces while artwork-driven playback stays contrast-safe. Press **Command-L** to paste a shared YouTube/YouTube Music song, album, artist, playlist or search link: Lilt routes it internally instead of handing playback to a browser. The registered `lilt://track/<video-id>`, `lilt://browse/<browse-id>`, `lilt://search?q=…` and wrapped `lilt://open?url=…` routes provide the same behavior to scripts and other Mac apps; legacy `bitchord://` links remain supported.
- YouTube Music sign-in, account history, Songs / Albums / Artists / Playlists search and signed library mutations. Song search races the built-in JioSaavn source against YouTube Music and blends its labelled results first without delaying the fallback. Track menus resolve YouTube's real artist/album destinations, open them natively and expose the macOS share sheet without sending playback to a browser. Playlist cards can be pinned to the front of Library in the same explicit five-item order as Android; the pin list moves through the portable backup.
- Local audio import plus non-destructive recursive folder indexing for FLAC, ALAC, MP3, M4A and other formats supported by AVFoundation. The local catalog reads file title/artist/album/duration, embedded or sibling artwork, supports search, and groups music into Songs / Artists / Albums / Folders.
- Persistent personal library remains under `~/Library/Application Support/BitChord` so the rename does not discard existing accounts, settings, downloads or listening history.
- Direct YouTube playback through `AVPlayer`, queue controls, loading state, previous / next / seek, media-key and Now Playing integration. The authenticated fast path now mirrors Kotlin's cipher flow: it sends the current player `signatureTimestamp`, unlocks `signatureCipher` and `n` with the matching `base.js`, validates the media range and falls back to cancellation-safe `yt-dlp` extraction only when necessary. Music-video rows are detected from YouTube metadata and safely matched to the corresponding catalogue audio release before playback, gapless preload and AutoPlay, with uncertain matches left untouched and a live Android-compatible opt-out. Fresh stream URLs are reused for 20 minutes. After eight seconds of real playback, full audio is cached in bounded 2 MB ranges under a stable video/quality key; replays open locally before another YouTube resolve. Settings exposes the same 512 MB–10 GB byte-based LRU limit and clear action as Android. YouTube's authoritative media duration overrides malformed doubled AAC timelines reported by AVFoundation, including automatic queue handoff at the real end.
- Visible queue, per-track and whole-collection Play Next / Add to Queue, Clear Upcoming, Kotlin-compatible AutoPlay radio, global Shuffle, Repeat All / Repeat One, gapless handoff, crossfade, persisted 0.5×–2× playback speed, app-level volume with mute, sleep timer and skip-silence controls. The full-width Now Playing volume control can be hidden with the Android-compatible setting, and its master gain is preserved through gapless, crossfade and Automix transitions. The current track, a bounded queue window, AutoPlay provenance and listening position survive a cold launch without resolving a stream until Play is pressed. Shuffle preserves the played prefix and keeps manual tracks ahead of recommendations; Repeat All temporarily removes the AutoPlay tail so a finite queue can loop cleanly. Radio duplicates are filtered, and late responses cannot overwrite a newly selected track.
- Optional Automix built on the same native C++ analysis engine as Android: it caches BPM, beat/downbeat, phrase, energy and cue-point analysis, aligns the next track to a structural handoff, applies spectral tempo matching within a safe range, and falls back to a constant-power fade when confidence is low.
- Native ten-band equalizer with preamp, Flat / Bass Boost / Electronic / Rock / Vocal / Acoustic presets and live custom curves, plus Kotlin-compatible stereo Spatial Audio with mid/side widening and delayed low-passed crossfeed. The shared MediaToolbox processing tap runs on decoded PCM, so the same effects apply to YouTube, cached, imported and lossless-module audio.
- Per-network quality profiles, source/codec/bitrate display, built-in JioSaavn and Kotlin-compatible JavaScript audio-source modules. The JioSaavn path mirrors Android's API context, strict match, DES URL decoding and conditional 160/320 kbps AAC choice; headerless streams go directly to AVFoundation while YouTube streams that require session headers retain the local proxy.
- Optional Android-compatible Stats for Nerds overlay with the measured codec, bitrate, bit depth, sample rate and channel layout of streaming, downloaded and imported audio.
- Native Last.fm and ListenBrainz scrobbling with Keychain-only credentials, validated sign-in/token flows, Now Playing updates and configurable audible-time thresholds that ignore pause and buffering time.
- Seven-source synced lyrics pipeline matching Android: LyricsPlus, PaxSenix, BetterLyrics, SimpMusic, KuGou, LRCLIB and Musixmatch run concurrently with deterministic user-defined priority, optional word-timing preference, background vocals and instrumental gaps.
- Strict source matching prevents JioSaavn or a module from substituting a different recording. JioSaavn and configured modules race the immediate YouTube fallback; a late better source can align and blend into already-playing audio instead of delaying the first note.
- Offline track and whole-collection downloads with persisted grouping, 1–4 parallel workers, Standard / High / Lossless quality choice and automatic local playback reuse. The Android-compatible unmetered-network policy blocks every new single or batch queue entry on an expensive hotspot with an explanatory alert, while a transfer that already started is allowed to finish. Music-video downloads use the same strictly matched catalogue audio while retaining the original library-row identity. Downloads carry portable line-synced LRC and a private enhanced field for BitChord's word timing in both M4A and FLAC.
- Downloads preserve JioSaavn source identity and can save its direct AAC stream. Lossless downloads ask a configured Kotlin-compatible source module first, can use the strictly matched built-in JioSaavn 320 kbps rung, and safely fall back to the best YouTube Music AAC stream.
- Private on-device listening statistics, stored as bounded monthly aggregates, with a native Replay for this month, this year and all time.
- Replay charts for songs, artists, albums and genres, listening-time/play totals, favorite hour and biggest listening day; song rows play directly. Genre tags use the Kotlin app's fixed vocabulary and aliases, prefer a configured Last.fm key, fall back to rate-limited MusicBrainz lookups and stay in a bounded on-device cache. Only artist names leave the Mac, and enrichment can be disabled in Settings.
- Replay stories in a fixed 9:16 canvas with timed and keyboard navigation, including a genre card when data is available, plus per-card sharing and a real 1080×1920 PNG poster rendered for the macOS save/share UI.
- Versioned JSON backup/restore compatible with the Android app for Replay, search history, theme and shared playback/download/cache/scrobbling/lyrics settings, with validation and a confirmation preview. Credentials, source URLs, downloads, imported audio and local paths are excluded.
- Full-screen now-playing view with artwork treatment, source badge, line timing and word/syllable-level lyric highlighting.
- Animated Now Playing and album-header artwork from Apple Music, TIDAL, the community index and optional Spotify Canvas, with strict title/artist/album validation, regional catalogue fallback, muted native looping and separate controls for metered networks. Spotify uses the listener's own `sp_dc` web session, keeps it only in Keychain and mints the same short-lived access/client tokens as the web player. Progressive clips plus HLS playlists/segments share a 150 MB on-device LRU cache, so a short loop is not downloaded again on every pass.
- Artwork-driven mini-player and Now Playing palette matching the Kotlin design: dominant cover tint, vibrant controls, bottom-edge wash, bounded palette cache, full-bleed or compact-square cover layouts, Reduce Animation and Android-compatible Reduce Dynamic Blur solid surfaces.

## Audio-source modules

The Android-compatible JioSaavn source is built in and enabled by default under **Settings → Audio Sources**. It supplies labelled song-search results and strictly matched AAC playback/download candidates; disable its toggle to use only YouTube Music and an optional module.

Use **Settings → Audio Sources → Add** to paste a module-index URL compatible with the Android app's format. A configured module is used only by the **High** quality profile; YouTube Music remains the immediate fallback. The app does not bundle a private third-party module index.

## Scrobbling

Open **Settings → Scrobbling**. ListenBrainz accepts the user token from its settings page and verifies it before saving. Last.fm requires your personal API key/shared secret plus the account login once; Lilt exchanges the password for a revocable session and never stores the password. Tokens, API credentials and sessions live in macOS Keychain and are excluded from backups.

## Synced lyrics

Open **Settings → Synced Lyrics** to enable or disable individual third-party providers, change their priority and optionally prefer word/syllable timing over a faster line-synced answer. Every enabled source starts at the same time, but a lower-priority response cannot unexpectedly replace a preferred source. Lyrics requests are cancelled and generation-checked when the track changes, including gapless and crossfade handoffs. Downloaded files are checked first, so embedded lyrics work without a connection; an older download is upgraded in place after its first successful online lookup.

## Tests

```sh
xcodebuild \
  -project macOS/BitChordMac.xcodeproj \
  -scheme Lilt \
  -configuration Debug \
  -derivedDataPath macOS/DerivedData \
  test
```

The suite covers recursive local-media indexing, legacy-library migration, cold-start queue/position/duration restoration, persisted master-volume/mute behavior, metered-network download refusal without cancelling active transfers, AutoPlay/repeat/shuffle and collection queue behavior, Android-ordered Explore/Charts merging with artist-row preservation and video-only filtering, music-video detection in live-style Home/search rows, catalogue-audio substitution that preserves the clicked row's loading state, authenticated `signatureCipher` parsing and `n` transformation, concurrent direct/yt-dlp stream resolution, authenticated extractor cookie jars for streaming fallbacks and downloads, JioSaavn search/details fixtures, DES URL decoding, 160/320 kbps selection and headerless direct-playback routing, shared/deep YouTube Music link parsing and single-request collection pages, bounded-range audio caching with byte-LRU eviction/cancellation and Android `long` backup compatibility, YouTube track-link resolution, pinned-playlist ordering, Apple/TIDAL/Spotify Canvas lookup, Spotify web-player Pathfinder, token/client-token and protobuf fixtures, progressive/HLS Canvas caching, Last.fm/MusicBrainz genre enrichment and caching, real MediaToolbox equalizer and Spatial Audio pipelines, an AVAssetReader → native resampler → shared Automix DSP pipeline and story-sized Replay PNG rendering.

The macOS app is self-contained except for the shared C++ Automix sources under `native/analyzer/`.
