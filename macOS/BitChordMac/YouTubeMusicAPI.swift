import CryptoKit
import Darwin
import Foundation
import os

enum YouTubeMusicAPIError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case noPlayableStream
    case malformedData
    case authenticationRequired
    case accountWriteRefused(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The service returned an invalid response."
        case .httpStatus(let code): "YouTube Music returned HTTP \(code)."
        case .noPlayableStream: "No direct audio stream was available for this track."
        case .malformedData: "The service response could not be read."
        case .authenticationRequired: "Sign in to YouTube Music to load your library."
        case .accountWriteRefused(let message): message
        }
    }
}

struct ResolvedStream: Sendable {
    let url: URL
    let headers: [String: String]
    let videoID: String?
    let info: AudioStreamInfo?
    let duration: TimeInterval?

    init(
        url: URL,
        headers: [String: String],
        videoID: String? = nil,
        info: AudioStreamInfo? = nil,
        duration: TimeInterval? = nil
    ) {
        self.url = url
        self.headers = headers
        self.videoID = videoID
        self.info = info
        let urlDuration = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "dur" })?
            .value
            .flatMap(TimeInterval.init)
        self.duration = Self.validDuration(duration) ?? Self.validDuration(urlDuration)
    }

    private static func validDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// The loopback proxy exists only to preserve resolver-supplied headers
    /// that AVPlayer drops on macOS. Headerless CDN streams are safer and
    /// faster when AVFoundation reads them directly.
    var requiresLocalPlaybackProxy: Bool {
        !headers.isEmpty
    }
}

struct PlaybackTrackingURLs: Equatable, Sendable {
    let playbackURL: String
    let watchtimeURL: String?
    let atrURL: String?
    let atrAfterSeconds: TimeInterval
}

@MainActor
protocol PlaybackHistoryAPI: AnyObject {
    var isAuthenticated: Bool { get }
    func playbackTracking(for videoID: String) async throws -> PlaybackTrackingURLs?
    func pingPlayback(_ baseURL: String, cpn: String) async throws
    func pingATR(_ baseURL: String, cpn: String) async throws
    func pingWatchtime(_ baseURL: String, cpn: String, seconds: Int, final: Bool) async throws
}

@MainActor
protocol AutoplayTrackProviding: AnyObject {
    func autoplayTracks(for videoID: String) async throws -> [Track]
}

@MainActor
protocol PlaybackStreamResolving: AnyObject {
    var isAuthenticated: Bool { get }
    /// Returns the catalogue audio release for a music-video row when the
    /// Android-compatible conversion preference is enabled.
    func resolvePlaybackTrack(for track: Track) async -> Track
    func resolveStream(for track: Track) async throws -> ResolvedStream
    func downloadPlaybackFallback(for track: Track) async throws -> URL
    func invalidateResolvedStream(for track: Track)
    func cacheResolvedStream(_ stream: ResolvedStream) async
    func lyrics(for track: Track) async throws -> Lyrics?
}

extension PlaybackStreamResolving {
    func resolvePlaybackTrack(for track: Track) async -> Track { track }
    func invalidateResolvedStream(for track: Track) {}
    func cacheResolvedStream(_ stream: ResolvedStream) async {}
}

struct ParsedYTDLPStream: Sendable {
    let stream: ResolvedStream
    let availableAt: TimeInterval?
}

struct PlaybackFallbackAttempt: Equatable, Sendable {
    let extractorClient: String
    let includesCookies: Bool
}

struct YouTubeSignatureCipher: Equatable, Sendable {
    let url: URL
    let encryptedSignature: String
    let signatureParameter: String
}

private struct YouTubePlayerJavaScript: Sendable {
    let url: URL
    let source: String
    let signatureTimestamp: Int?
}

private struct YouTubeChallengeSolution: Decodable, Sendable {
    let signature: String?
    let n: String?
}

private struct StreamCacheKey: Hashable {
    let videoID: String
    let quality: String
}

private struct CachedStream {
    let stream: ResolvedStream
    let storedAt: Date
}

private final class DownloadProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    func install(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancellationRequested else { return false }
        self.process = process
        return true
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let process = process
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }
}

@MainActor
final class YouTubeMusicAPI: PlaybackStreamResolving, PlaybackHistoryAPI, AutoplayTrackProviding, TrackDownloading {
    private let streamLogger = Logger(subsystem: "com.bitchord.mac", category: "StreamResolver")
    private let session: URLSession
    private let lyricsSettings: LyricsSettings
    private let lyricsRepository: LyricsRepository
    private let audioCache: AudioStreamCache

    private let musicBase = URL(string: "https://music.youtube.com/youtubei/v1")!
    private let youtubeBase = URL(string: "https://www.youtube.com/youtubei/v1")!

    private let webClient = PlayerClient(
        name: "WEB_REMIX",
        version: "1.20250101.01.00",
        id: "67",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
        origin: "https://music.youtube.com"
    )

    // Device clients are deliberately tried before WEB_REMIX. They return
    // unciphered audio URLs, which is the same route used by the Android app.
    private let streamClients = [
        PlayerClient(
            name: "ANDROID_MUSIC",
            version: "8.39.42",
            id: "21",
            userAgent: "com.google.android.apps.youtube.music/8.39.42 (Linux; U; Android 15; en_US; Pixel 9 Pro; Build/AP4A.250205.002) gzip",
            osName: "Android", osVersion: "15", deviceMake: "Google", deviceModel: "Pixel 9 Pro", androidSDK: 35
        ),
        PlayerClient(
            name: "TVHTML5",
            version: "7.20260707.07.00",
            id: "7",
            userAgent: "Mozilla/5.0(SMART-TV; Linux; Tizen 4.0.0.2) AppleWebkit/605.1.15 (KHTML, like Gecko) SamsungBrowser/9.2 TV Safari/605.1.15",
            origin: "https://www.youtube.com"
        ),
        PlayerClient(
            name: "ANDROID_VR",
            version: "1.65.10",
            id: "28",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
            osName: "Android", osVersion: "12L", deviceMake: "Oculus", deviceModel: "Quest 3", androidSDK: 32
        ),
        PlayerClient(
            name: "ANDROID_VR",
            version: "1.43.32",
            id: "28",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.43.32 (Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/107.0.5284.2)",
            osName: "Android", osVersion: "12L", deviceMake: "Oculus", deviceModel: "Quest 3", androidSDK: 32
        ),
        PlayerClient(
            name: "IOS",
            version: "21.26.4",
            id: "5",
            userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
            osName: "iPhone", osVersion: "18.3.2.22D82", deviceMake: "Apple", deviceModel: "iPhone16,2"
        ),
        PlayerClient(
            name: "IOS",
            version: "21.29.1",
            id: "5",
            userAgent: "com.google.ios.youtube/21.29.1 (iPhone16,2; U; CPU iOS 18_5 like Mac OS X;)",
            osName: "iPhone", osVersion: "18.5.22F70", deviceMake: "Apple", deviceModel: "iPhone16,2"
        )
    ]

    // yt-dlp's fastest authenticated path is not a browser extractor. It is
    // this downgraded Cobalt TV identity making one ordinary InnerTube player
    // request. Ask it directly so signed-in playback does not pay Python
    // startup plus yt-dlp's full metadata walk on every uncached track.
    // Keep the exact identity aligned with yt-dlp's `tv_downgraded` client;
    // the older version is deliberate and is what avoids the ad/media gate.
    private let authenticatedStreamClient = PlayerClient(
        name: "TVHTML5",
        version: YouTubeMusicAPI.authenticatedDirectClientVersion,
        id: "7",
        userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
        origin: "https://www.youtube.com"
    )

    private var cookieHeader: String?
    private var visitorData: String?
    private var sessionScope: SessionScope?
    private var editablePlaylistIDs: Set<String> = []
    private var cachedPlayerJavaScript: YouTubePlayerJavaScript?
    private var playbackQuality: AudioQuality = .high
    private var playbackCacheLimitBytes = AudioStreamCache.defaultLimitBytes
    private var convertVideoToAudio = true
    private var recentStreams: [StreamCacheKey: CachedStream] = [:]
    private var preferredStreamClientKey: String?

    private static let streamCacheTTL: TimeInterval = 20 * 60
    private static let maximumRememberedStreams = 32

    var isAuthenticated: Bool { cookieHeader != nil }

    init(
        session: URLSession? = nil,
        lyricsSettings: LyricsSettings? = nil,
        lyricsRepository: LyricsRepository? = nil,
        audioCache: AudioStreamCache? = nil
    ) {
        Self.cleanupStaleTemporaryCookieFiles()
        let resolvedSession: URLSession
        if let session {
            resolvedSession = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            resolvedSession = URLSession(configuration: configuration)
        }
        self.session = resolvedSession
        self.audioCache = audioCache ?? AudioStreamCache(session: resolvedSession)
        self.lyricsSettings = lyricsSettings ?? LyricsSettings()
        self.lyricsRepository = lyricsRepository
            ?? LyricsRepository(transport: URLSessionLyricsTransport(session: resolvedSession))
    }

    func setCookie(_ cookie: String?) {
        cookieHeader = cookie
        visitorData = nil
        sessionScope = nil
        editablePlaylistIDs = []
        recentStreams.removeAll()
    }

    func setPlaybackQuality(_ quality: AudioQuality) {
        playbackQuality = quality
    }

    func setConvertVideoToAudio(_ enabled: Bool) {
        convertVideoToAudio = enabled
    }

    func search(query: String, filter: SearchFilter) async throws -> [SearchResult] {
        await prepareWebSession()
        let response = try await post(
            endpoint: "search",
            on: musicBase,
            client: webClient,
            authenticated: cookieHeader != nil,
            body: [
                "query": query,
                "params": filter.apiParameter as Any
            ]
        )

        var seen = Set<String>()
        return collectObjects(response, named: "musicResponsiveListItemRenderer").compactMap { renderer in
            if let item = parseBrowseItem(renderer), seen.insert("browse:\(item.id)").inserted {
                return .browse(item)
            }
            guard let track = parseTrack(renderer),
                  !(filter == .songs && track.isMusicVideo),
                  seen.insert("track:\(track.id)").inserted else { return nil }
            return .track(track)
        }
    }

    /// Mirrors Kotlin's `YtMusicRepository.resolveAudio`: only rows identified
    /// as videos are searched, every query is normalized by the shared strict
    /// matcher, and an uncertain result falls back to the original upload.
    func resolvePlaybackTrack(for track: Track) async -> Track {
        guard convertVideoToAudio, track.isMusicVideo, track.videoID != nil else { return track }
        var candidates: [Track] = []
        for query in SourceTrackMatcher.queries(for: track) {
            guard !Task.isCancelled else { return track }
            let rows = (try? await search(query: query, filter: .songs)) ?? []
            candidates.append(contentsOf: rows.compactMap { result in
                guard case .track(let candidate) = result else { return nil }
                return candidate
            })
            if let match = SourceTrackMatcher.best(candidates, for: track) { return match }
        }
        return track
    }

    func home() async throws -> [HomeShelf] {
        await prepareWebSession()
        var shelves: [HomeShelf] = []

        if cookieHeader != nil,
           let history = try? await browse("FEmusic_history") {
            var seenTracks = Set<String>()
            let recent = collectObjects(history, named: "musicResponsiveListItemRenderer")
                .compactMap(parseTrack)
                .filter { seenTracks.insert($0.id).inserted }
                .prefix(20)
                .map { track in
                    ShelfItem(title: track.title, subtitle: track.artist, artworkURL: track.artworkURL, track: track)
                }
            if !recent.isEmpty {
                shelves.append(HomeShelf(title: "Recently played", items: Array(recent)))
            }
        }

        let response = try await post(
            endpoint: "browse",
            on: musicBase,
            client: webClient,
            authenticated: cookieHeader != nil,
            body: ["browseId": "FEmusic_home"]
        )
        shelves.append(contentsOf: parseShelves(response))

        if let newReleases = try? await browse("FEmusic_new_releases") {
            shelves.append(contentsOf: parseShelves(newReleases))
        }

        var seenTitles = Set<String>()
        return shelves.filter { seenTitles.insert($0.title.lowercased()).inserted }
    }

    /// Mirrors Android's Explore tab. YouTube Music splits moods/new releases
    /// and Daily/Weekly/Trending charts across two browse feeds, so both start
    /// together and are merged in that stable order.
    func explore() async -> [HomeShelf] {
        await prepareWebSession()
        async let exploreFeed = optionalShelves(for: "FEmusic_explore", excludingVideoContent: true)
        async let chartsFeed = optionalShelves(for: "FEmusic_charts", excludingVideoContent: true)
        let feeds = await [exploreFeed, chartsFeed]
        var seenTitles = Set<String>()
        return feeds.flatMap { $0 }.filter {
            seenTitles.insert($0.title.lowercased()).inserted
        }
    }

    private func optionalShelves(
        for browseID: String,
        excludingVideoContent: Bool = false
    ) async -> [HomeShelf] {
        guard let response = try? await browse(browseID) else { return [] }
        return parseShelves(response, excludingVideoContent: excludingVideoContent)
    }

