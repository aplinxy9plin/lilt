# Kotlin → macOS parity

This file tracks functional parity with the Android/Kotlin app. A checked item
means it has been exercised in a signed macOS build, not merely represented by
UI.

## Working on macOS

- [x] YouTube Music sign-in session and sign-out
- [x] Personalized Home shelves
- [x] Account listening history page with replayable queue rows
- [x] Local audible-time listening recorder with pause/buffering protection and Android-equivalent play threshold
- [x] Bounded on-device monthly listening aggregates
- [x] Native Replay for this month, this year and all time with songs, artists, albums and listening habits
- [x] Replay genre enrichment with Kotlin-compatible tag filtering, Last.fm when configured, a rate-limited MusicBrainz fallback, a 14-day miss cache and a privacy toggle shared with Android backups
- [x] Native 9:16 Replay stories with timed/keyboard navigation, per-card sharing and a real 1080×1920 PNG poster export through the macOS save/share UI
- [x] Signed playback, ATR and watchtime tracking that updates YouTube Music history and recommendations
- [x] Search for songs, albums, artists and playlists, with built-in JioSaavn song results blended ahead of the YouTube Music fallback
- [x] Android-compatible Explore feed combining YouTube Music Explore and Charts in stable order, with duplicate-shelf removal, video-only filtering, artist chart rows, native browse destinations and radio-seed playback
- [x] Kotlin-compatible YouTube/YouTube Music link routing for songs, albums, artists, playlists and searches, with a native paste sheet, `lilt://` deep links plus the legacy `bitchord://` alias, one-request collection loading and no browser handoff
- [x] Real Library playlists, artists, subscriptions and podcasts
- [x] Collection pages with whole-row playback and loading state
- [x] Queue playback, previous/next, seeking and media-key integration
- [x] Authoritative YouTube/local-file duration with real-end queue handoff when AVFoundation exposes a doubled AAC timeline
- [x] Preloaded gapless queue handoff and adjustable 0–12 second constant-power crossfade
- [x] Kotlin-compatible Automix analysis using the shared native C++ BPM/beat/energy/structure engine, persistent per-track results, phrase/downbeat cue planning, spectral tempo matching and a safe constant-power fallback
- [x] Visible queue with Play Next, Add to Queue, remove, reorder and direct selection
- [x] Kotlin-compatible cold-start restoration of the current track, bounded queue, AutoPlay provenance and listening position without eager stream resolution
- [x] Kotlin-compatible YouTube Music AutoPlay radio with a 10-track rolling tail, duplicate/session filtering, stale-response protection and manual queue priority
- [x] Kotlin-compatible music-video detection and safe catalogue-audio substitution for playback, gapless preloading, AutoPlay and downloads, with the shared Android backup setting
- [x] Persisted Android-compatible playback speed from 0.5× to 2×, applied live and restored on launch
- [x] Persisted app-level volume with mute/restore, a full-width Now Playing control, crossfade/Automix gain scaling and Android-compatible `hide_volume_bar` backup behavior
- [x] Sleep timer with fixed presets and stop-after-current-track mode
- [x] Per-network Low / Medium / High streaming quality with active codec and bitrate display
- [x] Native audio-source settings with a persistent built-in JioSaavn toggle plus custom module URL, enable/disable, health state and test action
- [x] Kotlin-compatible JioSaavn API search, strict source matching, DES media-URL decoding and conditional 160/320 kbps AAC selection; live macOS playback and immediate track switching are verified at 320 kbps without a browser handoff
- [x] Kotlin-compatible module index discovery and JavaScript module execution
- [x] Strict title/artist/duration matching and malformed stream URL rejection
- [x] Non-blocking YouTube fallback with aligned constant-power upgrade when a better module stream arrives
- [x] Skip silence for dead-air intervals of at least one second
- [x] Signed YouTube Music like/unlike actions with optimistic UI and rollback
- [x] Playlist create, add, rename, remove and delete actions, live-tested against the signed-in account
- [x] Direct YouTube stream resolution with availability-gate handling, cancellation-safe track switching, short-lived URL reuse and an authenticated cookie-jar fallback; an older music video that previously opened the browser is live-verified to play locally
- [x] Kotlin-equivalent authenticated `signatureCipher`/`n` handling using the current `base.js` and `signatureTimestamp`; live signed-build resolution measured 2.49 seconds cold and 1.53–2.12 seconds warm, with `yt-dlp` retained only as a fallback
- [x] Kotlin-compatible full-song audio cache: delayed read-ahead in bounded 2 MB ranges, stable video/quality keys, byte-based LRU eviction, adjustable 512 MB–10 GB limit, clear action and Android backup round-trip
- [x] Local audio import plus recursive folder indexing with file metadata, embedded/sibling artwork, search and Songs / Artists / Albums / Folders views
- [x] Non-destructive local-folder management: removing an indexed folder only removes its Lilt reference; original files stay untouched
- [x] Offline track downloads with authenticated cookie-jar extraction, progress, cancel, retry, persistence and automatic local playback reuse
- [x] Whole-playlist/album/artist downloads with persisted collection grouping and replayable downloaded detail pages
- [x] Configurable Standard / High / Lossless download quality and 1–4 parallel workers with aggregate batch progress
- [x] Android-compatible `wifi_only_downloads` policy: metered hotspots refuse every new single/batch queue entry with visible UI feedback, while transfers already in progress continue
- [x] Lossless source-module downloads with strict identity matching and automatic YouTube Music fallback
- [x] Portable line-synced LRC plus Lilt word-timed lyrics embedded in M4A/FLAC downloads, loaded before the network; older downloads are backfilled after one successful lookup
- [x] User-visible `~/Music/BitChord` audio files
- [x] Seven-source synced lyrics with deterministic priority, source controls, line and word/syllable timing, background vocals and instrumental gaps
- [x] Track-generation-safe lyric loading for direct selection, gapless and crossfade handoffs
- [x] Native SwiftUI shell, full-width progress bar and Now Playing view
- [x] Artwork-driven player theming with dominant/vibrant/edge palette extraction, bounded session cache and Reduce Animation support
- [x] Android-compatible full-bleed artwork and Reduce Dynamic Blur settings, including compact square fallback, solid mini-player/backdrop rendering and portable backup round-trip
- [x] Android-compatible System / Light / Dark `theme_mode` with live switching, adaptive macOS surfaces and portable backup round-trip
- [x] Android-compatible versioned JSON backup/restore for Replay, search history and shared playback/download settings, with validation and a native restore preview
- [x] Backup privacy boundary: YouTube credentials, source configuration, downloaded files, imported audio and local paths are excluded and preserved during restore
- [x] Optional Stats for Nerds with measured codec, bit depth, bitrate, sample rate and channel layout for streaming, downloaded and imported audio, using the same persisted/backup key as Android
- [x] Native ten-band equalizer with preamp, six presets, per-band live editing, MediaToolbox PCM processing for streaming/local/lossless audio, persisted custom curves and portable macOS backup fields
- [x] Kotlin-compatible stereo Spatial Audio with mid/side widening and delayed low-passed crossfeed in the native PCM pipeline

