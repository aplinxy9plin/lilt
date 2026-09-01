import CryptoKit
import Foundation
import Security
import os

enum ScrobblingError: LocalizedError {
    case invalidEndpoint
    case missingCredentials
    case invalidToken
    case service(String)
    case http(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Enter a valid HTTPS API endpoint."
        case .missingCredentials:
            "Complete every required field."
        case .invalidToken:
            "ListenBrainz rejected that user token."
        case .service(let message):
            message
        case .http(let status):
            "The service returned HTTP \(status)."
        case .invalidResponse:
            "The service returned an unreadable response."
        }
    }
}

struct ScrobbleTrack: Equatable, Sendable {
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval?
    let musicService: String?

    init(track: Track, duration: TimeInterval) {
        title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        album = track.album?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let resolvedDuration = duration > 0 ? duration : (track.duration ?? 0)
        self.duration = resolvedDuration > 0 ? resolvedDuration : nil
        musicService = track.videoID == nil ? nil : "music.youtube.com"
    }
}

protocol ScrobbleHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionScrobbleTransport: ScrobbleHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ScrobblingError.invalidResponse
        }
        return (data, response)
    }
}

protocol ScrobbleCredentialStoring: AnyObject {
    func string(for key: String) -> String?
    func set(_ value: String?, for key: String) throws
}

final class KeychainScrobbleCredentialStore: ScrobbleCredentialStoring {
    private let service: String

    init(service: String = "com.bitchord.mac.scrobbling") {
        self.service = service
    }

    func string(for key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, for key: String) throws {
        let query = baseQuery(for: key)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ScrobblingError.service("Keychain error \(status).")
            }
            return
        }

        let data = Data(value.utf8)
        let updated = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw ScrobblingError.service("Keychain error \(updated).")
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw ScrobblingError.service("Keychain error \(added).")
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}

struct LastFMCredentials: Equatable, Sendable {
    let endpoint: URL
    let apiKey: String
    let secret: String
    let sessionKey: String?
}

struct LastFMSession: Equatable, Sendable {
    let username: String
    let key: String
}

struct LastFMClient: Sendable {
    static let defaultEndpoint = "https://ws.audioscrobbler.com/2.0/"

    let credentials: LastFMCredentials
    let transport: any ScrobbleHTTPTransport

    init(
        credentials: LastFMCredentials,
        transport: any ScrobbleHTTPTransport = URLSessionScrobbleTransport()
    ) {
        self.credentials = credentials
        self.transport = transport
    }

    func mobileSession(username: String, password: String) async throws -> LastFMSession {
        let data = try await send(
            method: "auth.getMobileSession",
            extra: ["username": username, "password": password],
            sessionKey: nil
        )
        let decoded = try JSONDecoder().decode(AuthenticationResponse.self, from: data)
        return LastFMSession(username: decoded.session.name, key: decoded.session.key)
    }

    func updateNowPlaying(_ track: ScrobbleTrack) async throws {
        var extra = ["artist": track.artist, "track": track.title]
        if let album = track.album { extra["album"] = album }
        if let duration = track.duration { extra["duration"] = String(Int(duration.rounded())) }
        _ = try await send(
            method: "track.updateNowPlaying",
            extra: extra,
            sessionKey: try requiredSessionKey()
        )
    }

    func scrobble(_ track: ScrobbleTrack, startedAt: Date) async throws {
        var extra = [
            "artist[0]": track.artist,
            "track[0]": track.title,
            "timestamp[0]": String(Int(startedAt.timeIntervalSince1970))
        ]
        if let album = track.album { extra["album[0]"] = album }
        if let duration = track.duration { extra["duration[0]"] = String(Int(duration.rounded())) }
        _ = try await send(
            method: "track.scrobble",
            extra: extra,
            sessionKey: try requiredSessionKey()
        )
    }

    func makeRequest(
        method: String,
        extra: [String: String],
        sessionKey: String?
    ) -> URLRequest {
        var signed = ["method": method, "api_key": credentials.apiKey]
        if let sessionKey { signed["sk"] = sessionKey }
        signed.merge(extra) { _, new in new }
        let signature = Self.apiSignature(parameters: signed, secret: credentials.secret)
        var body = signed
        body["api_sig"] = signature
        body["format"] = "json"

        var components = URLComponents()
        components.queryItems = body.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: credentials.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Lilt macOS", forHTTPHeaderField: "User-Agent")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return request
    }