    func history() async throws -> [Track] {
        try requireAuthenticatedSession()
        await prepareWebSession()
        let response = try await browse("FEmusic_history")
        var seen = Set<String>()
        return collectObjects(response, named: "musicResponsiveListItemRenderer")
            .compactMap(parseTrack)
            .filter { track in
                guard let videoID = track.videoID else { return false }
                return seen.insert(videoID).inserted
            }
    }

    /// The same RDAMVM watch queue used by the Android app. Its first row is
    /// commonly the seed itself; the controller removes anything already in
    /// the queue before appending the recommendations.
    func autoplayTracks(for videoID: String) async throws -> [Track] {
        await prepareWebSession()
        let response = try await post(
            endpoint: "next",
            on: musicBase,
            client: webClient,
            authenticated: cookieHeader != nil,
            body: [
                "videoId": videoID,
                "playlistId": "RDAMVM\(videoID)",
                "isAudioOnly": true
            ]
        )
        let tracks = parseWatchQueue(response)
        guard convertVideoToAudio, tracks.contains(where: \.isMusicVideo) else { return tracks }
        return await withTaskGroup(of: (Int, Track).self) { group in
            for (index, track) in tracks.enumerated() {
                group.addTask { [weak self] in
                    guard let self else { return (index, track) }
                    return (index, await self.resolvePlaybackTrack(for: track))
                }
            }
            var resolved = Array(repeating: tracks[0], count: tracks.count)
            for await (index, track) in group { resolved[index] = track }
            return resolved
        }
    }

    /// Resolves the album and artist destinations for a track whose original
    /// card did not carry credit links. This mirrors Kotlin's `trackLinks`:
    /// the seed row in YouTube Music's own watch queue is authoritative.
    func trackLinks(for videoID: String) async throws -> Track {
        await prepareWebSession()
        let response = try await post(
            endpoint: "next",
            on: musicBase,
            client: webClient,
            authenticated: cookieHeader != nil,
            body: ["videoId": videoID, "isAudioOnly": true]
        )
        guard let track = parseWatchQueue(response).first(where: { $0.videoID == videoID }) else {
            throw YouTubeMusicAPIError.malformedData
        }
        return track
    }

    /// YouTube Music exposes the account library as separate browse feeds.
    /// This mirrors the Android repository instead of treating imported files
    /// as the user's YouTube library.
    func library() async throws -> [HomeShelf] {
        guard cookieHeader != nil else { throw YouTubeMusicAPIError.authenticationRequired }
        await prepareWebSession()

        let feeds: [(String, String)] = [
            ("Playlists", "FEmusic_liked_playlists"),
            ("Albums", "FEmusic_liked_albums"),
            ("Artists", "FEmusic_library_corpus_track_artists"),
            ("Subscriptions", "FEmusic_library_corpus_artists"),
            ("Podcasts", "FEmusic_library_non_music_audio_list")
        ]

        var shelves: [HomeShelf] = []
        var firstError: Error?
        for (title, browseID) in feeds {
            do {
                let response = try await browse(browseID)
                let items = parseLibraryItems(response)
                if !items.isEmpty { shelves.append(HomeShelf(title: title, items: items)) }
            } catch {
                firstError = firstError ?? error
            }
        }

        if shelves.isEmpty, let firstError { throw firstError }
        return shelves
    }

    func tracks(for browseID: String) async throws -> [Track] {
        try await page(for: browseID).tracks
    }

    /// Loads a shared album, playlist or artist URL as one coherent page.
    /// Keeping the header and rows from the same browse response avoids the
    /// blank generic title and duplicate network request that an ID-only link
    /// would otherwise produce in the collection sheet.
    func page(for browseID: String) async throws -> BrowsePage {
        await prepareWebSession()
        let response = try await browse(browseID)
        if browseID.hasPrefix("VL") {
            if !collectObjects(response, named: "musicEditablePlaylistDetailHeaderRenderer").isEmpty {
                editablePlaylistIDs.insert(browseID)
            } else {
                editablePlaylistIDs.remove(browseID)
            }
        }
        let fallback = pageCredits(in: response, browseID: browseID)
        var seen = Set<String>()
        let tracks: [Track] = collectObjects(response, named: "musicResponsiveListItemRenderer").compactMap { renderer in
            guard let track = parseTrack(renderer, fallback: fallback),
                  seen.insert(track.id).inserted else { return nil }
            return track
        }
        let item = parsePageItem(response, browseID: browseID, tracks: tracks)
        return BrowsePage(item: item, tracks: tracks)
    }

    func isEditablePlaylist(_ browseID: String) -> Bool {
        editablePlaylistIDs.contains(browseID)
    }

    func markEditablePlaylist(_ browseID: String) {
        editablePlaylistIDs.insert(browseID.hasPrefix("VL") ? browseID : "VL\(browseID)")
    }

    func userPlaylists() async throws -> [UserPlaylist] {
        try requireAuthenticatedSession()
        await prepareWebSession()
        let response = try await browse("FEmusic_liked_playlists")
        let reservedPrefixes = ["LM", "SE", "RD", "OLAK", "MPRE"]
        return parseLibraryItems(response).compactMap { item in
            guard let browse = item.browseItem, browse.id.hasPrefix("VL") else { return nil }
            let playlistID = String(browse.id.dropFirst(2))
            guard !reservedPrefixes.contains(where: playlistID.hasPrefix) else { return nil }
            return UserPlaylist(
                playlistID: playlistID,
                title: browse.title,
                subtitle: browse.subtitle,
                artworkURL: browse.artworkURL
            )
        }
    }

    func rate(videoID: String, status: LikeStatus) async throws {
        try requireAuthenticatedSession()
        await prepareWebSession()
        let endpoint: String
        switch status {
        case .like: endpoint = "like/like"
        case .dislike: endpoint = "like/dislike"
        case .indifferent: endpoint = "like/removelike"
        }
        let response = try await post(
            endpoint: endpoint,
            on: musicBase,
            client: webClient,
            authenticated: true,
            body: ["target": ["videoId": videoID]]
        )
        try validateWriteResponse(response)
    }

    func createPlaylist(
        title: String,
        privacy: PlaylistPrivacy,
        videoIDs: [String] = []
    ) async throws -> String {
        try requireAuthenticatedSession()
        await prepareWebSession()
        var body: [String: Any] = [
            "title": title,
            "description": "",
            "privacyStatus": privacy.rawValue
        ]
        if !videoIDs.isEmpty { body["videoIds"] = videoIDs }
        let response = try await post(
            endpoint: "playlist/create",
            on: musicBase,
            client: webClient,
            authenticated: true,
            body: body
        )
        try validateWriteResponse(response)
        guard let playlistID = string(response["playlistId"])
                ?? firstValue(forKey: "playlistId", in: response) else {
            throw YouTubeMusicAPIError.accountWriteRefused("The playlist was created, but YouTube did not return its ID.")
        }
        return playlistID
    }

    func addToPlaylist(playlistID: String, videoIDs: [String]) async throws -> [String: String] {
        let actions: [[String: Any]] = videoIDs.map {
            ["action": "ACTION_ADD_VIDEO", "addedVideoId": $0]
        }
        let response = try await editPlaylist(playlistID: playlistID, actions: actions)
        var added: [String: String] = [:]
        for result in collectObjects(response, named: "playlistEditVideoAddedResultData") {
            if let videoID = string(result["videoId"]), let setVideoID = string(result["setVideoId"]) {
                added[videoID] = setVideoID
            }
        }
        return added
    }

    func removeFromPlaylist(playlistID: String, track: Track) async throws {
        guard let videoID = track.videoID, let setVideoID = track.setVideoID else {
            throw YouTubeMusicAPIError.accountWriteRefused("This playlist row does not include the ID needed to remove it.")
        }
        _ = try await editPlaylist(playlistID: playlistID, actions: [[
            "action": "ACTION_REMOVE_VIDEO",
            "setVideoId": setVideoID,
            "removedVideoId": videoID
        ]])
    }

    func renamePlaylist(playlistID: String, title: String) async throws {
        _ = try await editPlaylist(playlistID: playlistID, actions: [[
            "action": "ACTION_SET_PLAYLIST_NAME",
            "playlistName": title
        ]])
    }

    func deletePlaylist(playlistID: String) async throws {
        try requireAuthenticatedSession()
        await prepareWebSession()
        let response = try await post(
            endpoint: "playlist/delete",
            on: musicBase,
            client: webClient,
            authenticated: true,
            body: ["playlistId": normalizedPlaylistID(playlistID)]
        )
        try validateWriteResponse(response)
    }

    private func editPlaylist(playlistID: String, actions: [[String: Any]]) async throws -> [String: Any] {
        try requireAuthenticatedSession()
        await prepareWebSession()
        let response = try await post(
            endpoint: "browse/edit_playlist",
            on: musicBase,
            client: webClient,
            authenticated: true,
            body: ["playlistId": normalizedPlaylistID(playlistID), "actions": actions]
        )
        try validateWriteResponse(response, requiresSucceededStatus: true)
        return response
    }

    private func requireAuthenticatedSession() throws {
        guard cookieHeader != nil else { throw YouTubeMusicAPIError.authenticationRequired }
    }

    private func normalizedPlaylistID(_ value: String) -> String {
        value.hasPrefix("VL") ? String(value.dropFirst(2)) : value
    }

    private func validateWriteResponse(
        _ response: [String: Any],
        requiresSucceededStatus: Bool = false
    ) throws {
        if let error = dictionary(response["error"]) {
            let message = string(error["message"]) ?? "YouTube Music refused the change."
            throw YouTubeMusicAPIError.accountWriteRefused(message)
        }
        if requiresSucceededStatus, let status = string(response["status"]), status != "STATUS_SUCCEEDED" {
            throw YouTubeMusicAPIError.accountWriteRefused("YouTube Music refused the playlist edit (\(status)).")
        }
    }

    /// Requests the same playback tracking block used by the web player. The
    /// signature timestamp proves that the request matches YouTube's current
    /// player revision; without it the endpoint answers 200 but omits the
    /// tracking URLs, which silently loses the account history entry.
    func playbackTracking(for videoID: String) async throws -> PlaybackTrackingURLs? {
        try requireAuthenticatedSession()
        await prepareWebSession()
        let signatureTimestamp = try await currentSignatureTimestamp(for: videoID)
        let response = try await post(
            endpoint: "player",
            on: musicBase,
            client: webClient,
            authenticated: true,
            body: [
                "videoId": videoID,
                "contentCheckOk": true,
                "racyCheckOk": true,
                "playbackContext": [
                    "contentPlaybackContext": [
                        "html5Preference": "HTML5_PREF_WANTS",
                        "referer": "https://music.youtube.com/watch?v=\(videoID)",
                        "signatureTimestamp": signatureTimestamp
                    ]
                ]
            ]
        )
        guard let tracking = dictionary(response["playbackTracking"]),
              let playbackURL = trackingURL(named: "videostatsPlaybackUrl", in: tracking) else {
            return nil
        }
        let atr = dictionary(tracking["atrUrl"])
        return PlaybackTrackingURLs(
            playbackURL: playbackURL,
            watchtimeURL: trackingURL(named: "videostatsWatchtimeUrl", in: tracking),
            atrURL: trackingURL(named: "atrUrl", in: tracking),
            atrAfterSeconds: number(atr?["elapsedMediaTimeSeconds"]) > 0
                ? number(atr?["elapsedMediaTimeSeconds"])
                : 5
        )
    }

    func pingPlayback(_ baseURL: String, cpn: String) async throws {
        try await pingStats(baseURL, cpn: cpn, extras: [])
    }

    func pingATR(_ baseURL: String, cpn: String) async throws {
        try await pingStats(baseURL, cpn: cpn, extras: [], includeClientShape: false)
    }

    func pingWatchtime(_ baseURL: String, cpn: String, seconds: Int, final: Bool) async throws {
        var extras = [
            URLQueryItem(name: "st", value: "0"),
            URLQueryItem(name: "et", value: String(max(0, seconds))),
            URLQueryItem(name: "cmt", value: String(max(0, seconds))),
            URLQueryItem(name: "state", value: final ? "paused" : "playing")
        ]
        if final { extras.append(URLQueryItem(name: "final", value: "1")) }
        try await pingStats(baseURL, cpn: cpn, extras: extras)
    }

    private func trackingURL(named key: String, in tracking: [String: Any]) -> String? {
        string(dictionary(tracking[key])?["baseUrl"])
    }

    private func currentSignatureTimestamp(for videoID: String) async throws -> Int {
        let player = try await playerJavaScript(for: videoID)
        guard let timestamp = player.signatureTimestamp else {
            throw YouTubeMusicAPIError.malformedData
        }
        return timestamp
    }