## Partial

- [ ] Downloads: live batch QA against a larger playlist; authenticated single-track download, one-song signed-build batch, failure/retry, persistence, offline playback and embedded-lyrics round trips are verified
- [ ] JioSaavn downloads: source identity, direct AAC download routing and metadata persistence are fixture-tested; a full live download/offline-playback round trip still needs QA
- [ ] Source modules: fixture-tested end to end, but a real third-party module index and live lossless/Hi-Res endpoint still need signed-build QA
- [ ] Playback quality: broader codec support beyond formats accepted by AVPlayer
- [ ] Last.fm and ListenBrainz: native clients, Keychain credentials, audible-time thresholds, pause/buffer protection and signed-build settings UI are implemented and fixture-tested; a real personal account still needs end-to-end QA
- [ ] Animated album canvas: Apple Music, TIDAL, community and Spotify lookup, strict track/album matching, regional fallback, metered-network controls, native looping, album-header integration and a shared 150 MB progressive/HLS LRU cache are implemented. Apple Music Now Playing motion, the Spotify setup UI and album-page static fallback are exercised in a signed build; a personal Spotify `sp_dc` session and a matching moving album still need live end-to-end QA.

## Not ported yet

- [ ] Android-only swipe-to-queue preference; macOS exposes Play Next and Add to Queue through native context menus instead of touch gestures
- [ ] Android recents-task shutdown preference; macOS window and process lifecycle do not have a direct task-removal equivalent

## Next implementation order

1. Live-test a larger whole-playlist download batch, cancellation and retry.
2. Live-test a real third-party module index and lossless download endpoint.
3. Live-test Spotify Canvas with a personal `sp_dc` session and a moving album match.
