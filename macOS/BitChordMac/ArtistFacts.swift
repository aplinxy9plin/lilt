import Foundation
import os

protocol ArtistFactsHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionArtistFactsTransport: ArtistFactsHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ArtistFactsError.invalidResponse
        }
        return (data, response)
    }
}

enum ArtistFactsSource: String, Codable, Sendable {
    case lastFM = "lastfm"
    case musicBrainz = "musicbrainz"

    var title: String {
        switch self {
        case .lastFM: "Last.fm"
        case .musicBrainz: "MusicBrainz"
        }
    }
}

struct ArtistFactsStatus: Equatable, Sendable {
    let enabled: Bool
    let cachedArtists: Int
    let queuedArtists: Int
    let lastSource: ArtistFactsSource?
    let lastError: String?

    var subtitle: String {
        guard enabled else { return "Replay's genre chart is hidden" }
        if queuedArtists > 0 {
            return "Working out genres · \(queuedArtists) artist\(queuedArtists == 1 ? "" : "s") left"
        }
        if cachedArtists > 0 {
            let source = lastSource.map { " · \($0.title)" } ?? ""
            return "\(cachedArtists) artist\(cachedArtists == 1 ? "" : "s") cached\(source)"
        }
        if let lastError { return lastError }
        return "Only artist names are sent; listening history stays on this Mac"
    }
}

enum ArtistFactsError: LocalizedError {
    case invalidURL
    case invalidResponse
    case http(Int)
    case noMatchingArtist

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The genre service URL is invalid."
        case .invalidResponse: "The genre service returned unreadable data."
        case .http(let status): "Genre lookup returned HTTP \(status)."
        case .noMatchingArtist: "No exact artist match was found."
        }
    }
}

struct StoredArtistFacts: Codable, Equatable, Sendable {
    let key: String
    var genres: [String]
    var genresAt: Int64
    var image: String?
    var browseId: String?
    var cardAt: Int64
    var genreSource: ArtistFactsSource?

    init(
        key: String,
        genres: [String] = [],
        genresAt: Int64 = 0,
        image: String? = nil,
        browseId: String? = nil,
        cardAt: Int64 = 0,
        genreSource: ArtistFactsSource? = nil
    ) {
        self.key = key
        self.genres = genres
        self.genresAt = genresAt
        self.image = image
        self.browseId = browseId
        self.cardAt = cardAt
        self.genreSource = genreSource
    }

    private enum CodingKeys: String, CodingKey {
        case key, genres, genresAt, image, browseId, cardAt, genreSource
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        genres = try values.decodeIfPresent([String].self, forKey: .genres) ?? []
        genresAt = try values.decodeIfPresent(Int64.self, forKey: .genresAt) ?? 0
        image = try values.decodeIfPresent(String.self, forKey: .image)
        browseId = try values.decodeIfPresent(String.self, forKey: .browseId)
        cardAt = try values.decodeIfPresent(Int64.self, forKey: .cardAt) ?? 0
        genreSource = try values.decodeIfPresent(ArtistFactsSource.self, forKey: .genreSource)
    }
}

private struct StoredArtistFactsEnvelope: Codable, Sendable {
    var version = 2
    var artists: [StoredArtistFacts] = []
}

