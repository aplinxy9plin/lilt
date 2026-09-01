import Foundation
import XCTest

@MainActor
final class BackupManagerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUp() async throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChordBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testRoundTripRestoresSettingsAndReplayWithoutDeviceData() async throws {
        let source = try makeEnvironment(named: "source")
        source.playback.themeMode = .light
        source.playback.unmeteredQuality = .medium
        source.playback.meteredQuality = .low
        source.playback.wifiOnlyDownloads = false
        source.playback.autoplay = false
        source.playback.dontRepeatSuggestions = true
        source.playback.crossfadeSeconds = 7
        source.playback.smartFadeEnabled = true
        source.playback.skipSilence = true
        source.playback.spatialAudio = true
        source.playback.convertVideoToAudio = false
        source.playback.playbackSpeed = 1.25
        source.playback.showNerdStats = true
        source.playback.hideVolumeBar = true
        source.playback.dynamicArtworkTheme = false
        source.playback.reduceAnimation = true
        source.playback.reduceDynamicBlur = true
        source.playback.fullBleedArtwork = false
        source.playback.animatedCanvas = false
        source.playback.canvasOverMetered = true
        source.playback.audioCacheLimitBytes = 3 * 1_024 * 1_024 * 1_024
        source.equalizer.isEnabled = true
        source.equalizer.selectPreset(.rock)
        source.equalizer.setBandGain(6, at: 0)
        source.downloads.preferredQuality = .high
        source.downloads.maximumParallelDownloads = 4
        source.scrobbling.applyPortableSettings(
            lastFMEnabled: true,
            lastFMUsername: "backup-user",
            lastFMEndpoint: LastFMClient.defaultEndpoint,
            lastFMScrobbleEnabled: true,
            lastFMNowPlaying: true,
            listenBrainzEnabled: true,
            minimumSongDuration: 45,
            delayPercent: 0.6,
            maximumDelay: 200
        )
        source.lyrics.applyPortableSettings(
            enabled: true,
            sources: [.simpMusic, .lrcLib],
            order: [.simpMusic, .lrcLib, .lyricsPlus],
            prioritizeWordTiming: true
        )
        source.replay.genresEnabled = false
        XCTAssertEqual(source.libraryPreferences.toggle("VLfirst"), .pinned)
        XCTAssertEqual(source.libraryPreferences.toggle("VLsecond"), .pinned)

        let secretPath = temporaryRoot
            .appendingPathComponent("private/never-export-me.flac")
            .path
        let track = Track(
            videoID: nil,
            title: "Local Secret Song",
            artist: "Private Artist",
            album: "Private Album",
            artworkURL: nil,
            duration: 180,
            localPath: secretPath,
            sourceURL: "https://private.example/token-in-source"
        )
        let playedAt = try date("2026-07-14T19:30:00Z")
        await source.listening.record(
            track: track,
            playedSeconds: 91,
            countsAsPlay: true,
            at: playedAt
        )

