import CommonCrypto
import Foundation

enum JioSaavnError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case noPlayableStream

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "JioSaavn returned an invalid response."
        case .httpStatus(let code): "JioSaavn returned HTTP \(code)."
        case .noPlayableStream: "JioSaavn did not return a playable stream for this track."
        }
    }
}

struct JioSaavnStream: Equatable, Sendable {
    let url: URL
    let kbps: Int?
}

private struct JioSaavnArtist: Decodable {
    let name: String
}

private struct JioSaavnArtistMap: Decodable {
    let primaryArtists: [JioSaavnArtist]

    private enum CodingKeys: String, CodingKey {
        case primaryArtists = "primary_artists"
    }
}

private struct JioSaavnMoreInfo: Decodable {
    let album: String
    let encryptedMediaURL: String
    let duration: String
    let has320Kbps: String
    let artistMap: JioSaavnArtistMap

    var supports320: Bool { has320Kbps.caseInsensitiveCompare("true") == .orderedSame }

    private enum CodingKeys: String, CodingKey {
        case album
        case encryptedMediaURL = "encrypted_media_url"
        case duration
        case has320Kbps = "320kbps"
        case artistMap
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        album = try container.decodeIfPresent(String.self, forKey: .album) ?? ""
        encryptedMediaURL = try container.decodeIfPresent(String.self, forKey: .encryptedMediaURL) ?? ""
        duration = try container.decodeIfPresent(String.self, forKey: .duration) ?? ""
        has320Kbps = try container.decodeIfPresent(String.self, forKey: .has320Kbps) ?? ""
        artistMap = try container.decodeIfPresent(JioSaavnArtistMap.self, forKey: .artistMap)
            ?? JioSaavnArtistMap(primaryArtists: [])
    }
}

private struct JioSaavnSong: Decodable {
    let id: String
    let title: String
    let image: String
    let moreInfo: JioSaavnMoreInfo

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case image
        case moreInfo = "more_info"
    }
}

private struct JioSaavnSearchResponse: Decodable {
    let results: [JioSaavnSong]
}

/// Native port of Android's built-in JioSaavn source. It is deliberately a
/// fixed protocol implementation rather than downloaded code: search and
/// stream resolution remain inspectable in the app, just as on Android.
final class JioSaavnService: @unchecked Sendable {
    private let session: URLSession
    private let endpoint: URL
    private let decoder = JSONDecoder()

