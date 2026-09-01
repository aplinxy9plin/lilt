import Foundation

struct BackupPreview: Equatable, Sendable {
    let exportedAt: String
    let versionName: String
    let months: Int
    let tracks: Int
    let settings: Int
    let compatibleSettings: Int

    var dateText: String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fractional.date(from: exportedAt) ?? ISO8601DateFormatter().date(from: exportedAt)
        guard let date else { return exportedAt }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct BackupCandidate: Identifiable, Sendable {
    let id = UUID()
    let data: Data
    let sourceURL: URL
    let preview: BackupPreview
}

struct BackupRestoreResult: Sendable {
    let preview: BackupPreview
    let searchHistory: [String]
}

struct BackupOperationStatus: Equatable, Sendable {
    let message: String
    let isError: Bool
}

enum BitChordBackupError: LocalizedError {
    case tooLarge
    case malformed
    case wrongApp
    case newerSchema
    case invalidSetting(String)
    case invalidListeningData(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge: "That backup is too large to be a Lilt settings backup."
        case .malformed: "That doesn’t look like a Lilt backup."
        case .wrongApp: "That backup was written by another app."
        case .newerSchema: "That backup was written by a newer version of Lilt."
        case .invalidSetting(let key): "The backup contains an invalid setting: \(key)."
        case .invalidListeningData(let detail): "The backup contains invalid listening data: \(detail)."
        }
    }
}