    static func apiSignature(parameters: [String: String], secret: String) -> String {
        let source = parameters.sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined() + secret
        let digest = Insecure.MD5.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func normalizeEndpoint(_ raw: String) throws -> URL {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.query == nil,
              components.fragment == nil else {
            throw ScrobblingError.invalidEndpoint
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = path.isEmpty ? "/2.0/" : "/\(path)/"
        guard let url = components.url else { throw ScrobblingError.invalidEndpoint }
        return url
    }

    private func send(
        method: String,
        extra: [String: String],
        sessionKey: String?
    ) async throws -> Data {
        let request = makeRequest(method: method, extra: extra, sessionKey: sessionKey)
        let (data, response) = try await transport.data(for: request)
        if let error = try? JSONDecoder().decode(LastFMErrorResponse.self, from: data),
           error.error != nil {
            throw ScrobblingError.service(error.message ?? "Last.fm rejected the request.")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ScrobblingError.http(response.statusCode)
        }
        return data
    }

    private func requiredSessionKey() throws -> String {
        guard let key = credentials.sessionKey, !key.isEmpty else {
            throw ScrobblingError.missingCredentials
        }
        return key
    }

    private struct AuthenticationResponse: Decodable {
        let session: Session

        struct Session: Decodable {
            let name: String
            let key: String
        }
    }

    private struct LastFMErrorResponse: Decodable {
        let error: Int?
        let message: String?
    }
}

struct ListenBrainzClient: Sendable {
    static let rootURL = URL(string: "https://api.listenbrainz.org")!

    let transport: any ScrobbleHTTPTransport
    let rootURL: URL

    init(
        transport: any ScrobbleHTTPTransport = URLSessionScrobbleTransport(),
        rootURL: URL = ListenBrainzClient.rootURL
    ) {
        self.transport = transport
        self.rootURL = rootURL
    }

    func validate(token: String) async throws -> String {
        var request = URLRequest(url: rootURL.appendingPathComponent("1/validate-token"))
        request.timeoutInterval = 20
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw ScrobblingError.http(response.statusCode)
        }
        let validation = try JSONDecoder().decode(TokenValidation.self, from: data)
        guard validation.valid, let username = validation.userName, !username.isEmpty else {
            throw ScrobblingError.invalidToken
        }
        return username
    }

    func submitNowPlaying(token: String, track: ScrobbleTrack, position: TimeInterval) async throws {
        let request = try submissionRequest(
            token: token,
            type: "playing_now",
            track: track,
            listenedAt: nil,
            position: max(0, position)
        )
        try await send(request)
    }

    func scrobble(token: String, track: ScrobbleTrack, startedAt: Date) async throws {
        let request = try submissionRequest(
            token: token,
            type: "single",
            track: track,
            listenedAt: Int(startedAt.timeIntervalSince1970),
            position: nil
        )
        try await send(request)
    }

    func submissionRequest(
        token: String,
        type: String,
        track: ScrobbleTrack,
        listenedAt: Int?,
        position: TimeInterval?
    ) throws -> URLRequest {
        let durationMS = track.duration.map { Int(($0 * 1_000).rounded()) }
        let positionMS = position.map { Int(($0 * 1_000).rounded()) }
        let info = AdditionalInfo(
            durationMS: durationMS.flatMap { $0 > 0 ? $0 : nil },
            positionMS: positionMS,
            submissionClient: "Lilt",
            musicService: track.musicService
        )
        let metadata = TrackMetadata(
            artistName: track.artist,
            trackName: track.title,
            releaseName: track.album,
            additionalInfo: info
        )
        let body = Submission(
            listenType: type,
            payload: [Listen(listenedAt: listenedAt, trackMetadata: metadata)]
        )
        var request = URLRequest(url: rootURL.appendingPathComponent("1/submit-listens"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func send(_ request: URLRequest) async throws {
        let (_, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw ScrobblingError.invalidToken }
            throw ScrobblingError.http(response.statusCode)
        }
    }

    private struct TokenValidation: Decodable {
        let valid: Bool
        let userName: String?

        enum CodingKeys: String, CodingKey {
            case valid
            case userName = "user_name"
        }
    }

    private struct Submission: Encodable {
        let listenType: String
        let payload: [Listen]

        enum CodingKeys: String, CodingKey {
            case listenType = "listen_type"
            case payload
        }
    }

    private struct Listen: Encodable {
        let listenedAt: Int?
        let trackMetadata: TrackMetadata

        enum CodingKeys: String, CodingKey {
            case listenedAt = "listened_at"
            case trackMetadata = "track_metadata"
        }
    }

    private struct TrackMetadata: Encodable {
        let artistName: String
        let trackName: String
        let releaseName: String?
        let additionalInfo: AdditionalInfo

        enum CodingKeys: String, CodingKey {
            case artistName = "artist_name"
            case trackName = "track_name"
            case releaseName = "release_name"
            case additionalInfo = "additional_info"
        }
    }

    private struct AdditionalInfo: Encodable {
        let durationMS: Int?
        let positionMS: Int?
        let submissionClient: String
        let musicService: String?

        enum CodingKeys: String, CodingKey {
            case durationMS = "duration_ms"
            case positionMS = "position_ms"
            case submissionClient = "submission_client"
            case musicService = "music_service"
        }
    }
}

struct ScrobblingStatus: Equatable, Sendable {
    let message: String
    let isError: Bool
}

enum ScrobbleThreshold {
    static func seconds(
        duration: TimeInterval,
        minimumSongDuration: Int,
        delayPercent: Double,
        maximumDelay: Int
    ) -> TimeInterval? {
        guard duration > TimeInterval(minimumSongDuration),
              delayPercent > 0,
              maximumDelay > 0 else { return nil }
        return min(duration * min(max(delayPercent, 0.1), 1), TimeInterval(maximumDelay))
    }
}

@MainActor
final class ScrobblingManager: ObservableObject {
    @Published var lastFMEnabled: Bool {
        didSet { defaults.set(lastFMEnabled, forKey: Keys.lastFMEnabled) }
    }
    @Published var lastFMScrobbleEnabled: Bool {
        didSet {
            defaults.set(lastFMScrobbleEnabled, forKey: Keys.lastFMScrobbleEnabled)
            if !lastFMScrobbleEnabled, lastFMNowPlayingEnabled {
                lastFMNowPlayingEnabled = false
            }
        }
    }
    @Published var lastFMNowPlayingEnabled: Bool {
        didSet {
            if lastFMNowPlayingEnabled, !lastFMScrobbleEnabled {
                lastFMNowPlayingEnabled = false
                return
            }
            defaults.set(lastFMNowPlayingEnabled, forKey: Keys.lastFMNowPlaying)
        }
    }
    @Published var listenBrainzEnabled: Bool {
        didSet { defaults.set(listenBrainzEnabled, forKey: Keys.listenBrainzEnabled) }
    }
    @Published var minimumSongDuration: Int {
        didSet {
            let value = min(max(minimumSongDuration, 15), 120)
            if value != minimumSongDuration { minimumSongDuration = value; return }
            defaults.set(value, forKey: Keys.minimumSongDuration)
        }
    }
    @Published var delayPercent: Double {
        didSet {
            let value = min(max(delayPercent, 0.1), 1)
            if value != delayPercent { delayPercent = value; return }
            defaults.set(value, forKey: Keys.delayPercent)
        }
    }
    @Published var maximumDelay: Int {
        didSet {
            let value = min(max(maximumDelay, 30), 300)
            if value != maximumDelay { maximumDelay = value; return }
            defaults.set(value, forKey: Keys.maximumDelay)
        }
    }
    @Published private(set) var lastFMUsername: String
    @Published private(set) var listenBrainzUsername: String
    @Published private(set) var lastFMEndpoint: String
    @Published private(set) var isConnecting = false
    @Published private(set) var connectionError: String?
    @Published private(set) var status: ScrobblingStatus?

    private let defaults: UserDefaults
    private let credentials: ScrobbleCredentialStoring
    private let transport: any ScrobbleHTTPTransport
    private let logger = Logger(subsystem: "com.bitchord.mac", category: "Scrobbling")
    private var active: ActivePlayback?

    private enum SecretKeys {
        static let lastFMAPIKey = "lastfm.apiKey"
        static let lastFMSecret = "lastfm.secret"
        static let lastFMSession = "lastfm.session"
        static let listenBrainzToken = "listenbrainz.token"
    }

    private enum Keys {
        static let lastFMEnabled = "BitChord.lastfm.enabled"
        static let lastFMScrobbleEnabled = "BitChord.lastfm.scrobble"
        static let lastFMNowPlaying = "BitChord.lastfm.nowPlaying"
        static let lastFMUsername = "BitChord.lastfm.username"
        static let lastFMEndpoint = "BitChord.lastfm.endpoint"
        static let listenBrainzEnabled = "BitChord.listenbrainz.enabled"
        static let listenBrainzUsername = "BitChord.listenbrainz.username"
        static let minimumSongDuration = "BitChord.scrobble.minimumDuration"
        static let delayPercent = "BitChord.scrobble.delayPercent"
        static let maximumDelay = "BitChord.scrobble.maximumDelay"
    }

    private struct ActivePlayback {
        let id: String
        var track: ScrobbleTrack
        let startedAt: Date
        var audibleSeconds: TimeInterval = 0
        var lastSampleAt: Date?
        var sentNowPlaying = false
        var submitted = false
    }

    var lastFMConnected: Bool {
        credentials.string(for: SecretKeys.lastFMAPIKey)?.isEmpty == false &&
            credentials.string(for: SecretKeys.lastFMSecret)?.isEmpty == false &&
            credentials.string(for: SecretKeys.lastFMSession)?.isEmpty == false &&
            !lastFMUsername.isEmpty
    }

    var listenBrainzConnected: Bool {
        credentials.string(for: SecretKeys.listenBrainzToken)?.isEmpty == false &&
            !listenBrainzUsername.isEmpty
    }

    init(
        defaults: UserDefaults = .standard,
        credentials: ScrobbleCredentialStoring = KeychainScrobbleCredentialStore(),
        transport: any ScrobbleHTTPTransport = URLSessionScrobbleTransport()
    ) {
        self.defaults = defaults
        self.credentials = credentials
        self.transport = transport
        lastFMEnabled = defaults.object(forKey: Keys.lastFMEnabled) as? Bool ?? false
        lastFMScrobbleEnabled = defaults.object(forKey: Keys.lastFMScrobbleEnabled) as? Bool ?? false
        lastFMNowPlayingEnabled = defaults.object(forKey: Keys.lastFMNowPlaying) as? Bool ?? false
        listenBrainzEnabled = defaults.object(forKey: Keys.listenBrainzEnabled) as? Bool ?? false
        minimumSongDuration = defaults.object(forKey: Keys.minimumSongDuration) as? Int ?? 30
        delayPercent = defaults.object(forKey: Keys.delayPercent) as? Double ?? 0.5
        maximumDelay = defaults.object(forKey: Keys.maximumDelay) as? Int ?? 180
        lastFMUsername = defaults.string(forKey: Keys.lastFMUsername) ?? ""
        listenBrainzUsername = defaults.string(forKey: Keys.listenBrainzUsername) ?? ""
        lastFMEndpoint = defaults.string(forKey: Keys.lastFMEndpoint) ?? LastFMClient.defaultEndpoint
    }

    @discardableResult
    func connectLastFM(
        endpoint: String,
        apiKey: String,
        secret: String,
        username: String,
        password: String
    ) async -> Bool {
        let values = [apiKey, secret, username, password].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard values.allSatisfy({ !$0.isEmpty }) else {
            connectionError = ScrobblingError.missingCredentials.localizedDescription
            return false
        }
        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }
        do {
            let url = try LastFMClient.normalizeEndpoint(endpoint)
            let config = LastFMCredentials(
                endpoint: url,
                apiKey: values[0],
                secret: values[1],
                sessionKey: nil
            )
            let session = try await LastFMClient(credentials: config, transport: transport)
                .mobileSession(username: values[2], password: password)
            do {
                try credentials.set(values[0], for: SecretKeys.lastFMAPIKey)
                try credentials.set(values[1], for: SecretKeys.lastFMSecret)
                try credentials.set(session.key, for: SecretKeys.lastFMSession)
            } catch {
                clearLastFMSecrets()
                throw error
            }
            lastFMUsername = session.username
            lastFMEndpoint = url.absoluteString
            defaults.set(lastFMUsername, forKey: Keys.lastFMUsername)
            defaults.set(lastFMEndpoint, forKey: Keys.lastFMEndpoint)
            lastFMEnabled = true
            lastFMScrobbleEnabled = true
            lastFMNowPlayingEnabled = true
            status = ScrobblingStatus(message: "Connected to Last.fm as \(session.username).", isError: false)
            objectWillChange.send()
            return true
        } catch {
            connectionError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func connectListenBrainz(token: String) async -> Bool {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            connectionError = ScrobblingError.missingCredentials.localizedDescription
            return false
        }
        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }
        do {
            let username = try await ListenBrainzClient(transport: transport).validate(token: clean)
            try credentials.set(clean, for: SecretKeys.listenBrainzToken)
            listenBrainzUsername = username
            defaults.set(username, forKey: Keys.listenBrainzUsername)
            listenBrainzEnabled = true
            status = ScrobblingStatus(message: "Connected to ListenBrainz as \(username).", isError: false)
            objectWillChange.send()
            return true
        } catch {
            connectionError = error.localizedDescription
            return false
        }
    }

    func disconnectLastFM() {
        clearLastFMSecrets()
        lastFMUsername = ""
        defaults.removeObject(forKey: Keys.lastFMUsername)
        lastFMEnabled = false
        lastFMScrobbleEnabled = false
        status = ScrobblingStatus(message: "Disconnected Last.fm.", isError: false)
        objectWillChange.send()
    }

    func disconnectListenBrainz() {
        try? credentials.set(nil, for: SecretKeys.listenBrainzToken)
        listenBrainzUsername = ""
        defaults.removeObject(forKey: Keys.listenBrainzUsername)
        listenBrainzEnabled = false
        status = ScrobblingStatus(message: "Disconnected ListenBrainz.", isError: false)
        objectWillChange.send()
    }

    func clearConnectionError() {
        connectionError = nil
    }

    func playbackStarted(
        track: Track,
        duration: TimeInterval,
        position: TimeInterval,
        now: Date = Date()
    ) {
        ensureActive(track: track, duration: duration, now: now)
        active?.lastSampleAt = now
        guard active?.sentNowPlaying == false, hasNowPlayingDestination,
              let event = active?.track else { return }
        active?.sentNowPlaying = true
        dispatchNowPlaying(event, position: position)
    }

    func playbackPaused(now: Date = Date()) {
        accrue(to: now)
        active?.lastSampleAt = nil
    }

    func playbackSample(
        track: Track,
        duration: TimeInterval,
        position: TimeInterval,
        now: Date = Date()
    ) {
        ensureActive(track: track, duration: duration, now: now)
        if active?.lastSampleAt == nil {
            playbackStarted(track: track, duration: duration, position: position, now: now)
            return
        }
        accrue(to: now)
        guard var current = active, !current.submitted,
              hasScrobbleDestination,
              let duration = current.track.duration,
              let threshold = ScrobbleThreshold.seconds(
                duration: duration,
                minimumSongDuration: minimumSongDuration,
                delayPercent: delayPercent,
                maximumDelay: maximumDelay
              ),
              current.audibleSeconds >= threshold else { return }
        current.submitted = true
        active = current
        dispatchScrobble(current.track, startedAt: current.startedAt)
    }

    func playbackStopped(now: Date = Date()) {
        playbackPaused(now: now)
        active = nil
    }

    func applyPortableSettings(
        lastFMEnabled: Bool,
        lastFMUsername: String,
        lastFMEndpoint: String,
        lastFMScrobbleEnabled: Bool,
        lastFMNowPlaying: Bool,
        listenBrainzEnabled: Bool,
        minimumSongDuration: Int,
        delayPercent: Double,
        maximumDelay: Int
    ) {
        self.lastFMUsername = lastFMUsername
        defaults.set(lastFMUsername, forKey: Keys.lastFMUsername)
        self.lastFMEndpoint = lastFMEndpoint
        defaults.set(lastFMEndpoint, forKey: Keys.lastFMEndpoint)
        self.lastFMEnabled = lastFMEnabled
        self.lastFMScrobbleEnabled = lastFMScrobbleEnabled
        self.lastFMNowPlayingEnabled = lastFMNowPlaying && lastFMScrobbleEnabled
        self.listenBrainzEnabled = listenBrainzEnabled
        self.minimumSongDuration = minimumSongDuration
        self.delayPercent = delayPercent
        self.maximumDelay = maximumDelay
    }

    private var hasNowPlayingDestination: Bool {
        (lastFMConnected && lastFMEnabled && lastFMScrobbleEnabled && lastFMNowPlayingEnabled) ||
            (listenBrainzConnected && listenBrainzEnabled)
    }

    private var hasScrobbleDestination: Bool {
        (lastFMConnected && lastFMEnabled && lastFMScrobbleEnabled) ||
            (listenBrainzConnected && listenBrainzEnabled)
    }

    private func ensureActive(track: Track, duration: TimeInterval, now: Date) {
        let event = ScrobbleTrack(track: track, duration: duration)
        if active?.id != track.id {
            active = ActivePlayback(id: track.id, track: event, startedAt: now)
        } else if event.duration != nil {
            active?.track = event
        }
    }

    private func accrue(to now: Date) {
        guard let last = active?.lastSampleAt else { return }
        // AVPlayer reports every 250 ms. Capping a delayed callback keeps sleep,
        // suspension or a stalled run loop from being counted as audible time.
        let delta = min(max(now.timeIntervalSince(last), 0), 1.5)
        active?.audibleSeconds += delta
        active?.lastSampleAt = now
    }

    private func dispatchNowPlaying(_ track: ScrobbleTrack, position: TimeInterval) {
        let lastFM = lastFMClientIfEnabled(requireNowPlaying: true)
        let listenBrainzToken = listenBrainzEnabled
            ? credentials.string(for: SecretKeys.listenBrainzToken)
            : nil
        guard lastFM != nil || listenBrainzToken != nil else { return }
        Task { [weak self, transport] in
            var failures: [String] = []
            if let lastFM {
                do { try await lastFM.updateNowPlaying(track) }
                catch { failures.append("Last.fm: \(error.localizedDescription)") }
            }
            if let token = listenBrainzToken {
                do {
                    try await ListenBrainzClient(transport: transport)
                        .submitNowPlaying(token: token, track: track, position: position)
                } catch {
                    failures.append("ListenBrainz: \(error.localizedDescription)")
                }
            }
            guard let self, !failures.isEmpty else { return }
            status = ScrobblingStatus(message: failures.joined(separator: "  "), isError: true)
            logger.error("Now-playing submission failed")
        }
    }

    private func dispatchScrobble(_ track: ScrobbleTrack, startedAt: Date) {
        let lastFM = lastFMClientIfEnabled(requireNowPlaying: false)
        let listenBrainzToken = listenBrainzEnabled
            ? credentials.string(for: SecretKeys.listenBrainzToken)
            : nil
        guard lastFM != nil || listenBrainzToken != nil else { return }
        Task { [weak self, transport] in
            var succeeded: [String] = []
            var failures: [String] = []
            if let lastFM {
                do {
                    try await lastFM.scrobble(track, startedAt: startedAt)
                    succeeded.append("Last.fm")
                } catch {
                    failures.append("Last.fm: \(error.localizedDescription)")
                }
            }
            if let token = listenBrainzToken {
                do {
                    try await ListenBrainzClient(transport: transport)
                        .scrobble(token: token, track: track, startedAt: startedAt)
                    succeeded.append("ListenBrainz")
                } catch {
                    failures.append("ListenBrainz: \(error.localizedDescription)")
                }
            }
            guard let self else { return }
            if failures.isEmpty {
                status = ScrobblingStatus(
                    message: "Scrobbled \(track.title) to \(succeeded.joined(separator: " and ")).",
                    isError: false
                )
            } else {
                status = ScrobblingStatus(message: failures.joined(separator: "  "), isError: true)
                logger.error("Scrobble submission failed")
            }
        }
    }

    private func lastFMClientIfEnabled(requireNowPlaying: Bool) -> LastFMClient? {
        guard lastFMEnabled, lastFMScrobbleEnabled,
              !requireNowPlaying || lastFMNowPlayingEnabled,
              let endpoint = try? LastFMClient.normalizeEndpoint(lastFMEndpoint),
              let apiKey = credentials.string(for: SecretKeys.lastFMAPIKey),
              let secret = credentials.string(for: SecretKeys.lastFMSecret),
              let session = credentials.string(for: SecretKeys.lastFMSession),
              !apiKey.isEmpty, !secret.isEmpty, !session.isEmpty else { return nil }
        return LastFMClient(
            credentials: LastFMCredentials(
                endpoint: endpoint,
                apiKey: apiKey,
                secret: secret,
                sessionKey: session
            ),
            transport: transport
        )
    }

    private func clearLastFMSecrets() {
        try? credentials.set(nil, for: SecretKeys.lastFMAPIKey)
        try? credentials.set(nil, for: SecretKeys.lastFMSecret)
        try? credentials.set(nil, for: SecretKeys.lastFMSession)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