    private func playerJavaScript(
        for videoID: String,
        hintedPath: String? = nil
    ) async throws -> YouTubePlayerJavaScript {
        if let cachedPlayerJavaScript { return cachedPlayerJavaScript }

        let playerURL: URL
        if let hintedPath,
           let hintedURL = URL(
               string: hintedPath.replacingOccurrences(of: #"\/"#, with: "/"),
               relativeTo: URL(string: "https://www.youtube.com")
           )?.absoluteURL {
            playerURL = hintedURL
        } else {
            guard var watch = URLComponents(string: "https://www.youtube.com/watch") else {
                throw YouTubeMusicAPIError.invalidResponse
            }
            watch.queryItems = [URLQueryItem(name: "v", value: videoID)]
            guard let watchURL = watch.url else { throw YouTubeMusicAPIError.invalidResponse }

            var watchRequest = URLRequest(url: watchURL)
            watchRequest.setValue(webClient.userAgent, forHTTPHeaderField: "User-Agent")
            watchRequest.timeoutInterval = 15
            let (watchData, watchResponse) = try await session.data(for: watchRequest)
            guard let watchHTTP = watchResponse as? HTTPURLResponse,
                  (200..<300).contains(watchHTTP.statusCode),
                  var html = String(data: watchData, encoding: .utf8) else {
                throw YouTubeMusicAPIError.invalidResponse
            }
            html = html.replacingOccurrences(of: #"\/"#, with: "/")
            guard let playerPath = capture(#"(/s/player/[^\"']+/base\.js)"#, in: html),
                  let resolvedURL = URL(
                      string: playerPath,
                      relativeTo: URL(string: "https://www.youtube.com")
                  )?.absoluteURL else {
                throw YouTubeMusicAPIError.malformedData
            }
            playerURL = resolvedURL
        }

        var playerRequest = URLRequest(url: playerURL)
        playerRequest.setValue(webClient.userAgent, forHTTPHeaderField: "User-Agent")
        playerRequest.timeoutInterval = 15
        let (playerData, playerResponse) = try await session.data(for: playerRequest)
        guard let playerHTTP = playerResponse as? HTTPURLResponse,
              (200..<300).contains(playerHTTP.statusCode),
              let javascript = String(data: playerData, encoding: .utf8) else {
            throw YouTubeMusicAPIError.invalidResponse
        }
        let timestamp = capture(#"(?:signatureTimestamp|sts)\s*[:=]\s*(\d{5,})"#, in: javascript)
            .flatMap(Int.init)
        let player = YouTubePlayerJavaScript(
            url: playerURL,
            source: javascript,
            signatureTimestamp: timestamp
        )
        cachedPlayerJavaScript = player
        return player
    }

    private func pingStats(
        _ baseURL: String,
        cpn: String,
        extras: [URLQueryItem],
        includeClientShape: Bool = true
    ) async throws {
        try requireAuthenticatedSession()
        await prepareWebSession()
        guard var components = URLComponents(string: baseURL) else {
            throw YouTubeMusicAPIError.invalidResponse
        }
        var items = components.queryItems ?? []
        if includeClientShape {
            items += [
                URLQueryItem(name: "ver", value: "2"),
                URLQueryItem(name: "c", value: "WEB_REMIX"),
                URLQueryItem(name: "cver", value: sessionScope?.clientVersion ?? webClient.version),
                URLQueryItem(name: "cplayer", value: "UNIPLAYER"),
                URLQueryItem(name: "cbr", value: "Chrome"),
                URLQueryItem(name: "cbrver", value: "141.0.0.0"),
                URLQueryItem(name: "cos", value: "Macintosh"),
                URLQueryItem(name: "cosver", value: "10_15_7"),
                URLQueryItem(name: "hl", value: "en_US"),
                URLQueryItem(name: "cr", value: "US")
            ]
        }
        items.append(URLQueryItem(name: "cpn", value: cpn))
        items += extras
        components.queryItems = items
        guard let url = components.url else { throw YouTubeMusicAPIError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "X-Origin")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(webClient.userAgent, forHTTPHeaderField: "User-Agent")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if let cookieHeader {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue(sessionScope?.authUser ?? "0", forHTTPHeaderField: "X-Goog-AuthUser")
            if let pageID = sessionScope?.pageID { request.setValue(pageID, forHTTPHeaderField: "X-Goog-PageId") }
            request.setValue(
                sapisidHash(for: cookieHeader, origin: "https://music.youtube.com"),
                forHTTPHeaderField: "Authorization"
            )
        }
        request.timeoutInterval = 15
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw YouTubeMusicAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw YouTubeMusicAPIError.httpStatus(http.statusCode) }
    }

    private func browse(_ browseID: String) async throws -> [String: Any] {
        try await post(
            endpoint: "browse",
            on: musicBase,
            client: webClient,
            authenticated: cookieHeader != nil,
            body: ["browseId": browseID]
        )
    }

    /// Mirrors the Android resolver: keep a short-lived proven URL cache, walk
    /// device clients first, then use yt-dlp's player-JS implementation. A
    /// cached full-file fallback wins before any network work, which makes a
    /// repeated play and a preloaded queue handoff immediate.
    func resolveStream(for track: Track) async throws -> ResolvedStream {
        guard let videoID = track.videoID else { throw YouTubeMusicAPIError.noPlayableStream }
        let quality = playbackQuality
        let key = StreamCacheKey(videoID: videoID, quality: quality.rawValue)

        if let localURL = await audioCache.cachedURL(videoID: videoID, quality: quality) {
            return ResolvedStream(
                url: localURL,
                headers: [:],
                videoID: videoID,
                duration: track.duration
            )
        }
        if let localURL = cachedPlaybackFallbackURL(videoID: videoID, quality: quality) {
            _ = await audioCache.registerCompletedFile(localURL)
            return ResolvedStream(
                url: localURL,
                headers: [:],
                videoID: videoID,
                duration: track.duration
            )
        }
        if let stream = cachedStream(for: key) { return stream }

        let stream = try await resolveStreamUncached(videoID: videoID, quality: quality)
        remember(stream, for: key)
        return stream
    }

    func cacheResolvedStream(_ stream: ResolvedStream) async {
        do {
            try await audioCache.store(stream, quality: playbackQuality)
        } catch is CancellationError {
            return
        } catch {
            streamLogger.debug("Could not cache playback stream: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setAudioCacheLimit(_ bytes: Int64) async -> AudioStreamCache.Snapshot {
        playbackCacheLimitBytes = min(
            max(bytes, AudioStreamCache.defaultLimitBytes),
            AudioStreamCache.maximumLimitBytes
        )
        return await audioCache.updateLimit(playbackCacheLimitBytes)
    }

    func clearAudioCache() async -> AudioStreamCache.Snapshot {
        await audioCache.clear()
    }

    func audioCacheSnapshot() async -> AudioStreamCache.Snapshot {
        await audioCache.snapshot()
    }

    func invalidateResolvedStream(for track: Track) {
        guard let videoID = track.videoID else { return }
        recentStreams = recentStreams.filter { $0.key.videoID != videoID }
    }

    private func cachedStream(for key: StreamCacheKey, now: Date = Date()) -> ResolvedStream? {
        guard let cached = recentStreams[key],
              now.timeIntervalSince(cached.storedAt) < Self.streamCacheTTL else {
            recentStreams.removeValue(forKey: key)
            return nil
        }
        if let expiration = URLComponents(url: cached.stream.url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "expire" })?
            .value
            .flatMap(TimeInterval.init),
           expiration - now.timeIntervalSince1970 < 60 {
            recentStreams.removeValue(forKey: key)
            return nil
        }
        return cached.stream
    }

    private func remember(_ stream: ResolvedStream, for key: StreamCacheKey) {
        let cutoff = Date().addingTimeInterval(-Self.streamCacheTTL)
        recentStreams = recentStreams.filter { $0.value.storedAt >= cutoff }
        if recentStreams.count >= Self.maximumRememberedStreams {
            recentStreams.removeValue(forKey: recentStreams.min(by: {
                $0.value.storedAt < $1.value.storedAt
            })?.key ?? key)
        }
        recentStreams[key] = CachedStream(stream: stream, storedAt: Date())
    }

    private func resolveStreamUncached(
        videoID: String,
        quality: AudioQuality
    ) async throws -> ResolvedStream {
        await prepareWebSession()

        // Match the Kotlin hot path: ask the lightweight device player endpoint
        // first and keep the last successful client at the head of the next
        // walk. Race that walk against the extractor fallbacks so a working
        // unciphered URL can start immediately while WEB_EMBEDDED remains the
        // reliable answer for networks that reject every device client.
        let authenticatedCookie = cookieHeader
        let activeDataSyncID = sessionScope?.dataSyncID
        let preferredKey = preferredStreamClientKey
        let hasExtractor = ytdlpExecutablePath() != nil
        var candidates: [@Sendable () async -> ResolvedStream?] = []

        // The two-range probe below is deliberately stronger than the tiny
        // read that produced earlier AVPlayer false positives: a candidate is
        // accepted only after both its opening bytes and a useful 64 KiB range
        // well into the media have arrived. That makes the direct Kotlin route
        // safe to keep enabled even when yt-dlp is installed.
        let directClients = orderedStreamClients(preferredKey: preferredKey)
        candidates.append { [weak self] in
            guard let self else { return nil }
            let startedAt = Date()
            for client in directClients {
                guard !Task.isCancelled else { return nil }
                if let stream = await self.resolveClientStreamCandidate(
                    videoID: videoID,
                    quality: quality,
                    client: client,
                    authenticated: authenticatedCookie != nil
                ) {
                    let elapsed = Date().timeIntervalSince(startedAt)
                    self.streamLogger.info("Direct device walk selected \(client.name, privacy: .public) in \(elapsed, format: .fixed(precision: 2), privacy: .public)s")
                    return stream
                }
            }
            return nil
        }
        if let authenticatedCookie {
            let authenticatedClient = authenticatedStreamClient
            candidates.append { [weak self] in
                guard let self, !Task.isCancelled else { return nil }
                let startedAt = Date()
                guard let stream = try? await self.resolve(
                    videoID: videoID,
                    client: authenticatedClient,
                    authenticated: true,
                    quality: quality,
                    unlockCipher: true
                ) else { return nil }
                let elapsed = Date().timeIntervalSince(startedAt)
                self.streamLogger.info("Authenticated direct TV stream selected in \(elapsed, format: .fixed(precision: 2), privacy: .public)s")
                return stream
            }
            for extractorClient in Self.authenticatedExtractorClients {
                candidates.append { [weak self] in
                    guard let self, !Task.isCancelled else { return nil }
                    return await self.resolveYTDLPStreamCandidate(
                        videoID: videoID,
                        cookieHeader: authenticatedCookie,
                        quality: quality,
                        extractorClient: extractorClient,
                        dataSyncID: activeDataSyncID
                    )
                }
            }
            if !hasExtractor {
                candidates.append { [weak self] in
                    guard let self, !Task.isCancelled else { return nil }
                    return try? await self.resolve(
                        videoID: videoID,
                        client: self.webClient,
                        authenticated: true,
                        quality: quality,
                        unlockCipher: true
                    )
                }
            }
        }

        if let stream = await Self.firstSuccessful(candidates) { return stream }

        throw YouTubeMusicAPIError.noPlayableStream
    }

    private func orderedStreamClients(preferredKey: String?) -> [PlayerClient] {
        let orderedKeys = Self.preferredFirst(
            streamClients.map(\.key),
            preferred: preferredKey
        )
        let clientsByKey = Dictionary(uniqueKeysWithValues: streamClients.map { ($0.key, $0) })
        return orderedKeys.compactMap { clientsByKey[$0] }
    }

    nonisolated static func preferredFirst(_ keys: [String], preferred: String?) -> [String] {
        guard let preferred, keys.contains(preferred) else { return keys }
        return [preferred] + keys.filter { $0 != preferred }
    }

    /// The authenticated TV client avoids the pre-roll advertising gate
    /// attached to WEB_EMBEDDED; the latter remains last as the most reliable
    /// fallback.
    nonisolated static let authenticatedDirectClientVersion = "5.20260114"

    nonisolated static let authenticatedExtractorClients = [
        "tv_downgraded",
        "web_embedded"
    ]

    private func resolveClientStreamCandidate(
        videoID: String,
        quality: AudioQuality,
        client: PlayerClient,
        authenticated: Bool
    ) async -> ResolvedStream? {
        guard !Task.isCancelled else { return nil }
        if let stream = try? await resolve(
            videoID: videoID,
            client: client,
            authenticated: false,
            quality: quality
        ) {
            preferredStreamClientKey = client.key
            return stream
        }
        guard authenticated, !Task.isCancelled else { return nil }
        if let stream = try? await resolve(
            videoID: videoID,
            client: client,
            authenticated: true,
            quality: quality
        ) {
            preferredStreamClientKey = client.key
            return stream
        }
        return nil
    }

    private func resolveYTDLPStreamCandidate(
        videoID: String,
        cookieHeader: String,
        quality: AudioQuality,
        extractorClient: String,
        dataSyncID: String?
    ) async -> ResolvedStream? {
        let startedAt = Date()
        guard !Task.isCancelled,
              let stream = try? await resolveWithYTDLP(
                  videoID: videoID,
                  cookieHeader: cookieHeader,
                  quality: quality,
                  extractorClient: extractorClient,
                  dataSyncID: dataSyncID
              ),
              !Task.isCancelled,
              await probe(stream) else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        streamLogger.debug("yt-dlp media \(Self.safeStreamMetadata(stream), privacy: .public)")
        streamLogger.info("Selected yt-dlp \(extractorClient, privacy: .public) stream at \(stream.info?.bitrateKbps ?? 0, privacy: .public) kbps in \(elapsed, format: .fixed(precision: 2), privacy: .public)s")
        return stream
    }

    nonisolated static func firstSuccessful<Value: Sendable>(
        _ candidates: [@Sendable () async -> Value?]
    ) async -> Value? {
        await withTaskGroup(of: Value?.self, returning: Value?.self) { group in
            for candidate in candidates { group.addTask(operation: candidate) }
            while let result = await group.next() {
                guard let result else { continue }
                group.cancelAll()
                return result
            }
            return nil
        }
    }

    func downloadPlaybackFallback(for track: Track) async throws -> URL {
        guard let videoID = track.videoID else { throw YouTubeMusicAPIError.noPlayableStream }
        await prepareWebSession()
        return try await downloadWithYTDLP(
            videoID: videoID,
            cookieHeader: cookieHeader ?? "",
            quality: playbackQuality,
            dataSyncID: sessionScope?.dataSyncID
        )
    }

    nonisolated static func playbackFallbackAttempts(hasCookies: Bool) -> [PlaybackFallbackAttempt] {
        let clients = ["tv_downgraded", "web_embedded"]
        if hasCookies {
            return clients.map { PlaybackFallbackAttempt(extractorClient: $0, includesCookies: true) }
                + clients.map { PlaybackFallbackAttempt(extractorClient: $0, includesCookies: false) }
        }
        return clients.map { PlaybackFallbackAttempt(extractorClient: $0, includesCookies: false) }
    }

    private func cachedPlaybackFallbackURL(
        videoID: String,
        quality: AudioQuality
    ) -> URL? {
        let url = playbackFallbackURL(videoID: videoID, quality: quality)
        return Self.fileHasData(url) ? url : nil
    }

    private func playbackFallbackURL(
        videoID: String,
        quality: AudioQuality
    ) -> URL {
        let safeVideoID = videoID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return playbackStreamCacheDirectory()
            .appendingPathComponent("fallback-\(safeVideoID)-\(quality.rawValue)")
            .appendingPathExtension("m4a")
    }

    private func playbackStreamCacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitChord/Streams", isDirectory: true)
    }

    func downloadTrack(
        _ track: Track,
        quality: DownloadQuality,
        to directory: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        await prepareWebSession()
        guard let videoID = track.videoID,
              let executablePath = ytdlpExecutablePath() else {
            throw YouTubeMusicAPIError.noPlayableStream
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileStem = downloadFileStem(for: track, videoID: videoID)
        let outputBase = directory.appendingPathComponent(fileStem)
        let destination = outputBase.appendingPathExtension("m4a")
        if Self.fileHasData(destination) {
            progress(1)
            return destination
        }
        Self.cleanupDownloadArtifacts(outputBase: outputBase)

        let processBox = DownloadProcessBox()
        let cookieHeader = cookieHeader ?? ""
        let dataSyncID = sessionScope?.dataSyncID
        let ffmpegPath = ffmpegExecutablePath()
        let denoPath = denoExecutablePath()
        let worker = Task.detached(priority: .utility) {
            let cookieFile = try Self.makeTemporaryCookieFileIfNeeded(cookieHeader: cookieHeader)
            defer {
                if let cookieFile { try? FileManager.default.removeItem(at: cookieFile) }
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            let formatSelector = quality == .standard
                ? "bestaudio[abr<=132]/bestaudio"
                : "bestaudio"
            let audioQuality = quality == .standard ? "128K" : "0"
            var arguments = [
                "--no-warnings",
                "--no-playlist",
                "--newline",
                "--no-colors",
                "--socket-timeout", "20",
                "--retries", "3",
                "--fragment-retries", "3",
                "--extractor-args", Self.ytdlpExtractorArguments(
                    for: "web_embedded",
                    dataSyncID: dataSyncID
                ),
                "--format", formatSelector,
                "--extract-audio",
                "--audio-format", "m4a",
                "--audio-quality", audioQuality,
                "--embed-metadata",
                "--progress-template", "download:%(progress._percent_str)s",
                "--output", outputBase.path + ".%(ext)s"
            ]
            arguments += Self.ytdlpCookieArguments(cookieFile: cookieFile)
            arguments += Self.ytdlpRuntimeArguments(denoPath: denoPath)
            if let ffmpegPath {
                arguments += ["--ffmpeg-location", ffmpegPath]
            }
            arguments.append("https://music.youtube.com/watch?v=\(videoID)")
            process.arguments = arguments

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            guard processBox.install(process) else { throw CancellationError() }

            do {
                try process.run()
            } catch {
                processBox.clear()
                throw error
            }

            var lineBuffer = ""
            while true {
                let data = outputPipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                lineBuffer += String(decoding: data, as: UTF8.self)
                let lines = lineBuffer.split(separator: "\n", omittingEmptySubsequences: false)
                lineBuffer = String(lines.last ?? "")
                for line in lines.dropLast() {
                    if let value = Self.parseDownloadProgress(String(line)) {
                        await progress(value)
                    }
                }
            }
            if let value = Self.parseDownloadProgress(lineBuffer) {
                await progress(value)
            }

            process.waitUntilExit()
            processBox.clear()
            try Task.checkCancellation()
            guard process.terminationStatus == 0, Self.fileHasData(destination) else {
                throw YouTubeMusicAPIError.noPlayableStream
            }
            return destination
        }

        return try await withTaskCancellationHandler {
            do {
                let fileURL = try await worker.value
                try Task.checkCancellation()
                progress(1)
                return fileURL
            } catch {
                processBox.cancel()
                worker.cancel()
                Self.cleanupDownloadArtifacts(outputBase: outputBase)
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            processBox.cancel()
            worker.cancel()
        }
    }

    private func downloadFileStem(for track: Track, videoID: String) -> String {
        let raw = "\(track.artist) - \(track.title) [\(videoID)]"
        let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|")
            .union(.controlCharacters)
        let sanitized = raw.components(separatedBy: illegal).joined(separator: " ")
        let collapsed = sanitized
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        return String(collapsed.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func parseDownloadProgress(_ line: String) -> Double? {
        guard let marker = line.range(of: "download:") else { return nil }
        let raw = line[marker.upperBound...]
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let percent = Double(raw) else { return nil }
        return min(max(percent / 100 * 0.94, 0), 0.94)
    }

    private nonisolated static func fileHasData(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value > 0
    }

    private nonisolated static func cleanupDownloadArtifacts(outputBase: URL) {
        let directory = outputBase.deletingLastPathComponent()
        let prefix = outputBase.lastPathComponent + "."
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in urls where url.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func resolveWithYTDLP(
        videoID: String,
        cookieHeader: String,
        quality: AudioQuality,
        extractorClient: String,
        dataSyncID: String?
    ) async throws -> ResolvedStream {
        guard let executablePath = ytdlpExecutablePath() else {
            throw YouTubeMusicAPIError.noPlayableStream
        }

        let formatSelector = playbackFormatSelector(for: quality)
        let extractorClients = Self.ytdlpExtractorArguments(
            for: extractorClient,
            dataSyncID: dataSyncID
        )
        let denoPath = denoExecutablePath()
        let processBox = DownloadProcessBox()
        let worker = Task.detached(priority: .userInitiated) {
            let cookieFile = try Self.makeTemporaryCookieFile(cookieHeader: cookieHeader)
            defer { try? FileManager.default.removeItem(at: cookieFile) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            var arguments = [
                "--quiet",
                "--no-warnings",
                "--no-playlist",
                "--skip-download",
                "--socket-timeout", "15",
                "--retries", "1",
                "--cookies", cookieFile.path,
                "--extractor-args", extractorClients,
                "--format", formatSelector,
                "--print", "{\"url\": %(url)j, \"headers\": %(http_headers)j, \"availableAt\": \"%(available_at)s\", \"abr\": %(abr)j, \"tbr\": %(tbr)j, \"acodec\": %(acodec)j, \"asr\": %(asr)j, \"audio_channels\": %(audio_channels)j}",
            ]
            arguments += Self.ytdlpRuntimeArguments(denoPath: denoPath)
            arguments.append("https://music.youtube.com/watch?v=\(videoID)")
            process.arguments = arguments

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            guard processBox.install(process) else { throw CancellationError() }
            do {
                try process.run()
            } catch {
                processBox.clear()
                throw error
            }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            processBox.clear()
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                throw YouTubeMusicAPIError.noPlayableStream
            }
            return try Self.parseYTDLPStream(
                data,
                videoID: videoID,
                cookieHeader: cookieHeader,
                quality: quality
            )
        }

        let parsed = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            processBox.cancel()
            worker.cancel()
        }

        try Task.checkCancellation()
        let delay = Self.streamReadinessDelay(availableAt: parsed.availableAt)
        if delay > 0 {
            streamLogger.info("Waiting \(delay, format: .fixed(precision: 2), privacy: .public)s for YouTube's media gate")
            try await Task.sleep(for: .seconds(delay))
        }
        try Task.checkCancellation()
        return parsed.stream
    }

    nonisolated static func ytdlpExtractorArguments(
        for client: String,
        dataSyncID: String? = nil
    ) -> String {
        var options = ["player_client=\(client)"]
        if client == "tv_downgraded" {
            options.append("player_skip=webpage,configs")
        }
        if let rawDataSyncID = dataSyncID,
           let dataSyncID = sanitizedYTDLPDataSyncID(rawDataSyncID) {
            options.append("data_sync_id=\(dataSyncID)")
        }
        return "youtube:\(options.joined(separator: ";"))"
    }

    private nonisolated static func sanitizedYTDLPDataSyncID(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.contains(";"),
              !value.contains("\n"),
              !value.contains("\r") else { return nil }
        return value
    }

    nonisolated static func ytdlpRuntimeArguments(denoPath: String?) -> [String] {
        guard let denoPath, !denoPath.isEmpty else { return [] }
        return ["--js-runtimes", "deno:\(denoPath)"]
    }

    nonisolated static func netscapeCookieFile(cookieHeader: String) -> Data? {
        let entries = cookieHeader.split(separator: ";").compactMap { raw -> String? in
            let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty,
                  !name.contains(where: { $0.isWhitespace || $0.isNewline }),
                  !value.contains(where: { $0 == "\t" || $0.isNewline }) else { return nil }
            return ".youtube.com\tTRUE\t/\tTRUE\t0\t\(name)\t\(value)"
        }
        guard !entries.isEmpty else { return nil }
        return Data((["# Netscape HTTP Cookie File"] + entries + [""]).joined(separator: "\n").utf8)
    }

    private nonisolated static func makeTemporaryCookieFile(cookieHeader: String) throws -> URL {
        guard let data = netscapeCookieFile(cookieHeader: cookieHeader) else {
            throw YouTubeMusicAPIError.authenticationRequired
        }
        let processID = ProcessInfo.processInfo.processIdentifier
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChord-\(processID)-\(UUID().uuidString)")
            .appendingPathExtension("cookies")
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw YouTubeMusicAPIError.noPlayableStream
        }
        return url
    }

    /// A normal task cancellation runs each worker's `defer`, but an app
    /// termination cannot. Process-scoped names let the next launch safely
    /// remove cookie jars whose owning BitChord process no longer exists.
    private nonisolated static func cleanupStaleTemporaryCookieFiles() {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let now = Date()
        for file in files where file.lastPathComponent.hasPrefix("BitChord-")
            && file.pathExtension == "cookies" {
            let values = try? file.resourceValues(forKeys: keys)
            let age = values?.contentModificationDate.map { now.timeIntervalSince($0) }
                ?? .greatestFiniteMagnitude
            let stem = file.deletingPathExtension().lastPathComponent
            let parts = stem.split(separator: "-", maxSplits: 2)

            if parts.count == 3, let owner = Int32(parts[1]) {
                guard owner != currentProcessID else { continue }
                if age < 24 * 60 * 60, processIsRunning(owner) { continue }
                try? fileManager.removeItem(at: file)
            } else if age >= 60 {
                // Legacy files predate process-scoped names. Give an active
                // extractor one minute, then treat the file as orphaned.
                try? fileManager.removeItem(at: file)
            }
        }
    }

    private nonisolated static func processIsRunning(_ processID: Int32) -> Bool {
        errno = 0
        return Darwin.kill(processID, 0) == 0 || errno == EPERM
    }

    private nonisolated static func makeTemporaryCookieFileIfNeeded(
        cookieHeader: String
    ) throws -> URL? {
        guard !cookieHeader.isEmpty else { return nil }
        return try makeTemporaryCookieFile(cookieHeader: cookieHeader)
    }

    nonisolated static func ytdlpCookieArguments(cookieFile: URL?) -> [String] {
        guard let cookieFile else { return [] }
        return ["--cookies", cookieFile.path]
    }

    nonisolated static func parseYTDLPStream(
        _ data: Data,
        videoID: String,
        cookieHeader: String,
        quality: AudioQuality
    ) throws -> ParsedYTDLPStream {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawURL = object["url"] as? String,
              let url = URL(string: rawURL) else {
            throw YouTubeMusicAPIError.noPlayableStream
        }
        let rawHeaders = object["headers"] as? [String: Any] ?? [:]
        var headers = rawHeaders.reduce(into: [String: String]()) { result, entry in
            if let value = entry.value as? String { result[entry.key] = value }
        }
        // yt-dlp deliberately omits an explicitly supplied Cookie header from
        // `http_headers`, even though its downloader sends that header to the
        // selected media URL. The local proxy must reproduce the same request.
        if !cookieHeader.isEmpty { headers["Cookie"] = cookieHeader }

        let bitrate = (object["abr"] as? NSNumber)?.doubleValue
            ?? (object["tbr"] as? NSNumber)?.doubleValue
        let info = AudioStreamInfo(
            requestedQuality: quality,
            bitrateKbps: bitrate.map { Int($0.rounded()) },
            codec: codecName(object["acodec"] as? String),
            sampleRate: (object["asr"] as? NSNumber)?.intValue,
            channels: (object["audio_channels"] as? NSNumber)?.intValue,
            sourceName: "YouTube Music"
        )
        let availableAt = (object["availableAt"] as? String)
            .flatMap(TimeInterval.init)
        let duration = (object["duration"] as? NSNumber)?.doubleValue
        return ParsedYTDLPStream(
            stream: ResolvedStream(
                url: url,
                headers: headers,
                videoID: videoID,
                info: info,
                duration: duration
            ),
            availableAt: availableAt
        )
    }

    nonisolated static func streamReadinessDelay(
        availableAt: TimeInterval?,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> TimeInterval {
        guard let availableAt else { return 0 }
        // A small margin absorbs whole-second timestamps and clock skew. The
        // upper bound prevents malformed extractor data from hanging playback.
        return min(max(availableAt - now + 0.35, 0), 12)
    }

    private func playbackFormatSelector(for quality: AudioQuality) -> String {
        switch quality {
        case .low:
            "bestaudio[ext=m4a][abr<=64]/bestaudio[acodec^=mp4a][abr<=64]/worstaudio[ext=m4a]/worstaudio[acodec^=mp4a]"
        case .medium:
            "bestaudio[ext=m4a][abr<=132]/bestaudio[acodec^=mp4a][abr<=132]/worstaudio[ext=m4a]/worstaudio[acodec^=mp4a]"
        case .high:
            "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]"
        }
    }

    private nonisolated static func codecName(_ rawValue: String?) -> String? {
        guard let rawValue, !rawValue.isEmpty, rawValue != "none" else { return nil }
        if rawValue.hasPrefix("mp4a") { return "AAC" }
        if rawValue.lowercased().contains("opus") { return "Opus" }
        return rawValue.uppercased()
    }

    nonisolated static func playbackHelperExecutablePath(
        bundledRelativePath: String,
        bundleURL: URL?,
        externalCandidates: [String],
        fileManager: FileManager = .default
    ) -> String? {
        var candidates: [String] = []
        if let bundleURL {
            candidates.append(
                bundleURL.appendingPathComponent(bundledRelativePath).path
            )
        }
        candidates += externalCandidates
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) })
    }

    private func ytdlpExecutablePath() -> String? {
        Self.playbackHelperExecutablePath(
            bundledRelativePath: "Contents/Resources/PlaybackHelpers/yt-dlp/yt-dlp",
            bundleURL: Bundle.main.bundleURL,
            externalCandidates: ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]
        )
    }

    private func ffmpegExecutablePath() -> String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private func ytdlpPythonPath() -> String? {
        [
            "/opt/homebrew/opt/yt-dlp/libexec/bin/python",
            "/usr/local/opt/yt-dlp/libexec/bin/python"
        ].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private func denoExecutablePath() -> String? {
        Self.playbackHelperExecutablePath(
            bundledRelativePath: "Contents/Resources/PlaybackHelpers/deno",
            bundleURL: Bundle.main.bundleURL,
            externalCandidates: ["/opt/homebrew/bin/deno", "/usr/local/bin/deno"]
        )
    }

    nonisolated static func parseSignatureCipher(_ rawValue: String) -> YouTubeSignatureCipher? {
        guard let components = URLComponents(string: "https://cipher.invalid/?\(rawValue)") else {
            return nil
        }
        let values = Dictionary(
            components.queryItems?.compactMap { item in
                item.value.map { (item.name, $0) }
            } ?? [],
            uniquingKeysWith: { _, last in last }
        )
        guard let rawURL = values["url"],
              let url = URL(string: rawURL),
              let signature = values["s"],
              !signature.isEmpty else { return nil }
        return YouTubeSignatureCipher(
            url: url,
            encryptedSignature: signature,
            signatureParameter: values["sp"].flatMap { $0.isEmpty ? nil : $0 } ?? "signature"
        )
    }

    nonisolated static func unlockedCipherURL(
        _ cipher: YouTubeSignatureCipher,
        solvedSignature: String,
        solvedN: String?,
        clientVersion: String
    ) -> URL? {
        guard !solvedSignature.isEmpty,
              var components = URLComponents(url: cipher.url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var queryItems = components.queryItems ?? []
        if let solvedN, !solvedN.isEmpty,
           let index = queryItems.firstIndex(where: { $0.name == "n" }) {
            queryItems[index] = URLQueryItem(name: "n", value: solvedN)
        }
        for index in queryItems.indices where queryItems[index].name == "cver" {
            queryItems[index] = URLQueryItem(name: "cver", value: clientVersion)
        }
        queryItems.removeAll { $0.name == cipher.signatureParameter }
        queryItems.append(URLQueryItem(name: cipher.signatureParameter, value: solvedSignature))
        components.queryItems = queryItems
        return components.url
    }

    nonisolated static func resolvedMediaHeaders(
        _ base: [String: String],
        cookieHeader: String?,
        authenticated: Bool
    ) -> [String: String] {
        guard authenticated, let cookieHeader, !cookieHeader.isEmpty else { return base }
        var headers = base
        headers["Cookie"] = cookieHeader
        return headers
    }

    private func unlockSignatureCipher(
        _ rawValue: String,
        videoID: String,
        clientVersion: String,
        hintedPlayerPath: String?
    ) async -> URL? {
        guard let cipher = Self.parseSignatureCipher(rawValue),
              let pythonPath = ytdlpPythonPath(),
              let denoPath = denoExecutablePath(),
              let player = try? await playerJavaScript(
                  for: videoID,
                  hintedPath: hintedPlayerPath
              ) else { return nil }

        let nChallenge = URLComponents(url: cipher.url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "n" })?
            .value
        let startedAt = Date()
        guard let solution = try? await Self.solveYouTubeChallenges(
            pythonPath: pythonPath,
            denoPath: denoPath,
            videoID: videoID,
            player: player,
            signature: cipher.encryptedSignature,
            n: nChallenge
        ),
        let signature = solution.signature,
        let url = Self.unlockedCipherURL(
            cipher,
            solvedSignature: signature,
            solvedN: solution.n,
            clientVersion: clientVersion
        ) else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        streamLogger.info("Unlocked YouTube player challenge in \(elapsed, format: .fixed(precision: 2), privacy: .public)s")
        return url
    }

    private nonisolated static func solveYouTubeChallenges(
        pythonPath: String,
        denoPath: String,
        videoID: String,
        player: YouTubePlayerJavaScript,
        signature: String,
        n: String?
    ) async throws -> YouTubeChallengeSolution {
        var payload: [String: Any] = [
            "video_id": videoID,
            "player_url": player.url.absoluteString,
            "player": player.source,
            "signature": signature,
            "deno": denoPath
        ]
        if let n, !n.isEmpty { payload["n"] = n }
        var input = try JSONSerialization.data(withJSONObject: payload)
        input.append(0x0A)

        let processBox = DownloadProcessBox()
        let worker = Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = ["-c", youtubeChallengeSolverSource]

            let inputPipe = Pipe()
            let outputPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            guard processBox.install(process) else { throw CancellationError() }
            do {
                try process.run()
            } catch {
                processBox.clear()
                throw error
            }
            inputPipe.fileHandleForWriting.write(input)
            try? inputPipe.fileHandleForWriting.close()
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            processBox.clear()
            try Task.checkCancellation()
            guard process.terminationStatus == 0, !output.isEmpty else {
                throw YouTubeMusicAPIError.noPlayableStream
            }
            return try JSONDecoder().decode(YouTubeChallengeSolution.self, from: output)
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            processBox.cancel()
            worker.cancel()
        }
    }

    private nonisolated static let youtubeChallengeSolverSource = #"""
import json
import sys
from yt_dlp import YoutubeDL
from yt_dlp.extractor.youtube import YoutubeIE
from yt_dlp.extractor.youtube.jsc._director import initialize_jsc_director
from yt_dlp.extractor.youtube.jsc.provider import (
    JsChallengeRequest, JsChallengeType, NChallengeInput, SigChallengeInput,
)

payload = json.loads(sys.stdin.readline())
params = {
    'quiet': True,
    'no_warnings': True,
    'js_runtimes': {'deno': {'path': payload['deno']}},
}
with YoutubeDL(params) as ydl:
    ie = YoutubeIE(ydl)
    ie._load_player = lambda *args, **kwargs: payload['player']
    ie._jsc_director = initialize_jsc_director(ie)
    requests = [JsChallengeRequest(
        type=JsChallengeType.SIG,
        video_id=payload['video_id'],
        input=SigChallengeInput(
            challenges=[payload['signature']],
            player_url=payload['player_url'],
        ),
    )]
    if payload.get('n'):
        requests.append(JsChallengeRequest(
            type=JsChallengeType.N,
            video_id=payload['video_id'],
            input=NChallengeInput(
                challenges=[payload['n']],
                player_url=payload['player_url'],
            ),
        ))
    output = {}
    for _, response in ie._jsc_director.bulk_solve(requests):
        key = response.type.value
        challenge = payload['signature'] if key == 'sig' else payload.get('n')
        output['signature' if key == 'sig' else 'n'] = response.output.results.get(challenge)
    print(json.dumps(output), flush=True)
"""#

    nonisolated static func playerRequestBody(
        videoID: String,
        signatureTimestamp: Int?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        if let signatureTimestamp {
            body["playbackContext"] = [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS",
                    "signatureTimestamp": signatureTimestamp
                ]
            ]
        }
        return body
    }

    private func resolve(
        videoID: String,
        client: PlayerClient,
        authenticated: Bool,
        quality: AudioQuality,
        unlockCipher: Bool = false
    ) async throws -> ResolvedStream {
        let base = client.origin == "https://music.youtube.com" ? musicBase : youtubeBase
        let signatureTimestamp: Int?
        if unlockCipher {
            signatureTimestamp = try await currentSignatureTimestamp(for: videoID)
        } else {
            signatureTimestamp = nil
        }
        let response: [String: Any]
        do {
            response = try await post(
                endpoint: "player",
                on: base,
                client: client,
                authenticated: authenticated,
                body: Self.playerRequestBody(
                    videoID: videoID,
                    signatureTimestamp: signatureTimestamp
                )
            )
        } catch {
            streamLogger.debug("Player \(client.key, privacy: .public) request failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        let streamingData = dictionary(response["streamingData"]) ?? [:]
        let formats = (array(streamingData["adaptiveFormats"]) + array(streamingData["formats"]))
            .compactMap(dictionary)
            .filter { string($0["mimeType"])?.hasPrefix("audio/") == true }
        // CoreMedia is much more reliable with YouTube's AAC/MP4 ladder than
        // with Opus/WebM. If this client only offers WebM, let the next client
        // try instead of handing an apparently valid but unusable URL to AVPlayer.
        let compatibleFormats = formats.filter {
            string($0["mimeType"])?.hasPrefix("audio/mp4") == true
        }
        let playbackFormats = prioritizedPlaybackFormats(compatibleFormats, quality: quality)
        let hintedPlayerPath = string(dictionary(response["assets"])?["js"])
        let mediaHeaders = Self.resolvedMediaHeaders(
            client.mediaHeaders,
            cookieHeader: cookieHeader,
            authenticated: authenticated
        )

        for format in playbackFormats {
            let url: URL?
            if let rawURL = string(format["url"]) {
                url = URL(string: rawURL)
            } else if unlockCipher, let cipher = string(format["signatureCipher"]) ?? string(format["cipher"]) {
                url = await unlockSignatureCipher(
                    cipher,
                    videoID: videoID,
                    clientVersion: client.version,
                    hintedPlayerPath: hintedPlayerPath
                )
            } else {
                url = nil
            }
            if let url {
                let mimeType = string(format["mimeType"])
                let codec = mimeType?
                    .split(separator: "\"")
                    .dropFirst()
                    .first
                    .map(String.init)
                let info = AudioStreamInfo(
                    requestedQuality: quality,
                    bitrateKbps: Int((number(format["bitrate"]) / 1_000).rounded()),
                    codec: Self.codecName(codec),
                    sampleRate: Int(string(format["audioSampleRate"]) ?? ""),
                    channels: Int(number(format["audioChannels"])),
                    sourceName: "YouTube Music"
                )
                let stream = ResolvedStream(
                    url: url,
                    headers: mediaHeaders,
                    videoID: videoID,
                    info: info,
                    duration: string(format["approxDurationMs"])
                        .flatMap(TimeInterval.init)
                        .map { $0 / 1_000 }
                )
                if await probe(stream) {
                    streamLogger.debug("Direct media \(Self.safeStreamMetadata(stream), privacy: .public)")
                    streamLogger.info("Selected \(client.name, privacy: .public) stream at \(info.bitrateKbps ?? 0, privacy: .public) kbps")
                    return stream
                }
                streamLogger.info("Probe rejected \(client.key, privacy: .public) itag=\(self.number(format["itag"]), format: .fixed(precision: 0), privacy: .public)")
            }
        }
        throw YouTubeMusicAPIError.noPlayableStream
    }

    private func prioritizedPlaybackFormats(
        _ formats: [[String: Any]],
        quality: AudioQuality
    ) -> [[String: Any]] {
        let ceiling = quality.selectionCeilingKbps * 1_000
        let atOrBelow = formats
            .filter { number($0["bitrate"]) <= ceiling }
            .sorted { number($0["bitrate"]) > number($1["bitrate"]) }
        let over = formats
            .filter { number($0["bitrate"]) > ceiling }
            .sorted { number($0["bitrate"]) < number($1["bitrate"]) }
        return atOrBelow + over
    }

    func downloadStream(_ stream: ResolvedStream) async throws -> URL {
        if let videoID = stream.videoID {
            await prepareWebSession()
            return try await downloadWithYTDLP(
                videoID: videoID,
                cookieHeader: stream.headers["Cookie"] ?? "",
                quality: stream.info?.requestedQuality ?? playbackQuality,
                dataSyncID: sessionScope?.dataSyncID
            )
        }

        var request = URLRequest(url: stream.url)
        request.timeoutInterval = 90
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        for (name, value) in stream.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw YouTubeMusicAPIError.noPlayableStream
        }

        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitChord/Streams", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let destination = cacheDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func downloadWithYTDLP(
        videoID: String,
        cookieHeader: String,
        quality: AudioQuality,
        dataSyncID: String?
    ) async throws -> URL {
        let cacheDirectory = playbackStreamCacheDirectory()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let destination = playbackFallbackURL(videoID: videoID, quality: quality)
        if Self.fileHasData(destination) { return destination }

        let outputBase = cacheDirectory.appendingPathComponent("partial-\(UUID().uuidString)")
        let outputPath = outputBase.path + ".%(ext)s"
        guard let executablePath = ytdlpExecutablePath() else {
            throw YouTubeMusicAPIError.noPlayableStream
        }
        let denoPath = denoExecutablePath()
        let formatSelector = playbackFormatSelector(for: quality)
        let attempts = Self.playbackFallbackAttempts(hasCookies: !cookieHeader.isEmpty)

        let processBox = DownloadProcessBox()
        let worker = Task.detached(priority: .userInitiated) {
            let cookieFile = try Self.makeTemporaryCookieFileIfNeeded(cookieHeader: cookieHeader)
            defer {
                if let cookieFile { try? FileManager.default.removeItem(at: cookieFile) }
            }

            for attempt in attempts {
                try Task.checkCancellation()
                Self.removeYTDLPArtifacts(outputBase: outputBase)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                var arguments = [
                    "--quiet",
                    "--no-warnings",
                    "--no-playlist",
                    "--no-part",
                    "--socket-timeout", "15",
                    "--retries", "1",
                    "--fragment-retries", "1",
                    "--extractor-args", Self.ytdlpExtractorArguments(
                        for: attempt.extractorClient,
                        dataSyncID: attempt.includesCookies ? dataSyncID : nil
                    ),
                    "--format", formatSelector,
                    "--output", outputPath
                ]
                if attempt.includesCookies {
                    arguments += Self.ytdlpCookieArguments(cookieFile: cookieFile)
                }
                arguments += Self.ytdlpRuntimeArguments(denoPath: denoPath)
                arguments.append("https://music.youtube.com/watch?v=\(videoID)")
                process.arguments = arguments

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                guard processBox.install(process) else { throw CancellationError() }
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    processBox.clear()
                    continue
                }
                _ = outputPipe.fileHandleForReading.readDataToEndOfFile()
                _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
                processBox.clear()
                try Task.checkCancellation()
                let producedURL = outputBase.appendingPathExtension("m4a")

                if process.terminationStatus == 0, Self.fileHasData(producedURL) {
                    return producedURL
                }
            }
            throw YouTubeMusicAPIError.noPlayableStream
        }

        do {
            let producedURL = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                processBox.cancel()
                worker.cancel()
            }
            try Task.checkCancellation()

            if Self.fileHasData(destination) {
                try? FileManager.default.removeItem(at: producedURL)
            } else {
                do {
                    try FileManager.default.moveItem(at: producedURL, to: destination)
                } catch {
                    // Two callers can finish the same fallback at nearly the
                    // same time. If the other one already installed a valid
                    // cache entry, keep it and discard this duplicate.
                    guard Self.fileHasData(destination) else { throw error }
                    try? FileManager.default.removeItem(at: producedURL)
                }
            }
            Self.removeYTDLPArtifacts(outputBase: outputBase)
            _ = await audioCache.registerCompletedFile(destination)
            return destination
        } catch {
            processBox.cancel()
            worker.cancel()
            Self.removeYTDLPArtifacts(outputBase: outputBase)
            throw error
        }
    }

    private nonisolated static func removeYTDLPArtifacts(outputBase: URL) {
        let directory = outputBase.deletingLastPathComponent()
        let prefix = outputBase.lastPathComponent + "."
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in urls where url.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func probe(_ stream: ResolvedStream) async -> Bool {
        let contentLength = URLComponents(url: stream.url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "clen" })?
            .value
            .flatMap(Int64.init)

        async let opening = probe(stream, range: "bytes=0-1")
        if let contentLength, contentLength > 4 {
            // A URL can serve its opening probe and still refuse every useful
            // read later in the file. The Kotlin player learns that only after
            // ExoPlayer reports a 403 and then retires the client. AVPlayer has
            // no equivalent data-source callback, so reject the same bad URL
            // up front with a real bounded read well into the media. Some
            // refused clients permit one or two bytes anywhere but reject the
            // first useful chunk, so a tiny tail probe is a false positive.
            let offset = min(contentLength - 2, max(2, contentLength * 3 / 4))
            let end = min(contentLength - 1, offset + 64 * 1_024 - 1)
            async let distant = probe(stream, range: "bytes=\(offset)-\(end)")
            let openingOK = await opening
            let distantOK = await distant
            return openingOK && distantOK
        }
        return await opening
    }

    private func probe(_ stream: ResolvedStream, range: String) async -> Bool {
        var request = URLRequest(url: stream.url)
        request.httpMethod = "GET"
        request.setValue(range, forHTTPHeaderField: "Range")
        request.timeoutInterval = 10
        for (name, value) in stream.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            streamLogger.debug("Media probe received no HTTP response")
            return false
        }
        let accepted = (200..<300).contains(http.statusCode)
        if !accepted {
            streamLogger.debug(
                "Media probe rejected status=\(http.statusCode, privacy: .public) range=\(range, privacy: .public) contentType=\(http.value(forHTTPHeaderField: "Content-Type") ?? "missing", privacy: .public) metadata=\(Self.safeStreamMetadata(stream), privacy: .public)"
            )
        }
        return accepted
    }

    private nonisolated static func safeStreamMetadata(_ stream: ResolvedStream) -> String {
        let components = URLComponents(url: stream.url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        let values = Dictionary(items.compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { _, last in last })
        let publicValues = ["c", "cver", "itag", "mime", "source"]
            .compactMap { key in values[key].map { "\(key)=\($0)" } }
        let protectedLengths = ["sig", "signature", "lsig", "n", "pot"]
            .compactMap { key in values[key].map { "\(key).length=\($0.count)" } }
        let keys = Set(items.map(\.name)).sorted().joined(separator: ",")
        let headers = stream.headers.keys.sorted().joined(separator: ",")
        return ([
            "host=\(components?.host ?? "missing")",
            "keys=[\(keys)]",
            "headers=[\(headers)]"
        ] + publicValues + protectedLengths).joined(separator: " ")
    }

    func lyrics(for track: Track) async throws -> Lyrics? {
        await lyricsRepository.lyrics(for: track, preferences: lyricsSettings.snapshot)
    }

    private func post(
        endpoint: String,
        on base: URL,
        client: PlayerClient,
        authenticated: Bool,
        body: [String: Any]
    ) async throws -> [String: Any] {
        let clientVersion = client.name == "WEB_REMIX"
            ? (sessionScope?.clientVersion ?? client.version)
            : client.version
        var clientContext: [String: Any] = [
            "clientName": client.name,
            "clientVersion": clientVersion,
            "hl": "en",
            "gl": "US"
        ]
        if let osName = client.osName { clientContext["osName"] = osName }
        if let osVersion = client.osVersion { clientContext["osVersion"] = osVersion }
        if let deviceMake = client.deviceMake { clientContext["deviceMake"] = deviceMake }
        if let deviceModel = client.deviceModel { clientContext["deviceModel"] = deviceModel }
        if let androidSDK = client.androidSDK { clientContext["androidSdkVersion"] = androidSDK }
        if let visitorData { clientContext["visitorData"] = visitorData }

        var context: [String: Any] = ["client": clientContext]
        if client.name == "WEB_REMIX" {
            var user: [String: Any] = ["lockedSafetyMode": false]
            if let dataSyncID = sessionScope?.dataSyncID { user["onBehalfOfUser"] = dataSyncID }
            context["user"] = user
            context["request"] = ["useSsl": true]
        }
        var payload = body
        payload["context"] = context

        let requestBody = try JSONSerialization.data(withJSONObject: payload)
        var lastError: Error?
        for requestBase in requestBases(for: base) {
            guard var components = URLComponents(
                url: requestBase.appendingPathComponent(endpoint),
                resolvingAgainstBaseURL: false
            ) else {
                throw YouTubeMusicAPIError.invalidResponse
            }
            components.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")]
            guard let url = components.url else { throw YouTubeMusicAPIError.invalidResponse }

            let requestOrigin = requestBase.host == youtubeBase.host
                ? "https://www.youtube.com"
                : (client.origin ?? "https://music.youtube.com")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = requestBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(requestOrigin, forHTTPHeaderField: "Origin")
            request.setValue("\(requestOrigin)/", forHTTPHeaderField: "Referer")
            request.setValue(requestOrigin, forHTTPHeaderField: "X-Origin")
            request.setValue(client.id, forHTTPHeaderField: "X-YouTube-Client-Name")
            request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
            request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
            if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
            if authenticated, let cookieHeader {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                request.setValue(sessionScope?.authUser ?? "0", forHTTPHeaderField: "X-Goog-AuthUser")
                if let pageID = sessionScope?.pageID {
                    request.setValue(pageID, forHTTPHeaderField: "X-Goog-PageId")
                }
                request.setValue(sapisidHash(for: cookieHeader, origin: requestOrigin), forHTTPHeaderField: "Authorization")
            }
            request.timeoutInterval = 20

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw YouTubeMusicAPIError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else { throw YouTubeMusicAPIError.httpStatus(http.statusCode) }
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw YouTubeMusicAPIError.malformedData
                }
                if visitorData == nil,
                   let responseContext = object["responseContext"] as? [String: Any],
                   let responseVisitor = responseContext["visitorData"] as? String {
                    visitorData = responseVisitor
                }
                return object
            } catch {
                lastError = error
                guard requestBase.host == musicBase.host,
                      requestBases(for: base).count > 1,
                      Self.shouldFallbackToYouTubeHost(error) else {
                    throw error
                }
                streamLogger.info(
                    "YouTube host \(requestBase.host ?? "unknown", privacy: .public) unavailable; retrying API request on www.youtube.com"
                )
            }
        }

        throw lastError ?? YouTubeMusicAPIError.invalidResponse
    }

    private func requestBases(for base: URL) -> [URL] {
        guard base.host == musicBase.host else { return [base] }
        return [base, youtubeBase]
    }

    private nonisolated static func shouldFallbackToYouTubeHost(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return nsError.code == URLError.cannotFindHost.rawValue
            || nsError.code == URLError.dnsLookupFailed.rawValue
    }

    private func prepareWebSession() async {
        if cookieHeader != nil { await ensureSessionScope() }
        await ensureVisitorData()
    }

    /// A Google cookie can contain several accounts and brand channels. The
    /// web shell tells the official client which one is active; every signed
    /// Innertube request must repeat that scope or Library quietly resolves to
    /// the first/anonymous identity in the jar.
    private func ensureSessionScope() async {
        guard sessionScope == nil, let cookieHeader else { return }
        let webHosts = [
            (url: URL(string: "https://music.youtube.com/"), origin: "https://music.youtube.com"),
            (url: URL(string: "https://www.youtube.com/"), origin: "https://www.youtube.com")
        ]

        for webHost in webHosts {
            guard let url = webHost.url else { continue }
            var request = URLRequest(url: url)
            request.setValue(webClient.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue(sapisidHash(for: cookieHeader, origin: webHost.origin), forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 20

            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else {
                if webHost.origin == "https://music.youtube.com" {
                    streamLogger.info("YouTube web host music.youtube.com unavailable; retrying session bootstrap on www.youtube.com")
                    continue
                }
                return
            }

            let clientVersion = capture(#""INNERTUBE_CLIENT_VERSION"\s*:\s*"([^"]+)""#, in: html)
            let signedIn = capture(#""LOGGED_IN"\s*:\s*(true|false)"#, in: html) == "true"
            if let shellVisitor = capture(#""VISITOR_DATA"\s*:\s*"([^"]+)""#, in: html), !shellVisitor.isEmpty {
                visitorData = shellVisitor
            }

            guard signedIn else {
                if let clientVersion {
                    sessionScope = SessionScope(dataSyncID: nil, pageID: nil, authUser: "0", clientVersion: clientVersion)
                }
                return
            }

            let dataSyncID = capture(#""DATASYNC_ID"\s*:\s*"([^"]+)""#, in: html)?
                .components(separatedBy: "||").first
                .flatMap { $0.isEmpty ? nil : $0 }
            let pageID = capture(#""DELEGATED_SESSION_ID"\s*:\s*"([^"]+)""#, in: html)
            let authUser = capture(#""SESSION_INDEX"\s*:\s*"?(\d+)"#, in: html) ?? "0"
            sessionScope = SessionScope(
                dataSyncID: dataSyncID,
                pageID: pageID?.isEmpty == false ? pageID : nil,
                authUser: authUser,
                clientVersion: clientVersion
            )
            return
        }
    }

    private func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func ensureVisitorData() async {
        guard visitorData == nil,
              let url = URL(string: "https://www.youtube.com/sw.js_data") else { return }
        var request = URLRequest(url: url)
        request.setValue(webClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        guard let (data, _) = try? await session.data(for: request),
              let html = String(data: data, encoding: .utf8),
              let range = html.range(of: #"Cg[A-Za-z0-9_%-]{40,}"#, options: .regularExpression) else { return }
        visitorData = String(html[range])
    }

    private func sapisidHash(for cookieHeader: String, origin: String) -> String {
        var jar: [String: String] = [:]
        for entry in cookieHeader.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !value.isEmpty, jar[name] == nil { jar[name] = value }
        }
        let secret = ["SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID"]
            .compactMap { jar[$0] }
            .first ?? ""
        let timestamp = Int(Date().timeIntervalSince1970)
        let input = "\(timestamp) \(secret) \(origin)"
        let digest = Insecure.SHA1.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "SAPISIDHASH \(timestamp)_\(digest)"
    }

    private struct PlayerClient: Sendable {
        let name: String
        let version: String
        let id: String
        let userAgent: String
        let osName: String?
        let osVersion: String?
        let deviceMake: String?
        let deviceModel: String?
        let androidSDK: Int?
        let origin: String?

        init(
            name: String,
            version: String,
            id: String,
            userAgent: String,
            osName: String? = nil,
            osVersion: String? = nil,
            deviceMake: String? = nil,
            deviceModel: String? = nil,
            androidSDK: Int? = nil,
            origin: String? = nil
        ) {
            self.name = name
            self.version = version
            self.id = id
            self.userAgent = userAgent
            self.osName = osName
            self.osVersion = osVersion
            self.deviceMake = deviceMake
            self.deviceModel = deviceModel
            self.androidSDK = androidSDK
            self.origin = origin
        }

        var mediaHeaders: [String: String] {
            var headers = ["User-Agent": userAgent]
            if let origin {
                headers["Origin"] = origin
                headers["Referer"] = "\(origin)/"
            }
            return headers
        }

        var key: String { "\(name)@\(version)" }
    }

    private struct SessionScope {
        let dataSyncID: String?
        let pageID: String?
        let authUser: String
        let clientVersion: String?
    }

    private func parseShelves(
        _ root: [String: Any],
        excludingVideoContent: Bool = false
    ) -> [HomeShelf] {
        var shelves: [HomeShelf] = []
        var seen = Set<String>()

        // First-page browse responses carry an ordered section list. Preserve
        // that order instead of grouping all carousels before all plain rows.
        if let sectionList = collectObjects(root, named: "sectionListRenderer").first {
            for raw in array(sectionList["contents"]) {
                let section = dictionary(raw) ?? [:]
                let renderer = dictionary(section["musicCarouselShelfRenderer"])
                    ?? dictionary(section["musicShelfRenderer"])
                guard let renderer,
                      let shelf = parseShelf(renderer, excludingVideoContent: excludingVideoContent),
                      seen.insert(shelf.id).inserted else {
                    continue
                }
                shelves.append(shelf)
            }
            if !shelves.isEmpty { return shelves }
        }

        for renderer in collectObjects(root, named: "musicCarouselShelfRenderer") {
            if let shelf = parseShelf(renderer, excludingVideoContent: excludingVideoContent),
               seen.insert(shelf.id).inserted {
                shelves.append(shelf)
            }
        }
        for renderer in collectObjects(root, named: "musicShelfRenderer") {
            if let shelf = parseShelf(renderer, excludingVideoContent: excludingVideoContent),
               seen.insert(shelf.id).inserted {
                shelves.append(shelf)
            }
        }
        return shelves
    }

    private func parseShelf(
        _ renderer: [String: Any],
        excludingVideoContent: Bool = false
    ) -> HomeShelf? {
        let header = dictionary(renderer["header"]) ?? [:]
        let headerRenderer = dictionary(header["musicCarouselShelfBasicHeaderRenderer"]) ?? header
        let title = text(headerRenderer["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = text(headerRenderer["strapline"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if excludingVideoContent, Self.mentionsVideo(title) { return nil }
        let contents = array(renderer["contents"])
        let items = contents.compactMap { raw -> ShelfItem? in
            let item = dictionary(raw) ?? [:]
            if let twoRow = dictionary(item["musicTwoRowItemRenderer"]), let shelfItem = parseTwoRowItem(twoRow) {
                if excludingVideoContent {
                    if shelfItem.track?.isMusicVideo == true { return nil }
                    if shelfItem.browseItem != nil,
                       Self.mentionsVideo(shelfItem.title) || Self.mentionsVideo(shelfItem.subtitle) {
                        return nil
                    }
                }
                return shelfItem
            }
            if let responsive = dictionary(item["musicResponsiveListItemRenderer"]), let track = parseTrack(responsive) {
                if excludingVideoContent, track.isMusicVideo { return nil }
                return ShelfItem(title: track.title, subtitle: track.artist, artworkURL: track.artworkURL, track: track)
            }
            if let responsive = dictionary(item["musicResponsiveListItemRenderer"]),
               let artist = parseArtistShelfItem(responsive) {
                return artist
            }
            return nil
        }
        guard !items.isEmpty else { return nil }
        return HomeShelf(title: title.isEmpty ? "For you" : title, subtitle: subtitle, items: items)
    }

    /// Chart artist rows contain a browse destination but no video id, so the
    /// normal track parser intentionally rejects them. Keep the destination as
    /// a real artist card rather than dropping the entire Top Artists shelf.
    private func parseArtistShelfItem(_ renderer: [String: Any]) -> ShelfItem? {
        guard let endpoint = dictionary(renderer["navigationEndpoint"]),
              let browse = dictionary(endpoint["browseEndpoint"]),
              let browseID = string(browse["browseId"]) else { return nil }
        let configs = dictionary(browse["browseEndpointContextSupportedConfigs"])
        let musicConfig = dictionary(configs?["browseEndpointContextMusicConfig"])
        guard text(musicConfig?["pageType"]).localizedCaseInsensitiveContains("ARTIST") else {
            return nil
        }
        let columns = array(renderer["flexColumns"])
        let title = flexColumnText(columns[safe: 0])
        guard !title.isEmpty else { return nil }
        let subtitle = flexColumnText(columns[safe: 1])
        let item = BrowseItem(
            id: browseID,
            title: title,
            subtitle: subtitle,
            artworkURL: thumbnailURL(in: renderer["thumbnail"]),
            kind: .artist
        )
        return ShelfItem(
            title: title,
            subtitle: subtitle,
            artworkURL: item.artworkURL,
            browseItem: item
        )
    }

    private func parseLibraryItems(_ root: [String: Any]) -> [ShelfItem] {
        var items: [ShelfItem] = []
        var seen = Set<String>()

        for renderer in collectObjects(root, named: "musicTwoRowItemRenderer") {
            guard let item = parseTwoRowItem(renderer),
                  let browse = item.browseItem,
                  seen.insert(browse.id).inserted else { continue }
            items.append(item)
        }
        for renderer in collectObjects(root, named: "musicResponsiveListItemRenderer") {
            guard let browse = parseBrowseItem(renderer), seen.insert(browse.id).inserted else { continue }
            items.append(ShelfItem(
                title: browse.title,
                subtitle: browse.subtitle,
                artworkURL: browse.artworkURL,
                browseItem: browse
            ))
        }
        return items
    }

    private func parseTwoRowItem(_ renderer: [String: Any]) -> ShelfItem? {
        let title = text(renderer["title"])
        guard !title.isEmpty else { return nil }
        let subtitle = text(renderer["subtitle"])
        // Two-row cards use thumbnailRenderer; reading only `thumbnail`
        // made every real cover fall through to the coloured placeholder.
        let artwork = thumbnailURL(in: renderer["thumbnailRenderer"] ?? renderer["thumbnail"])
        let endpoint = dictionary(renderer["navigationEndpoint"]) ?? [:]
        let browse = dictionary(endpoint["browseEndpoint"])
        let rawBrowseID = string(browse?["browseId"])
        let watch = dictionary(endpoint["watchEndpoint"])
        let videoID: String?
        if let watchID = string(watch?["videoId"]) {
            videoID = watchID
        } else if let rawBrowseID, rawBrowseID.hasPrefix("MPED") {
            videoID = String(rawBrowseID.dropFirst(4))
        } else {
            videoID = nil
        }
        let browseID = rawBrowseID?.hasPrefix("MPED") == true ? nil : rawBrowseID
        let isVideo = subtitle.localizedCaseInsensitiveContains("views")
            || thumbnailIsNotSquare(in: renderer["thumbnailRenderer"] ?? renderer["thumbnail"])

        var browseItem: BrowseItem?
        if let browse, let browseID {
            let configs = dictionary(browse["browseEndpointContextSupportedConfigs"])
            let musicConfig = dictionary(configs?["browseEndpointContextMusicConfig"])
            let kind = browseKind(pageType: text(musicConfig?["pageType"]), browseID: browseID)
            browseItem = BrowseItem(id: browseID, title: title, subtitle: subtitle, artworkURL: artwork, kind: kind)
        }
        let track = videoID.map {
            Track(
                videoID: $0,
                title: title,
                artist: artist(from: subtitle),
                album: nil,
                artworkURL: artwork,
                duration: nil,
                localPath: nil,
                sourceURL: nil,
                isVideo: isVideo
            )
        }
        guard track != nil || browseItem != nil else { return nil }
        return ShelfItem(title: title, subtitle: subtitle, artworkURL: artwork, track: track, browseItem: browseItem)
    }

    private func parseBrowseItem(_ renderer: [String: Any]) -> BrowseItem? {
        guard let endpoint = dictionary(renderer["navigationEndpoint"]),
              let browse = dictionary(endpoint["browseEndpoint"]),
              let browseID = string(browse["browseId"]) else { return nil }
        let columns = array(renderer["flexColumns"])
        let title = flexColumnText(columns[safe: 0])
        guard !title.isEmpty else { return nil }
        let subtitle = flexColumnText(columns[safe: 1])
        let configs = dictionary(browse["browseEndpointContextSupportedConfigs"])
        let musicConfig = dictionary(configs?["browseEndpointContextMusicConfig"])
        let pageType = text(musicConfig?["pageType"])
        return BrowseItem(id: browseID, title: title, subtitle: subtitle, artworkURL: thumbnailURL(in: renderer["thumbnail"]), kind: browseKind(pageType: pageType, browseID: browseID))
    }

    private struct TrackCredits {
        var artistID: String?
        var artistName: String?
        var albumID: String?
        var albumName: String?

        func fillingMissing(with fallback: TrackCredits) -> TrackCredits {
            TrackCredits(
                artistID: artistID ?? fallback.artistID,
                artistName: artistName ?? fallback.artistName,
                albumID: albumID ?? fallback.albumID,
                albumName: albumName ?? fallback.albumName
            )
        }
    }

    private func parseTrack(_ renderer: [String: Any]) -> Track? {
        parseTrack(renderer, fallback: TrackCredits())
    }

    private func parseTrack(_ renderer: [String: Any], fallback: TrackCredits) -> Track? {
        let playlistData = dictionary(renderer["playlistItemData"])
        let overlay = dictionary(renderer["overlay"])
        let overlayRenderer = dictionary(overlay?["musicItemThumbnailOverlayRenderer"])
        let overlayContent = dictionary(overlayRenderer?["content"])
        let playButton = dictionary(overlayContent?["musicPlayButtonRenderer"])
        let navigation = dictionary(playButton?["playNavigationEndpoint"])
        let watchEndpoint = dictionary(navigation?["watchEndpoint"])
        let videoID = string(playlistData?["videoId"])
            ?? string(watchEndpoint?["videoId"])
            ?? firstValue(forKey: "videoId", in: renderer)
        guard let videoID, !videoID.isEmpty else { return nil }

        let columns = array(renderer["flexColumns"])
        let title = flexColumnText(columns[safe: 0])
        guard !title.isEmpty else { return nil }
        let credits = credits(inColumns: columns).fillingMissing(with: fallback)
        let subtitle = flexColumnText(columns[safe: 1])
        let subtitleParts = subtitle.components(separatedBy: " • ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let rowType = subtitleParts.first { Self.trackTypeWords.contains($0.lowercased()) }?.lowercased()
        let fallbackArtist = subtitleParts.first { part in
            let lowered = part.lowercased()
            return !Self.trackTypeWords.contains(lowered)
                && parseDuration(part) == nil
                && !Self.looksLikeTally(part)
        }
        let artist = credits.artistName ?? fallbackArtist ?? subtitle
        let duration = parseDuration(fixedColumnText(array(renderer["fixedColumns"])[safe: 0]))
        let setVideoID = string(playlistData?["playlistSetVideoId"])
            ?? firstValue(forKey: "playlistSetVideoId", in: renderer)
        let isVideo = rowType == "video" || thumbnailIsNotSquare(in: renderer["thumbnail"])
        return Track(
            videoID: videoID,
            title: title,
            artist: artist.isEmpty ? "YouTube Music" : artist,
            album: credits.albumName,
            artworkURL: thumbnailURL(in: renderer["thumbnail"]),
            duration: duration,
            localPath: nil,
            sourceURL: nil,
            artistBrowseID: credits.artistID,
            albumBrowseID: credits.albumID,
            setVideoID: setVideoID,
            isVideo: isVideo
        )
    }

    private func parseWatchQueue(_ root: [String: Any]) -> [Track] {
        var tracks: [Track] = []
        var seen = Set<String>()
        for renderer in collectObjects(root, named: "playlistPanelVideoRenderer") {
            guard let videoID = string(renderer["videoId"]), !videoID.isEmpty,
                  seen.insert(videoID).inserted else { continue }
            let title = text(renderer["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let byline = text(renderer["longBylineText"])
            let credits = credits(inText: renderer["longBylineText"])
            let artist = byline
                .components(separatedBy: " • ")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            tracks.append(Track(
                videoID: videoID,
                title: title,
                artist: credits.artistName ?? (artist?.isEmpty == false ? artist! : "YouTube Music"),
                album: credits.albumName,
                artworkURL: thumbnailURL(in: renderer["thumbnail"]),
                duration: parseDuration(text(renderer["lengthText"])),
                localPath: nil,
                sourceURL: nil,
                artistBrowseID: credits.artistID,
                albumBrowseID: credits.albumID,
                isVideo: byline.localizedCaseInsensitiveContains("views")
            ))
        }
        return tracks
    }

    private func browseKind(pageType: String, browseID: String) -> BrowseItem.Kind {
        if pageType.localizedCaseInsensitiveContains("ALBUM") { return .album }
        if pageType.localizedCaseInsensitiveContains("ARTIST") { return .artist }
        if pageType.localizedCaseInsensitiveContains("PLAYLIST") { return .playlist }
        if browseID.hasPrefix("VL") { return .playlist }
        if browseID.hasPrefix("MPRE") || browseID.hasPrefix("MPR") { return .album }
        if browseID.hasPrefix("UC") { return .artist }
        return .other
    }

    private func artist(from subtitle: String) -> String {
        let ignored = Set(["song", "single", "album", "playlist", "ep"])
        return subtitle
            .components(separatedBy: " • ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !ignored.contains($0.lowercased()) }
            ?? subtitle
    }

    private func flexColumnText(_ raw: Any?) -> String {
        guard let column = dictionary(raw) else { return "" }
        let renderer = dictionary(column["musicResponsiveListItemFlexColumnRenderer"]) ?? column
        return text(renderer["text"])
    }

    private func fixedColumnText(_ raw: Any?) -> String {
        guard let column = dictionary(raw) else { return "" }
        let renderer = dictionary(column["musicResponsiveListItemFixedColumnRenderer"]) ?? column
        return text(renderer["text"])
    }

    private func credits(inColumns columns: [Any]) -> TrackCredits {
        credits(inRuns: columns.flatMap { raw -> [[String: Any]] in
            guard let column = dictionary(raw) else { return [] }
            let renderer = dictionary(column["musicResponsiveListItemFlexColumnRenderer"]) ?? column
            return runs(in: renderer["text"])
        })
    }

    private func credits(inText raw: Any?) -> TrackCredits {
        credits(inRuns: runs(in: raw))
    }

    private func credits(inRuns runs: [[String: Any]]) -> TrackCredits {
        var result = TrackCredits()
        for run in runs {
            guard let endpoint = dictionary(run["navigationEndpoint"]),
                  let browse = dictionary(endpoint["browseEndpoint"]),
                  let browseID = string(browse["browseId"]) else { continue }
            let configs = dictionary(browse["browseEndpointContextSupportedConfigs"])
            let musicConfig = dictionary(configs?["browseEndpointContextMusicConfig"])
            let pageType = text(musicConfig?["pageType"])
            if pageType.localizedCaseInsensitiveContains("ARTIST"), result.artistID == nil {
                result.artistID = browseID
                result.artistName = string(run["text"])
            } else if pageType.localizedCaseInsensitiveContains("ALBUM"), result.albumID == nil {
                result.albumID = browseID
                result.albumName = string(run["text"])
            }
        }
        return result
    }

    private func pageCredits(in root: [String: Any], browseID: String) -> TrackCredits {
        let isAlbum = browseID.hasPrefix("MPRE") || browseID.hasPrefix("MPR")
        let isArtist = browseID.hasPrefix("UC")
        guard isAlbum || isArtist else { return TrackCredits() }
        let headerNames = [
            "musicResponsiveHeaderRenderer",
            "musicDetailHeaderRenderer",
            "musicEditablePlaylistDetailHeaderRenderer",
            "musicImmersiveHeaderRenderer"
        ]
        guard let header = headerNames.lazy.compactMap({ self.collectObjects(root, named: $0).first }).first else {
            return TrackCredits(
                artistID: isArtist ? browseID : nil,
                albumID: isAlbum ? browseID : nil
            )
        }

        let title = text(header["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let creditFields = ["straplineTextOne", "subtitle", "secondSubtitle"]
        let creditRuns = creditFields.flatMap { runs(in: header[$0]) }
        var result = credits(inRuns: creditRuns)
        if isAlbum {
            result.albumID = browseID
            if !title.isEmpty { result.albumName = title }
        } else {
            result.artistID = browseID
            if !title.isEmpty { result.artistName = title }
        }
        if result.artistName == nil {
            let ignored = Set(["album", "single", "ep", "artist", "playlist"])
            let pieces = creditFields
                .flatMap { text(header[$0]).components(separatedBy: " • ") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            result.artistName = pieces.first {
                !$0.isEmpty && !ignored.contains($0.lowercased()) && Int($0) == nil
            }
        }
        return result
    }

    private func parsePageItem(
        _ root: [String: Any],
        browseID: String,
        tracks: [Track]
    ) -> BrowseItem {
        let kind = browseKind(pageType: "", browseID: browseID)
        let headerNames = [
            "musicResponsiveHeaderRenderer",
            "musicDetailHeaderRenderer",
            "musicEditablePlaylistDetailHeaderRenderer",
            "musicImmersiveHeaderRenderer"
        ]
        let header = headerNames.lazy.compactMap { self.collectObjects(root, named: $0).first }.first
        let headerTitle = header.map {
            text($0["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let subtitleFields = ["straplineTextOne", "subtitle", "secondSubtitle"]
        var seenSubtitles = Set<String>()
        let subtitle = header.map { value in
            subtitleFields
                .map { text(value[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seenSubtitles.insert($0).inserted }
                .joined(separator: " • ")
        } ?? ""
        let artwork = header.flatMap { thumbnailURL(in: $0) } ?? tracks.first?.artworkURL

        let fallbackTitle: String
        switch kind {
        case .album:
            fallbackTitle = tracks.first?.album?.nilIfBlank ?? "Album"
        case .artist:
            fallbackTitle = tracks.first?.artist.nilIfBlank ?? "Artist"
        case .playlist:
            fallbackTitle = browseID == "LM" || browseID == "VLLM" ? "Liked Music" : "Playlist"
        case .other:
            fallbackTitle = "YouTube Music"
        }
        return BrowseItem(
            id: browseID,
            title: headerTitle?.nilIfBlank ?? fallbackTitle,
            subtitle: subtitle.isEmpty ? kindSubtitle(kind) : subtitle,
            artworkURL: artwork,
            kind: kind
        )
    }

    private func kindSubtitle(_ kind: BrowseItem.Kind) -> String {
        switch kind {
        case .album: return "Album"
        case .artist: return "Artist"
        case .playlist: return "Playlist"
        case .other: return "YouTube Music"
        }
    }

    private func runs(in raw: Any?) -> [[String: Any]] {
        guard let object = dictionary(raw) else { return [] }
        return array(object["runs"]).compactMap(dictionary)
    }

    private func parseDuration(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        return parts[0] * 3_600 + parts[1] * 60 + parts[2]
    }

    private func collectObjects(_ value: Any, named key: String) -> [[String: Any]] {
        var result: [[String: Any]] = []
        func walk(_ value: Any) {
            if let object = value as? [String: Any] {
                if let match = object[key] as? [String: Any] { result.append(match) }
                object.values.forEach(walk)
            } else if let values = value as? [Any] {
                values.forEach(walk)
            }
        }
        walk(value)
        return result
    }

    private func firstValue(forKey key: String, in object: [String: Any]) -> String? {
        if let value = string(object[key]) { return value }
        for value in object.values {
            if let nested = value as? [String: Any], let match = firstValue(forKey: key, in: nested) { return match }
            if let nested = value as? [Any] {
                for item in nested {
                    if let nestedObject = item as? [String: Any], let match = firstValue(forKey: key, in: nestedObject) { return match }
                }
            }
        }
        return nil
    }

    private func thumbnailURL(in value: Any?) -> String? {
        if let object = value as? [String: Any] {
            if let thumbnails = object["thumbnails"] as? [[String: Any]],
               let url = thumbnails.last.flatMap({ string($0["url"]) }) { return url }
            for nested in object.values {
                if let url = thumbnailURL(in: nested) { return url }
            }
        } else if let values = value as? [Any] {
            for item in values {
                if let url = thumbnailURL(in: item) { return url }
            }
        }
        return nil
    }

    /// Catalogue sleeves are square; video thumbnails are widescreen. Missing
    /// dimensions stay conservative so an incomplete response is never
    /// rewritten merely because it could not prove what kind of row it was.
    private func thumbnailIsNotSquare(in value: Any?) -> Bool {
        if let object = value as? [String: Any] {
            if let thumbnails = object["thumbnails"] as? [[String: Any]],
               let last = thumbnails.last,
               let width = (last["width"] as? NSNumber)?.doubleValue,
               let height = (last["height"] as? NSNumber)?.doubleValue,
               width > 0, height > 0 {
                let ratio = width / height
                return !(0.85...1.15).contains(ratio)
            }
            for nested in object.values where thumbnailIsNotSquare(in: nested) { return true }
        } else if let values = value as? [Any] {
            for item in values where thumbnailIsNotSquare(in: item) { return true }
        }
        return false
    }

    private static func looksLikeTally(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return lowered.contains("views")
            || lowered.contains("plays")
            || lowered.contains("listeners")
            || lowered.range(of: #"^[0-9.,]+[kmb]?\s*(views?|plays?)?$"#, options: .regularExpression) != nil
    }

    private static func mentionsVideo(_ value: String) -> Bool {
        value.range(of: #"\bvideos?\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let trackTypeWords = Set([
        "song", "video", "single", "album", "ep", "podcast", "episode", "playlist"
    ])

    private func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    private func array(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
    private func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
    private func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }

    private func text(_ value: Any?) -> String {
        guard let object = dictionary(value) else { return string(value) ?? "" }
        if let simple = string(object["simpleText"]) { return simple }
        if let runs = object["runs"] as? [[String: Any]] {
            return runs.compactMap { string($0["text"]) }.joined()
        }
        return string(object["text"]) ?? ""
    }
}

private extension String {
    var nilIfBlank: String? {
        let cleaned = trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