/// The same portable JSON envelope used by the Kotlin app. A backup can move
/// Replay and the shared settings between Android and macOS; credentials,
/// configured private sources, downloads and local file paths are excluded.
@MainActor
final class BackupManager {
    private let listening: ListeningStatsStore
    private let playbackSettings: PlaybackSettings
    private let downloads: DownloadManager
    private let replay: ReplayViewModel
    private let scrobbling: ScrobblingManager
    private let lyricsSettings: LyricsSettings
    private let equalizer: EqualizerSettings
    private let libraryPreferences: LibraryPreferences
    private let appVersion: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        listening: ListeningStatsStore,
        playbackSettings: PlaybackSettings,
        downloads: DownloadManager,
        replay: ReplayViewModel,
        scrobbling: ScrobblingManager,
        lyricsSettings: LyricsSettings,
        equalizer: EqualizerSettings,
        libraryPreferences: LibraryPreferences,
        appVersion: String? = nil
    ) {
        self.listening = listening
        self.playbackSettings = playbackSettings
        self.downloads = downloads
        self.replay = replay
        self.scrobbling = scrobbling
        self.lyricsSettings = lyricsSettings
        self.equalizer = equalizer
        self.libraryPreferences = libraryPreferences
        self.appVersion = appVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        self.decoder = decoder
    }

    static func suggestedFilename(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return "lilt-backup-\(formatter.string(from: now)).json"
    }

    func export(searchHistory: [String], now: Date = Date()) async throws -> Data {
        let nativeBuckets = await listening.exportAll()
        let file = PortableBackupFile(
            versionName: appVersion,
            exportedAt: Self.iso8601.string(from: now),
            settings: portableSettings(searchHistory: searchHistory),
            listening: nativeBuckets.map(Self.portableBucket(from:))
        )
        return try encoder.encode(file)
    }

    func inspect(_ data: Data) throws -> BackupPreview {
        let prepared = try prepare(data)
        return prepared.preview
    }

    func restore(_ data: Data) async throws -> BackupRestoreResult {
        let prepared = try prepare(data)

        // Disk data is replaced first. Every setting below has already been
        // decoded and validated, and property assignment cannot fail.
        try await listening.replaceAll(with: prepared.listening)
        playbackSettings.unmeteredQuality = prepared.wifiQuality
        playbackSettings.meteredQuality = prepared.meteredQuality
        playbackSettings.themeMode = prepared.themeMode
        playbackSettings.wifiOnlyDownloads = prepared.wifiOnlyDownloads
        playbackSettings.autoplay = prepared.autoplay
        playbackSettings.dontRepeatSuggestions = prepared.dontRepeatSuggestions
        playbackSettings.crossfadeSeconds = prepared.crossfadeSeconds
        playbackSettings.smartFadeEnabled = prepared.smartFadeEnabled
        playbackSettings.skipSilence = prepared.skipSilence
        playbackSettings.spatialAudio = prepared.spatialAudio
        playbackSettings.convertVideoToAudio = prepared.convertVideoToAudio
        playbackSettings.playbackSpeed = prepared.playbackSpeed
        playbackSettings.showNerdStats = prepared.showNerdStats
        playbackSettings.hideVolumeBar = prepared.hideVolumeBar
        playbackSettings.dynamicArtworkTheme = prepared.dynamicArtworkTheme
        playbackSettings.reduceAnimation = prepared.reduceAnimation
        playbackSettings.reduceDynamicBlur = prepared.reduceDynamicBlur
        playbackSettings.fullBleedArtwork = prepared.fullBleedArtwork
        playbackSettings.animatedCanvas = prepared.animatedCanvas
        playbackSettings.canvasOverMetered = prepared.canvasOverMetered
        playbackSettings.audioCacheLimitBytes = prepared.audioCacheLimitBytes
        downloads.preferredQuality = prepared.downloadQuality
        downloads.maximumParallelDownloads = prepared.parallelDownloads
        replay.genresEnabled = prepared.replayGenres
        scrobbling.applyPortableSettings(
            lastFMEnabled: prepared.lastFMEnabled,
            lastFMUsername: prepared.lastFMUsername,
            lastFMEndpoint: prepared.lastFMEndpoint,
            lastFMScrobbleEnabled: prepared.lastFMScrobbleEnabled,
            lastFMNowPlaying: prepared.lastFMNowPlaying,
            listenBrainzEnabled: prepared.listenBrainzEnabled,
            minimumSongDuration: prepared.minimumSongDuration,
            delayPercent: prepared.scrobbleDelayPercent,
            maximumDelay: prepared.maximumScrobbleDelay
        )
        lyricsSettings.applyPortableSettings(
            enabled: prepared.syncedLyrics,
            sources: prepared.lyricsSources,
            order: prepared.lyricsSourceOrder,
            prioritizeWordTiming: prepared.prioritizeSyllableSync
        )
        equalizer.applyPortable(
            enabled: prepared.equalizerEnabled,
            presetRaw: prepared.equalizerPreset.rawValue,
            preampDB: prepared.equalizerPreampDB,
            gainsDB: prepared.equalizerGainsDB
        )
        libraryPreferences.replace(with: prepared.pinnedPlaylistIDs)

        return BackupRestoreResult(
            preview: prepared.preview,
            searchHistory: prepared.searchHistory
        )
    }

    private func portableSettings(searchHistory: [String]) -> [String: PortablePreference] {
        let history = (try? JSONEncoder().encode(Array(searchHistory.prefix(20))))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return [
            "audio_quality_wifi": .string(playbackSettings.unmeteredQuality.rawValue.uppercased()),
            "audio_quality_cellular": .string(playbackSettings.meteredQuality.rawValue.uppercased()),
            "audio_quality_download": .string(downloads.preferredQuality.rawValue.uppercased()),
            "theme_mode": .string(playbackSettings.themeMode.rawValue.uppercased()),
            "wifi_only_downloads": .bool(playbackSettings.wifiOnlyDownloads),
            "autoplay": .bool(playbackSettings.autoplay),
            "dont_repeat_suggestions": .bool(playbackSettings.dontRepeatSuggestions),
            "crossfade_seconds": .int(playbackSettings.crossfadeSeconds),
            "smart_fade_enabled": .bool(playbackSettings.smartFadeEnabled),
            "skip_silence": .bool(playbackSettings.skipSilence),
            "spatial_audio": .bool(playbackSettings.spatialAudio),
            "convert_video_to_audio": .bool(playbackSettings.convertVideoToAudio),
            "playback_speed": .float(playbackSettings.playbackSpeed),
            "show_nerd_stats": .bool(playbackSettings.showNerdStats),
            "hide_volume_bar": .bool(playbackSettings.hideVolumeBar),
            "reduce_animation": .bool(playbackSettings.reduceAnimation),
            "reduce_dynamic_blur": .bool(playbackSettings.reduceDynamicBlur),
            "full_bleed_artwork": .bool(playbackSettings.fullBleedArtwork),
            "animated_canvas": .bool(playbackSettings.animatedCanvas),
            "canvas_over_cellular": .bool(playbackSettings.canvasOverMetered),
            "audio_cache_limit_bytes": .long(playbackSettings.audioCacheLimitBytes),
            "replay_genres": .bool(replay.genresEnabled),
            "pinned_playlists": .string(libraryPreferences.pinnedPlaylistIDs.joined(separator: ",")),
            "mac_dynamic_artwork_theme": .bool(playbackSettings.dynamicArtworkTheme),
            "search_history": .string(history),
            "mac_parallel_downloads": .int(downloads.maximumParallelDownloads),
            "lastfm_enabled": .bool(scrobbling.lastFMEnabled),
            "lastfm_username": .string(scrobbling.lastFMUsername),
            "lastfm_endpoint": .string(scrobbling.lastFMEndpoint),
            "lastfm_scrobble_enabled": .bool(scrobbling.lastFMScrobbleEnabled),
            "lastfm_now_playing": .bool(scrobbling.lastFMNowPlayingEnabled),
            "listenbrainz_enabled": .bool(scrobbling.listenBrainzEnabled),
            "scrobble_min_duration": .int(scrobbling.minimumSongDuration),
            "scrobble_delay_percent": .float(scrobbling.delayPercent),
            "scrobble_delay_seconds": .int(scrobbling.maximumDelay),
            "synced_lyrics": .bool(lyricsSettings.enabled),
            "lyrics_sources": .string(
                LyricsSource.allCases.filter(lyricsSettings.enabledSources.contains)
                    .map(\.rawValue).joined(separator: ",")
            ),
            "lyrics_source_order": .string(lyricsSettings.sourceOrder.map(\.rawValue).joined(separator: ",")),
            "prioritize_syllable_sync": .bool(lyricsSettings.prioritizeWordTiming),
            "mac_equalizer_enabled": .bool(equalizer.isEnabled),
            "mac_equalizer_preset": .string(equalizer.preset.rawValue),
            "mac_equalizer_preamp": .float(Double(equalizer.preampDB)),
            "mac_equalizer_gains": .string(equalizer.bandGainsDB.map { String($0) }.joined(separator: ","))
        ]
    }

    private func prepare(_ data: Data) throws -> PreparedBackup {
        guard data.count <= 25 * 1_024 * 1_024 else { throw BitChordBackupError.tooLarge }
        guard let file = try? decoder.decode(PortableBackupFile.self, from: data) else {
            throw BitChordBackupError.malformed
        }
        guard file.app == "bitchord" else { throw BitChordBackupError.wrongApp }
        guard file.version <= 1 else { throw BitChordBackupError.newerSchema }
        guard file.listening.count <= 120 else {
            throw BitChordBackupError.invalidListeningData("too many monthly buckets")
        }

        let wifi = try audioQuality(file.settings["audio_quality_wifi"], key: "audio_quality_wifi")
        let metered = try audioQuality(file.settings["audio_quality_cellular"], key: "audio_quality_cellular")
        let download = try downloadQuality(file.settings["audio_quality_download"])
        let themeMode = try themeMode(file.settings["theme_mode"])
        let wifiOnlyDownloads = try boolean(
            file.settings["wifi_only_downloads"],
            key: "wifi_only_downloads",
            default: true
        )
        let autoplay = try boolean(file.settings["autoplay"], key: "autoplay", default: true)
        let dontRepeatSuggestions = try boolean(
            file.settings["dont_repeat_suggestions"],
            key: "dont_repeat_suggestions",
            default: false
        )
        let crossfade = try integer(file.settings["crossfade_seconds"], key: "crossfade_seconds", default: 0)
        guard (0...12).contains(crossfade) else { throw BitChordBackupError.invalidSetting("crossfade_seconds") }
        let smartFade = try boolean(
            file.settings["smart_fade_enabled"],
            key: "smart_fade_enabled",
            default: false
        )
        let skip = try boolean(file.settings["skip_silence"], key: "skip_silence", default: false)
        let spatialAudio = try boolean(
            file.settings["spatial_audio"],
            key: "spatial_audio",
            default: false
        )
        let convertVideoToAudio = try boolean(
            file.settings["convert_video_to_audio"],
            key: "convert_video_to_audio",
            default: true
        )
        let playbackSpeed = try floatingPoint(
            file.settings["playback_speed"],
            key: "playback_speed",
            default: 1
        )
        guard (0.5...2).contains(playbackSpeed) else {
            throw BitChordBackupError.invalidSetting("playback_speed")
        }
        let showNerdStats = try boolean(
            file.settings["show_nerd_stats"],
            key: "show_nerd_stats",
            default: false
        )
        let hideVolumeBar = try boolean(
            file.settings["hide_volume_bar"],
            key: "hide_volume_bar",
            default: false
        )
        let reduceAnimation = try boolean(
            file.settings["reduce_animation"],
            key: "reduce_animation",
            default: false
        )
        let reduceDynamicBlur = try boolean(
            file.settings["reduce_dynamic_blur"],
            key: "reduce_dynamic_blur",
            default: false
        )
        let fullBleedArtwork = try boolean(
            file.settings["full_bleed_artwork"],
            key: "full_bleed_artwork",
            default: true
        )
        let dynamicArtworkTheme = try boolean(
            file.settings["mac_dynamic_artwork_theme"],
            key: "mac_dynamic_artwork_theme",
            default: true
        )
        let animatedCanvas = try boolean(
            file.settings["animated_canvas"],
            key: "animated_canvas",
            default: true
        )
        let canvasOverMetered = try boolean(
            file.settings["canvas_over_cellular"],
            key: "canvas_over_cellular",
            default: false
        )
        let audioCacheLimitBytes = try longInteger(
            file.settings["audio_cache_limit_bytes"],
            key: "audio_cache_limit_bytes",
            default: AudioStreamCache.defaultLimitBytes
        )
        guard (AudioStreamCache.defaultLimitBytes...AudioStreamCache.maximumLimitBytes)
            .contains(audioCacheLimitBytes) else {
            throw BitChordBackupError.invalidSetting("audio_cache_limit_bytes")
        }
        let replayGenres = try boolean(
            file.settings["replay_genres"],
            key: "replay_genres",
            default: true
        )
        let pinnedPlaylists = LibraryPreferences.decode(try string(
            file.settings[LibraryPreferences.storageKey],
            key: LibraryPreferences.storageKey,
            default: ""
        ))
        let parallel = try integer(file.settings["mac_parallel_downloads"], key: "mac_parallel_downloads", default: 3)
        guard (1...4).contains(parallel) else { throw BitChordBackupError.invalidSetting("mac_parallel_downloads") }
        let searchHistory = try decodeSearchHistory(file.settings["search_history"])
        let lastFMEnabled = try boolean(file.settings["lastfm_enabled"], key: "lastfm_enabled", default: false)
        let lastFMUsername = try string(file.settings["lastfm_username"], key: "lastfm_username", default: "")
        let lastFMEndpointRaw = try string(
            file.settings["lastfm_endpoint"],
            key: "lastfm_endpoint",
            default: LastFMClient.defaultEndpoint
        )
        guard let lastFMEndpoint = try? LastFMClient.normalizeEndpoint(lastFMEndpointRaw).absoluteString else {
            throw BitChordBackupError.invalidSetting("lastfm_endpoint")
        }
        let lastFMScrobbleEnabled = try boolean(
            file.settings["lastfm_scrobble_enabled"],
            key: "lastfm_scrobble_enabled",
            default: false
        )
        let lastFMNowPlaying = try boolean(
            file.settings["lastfm_now_playing"],
            key: "lastfm_now_playing",
            default: false
        )
        let listenBrainzEnabled = try boolean(
            file.settings["listenbrainz_enabled"],
            key: "listenbrainz_enabled",
            default: false
        )
        let minimumSongDuration = try integer(
            file.settings["scrobble_min_duration"],
            key: "scrobble_min_duration",
            default: 30
        )
        guard (15...120).contains(minimumSongDuration) else {
            throw BitChordBackupError.invalidSetting("scrobble_min_duration")
        }
        let scrobbleDelayPercent = try floatingPoint(
            file.settings["scrobble_delay_percent"],
            key: "scrobble_delay_percent",
            default: 0.5
        )
        guard (0.1...1).contains(scrobbleDelayPercent) else {
            throw BitChordBackupError.invalidSetting("scrobble_delay_percent")
        }
        let maximumScrobbleDelay = try integer(
            file.settings["scrobble_delay_seconds"],
            key: "scrobble_delay_seconds",
            default: 180
        )
        guard (30...300).contains(maximumScrobbleDelay) else {
            throw BitChordBackupError.invalidSetting("scrobble_delay_seconds")
        }
        let syncedLyrics = try boolean(file.settings["synced_lyrics"], key: "synced_lyrics", default: true)
        let lyricsSourcesRaw = try string(
            file.settings["lyrics_sources"],
            key: "lyrics_sources",
            default: LyricsSource.allCases.map(\.rawValue).joined(separator: ",")
        )
        let lyricsSources = Set(lyricsSourcesRaw.split(separator: ",").compactMap {
            LyricsSource(rawValue: String($0))
        })
        let lyricsOrderRaw = try string(
            file.settings["lyrics_source_order"],
            key: "lyrics_source_order",
            default: LyricsSource.allCases.map(\.rawValue).joined(separator: ",")
        )
        var seenLyricsSources = Set<LyricsSource>()
        let savedLyricsOrder = lyricsOrderRaw.split(separator: ",").compactMap {
            LyricsSource(rawValue: String($0))
        }.filter { seenLyricsSources.insert($0).inserted }
        let lyricsSourceOrder = savedLyricsOrder + LyricsSource.allCases.filter { !seenLyricsSources.contains($0) }
        let prioritizeSyllableSync = try boolean(
            file.settings["prioritize_syllable_sync"],
            key: "prioritize_syllable_sync",
            default: false
        )
        let equalizerEnabled = try boolean(
            file.settings["mac_equalizer_enabled"],
            key: "mac_equalizer_enabled",
            default: false
        )
        let equalizerPresetRaw = try string(
            file.settings["mac_equalizer_preset"],
            key: "mac_equalizer_preset",
            default: EqualizerPreset.flat.rawValue
        )
        guard let equalizerPreset = EqualizerPreset(rawValue: equalizerPresetRaw) else {
            throw BitChordBackupError.invalidSetting("mac_equalizer_preset")
        }
        let equalizerPreamp = try floatingPoint(
            file.settings["mac_equalizer_preamp"],
            key: "mac_equalizer_preamp",
            default: 0
        )
        guard EqualizerSnapshot.preampRange.contains(Float(equalizerPreamp)) else {
            throw BitChordBackupError.invalidSetting("mac_equalizer_preamp")
        }
        let defaultEqualizerGains = repeatElement("0", count: EqualizerSnapshot.frequencies.count)
            .joined(separator: ",")
        let equalizerGainsRaw = try string(
            file.settings["mac_equalizer_gains"],
            key: "mac_equalizer_gains",
            default: defaultEqualizerGains
        )
        let equalizerGains = equalizerGainsRaw.split(separator: ",", omittingEmptySubsequences: false)
            .compactMap { Float($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard equalizerGains.count == EqualizerSnapshot.frequencies.count,
              equalizerGains.allSatisfy(EqualizerSnapshot.gainRange.contains) else {
            throw BitChordBackupError.invalidSetting("mac_equalizer_gains")
        }

        var months = Set<String>()
        let nativeBuckets = try file.listening.map { portable -> StoredListeningBucket in
            guard Self.validMonth(portable.month), months.insert(portable.month).inserted else {
                throw BitChordBackupError.invalidListeningData("invalid or duplicate month \(portable.month)")
            }
            guard portable.tracks.count <= 5_000,
                  portable.hours.count <= 24,
                  portable.hours.allSatisfy({ $0 >= 0 }),
                  portable.days.values.allSatisfy({ $0 >= 0 }) else {
                throw BitChordBackupError.invalidListeningData(portable.month)
            }

            var tracks: [String: StoredListeningTrack] = [:]
            for entry in portable.tracks {
                guard !entry.id.isEmpty,
                      entry.milliseconds >= 0,
                      entry.plays >= 0,
                      tracks[entry.id] == nil else {
                    throw BitChordBackupError.invalidListeningData("invalid track in \(portable.month)")
                }
                let isPortableLocal = entry.id.hasPrefix("local:")
                let track = Track(
                    videoID: isPortableLocal ? nil : entry.id,
                    title: entry.title.isEmpty ? "Unknown song" : entry.title,
                    artist: entry.artist.isEmpty ? "Unknown artist" : entry.artist,
                    album: entry.album,
                    artworkURL: entry.artworkURL,
                    duration: nil,
                    localPath: nil,
                    sourceURL: nil
                )
                tracks[entry.id] = StoredListeningTrack(
                    track: track,
                    milliseconds: entry.milliseconds,
                    plays: entry.plays,
                    lastPlayedAt: Date(timeIntervalSince1970: Double(entry.lastPlayedAt) / 1_000)
                )
            }

            var bucket = StoredListeningBucket(month: portable.month)
            bucket.tracks = tracks
            bucket.hours = Array(portable.hours.prefix(24))
            if bucket.hours.count < 24 {
                bucket.hours.append(contentsOf: repeatElement(0, count: 24 - bucket.hours.count))
            }
            bucket.days = Dictionary(uniqueKeysWithValues: portable.days.compactMap { day, milliseconds in
                guard (1...31).contains(day) else { return nil }
                return (String(format: "%@-%02d", portable.month, day), milliseconds)
            })
            guard bucket.days.count == portable.days.count else {
                throw BitChordBackupError.invalidListeningData("invalid day in \(portable.month)")
            }
            return bucket
        }

        let supportedKeys = Set([
            "audio_quality_wifi", "audio_quality_cellular", "audio_quality_download", "theme_mode", "wifi_only_downloads",
            "autoplay", "dont_repeat_suggestions",
            "crossfade_seconds", "smart_fade_enabled", "skip_silence", "spatial_audio",
            "convert_video_to_audio", "playback_speed",
            "show_nerd_stats", "hide_volume_bar", "reduce_animation", "reduce_dynamic_blur",
            "full_bleed_artwork",
            "animated_canvas", "canvas_over_cellular", "audio_cache_limit_bytes",
            "replay_genres", "pinned_playlists",
            "mac_dynamic_artwork_theme", "search_history",
            "mac_parallel_downloads", "lastfm_enabled", "lastfm_username", "lastfm_endpoint",
            "lastfm_scrobble_enabled", "lastfm_now_playing", "listenbrainz_enabled",
            "scrobble_min_duration", "scrobble_delay_percent", "scrobble_delay_seconds",
            "synced_lyrics", "lyrics_sources", "lyrics_source_order", "prioritize_syllable_sync",
            "mac_equalizer_enabled", "mac_equalizer_preset", "mac_equalizer_preamp", "mac_equalizer_gains"
        ])
        let preview = BackupPreview(
            exportedAt: file.exportedAt,
            versionName: file.versionName.isEmpty ? "unknown" : file.versionName,
            months: nativeBuckets.count,
            tracks: nativeBuckets.reduce(0) { $0 + $1.tracks.count },
            settings: file.settings.count,
            compatibleSettings: file.settings.keys.filter(supportedKeys.contains).count
        )
        return PreparedBackup(
            preview: preview,
            listening: nativeBuckets,
            wifiQuality: wifi,
            meteredQuality: metered,
            downloadQuality: download,
            themeMode: themeMode,
            wifiOnlyDownloads: wifiOnlyDownloads,
            autoplay: autoplay,
            dontRepeatSuggestions: dontRepeatSuggestions,
            crossfadeSeconds: crossfade,
            smartFadeEnabled: smartFade,
            skipSilence: skip,
            spatialAudio: spatialAudio,
            convertVideoToAudio: convertVideoToAudio,
            playbackSpeed: playbackSpeed,
            showNerdStats: showNerdStats,
            hideVolumeBar: hideVolumeBar,
            dynamicArtworkTheme: dynamicArtworkTheme,
            reduceAnimation: reduceAnimation,
            reduceDynamicBlur: reduceDynamicBlur,
            fullBleedArtwork: fullBleedArtwork,
            animatedCanvas: animatedCanvas,
            canvasOverMetered: canvasOverMetered,
            audioCacheLimitBytes: audioCacheLimitBytes,
            replayGenres: replayGenres,
            pinnedPlaylistIDs: pinnedPlaylists,
            parallelDownloads: parallel,
            searchHistory: searchHistory,
            lastFMEnabled: lastFMEnabled,
            lastFMUsername: lastFMUsername,
            lastFMEndpoint: lastFMEndpoint,
            lastFMScrobbleEnabled: lastFMScrobbleEnabled,
            lastFMNowPlaying: lastFMNowPlaying,
            listenBrainzEnabled: listenBrainzEnabled,
            minimumSongDuration: minimumSongDuration,
            scrobbleDelayPercent: scrobbleDelayPercent,
            maximumScrobbleDelay: maximumScrobbleDelay,
            syncedLyrics: syncedLyrics,
            lyricsSources: lyricsSources,
            lyricsSourceOrder: lyricsSourceOrder,
            prioritizeSyllableSync: prioritizeSyllableSync,
            equalizerEnabled: equalizerEnabled,
            equalizerPreset: equalizerPreset,
            equalizerPreampDB: Float(equalizerPreamp),
            equalizerGainsDB: equalizerGains
        )
    }

    private func audioQuality(_ value: PortablePreference?, key: String) throws -> AudioQuality {
        guard let value else { return .high }
        guard value.type == "string", let raw = value.value?.lowercased(),
              let quality = AudioQuality(rawValue: raw) else {
            throw BitChordBackupError.invalidSetting(key)
        }
        return quality
    }

    private func downloadQuality(_ value: PortablePreference?) throws -> DownloadQuality {
        guard let value else { return .lossless }
        guard value.type == "string", let raw = value.value?.lowercased(),
              let quality = DownloadQuality(rawValue: raw) else {
            throw BitChordBackupError.invalidSetting("audio_quality_download")
        }
        return quality
    }

    private func themeMode(_ value: PortablePreference?) throws -> AppThemeMode {
        guard let value else { return .dark }
        guard value.type == "string", let raw = value.value?.lowercased(),
              let theme = AppThemeMode(rawValue: raw) else {
            throw BitChordBackupError.invalidSetting("theme_mode")
        }
        return theme
    }

    private func integer(
        _ value: PortablePreference?,
        key: String,
        default defaultValue: Int
    ) throws -> Int {
        guard let value else { return defaultValue }
        guard value.type == "int", let raw = value.value, let number = Int(raw) else {
            throw BitChordBackupError.invalidSetting(key)
        }
        return number
    }

    private func longInteger(
        _ value: PortablePreference?,
        key: String,
        default defaultValue: Int64
    ) throws -> Int64 {
        guard let value else { return defaultValue }
        guard value.type == "long", let raw = value.value, let number = Int64(raw) else {
            throw BitChordBackupError.invalidSetting(key)
        }
        return number
    }

    private func boolean(
        _ value: PortablePreference?,
        key: String,
        default defaultValue: Bool
    ) throws -> Bool {
        guard let value else { return defaultValue }
        guard value.type == "bool", let raw = value.value,
              raw == "true" || raw == "false" else {
            throw BitChordBackupError.invalidSetting(key)
        }
        return raw == "true"
    }

    private func string(
        _ value: PortablePreference?,
        key: String,
        default defaultValue: String
    ) throws -> String {
        guard let value else { return defaultValue }
        guard value.type == "string", let raw = value.value else {
            throw BitChordBackupError.invalidSetting(key)
        }
        return raw
    }

    private func floatingPoint(
        _ value: PortablePreference?,
        key: String,
        default defaultValue: Double
    ) throws -> Double {
        guard let value else { return defaultValue }
        guard value.type == "float", let raw = value.value, let number = Double(raw) else {
            throw BitChordBackupError.invalidSetting(key)
        }
        return number
    }

    private func decodeSearchHistory(_ value: PortablePreference?) throws -> [String] {
        guard let value else { return [] }
        guard value.type == "string", let raw = value.value,
              let data = raw.data(using: .utf8),
              let history = try? JSONDecoder().decode([String].self, from: data) else {
            throw BitChordBackupError.invalidSetting("search_history")
        }
        return Array(history.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .uniquedCaseInsensitive()
            .prefix(20))
    }

    private static func portableBucket(from bucket: StoredListeningBucket) -> PortableListeningBucket {
        let tracks = bucket.tracks.map { id, stored in
            PortableTrackEntry(
                id: stored.track.videoID ?? opaqueLocalID(track: stored.track),
                title: stored.track.title,
                artist: stored.track.artist,
                album: stored.track.album,
                artworkURL: stored.track.artworkURL,
                milliseconds: stored.milliseconds,
                plays: stored.plays,
                lastPlayedAt: Int64(stored.lastPlayedAt.timeIntervalSince1970 * 1_000)
            )
        }
        .sorted { $0.id < $1.id }

        return PortableListeningBucket(
            month: bucket.month,
            tracks: tracks,
            artists: aggregateNames(tracks: tracks, albums: false),
            albums: aggregateNames(tracks: tracks, albums: true),
            hours: bucket.hours,
            days: Dictionary(uniqueKeysWithValues: bucket.days.compactMap { key, value in
                guard let day = Int(key.suffix(2)) else { return nil }
                return (day, value)
            })
        )
    }

    private static func aggregateNames(tracks: [PortableTrackEntry], albums: Bool) -> [PortableNameEntry] {
        var result: [String: PortableNameEntry] = [:]
        for track in tracks {
            let name = albums ? track.album?.trimmingCharacters(in: .whitespacesAndNewlines) : primaryArtist(track.artist)
            guard let name, !name.isEmpty else { continue }
            let subtitle = albums ? track.artist : nil
            let key = albums ? "\(name.lowercased())\u{1f}\(track.artist.lowercased())" : name.lowercased()
            var current = result[key] ?? PortableNameEntry(
                name: name,
                subtitle: subtitle,
                artworkURL: track.artworkURL,
                milliseconds: 0,
                plays: 0
            )
            current.milliseconds += track.milliseconds
            current.plays += track.plays
            if current.artworkURL == nil { current.artworkURL = track.artworkURL }
            result[key] = current
        }
        return result.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func primaryArtist(_ raw: String) -> String? {
        let separators = [" feat.", " featuring ", " ft.", " & ", " x ", " vs. ", ","]
        let ranges = separators.compactMap { raw.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
        let value = ranges.min(by: { $0.lowerBound < $1.lowerBound })
            .map { String(raw[..<$0.lowerBound]) } ?? raw
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func opaqueLocalID(track: Track) -> String {
        // Never place a local path in a portable backup. This small stable hash
        // only keeps the same local recording grouped across monthly buckets.
        let source = "\(track.title)\u{1f}\(track.artist)\u{1f}\(track.album ?? "")"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "local:\(String(hash, radix: 16))"
    }

    private static func validMonth(_ value: String) -> Bool {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        return pieces.count == 2
            && pieces[0].count == 4
            && Int(pieces[0]).map { (2000...9999).contains($0) } == true
            && Int(pieces[1]).map { (1...12).contains($0) } == true
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct PreparedBackup {
    let preview: BackupPreview
    let listening: [StoredListeningBucket]
    let wifiQuality: AudioQuality
    let meteredQuality: AudioQuality
    let downloadQuality: DownloadQuality
    let themeMode: AppThemeMode
    let wifiOnlyDownloads: Bool
    let autoplay: Bool
    let dontRepeatSuggestions: Bool
    let crossfadeSeconds: Int
    let smartFadeEnabled: Bool
    let skipSilence: Bool
    let spatialAudio: Bool
    let convertVideoToAudio: Bool
    let playbackSpeed: Double
    let showNerdStats: Bool
    let hideVolumeBar: Bool
    let dynamicArtworkTheme: Bool
    let reduceAnimation: Bool
    let reduceDynamicBlur: Bool
    let fullBleedArtwork: Bool
    let animatedCanvas: Bool
    let canvasOverMetered: Bool
    let audioCacheLimitBytes: Int64
    let replayGenres: Bool
    let pinnedPlaylistIDs: [String]
    let parallelDownloads: Int
    let searchHistory: [String]
    let lastFMEnabled: Bool
    let lastFMUsername: String
    let lastFMEndpoint: String
    let lastFMScrobbleEnabled: Bool
    let lastFMNowPlaying: Bool
    let listenBrainzEnabled: Bool
    let minimumSongDuration: Int
    let scrobbleDelayPercent: Double
    let maximumScrobbleDelay: Int
    let syncedLyrics: Bool
    let lyricsSources: Set<LyricsSource>
    let lyricsSourceOrder: [LyricsSource]
    let prioritizeSyllableSync: Bool
    let equalizerEnabled: Bool
    let equalizerPreset: EqualizerPreset
    let equalizerPreampDB: Float
    let equalizerGainsDB: [Float]
}

private struct PortableBackupFile: Codable {
    var app = "bitchord"
    var version = 1
    var versionName = ""
    var exportedAt = ""
    var settings: [String: PortablePreference] = [:]
    var listening: [PortableListeningBucket] = []
}

private struct PortablePreference: Codable {
    var type: String
    var value: String?
    var values: [String] = []

    static func string(_ value: String) -> Self { .init(type: "string", value: value) }
    static func int(_ value: Int) -> Self { .init(type: "int", value: String(value)) }
    static func long(_ value: Int64) -> Self { .init(type: "long", value: String(value)) }
    static func bool(_ value: Bool) -> Self { .init(type: "bool", value: String(value)) }
    static func float(_ value: Double) -> Self { .init(type: "float", value: String(value)) }
}

private struct PortableListeningBucket: Codable {
    var version = 1
    var month: String
    var tracks: [PortableTrackEntry] = []
    var artists: [PortableNameEntry] = []
    var albums: [PortableNameEntry] = []
    var hours: [Int64] = Array(repeating: 0, count: 24)
    var days: [Int: Int64] = [:]
}

private struct PortableTrackEntry: Codable {
    var id: String
    var title = ""
    var artist = ""
    var album: String?
    var albumId: String?
    var artistId: String?
    var art: String?
    var ms: Int64 = 0
    var plays = 0
    var last: Int64 = 0

    var artworkURL: String? { art }
    var milliseconds: Int64 { ms }
    var lastPlayedAt: Int64 { last }

    init(
        id: String,
        title: String,
        artist: String,
        album: String?,
        artworkURL: String?,
        milliseconds: Int64,
        plays: Int,
        lastPlayedAt: Int64
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        art = artworkURL
        ms = milliseconds
        self.plays = plays
        last = lastPlayedAt
    }
}

private struct PortableNameEntry: Codable {
    var name = ""
    var sub: String?
    var art: String?
    var id: String?
    var ms: Int64 = 0
    var plays = 0
    var key: String?

    var artworkURL: String? {
        get { art }
        set { art = newValue }
    }
    var milliseconds: Int64 {
        get { ms }
        set { ms = newValue }
    }
    var subtitle: String? { sub }

    init(
        name: String,
        subtitle: String?,
        artworkURL: String?,
        milliseconds: Int64,
        plays: Int
    ) {
        self.name = name
        sub = subtitle
        art = artworkURL
        ms = milliseconds
        self.plays = plays
    }
}

private extension Sequence where Element == String {
    func uniquedCaseInsensitive() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted }
    }
}