/// On-device artist enrichment matching Android's ArtistFacts behavior.
/// Reads are always local; slow service calls run serially in the background.
actor ArtistFactsStore {
    typealias LastFMConfigurationProvider = @Sendable () -> (endpoint: URL, apiKey: String)?

    static let settingKey = "replay_genres"
    static let requestSpacingNanoseconds: UInt64 = 1_500_000_000

    private let fileURL: URL
    private let transport: any ArtistFactsHTTPTransport
    private let now: @Sendable () -> Date
    private let lastFMConfigurationProvider: LastFMConfigurationProvider?
    private let requestSpacing: UInt64
    private let logger = Logger(subsystem: "com.bitchord.mac", category: "ArtistFacts")

    private var enabled: Bool
    private var known: [String: StoredArtistFacts]
    private var queuedNames: [String] = []
    private var queuedKeys = Set<String>()
    private var worker: Task<Void, Never>?
    private var revision = 0
    private var observers: [UUID: AsyncStream<Int>.Continuation] = [:]
    private var lastSource: ArtistFactsSource?
    private var lastError: String?

    init(
        directory: URL? = nil,
        enabled: Bool = true,
        transport: any ArtistFactsHTTPTransport = URLSessionArtistFactsTransport(),
        now: @escaping @Sendable () -> Date = { Date() },
        lastFMConfigurationProvider: LastFMConfigurationProvider? = nil,
        requestSpacingNanoseconds: UInt64 = ArtistFactsStore.requestSpacingNanoseconds
    ) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitChord", isDirectory: true)
        fileURL = root.appendingPathComponent("artist_facts.json")
        self.enabled = enabled
        self.transport = transport
        self.now = now
        self.lastFMConfigurationProvider = lastFMConfigurationProvider
        requestSpacing = requestSpacingNanoseconds

        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode(StoredArtistFactsEnvelope.self, from: data) {
            known = Dictionary(uniqueKeysWithValues: stored.artists.map { ($0.key, $0) })
            lastSource = stored.artists.max(by: { $0.genresAt < $1.genresAt })?.genreSource
        } else {
            known = [:]
        }
    }

    deinit {
        worker?.cancel()
        observers.values.forEach { $0.finish() }
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if !value {
            queuedNames.removeAll()
            queuedKeys.removeAll()
            worker?.cancel()
            worker = nil
        }
        publishRevision()
    }

    func status() -> ArtistFactsStatus {
        ArtistFactsStatus(
            enabled: enabled,
            cachedArtists: known.values.filter { !$0.genres.isEmpty }.count,
            queuedArtists: queuedNames.count + (worker == nil ? 0 : 1),
            lastSource: lastSource,
            lastError: lastError
        )
    }

    func revisions() -> AsyncStream<Int> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.yield(revision)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    func warm(artists: [String]) {
        guard enabled else { return }
        for artist in artists.prefix(50) { enqueue(artist) }
        startWorkerIfNeeded()
    }

    func notice(_ rawArtist: String) {
        guard enabled else { return }
        enqueue(rawArtist)
        startWorkerIfNeeded()
    }

    func applyingGenres(to summary: ReplaySummary) -> ReplaySummary {
        var aggregated: [String: ReplayNamedStat] = [:]
        if enabled {
            for artist in summary.artists {
                for genre in known[Self.key(artist.title)]?.genres ?? [] {
                    let genreKey = Self.key(genre)
                    let current = aggregated[genreKey]
                    aggregated[genreKey] = ReplayNamedStat(
                        id: genreKey,
                        title: current?.title ?? genre,
                        subtitle: nil,
                        artworkURL: nil,
                        milliseconds: (current?.milliseconds ?? 0) + artist.milliseconds,
                        plays: (current?.plays ?? 0) + artist.plays
                    )
                }
            }
        }
        let genres = aggregated.values.sorted {
            if $0.milliseconds != $1.milliseconds { return $0.milliseconds > $1.milliseconds }
            if $0.plays != $1.plays { return $0.plays > $1.plays }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        return ReplaySummary(
            period: summary.period,
            totalMilliseconds: summary.totalMilliseconds,
            totalPlays: summary.totalPlays,
            tracks: summary.tracks,
            artists: summary.artists,
            albums: summary.albums,
            genres: genres,
            busiestHour: summary.busiestHour,
            busiestHourMilliseconds: summary.busiestHourMilliseconds,
            busiestDay: summary.busiestDay,
            busiestDayMilliseconds: summary.busiestDayMilliseconds,
            memberSince: summary.memberSince
        )
    }

    static func canonicalGenre(_ raw: String) -> String? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        cleaned = cleaned.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "&", with: "and")
        cleaned = cleaned.unicodeScalars.map { scalar -> Character in
            Character(CharacterSet.alphanumerics.contains(scalar) || scalar == " " ? scalar : " ")
        }.reduce(into: "") { $0.append($1) }
        cleaned = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        let canonical = aliases[cleaned] ?? cleaned
        return vocabulary[canonical]
    }

    static func canonicalGenres(from tags: [(name: String, count: Int?)]) -> [String] {
        var seen = Set<String>()
        return tags.enumerated()
            .sorted {
                let lhs = $0.element.count ?? 0
                let rhs = $1.element.count ?? 0
                return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
            }
            .compactMap { canonicalGenre($0.element.name) }
            .filter { seen.insert($0).inserted }
            .prefix(2)
            .map { $0 }
    }

    private func enqueue(_ rawArtist: String) {
        let artist = Self.primaryArtist(rawArtist)
        let artistKey = Self.key(artist)
        guard !artistKey.isEmpty, artistKey.count <= 120,
              shouldRequest(artistKey), queuedKeys.insert(artistKey).inserted else { return }
        queuedNames.append(artist)
    }

    private func shouldRequest(_ artistKey: String) -> Bool {
        guard let entry = known[artistKey] else { return true }
        let age = Int64(now().timeIntervalSince1970 * 1_000) - entry.genresAt
        return entry.genres.isEmpty && age > 14 * 24 * 60 * 60 * 1_000
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !queuedNames.isEmpty else { return }
        worker = Task { [weak self] in await self?.workerLoop() }
    }

    private func workerLoop() async {
        while enabled, !Task.isCancelled, !queuedNames.isEmpty {
            let artist = queuedNames.removeFirst()
            let artistKey = Self.key(artist)
            do {
                let result = try await fetchGenres(for: artist)
                let timestamp = Int64(now().timeIntervalSince1970 * 1_000)
                var entry = known[artistKey] ?? StoredArtistFacts(key: artistKey)
                entry.genres = result.genres
                entry.genresAt = timestamp
                entry.genreSource = result.source
                known[artistKey] = entry
                lastSource = result.source
                lastError = nil
                save()
                publishRevision()
            } catch ArtistFactsError.noMatchingArtist {
                // A real miss is cached too. Otherwise an artist absent from
                // both catalogues would be retried on every app launch.
                let timestamp = Int64(now().timeIntervalSince1970 * 1_000)
                var entry = known[artistKey] ?? StoredArtistFacts(key: artistKey)
                entry.genres = []
                entry.genresAt = timestamp
                entry.genreSource = .musicBrainz
                known[artistKey] = entry
                lastSource = .musicBrainz
                lastError = nil
                save()
                publishRevision()
            } catch {
                lastError = error.localizedDescription
                logger.warning("Genre lookup failed for \(artist, privacy: .private): \(error.localizedDescription, privacy: .public)")
                publishRevision()
            }
            if !queuedNames.isEmpty, requestSpacing > 0 {
                try? await Task.sleep(nanoseconds: requestSpacing)
            }
        }
        worker = nil
        publishRevision()
    }

    private func fetchGenres(for artist: String) async throws -> (genres: [String], source: ArtistFactsSource) {
        if let configuration = configuredLastFM() {
            do {
                let tags = try await lastFMTags(for: artist, configuration: configuration)
                let genres = Self.canonicalGenres(from: tags)
                if !genres.isEmpty { return (genres, .lastFM) }
            } catch {
                logger.debug("Last.fm genre lookup fell back to MusicBrainz")
            }
        }
        let tags = try await musicBrainzTags(for: artist)
        return (Self.canonicalGenres(from: tags), .musicBrainz)
    }

    private func configuredLastFM() -> (endpoint: URL, apiKey: String)? {
        if let injected = lastFMConfigurationProvider?() { return injected }
        let credentials = KeychainScrobbleCredentialStore()
        guard let apiKey = credentials.string(for: "lastfm.apiKey")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else { return nil }
        let rawEndpoint = UserDefaults.standard.string(forKey: "BitChord.lastfm.endpoint")
            ?? LastFMClient.defaultEndpoint
        guard let endpoint = try? LastFMClient.normalizeEndpoint(rawEndpoint) else { return nil }
        return (endpoint, apiKey)
    }

    private func lastFMTags(
        for artist: String,
        configuration: (endpoint: URL, apiKey: String)
    ) async throws -> [(name: String, count: Int?)] {
        guard var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false) else {
            throw ArtistFactsError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "method", value: "artist.gettoptags"),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "api_key", value: configuration.apiKey),
            URLQueryItem(name: "autocorrect", value: "1"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else { throw ArtistFactsError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.data(for: request)
        guard 200..<300 ~= response.statusCode else { throw ArtistFactsError.http(response.statusCode) }
        let decoded = try JSONDecoder().decode(LastFMTopTagsResponse.self, from: data)
        if let returned = decoded.topTags.attributes?.artist,
           Self.key(returned) != Self.key(artist) {
            throw ArtistFactsError.noMatchingArtist
        }
        return decoded.topTags.tags.map { ($0.name, nil) }
    }

    private func musicBrainzTags(for artist: String) async throws -> [(name: String, count: Int?)] {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/artist/")
        components?.queryItems = [
            URLQueryItem(name: "query", value: artist),
            URLQueryItem(name: "dismax", value: "true"),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = components?.url else { throw ArtistFactsError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.data(for: request)
        guard 200..<300 ~= response.statusCode else { throw ArtistFactsError.http(response.statusCode) }
        let decoded = try JSONDecoder().decode(MusicBrainzArtistSearchResponse.self, from: data)
        guard let match = decoded.artists.first(where: {
            Self.key($0.name) == Self.key(artist) && ($0.score ?? 100) >= 85
        }) else {
            throw ArtistFactsError.noMatchingArtist
        }
        return (match.tags ?? []).map { ($0.name, $0.count) }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let artists = known.values.sorted {
                max($0.genresAt, $0.cardAt) > max($1.genresAt, $1.cardAt)
            }.prefix(4_000)
            let envelope = StoredArtistFactsEnvelope(artists: Array(artists))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(envelope).write(to: fileURL, options: .atomic)
        } catch {
            logger.warning("Could not save artist facts: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func publishRevision() {
        revision &+= 1
        observers.values.forEach { $0.yield(revision) }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private static func primaryArtist(_ raw: String) -> String {
        let artist = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = [" feat.", " featuring ", " ft.", " & ", " x ", " vs. ", ","]
        let ranges = separators.compactMap {
            artist.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])
        }
        guard let first = ranges.min(by: { $0.lowerBound < $1.lowerBound }) else { return artist }
        return String(artist[..<first.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func key(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static let userAgent = "Lilt/1.0 (macOS)"

    private static let spellings: [String: String] = [
        "randb": "R&B", "edm": "EDM", "lo fi": "Lo-Fi", "hip hop": "Hip-Hop",
        "k pop": "K-Pop", "j pop": "J-Pop", "j rock": "J-Rock", "c pop": "C-Pop",
        "drum and bass": "Drum & Bass", "singer songwriter": "Singer-Songwriter",
        "post punk": "Post-Punk", "post rock": "Post-Rock", "bossa nova": "Bossa Nova"
    ]

    private static let vocabulary: [String: String] = {
        let values = [
            "pop", "rock", "hip hop", "rap", "randb", "soul", "funk", "jazz", "blues",
            "country", "folk", "indie", "indie pop", "indie rock", "alternative",
            "alternative rock", "metal", "heavy metal", "punk", "punk rock", "hardcore",
            "electronic", "house", "deep house", "techno", "trance", "dubstep",
            "drum and bass", "edm", "ambient", "lo fi", "synthpop", "disco",
            "classical", "opera", "soundtrack", "instrumental", "acoustic",
            "reggae", "reggaeton", "dancehall", "ska", "latin", "salsa", "bossa nova",
            "afrobeats", "afrobeat", "k pop", "j pop", "j rock", "c pop",
            "bollywood", "punjabi", "desi", "bhangra", "hindi", "sufi", "ghazal",
            "singer songwriter", "emo", "grunge", "shoegaze", "psychedelic",
            "progressive rock", "hard rock", "garage rock", "post punk", "new wave",
            "gospel", "christian", "world", "experimental", "trap", "drill", "grime",
            "phonk", "hyperpop", "chillout", "downtempo", "jungle", "garage",
            "bluegrass", "americana", "swing", "big band", "motown", "britpop",
            "dream pop", "art pop", "noise", "industrial", "gothic", "doom metal",
            "black metal", "death metal", "thrash metal", "metalcore", "post rock",
            "math rock", "jam band", "surf rock", "rockabilly", "boom bap",
            "cloud rap", "conscious hip hop", "west coast rap", "east coast rap"
        ]
        return Dictionary(uniqueKeysWithValues: values.map { value in
            let display = spellings[value] ?? value.split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
            return (value, display)
        })
    }()

    private static let aliases: [String: String] = [
        "rnb": "randb", "r and b": "randb", "rhythm and blues": "randb",
        "contemporary randb": "randb", "hiphop": "hip hop", "hip hop rap": "hip hop",
        "lofi": "lo fi", "lo fi hip hop": "lo fi", "chillhop": "lo fi",
        "kpop": "k pop", "jpop": "j pop", "jrock": "j rock", "cpop": "c pop",
        "korean": "k pop", "dnb": "drum and bass", "drum n bass": "drum and bass",
        "drumandbass": "drum and bass", "electronica": "electronic", "electro": "electronic",
        "dance": "electronic", "electropop": "synthpop", "synth pop": "synthpop",
        "indierock": "indie rock", "indiepop": "indie pop", "alt rock": "alternative rock",
        "altrock": "alternative rock", "singersongwriter": "singer songwriter",
        "female vocalists": "pop", "hindi pop": "bollywood", "indian": "desi",
        "filmi": "bollywood", "afro beats": "afrobeats", "afropop": "afrobeats",
        "amapiano": "afrobeats", "regueton": "reggaeton", "latin pop": "latin",
        "trip hop": "downtempo", "nu metal": "metal", "classic rock": "rock",
        "soft rock": "rock", "pop rock": "rock", "pop punk": "punk",
        "hardcore punk": "hardcore", "orchestral": "classical", "film score": "soundtrack",
        "score": "soundtrack", "ost": "soundtrack", "chill": "chillout",
        "chillwave": "chillout", "worship": "christian", "rap rock": "rap",
        "gangsta rap": "rap", "underground hip hop": "hip hop"
    ]
}

private struct LastFMTopTagsResponse: Decodable {
    let topTags: TopTags

    enum CodingKeys: String, CodingKey { case topTags = "toptags" }

    struct TopTags: Decodable {
        let tags: [Tag]
        let attributes: Attributes?

        enum CodingKeys: String, CodingKey {
            case tags = "tag"
            case attributes = "@attr"
        }
    }

    struct Tag: Decodable { let name: String }
    struct Attributes: Decodable { let artist: String? }
}

private struct MusicBrainzArtistSearchResponse: Decodable {
    let artists: [Artist]

    struct Artist: Decodable {
        let score: Int?
        let name: String
        let tags: [Tag]?
    }

    struct Tag: Decodable {
        let count: Int?
        let name: String
    }
}