        let data = try await source.backup.export(
            searchHistory: ["Portishead", "Massive Attack"],
            now: try date("2026-08-31T03:00:00Z")
        )
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("\"app\" : \"bitchord\""))
        XCTAssertTrue(json.contains("\"local:"), "A local track gets an opaque portable ID")
        XCTAssertFalse(json.contains(secretPath))
        XCTAssertFalse(json.contains("token-in-source"))
        XCTAssertFalse(json.contains("youtubeCookie"))
        XCTAssertFalse(json.contains("filePath"))
        XCTAssertFalse(json.contains("\"downloads\""))
        XCTAssertFalse(json.contains("never-export-api-key"))
        XCTAssertFalse(json.contains("never-export-secret"))
        XCTAssertFalse(json.contains("never-export-session"))
        XCTAssertFalse(json.contains("never-export-listenbrainz"))
        XCTAssertTrue(json.contains("\"audio_cache_limit_bytes\""))
        XCTAssertTrue(json.contains("\"type\" : \"long\""))

        let destination = try makeEnvironment(named: "destination")
        destination.playback.unmeteredQuality = .high
        destination.playback.meteredQuality = .high
        destination.downloads.preferredQuality = .lossless
        let staleTrack = Track(
            videoID: "stale-video",
            title: "Stale",
            artist: "Old",
            album: nil,
            artworkURL: nil,
            duration: 10,
            localPath: nil,
            sourceURL: nil
        )
        await destination.listening.record(
            track: staleTrack,
            playedSeconds: 10,
            countsAsPlay: true,
            at: try date("2025-01-01T12:00:00Z")
        )

        let result = try await destination.backup.restore(data)
        let replay = await destination.listening.summary(for: .allTime, now: playedAt)

        XCTAssertEqual(result.searchHistory, ["Portishead", "Massive Attack"])
        XCTAssertEqual(result.preview.months, 1)
        XCTAssertEqual(result.preview.tracks, 1)
        XCTAssertEqual(destination.playback.themeMode, .light)
        XCTAssertEqual(destination.playback.unmeteredQuality, .medium)
        XCTAssertEqual(destination.playback.meteredQuality, .low)
        XCTAssertFalse(destination.playback.wifiOnlyDownloads)
        XCTAssertFalse(destination.playback.autoplay)
        XCTAssertTrue(destination.playback.dontRepeatSuggestions)
        XCTAssertEqual(destination.playback.crossfadeSeconds, 7)
        XCTAssertTrue(destination.playback.smartFadeEnabled)
        XCTAssertTrue(destination.playback.skipSilence)
        XCTAssertTrue(destination.playback.spatialAudio)
        XCTAssertFalse(destination.playback.convertVideoToAudio)
        XCTAssertEqual(destination.playback.playbackSpeed, 1.25)
        XCTAssertTrue(destination.playback.showNerdStats)
        XCTAssertTrue(destination.playback.hideVolumeBar)
        XCTAssertFalse(destination.playback.dynamicArtworkTheme)
        XCTAssertTrue(destination.playback.reduceAnimation)
        XCTAssertTrue(destination.playback.reduceDynamicBlur)
        XCTAssertFalse(destination.playback.fullBleedArtwork)
        XCTAssertFalse(destination.playback.animatedCanvas)
        XCTAssertTrue(destination.playback.canvasOverMetered)
        XCTAssertEqual(destination.playback.audioCacheLimitBytes, 3 * 1_024 * 1_024 * 1_024)
        XCTAssertTrue(destination.equalizer.isEnabled)
        XCTAssertEqual(destination.equalizer.preset, .custom)
        XCTAssertEqual(destination.equalizer.preampDB, -4)
        XCTAssertEqual(destination.equalizer.bandGainsDB[0], 6)
        XCTAssertEqual(destination.downloads.preferredQuality, .high)
        XCTAssertEqual(destination.downloads.maximumParallelDownloads, 4)
        XCTAssertTrue(destination.scrobbling.lastFMEnabled)
        XCTAssertEqual(destination.scrobbling.lastFMUsername, "backup-user")
        XCTAssertTrue(destination.scrobbling.lastFMScrobbleEnabled)
        XCTAssertTrue(destination.scrobbling.lastFMNowPlayingEnabled)
        XCTAssertTrue(destination.scrobbling.listenBrainzEnabled)
        XCTAssertEqual(destination.scrobbling.minimumSongDuration, 45)
        XCTAssertEqual(destination.scrobbling.delayPercent, 0.6)
        XCTAssertEqual(destination.scrobbling.maximumDelay, 200)
        XCTAssertTrue(destination.lyrics.enabled)
        XCTAssertEqual(destination.lyrics.enabledSources, [.simpMusic, .lrcLib])
        XCTAssertEqual(Array(destination.lyrics.sourceOrder.prefix(3)), [.simpMusic, .lrcLib, .lyricsPlus])
        XCTAssertTrue(destination.lyrics.prioritizeWordTiming)
        XCTAssertFalse(destination.replay.genresEnabled)
        XCTAssertEqual(destination.libraryPreferences.pinnedPlaylistIDs, ["VLfirst", "VLsecond"])
        XCTAssertEqual(replay.totalMilliseconds, 91_000)
        XCTAssertEqual(replay.totalPlays, 1)
        XCTAssertEqual(replay.tracks.map(\.track.title), ["Local Secret Song"])
        XCTAssertNil(replay.tracks.first?.track.localPath)
        XCTAssertNil(replay.tracks.first?.track.sourceURL)
    }

    func testImportsAndroidVersionOneFixture() async throws {
        let environment = try makeEnvironment(named: "android")
        let data = try XCTUnwrap(Self.androidFixture.data(using: .utf8))

        let preview = try environment.backup.inspect(data)
        let result = try await environment.backup.restore(data)
        let replay = await environment.listening.summary(
            for: .allTime,
            now: try date("2026-08-01T00:00:00Z")
        )

        XCTAssertEqual(preview.versionName, "android-1.0")
        XCTAssertEqual(preview.months, 1)
        XCTAssertEqual(preview.tracks, 1)
        XCTAssertEqual(preview.settings, 37)
        XCTAssertEqual(result.searchHistory, ["Radiohead", "Björk"])
        XCTAssertEqual(environment.playback.themeMode, .system)
        XCTAssertEqual(environment.playback.unmeteredQuality, .high)
        XCTAssertEqual(environment.playback.meteredQuality, .low)
        XCTAssertTrue(environment.playback.wifiOnlyDownloads)
        XCTAssertFalse(environment.playback.autoplay)
        XCTAssertTrue(environment.playback.dontRepeatSuggestions)
        XCTAssertEqual(environment.playback.crossfadeSeconds, 5)
        XCTAssertTrue(environment.playback.smartFadeEnabled)
        XCTAssertTrue(environment.playback.skipSilence)
        XCTAssertTrue(environment.playback.spatialAudio)
        XCTAssertFalse(environment.playback.convertVideoToAudio)
        XCTAssertEqual(environment.playback.playbackSpeed, 1.5)
        XCTAssertTrue(environment.playback.showNerdStats)
        XCTAssertTrue(environment.playback.hideVolumeBar)
        XCTAssertTrue(environment.playback.reduceAnimation)
        XCTAssertTrue(environment.playback.reduceDynamicBlur)
        XCTAssertFalse(environment.playback.fullBleedArtwork)
        XCTAssertFalse(environment.playback.animatedCanvas)
        XCTAssertTrue(environment.playback.canvasOverMetered)
        XCTAssertEqual(environment.playback.audioCacheLimitBytes, 1_024 * 1_024 * 1_024)
        XCTAssertFalse(environment.equalizer.isEnabled)
        XCTAssertEqual(environment.equalizer.preset, .flat)
        XCTAssertEqual(environment.downloads.preferredQuality, .standard)
        XCTAssertTrue(environment.scrobbling.lastFMEnabled)
        XCTAssertEqual(environment.scrobbling.lastFMUsername, "android-user")
        XCTAssertTrue(environment.scrobbling.lastFMScrobbleEnabled)
        XCTAssertTrue(environment.scrobbling.lastFMNowPlayingEnabled)
        XCTAssertTrue(environment.scrobbling.listenBrainzEnabled)
        XCTAssertEqual(environment.scrobbling.minimumSongDuration, 45)
        XCTAssertEqual(environment.scrobbling.delayPercent, 0.6)
        XCTAssertEqual(environment.scrobbling.maximumDelay, 200)
        XCTAssertTrue(environment.lyrics.enabled)
        XCTAssertEqual(environment.lyrics.enabledSources, [.betterLyrics, .lrcLib])
        XCTAssertEqual(Array(environment.lyrics.sourceOrder.prefix(3)), [.lrcLib, .betterLyrics, .simpMusic])
        XCTAssertTrue(environment.lyrics.prioritizeWordTiming)
        XCTAssertFalse(environment.replay.genresEnabled)
        XCTAssertEqual(environment.libraryPreferences.pinnedPlaylistIDs, ["VLandroid-one", "VLandroid-two"])
        XCTAssertEqual(replay.totalMilliseconds, 123_000)
        XCTAssertEqual(replay.totalPlays, 2)
        XCTAssertEqual(replay.tracks.first?.track.title, "Android Song")
        XCTAssertEqual(replay.busiestHour, 9)
        XCTAssertEqual(replay.busiestDay, "2026-07-03")
    }

    func testRejectedNewerBackupLeavesExistingStateUntouched() async throws {
        let environment = try makeEnvironment(named: "untouched")
        environment.playback.unmeteredQuality = .low
        environment.playback.crossfadeSeconds = 4
        let track = Track(
            videoID: "keep-me",
            title: "Keep Me",
            artist: "Existing Artist",
            album: nil,
            artworkURL: nil,
            duration: 30,
            localPath: nil,
            sourceURL: nil
        )
        let now = try date("2026-08-20T10:00:00Z")
        await environment.listening.record(
            track: track,
            playedSeconds: 30,
            countsAsPlay: true,
            at: now
        )
        let invalid = Self.androidFixture.replacingOccurrences(
            of: "\"version\": 1",
            with: "\"version\": 99"
        )
        let invalidData = try XCTUnwrap(invalid.data(using: .utf8))

        do {
            _ = try await environment.backup.restore(invalidData)
            XCTFail("A newer schema must be rejected")
        } catch let error as BitChordBackupError {
            guard case .newerSchema = error else {
                return XCTFail("Unexpected backup error: \(error)")
            }
        }

        let replay = await environment.listening.summary(for: .allTime, now: now)
        XCTAssertEqual(environment.playback.unmeteredQuality, .low)
        XCTAssertEqual(environment.playback.crossfadeSeconds, 4)
        XCTAssertEqual(replay.totalMilliseconds, 30_000)
        XCTAssertEqual(replay.tracks.map(\.track.title), ["Keep Me"])
    }

    func testPinnedPlaylistPreferencesPersistCapAndApplyPinOrderOnlyToPlaylists() throws {
        let suiteName = "BitChordPinnedPlaylists.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = LibraryPreferences(defaults: defaults)

        for id in ["VLthree", "VLone", "VLfive", "VLtwo", "VLfour"] {
            XCTAssertEqual(preferences.toggle(id), .pinned)
        }
        XCTAssertEqual(preferences.toggle("VLsix"), .limitReached)
        XCTAssertEqual(preferences.toggle("VLfive"), .unpinned)
        XCTAssertEqual(preferences.toggle("VLsix"), .pinned)

        let makeItem: (String) -> ShelfItem = { id in
            let browse = BrowseItem(id: id, title: id, subtitle: "", artworkURL: nil, kind: .playlist)
            return ShelfItem(title: id, subtitle: "", artworkURL: nil, browseItem: browse)
        }
        let originalItems = ["VLone", "VLtwo", "VLthree", "VLfour", "VLsix"].map(makeItem)
        let playlists = HomeShelf(title: "Playlists", items: originalItems)
        let albums = HomeShelf(title: "Albums", items: originalItems)

        XCTAssertEqual(
            preferences.ordered(playlists).items.map(\.id),
            ["VLthree", "VLone", "VLtwo", "VLfour", "VLsix"]
        )
        XCTAssertEqual(preferences.ordered(albums).items.map(\.id), originalItems.map(\.id))

        let restored = LibraryPreferences(defaults: defaults)
        XCTAssertEqual(restored.pinnedPlaylistIDs, ["VLthree", "VLone", "VLtwo", "VLfour", "VLsix"])
    }

    private func makeEnvironment(named name: String) throws -> BackupTestEnvironment {
        let root = temporaryRoot.appendingPathComponent(name, isDirectory: true)
        let defaultsName = "BitChordBackupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        let playback = PlaybackSettings(defaults: defaults, monitorNetwork: false)
        let downloads = DownloadManager(
            downloader: BackupFakeDownloader(),
            downloadsDirectory: root.appendingPathComponent("Music", isDirectory: true),
            metadataURL: root.appendingPathComponent("State/downloads.json")
        )
        let listening = ListeningStatsStore(
            directory: root.appendingPathComponent("ListeningStats", isDirectory: true)
        )
        let artistFacts = ArtistFactsStore(
            directory: root.appendingPathComponent("ArtistFacts", isDirectory: true),
            enabled: true,
            transport: BackupArtistFactsTransport(),
            requestSpacingNanoseconds: 0
        )
        let replay = ReplayViewModel(store: listening, artistFacts: artistFacts, defaults: defaults)
        let credentialStore = BackupTestCredentialStore(values: [
            "lastfm.apiKey": "never-export-api-key",
            "lastfm.secret": "never-export-secret",
            "lastfm.session": "never-export-session",
            "listenbrainz.token": "never-export-listenbrainz"
        ])
        let scrobbling = ScrobblingManager(
            defaults: defaults,
            credentials: credentialStore,
            transport: BackupScrobbleTransport()
        )
        let lyrics = LyricsSettings(defaults: defaults)
        let equalizer = EqualizerSettings(defaults: defaults)
        let libraryPreferences = LibraryPreferences(defaults: defaults)
        let backup = BackupManager(
            listening: listening,
            playbackSettings: playback,
            downloads: downloads,
            replay: replay,
            scrobbling: scrobbling,
            lyricsSettings: lyrics,
            equalizer: equalizer,
            libraryPreferences: libraryPreferences,
            appVersion: "mac-test"
        )
        return BackupTestEnvironment(
            defaultsName: defaultsName,
            playback: playback,
            downloads: downloads,
            listening: listening,
            replay: replay,
            scrobbling: scrobbling,
            lyrics: lyrics,
            equalizer: equalizer,
            libraryPreferences: libraryPreferences,
            backup: backup
        )
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    private static let androidFixture = #"""
    {
      "app": "bitchord",
      "version": 1,
      "versionName": "android-1.0",
      "exportedAt": "2026-08-31T03:04:05.123Z",
      "settings": {
        "audio_quality_wifi": {"type": "string", "value": "HIGH", "values": []},
        "audio_quality_cellular": {"type": "string", "value": "LOW", "values": []},
        "audio_quality_download": {"type": "string", "value": "STANDARD", "values": []},
        "theme_mode": {"type": "string", "value": "SYSTEM", "values": []},
        "wifi_only_downloads": {"type": "bool", "value": "true", "values": []},
        "autoplay": {"type": "bool", "value": "false", "values": []},
        "dont_repeat_suggestions": {"type": "bool", "value": "true", "values": []},
        "crossfade_seconds": {"type": "int", "value": "5", "values": []},
        "smart_fade_enabled": {"type": "bool", "value": "true", "values": []},
        "skip_silence": {"type": "bool", "value": "true", "values": []},
        "spatial_audio": {"type": "bool", "value": "true", "values": []},
        "convert_video_to_audio": {"type": "bool", "value": "false", "values": []},
        "playback_speed": {"type": "float", "value": "1.5", "values": []},
        "show_nerd_stats": {"type": "bool", "value": "true", "values": []},
        "hide_volume_bar": {"type": "bool", "value": "true", "values": []},
        "reduce_animation": {"type": "bool", "value": "true", "values": []},
        "reduce_dynamic_blur": {"type": "bool", "value": "true", "values": []},
        "full_bleed_artwork": {"type": "bool", "value": "false", "values": []},
        "animated_canvas": {"type": "bool", "value": "false", "values": []},
        "canvas_over_cellular": {"type": "bool", "value": "true", "values": []},
        "audio_cache_limit_bytes": {"type": "long", "value": "1073741824", "values": []},
        "lastfm_enabled": {"type": "bool", "value": "true", "values": []},
        "lastfm_username": {"type": "string", "value": "android-user", "values": []},
        "lastfm_endpoint": {"type": "string", "value": "https://ws.audioscrobbler.com/2.0/", "values": []},
        "lastfm_scrobble_enabled": {"type": "bool", "value": "true", "values": []},
        "lastfm_now_playing": {"type": "bool", "value": "true", "values": []},
        "listenbrainz_enabled": {"type": "bool", "value": "true", "values": []},
        "scrobble_min_duration": {"type": "int", "value": "45", "values": []},
        "scrobble_delay_percent": {"type": "float", "value": "0.6", "values": []},
        "scrobble_delay_seconds": {"type": "int", "value": "200", "values": []},
        "synced_lyrics": {"type": "bool", "value": "true", "values": []},
        "lyrics_sources": {"type": "string", "value": "BETTER_LYRICS,LRCLIB", "values": []},
        "lyrics_source_order": {"type": "string", "value": "LRCLIB,BETTER_LYRICS,SIMP_MUSIC", "values": []},
        "prioritize_syllable_sync": {"type": "bool", "value": "true", "values": []},
        "replay_genres": {"type": "bool", "value": "false", "values": []},
        "pinned_playlists": {"type": "string", "value": "VLandroid-one,VLandroid-two", "values": []},
        "search_history": {"type": "string", "value": "[\"Radiohead\",\"Björk\"]", "values": []}
      },
      "listening": [{
        "version": 1,
        "month": "2026-07",
        "tracks": [{
          "id": "android123",
          "title": "Android Song",
          "artist": "Android Artist",
          "album": "Android Album",
          "albumId": null,
          "artistId": null,
          "art": "https://example.com/android.jpg",
          "ms": 123000,
          "plays": 2,
          "last": 1784000000000
        }],
        "artists": [],
        "albums": [],
        "hours": [0,0,0,0,0,0,0,0,0,123000,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
        "days": {"3": 123000}
      }]
    }
    """#
}

@MainActor
private struct BackupTestEnvironment {
    let defaultsName: String
    let playback: PlaybackSettings
    let downloads: DownloadManager
    let listening: ListeningStatsStore
    let replay: ReplayViewModel
    let scrobbling: ScrobblingManager
    let lyrics: LyricsSettings
    let equalizer: EqualizerSettings
    let libraryPreferences: LibraryPreferences
    let backup: BackupManager
}

private final class BackupTestCredentialStore: ScrobbleCredentialStoring {
    private var values: [String: String]

    init(values: [String: String]) {
        self.values = values
    }

    func string(for key: String) -> String? { values[key] }

    func set(_ value: String?, for key: String) throws {
        values[key] = value
    }
}

private struct BackupScrobbleTransport: ScrobbleHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

private struct BackupArtistFactsTransport: ArtistFactsHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

@MainActor
private final class BackupFakeDownloader: TrackDownloading {
    func downloadTrack(
        _ track: Track,
        quality: DownloadQuality,
        to directory: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        throw CocoaError(.fileNoSuchFile)
    }
}