    init(
        session: URLSession? = nil,
        endpoint: URL = URL(string: "https://www.jiosaavn.com/api.php")!
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 6
            configuration.timeoutIntervalForResource = 8
            self.session = URLSession(configuration: configuration)
        }
        self.endpoint = endpoint
    }

    func search(query: String, limit: Int = 10) async throws -> [Track] {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        let data = try await request(
            call: "search.getResults",
            parameters: [
                URLQueryItem(name: "q", value: cleaned),
                URLQueryItem(name: "p", value: "1"),
                URLQueryItem(name: "n", value: String(max(1, min(limit, 25))))
            ]
        )
        let response = try decoder.decode(JioSaavnSearchResponse.self, from: data)
        return response.results.prefix(limit).map(Self.track(from:))
    }

    func resolveMatch(for target: Track, quality: AudioQuality = .high) async -> ResolvedStream? {
        if target.catalogSource == .jioSaavn, let trackID = target.catalogTrackID {
            return try? await stream(trackID: trackID, cacheID: target.downloadIdentifier, quality: quality)
        }

        var candidates: [Track] = []
        var seen = Set<String>()
        for query in SourceTrackMatcher.queries(for: target) {
            guard !Task.isCancelled else { return nil }
            let rows = (try? await search(query: query, limit: 10)) ?? []
            for row in rows where seen.insert(row.id).inserted { candidates.append(row) }
            if SourceTrackMatcher.best(candidates, for: target) != nil { break }
        }
        guard let match = SourceTrackMatcher.best(candidates, for: target),
              let trackID = match.catalogTrackID else { return nil }
        return try? await stream(
            trackID: trackID,
            cacheID: target.videoID ?? target.downloadIdentifier,
            quality: quality
        )
    }

    func stream(
        trackID: String,
        cacheID: String?,
        quality: AudioQuality = .high
    ) async throws -> ResolvedStream {
        let (song, offered) = try await songAndStream(trackID: trackID)
        // The Android source refuses 48/96 kbps rungs because they are not an
        // upgrade over YouTube. Preserve that floor on macOS.
        if let kbps = offered.kbps, kbps <= 96 { throw JioSaavnError.noPlayableStream }
        return ResolvedStream(
            url: offered.url,
            headers: [:],
            videoID: cacheID,
            info: AudioStreamInfo(
                requestedQuality: quality,
                bitrateKbps: offered.kbps,
                codec: "AAC",
                sampleRate: nil,
                channels: 2,
                sourceName: "JioSaavn"
            ),
            duration: TimeInterval(song.moreInfo.duration)
        )
    }

    private func songAndStream(trackID: String) async throws -> (JioSaavnSong, JioSaavnStream) {
        let data = try await request(
            call: "song.getDetails",
            parameters: [URLQueryItem(name: "pids", value: trackID)]
        )
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JioSaavnError.invalidResponse
        }
        let rawSong: Any?
        if let keyed = root[trackID] {
            rawSong = keyed
        } else if let songs = root["songs"] as? [Any] {
            rawSong = songs.first
        } else {
            rawSong = root.values.first { $0 is [String: Any] }
        }
        guard let rawSong,
              JSONSerialization.isValidJSONObject(rawSong),
              let encoded = try? JSONSerialization.data(withJSONObject: rawSong),
              let song = try? decoder.decode(JioSaavnSong.self, from: encoded),
              let stream = Self.bestStream(
                encryptedMediaURL: song.moreInfo.encryptedMediaURL,
                supports320: song.moreInfo.supports320
              ) else {
            throw JioSaavnError.noPlayableStream
        }
        return (song, stream)
    }

    private func request(call: String, parameters: [URLQueryItem]) async throws -> Data {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw JioSaavnError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "__call", value: call),
            URLQueryItem(name: "_format", value: "json"),
            URLQueryItem(name: "_marker", value: "0"),
            URLQueryItem(name: "api_version", value: "4"),
            URLQueryItem(name: "ctx", value: "android")
        ] + parameters
        guard let url = components.url else { throw JioSaavnError.invalidResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("49.36.0.1", forHTTPHeaderField: "X-Forwarded-For")
        request.setValue("49.36.0.1", forHTTPHeaderField: "X-Real-IP")
        request.setValue("en-IN,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("explicit_content=1", forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JioSaavnError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw JioSaavnError.httpStatus(http.statusCode) }
        return data
    }

    static func bestStream(encryptedMediaURL: String, supports320: Bool) -> JioSaavnStream? {
        guard let decrypted = decryptMediaURL(encryptedMediaURL),
              let originalURL = URL(string: decrypted) else { return nil }
        let pattern = #"_(48|96|160|320)\.(mp4|aac|mp3)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(
                in: decrypted,
                range: NSRange(decrypted.startIndex..., in: decrypted)
              ),
              let bitrateRange = Range(match.range(at: 1), in: decrypted),
              let offeredKbps = Int(decrypted[bitrateRange]) else {
            return JioSaavnStream(url: originalURL, kbps: supports320 ? 320 : nil)
        }
        guard supports320,
              let suffixRange = Range(match.range, in: decrypted),
              let extensionRange = Range(match.range(at: 2), in: decrypted) else {
            return JioSaavnStream(url: originalURL, kbps: offeredKbps)
        }
        let upgraded = decrypted.replacingCharacters(
            in: suffixRange,
            with: "_320.\(decrypted[extensionRange])"
        )
        guard let upgradedURL = URL(string: upgraded) else { return nil }
        return JioSaavnStream(url: upgradedURL, kbps: 320)
    }

    static func decryptMediaURL(_ encrypted: String) -> String? {
        guard !encrypted.isEmpty, let input = Data(base64Encoded: encrypted) else { return nil }
        let key = Data("38346591".utf8)
        let outputCapacity = input.count + kCCBlockSizeDES
        var output = Data(count: outputCapacity)
        var outputCount = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmDES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        inputBytes.baseAddress,
                        input.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &outputCount
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.count = outputCount
        return String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func track(from song: JioSaavnSong) -> Track {
        let artists = song.moreInfo.artistMap.primaryArtists
            .map(\.name)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return Track(
            videoID: nil,
            title: decodedText(song.title),
            artist: decodedText(artists.isEmpty ? "Unknown Artist" : artists),
            album: decodedText(song.moreInfo.album),
            artworkURL: upgradedArtworkURL(song.image),
            duration: TimeInterval(song.moreInfo.duration),
            localPath: nil,
            sourceURL: nil,
            catalogSource: .jioSaavn,
            catalogTrackID: song.id
        )
    }

    private static func upgradedArtworkURL(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        return value
            .replacingOccurrences(of: "http://", with: "https://")
            .replacingOccurrences(of: "150x150", with: "500x500")
            .replacingOccurrences(of: "50x50", with: "500x500")
    }

    private static func decodedText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
