import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

enum CanvasSource: String, Codable, Sendable {
    case appleMusic
    case tidal
    case community
    case spotify

    var title: String {
        switch self {
        case .appleMusic: "Apple Music Motion"
        case .tidal: "TIDAL Video Cover"
        case .community: "Community Canvas"
        case .spotify: "Spotify Canvas"
        }
    }
}

struct CanvasArtwork: Equatable, Sendable {
    let url: URL
    let fallbackURL: URL?
    let title: String?
    let artist: String?
    let album: String?
    let source: CanvasSource
    let cachedURL: URL?
    let cachedFallbackURL: URL?

    init?(
        url: URL,
        fallbackURL: URL? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        source: CanvasSource,
        cachedURL: URL? = nil,
        cachedFallbackURL: URL? = nil
    ) {
        guard Self.isSafeRemoteVideoURL(url) else { return nil }
        self.url = url
        self.fallbackURL = fallbackURL.flatMap { Self.isSafeRemoteVideoURL($0) ? $0 : nil }
        self.title = title
        self.artist = artist
        self.album = album
        self.source = source
        self.cachedURL = cachedURL.flatMap { $0.isFileURL ? $0 : nil }
        self.cachedFallbackURL = cachedFallbackURL.flatMap { $0.isFileURL ? $0 : nil }
    }

    var playbackURL: URL { cachedURL ?? url }
    var playbackFallbackURL: URL? { cachedFallbackURL ?? fallbackURL }

    func usingCached(primary: URL?, fallback: URL? = nil) -> CanvasArtwork {
        CanvasArtwork(
            url: url,
            fallbackURL: fallbackURL,
            title: title,
            artist: artist,
            album: album,
            source: source,
            cachedURL: primary,
            cachedFallbackURL: fallback
        ) ?? self
    }

    func matches(title wantedTitle: String, artist wantedArtist: String, album wantedAlbum: String?) -> Bool {
        let titleMatches = title == nil || wantedTitle.isEmpty ||
            title?.canvasNormalized == wantedTitle.canvasNormalized

        let wantedArtists = CanvasMatching.splitArtists(wantedArtist)
        let creditedArtists = CanvasMatching.splitArtists(artist ?? "")
        let artistMatches = artist == nil || wantedArtist.isEmpty ||
            (!wantedArtists.isEmpty && !creditedArtists.isEmpty &&
                wantedArtists.allSatisfy { wanted in creditedArtists.contains(wanted) })

        let albumMatches = album?.isEmpty != false || wantedAlbum?.isEmpty != false ||
            album?.canvasNormalized == wantedAlbum?.canvasNormalized
        return titleMatches && artistMatches && albumMatches
    }

    private static func isSafeRemoteVideoURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            return false
        }
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty || ["mp4", "m3u8", "mov"].contains(ext)
    }
}

enum CanvasMatching {
    static func splitArtists(_ raw: String) -> [String] {
        let separators = #"(?:\s*,\s*|\s*&\s*|\s+×\s+|\s+x\s+|\bfeat\.?\b|\bft\.?\b|\bfeaturing\b|\bwith\b)"#
        let divided = raw.replacingOccurrences(
            of: separators,
            with: "\u{001F}",
            options: [.regularExpression, .caseInsensitive]
        )
        return divided.split(separator: "\u{001F}")
            .map { String($0).canvasNormalized }
            .filter { !$0.isEmpty }
    }

    static func cleanedTitle(_ value: String) -> String {
        let noise = #"\((?:from|official|lyrical|video|audio)[^)]*\)|\[[^]]*\]|\b(?:official (?:video|audio|music video)|lyrical|full song|4k video)\b"#
        let cleaned = value
            .replacingOccurrences(of: noise, with: " ", options: [.regularExpression, .caseInsensitive])
            .components(separatedBy: " | ").first ?? value
        return cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension String {
    var canvasNormalized: String {
        let folded = folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar)
                ? String(scalar)
                : " "
        }.joined()
        return scalars.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

struct CanvasHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

protocol CanvasHTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> CanvasHTTPResponse
}

struct URLSessionCanvasHTTPClient: CanvasHTTPClient {
    func get(_ url: URL, headers: [String: String]) async throws -> CanvasHTTPResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .returnCacheDataElseLoad
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return CanvasHTTPResponse(data: Data(), statusCode: -1)
        }
        return CanvasHTTPResponse(data: data, statusCode: http.statusCode)
    }
}

protocol CanvasProvider: Sendable {
    func canvas(title: String, artist: String, album: String?) async -> CanvasArtwork?
    func albumCanvas(album: String, artist: String) async -> CanvasArtwork?
}

extension CanvasProvider {
    func albumCanvas(album: String, artist: String) async -> CanvasArtwork? { nil }
}

actor TidalCanvasProvider: CanvasProvider {
    static let embedToken = "vNVdglQOjFJJGG2U"
    private let http: any CanvasHTTPClient
    private let countryCode: String

    init(http: any CanvasHTTPClient, countryCode: String = Locale.current.region?.identifier ?? "US") {
        self.http = http
        self.countryCode = countryCode.count == 2 ? countryCode.uppercased() : "US"
    }

    func canvas(title: String, artist: String, album: String?) async -> CanvasArtwork? {
        var regions = [countryCode]
        if countryCode != "US" { regions.append("US") }
        for region in regions {
            if let artwork = await search(title: title, artist: artist, album: album, countryCode: region) {
                return artwork
            }
        }
        return nil
    }

    func albumCanvas(album: String, artist: String) async -> CanvasArtwork? {
        var regions = [countryCode]
        if countryCode != "US" { regions.append("US") }
        for region in regions {
            let query = "\(album) \(artist)"
            guard let url = Self.searchURL(query: query, type: "ALBUMS", countryCode: region),
                  let response = try? await http.get(url, headers: [
                    "X-Tidal-Token": Self.embedToken,
                    "User-Agent": CanvasUserAgent.browser
                  ]),
                  (200..<300).contains(response.statusCode),
                  let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let albums = root["albums"] as? [String: Any],
                  let items = albums["items"] as? [[String: Any]] else { continue }
            for item in items {
                guard let hitTitle = item["title"] as? String,
                      let artists = item["artists"] as? [[String: Any]] else { continue }
                let credits = artists.compactMap { $0["name"] as? String }
                guard Self.isMatch(name: hitTitle, artists: credits, wantedName: album, wantedArtist: artist),
                      let videoCover = item["videoCover"] as? String,
                      let videoURL = Self.coverURL(id: videoCover) else { continue }
                return CanvasArtwork(
                    url: videoURL,
                    title: hitTitle,
                    artist: credits.joined(separator: ", "),
                    album: hitTitle,
                    source: .tidal
                )
            }
        }
        return nil
    }

    private func search(title: String, artist: String, album: String?, countryCode: String) async -> CanvasArtwork? {
        let query = [album, artist, title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
        guard let url = Self.searchURL(query: query, countryCode: countryCode),
              let response = try? await http.get(url, headers: [
                "X-Tidal-Token": Self.embedToken,
                "User-Agent": CanvasUserAgent.browser
              ]),
              (200..<300).contains(response.statusCode),
              let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let tracks = root["tracks"] as? [String: Any],
              let items = tracks["items"] as? [[String: Any]] else { return nil }

        for item in items {
            guard let hitTitle = item["title"] as? String,
                  let artists = item["artists"] as? [[String: Any]] else { continue }
            let credits = artists.compactMap { $0["name"] as? String }
            guard Self.isMatch(name: hitTitle, artists: credits, wantedName: title, wantedArtist: artist),
                  let albumObject = item["album"] as? [String: Any],
                  let videoCover = albumObject["videoCover"] as? String,
                  let videoURL = Self.coverURL(id: videoCover) else { continue }
            return CanvasArtwork(
                url: videoURL,
                title: hitTitle,
                artist: credits.joined(separator: ", "),
                album: albumObject["title"] as? String,
                source: .tidal
            )
        }
        return nil
    }

    static func coverURL(id: String) -> URL? {
        let parts = id.split(separator: "-")
        guard parts.count == 5 else { return nil }
        return URL(string: "https://resources.tidal.com/videos/\(parts.joined(separator: "/"))/1280x1280.mp4")
    }

    static func searchURL(query: String, countryCode: String) -> URL? {
        searchURL(query: query, type: "TRACKS", countryCode: countryCode)
    }

    static func searchURL(query: String, type: String, countryCode: String) -> URL? {
        var components = URLComponents(string: "https://api.tidal.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "types", value: type),
            URLQueryItem(name: "countryCode", value: countryCode)
        ]
        return components?.url
    }

    static func isMatch(name: String, artists: [String], wantedName: String, wantedArtist: String) -> Bool {
        guard name.canvasNormalized == wantedName.canvasNormalized else { return false }
        let wanted = CanvasMatching.splitArtists(wantedArtist)
        let credited = artists.map(\.canvasNormalized).filter { !$0.isEmpty }
        return !wanted.isEmpty && !credited.isEmpty && wanted.allSatisfy(credited.contains)
    }
}

actor CommunityCanvasProvider: CanvasProvider {
    private struct Entry: Sendable {
        let song: String
        let artist: String
        let album: String
        let url: URL
    }

    private static let manifestURL = URL(string: "https://vivimusicanvas.mkmdevilmi.workers.dev/canvas.json")!
    private static let ttl: TimeInterval = 30 * 60
    private let http: any CanvasHTTPClient
    private var entries: [Entry] = []
    private var fetchedAt = Date.distantPast

    init(http: any CanvasHTTPClient) {
        self.http = http
    }

    func canvas(title: String, artist: String, album: String?) async -> CanvasArtwork? {
        let index = await manifest()
        let wantedTitle = title.canvasNormalized
        let wantedArtist = artist.canvasNormalized
        let wantedAlbum = album?.canvasNormalized

        guard let hit = index.first(where: { entry in
            let song = entry.song.canvasNormalized
            let credit = entry.artist.canvasNormalized
            let listedAlbum = entry.album.canvasNormalized
            let titleMatches = !song.isEmpty && (wantedTitle.contains(song) || song.contains(wantedTitle))
            let artistMatches = !credit.isEmpty && (wantedArtist.contains(credit) || credit.contains(wantedArtist))
            let albumMatches = listedAlbum.isEmpty || wantedAlbum?.isEmpty != false || listedAlbum == wantedAlbum
            return titleMatches && artistMatches && albumMatches
        }) else { return nil }

        return CanvasArtwork(
            url: hit.url,
            title: hit.song,
            artist: hit.artist,
            album: hit.album.isEmpty ? nil : hit.album,
            source: .community
        )
    }

    func albumCanvas(album: String, artist: String) async -> CanvasArtwork? {
        let index = await manifest()
        let wantedAlbum = album.canvasNormalized
        let wantedArtist = artist.canvasNormalized
        guard !wantedAlbum.isEmpty else { return nil }
        guard let hit = index.first(where: { entry in
            let listedAlbum = entry.album.canvasNormalized
            let credited = entry.artist.canvasNormalized
            return listedAlbum == wantedAlbum && !credited.isEmpty &&
                (wantedArtist.contains(credited) || credited.contains(wantedArtist))
        }) else { return nil }
        return CanvasArtwork(
            url: hit.url,
            title: hit.album,
            artist: hit.artist,
            album: hit.album,
            source: .community
        )
    }

    private func manifest(now: Date = Date()) async -> [Entry] {
        if !entries.isEmpty, now.timeIntervalSince(fetchedAt) < Self.ttl { return entries }
        defer { fetchedAt = now }
        guard let response = try? await http.get(Self.manifestURL, headers: ["User-Agent": CanvasUserAgent.browser]),
              (200..<300).contains(response.statusCode),
              let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return entries }
        let parsed = items.compactMap { item -> Entry? in
            guard let song = item["song"] as? String,
                  let artist = item["artist"] as? String,
                  let rawURL = item["url"] as? String,
                  let url = URL(string: rawURL),
                  CanvasArtwork(url: url, source: .community) != nil else { return nil }
            return Entry(song: song, artist: artist, album: item["album"] as? String ?? "", url: url)
        }
        if !parsed.isEmpty { entries = parsed }
        return entries
    }
}

actor AppleMusicCanvasProvider: CanvasProvider {
    private static let webPlayer = URL(string: "https://music.apple.com/us/browse")!
    private static let tokenRetry: TimeInterval = 30 * 60
    private static let minimumScore = 12
    private let http: any CanvasHTTPClient
    private let storefront: String
    private var cachedToken: String?
    private var tokenExpiry = Date.distantPast
    private var retryAfter = Date.distantPast
    private var rejectedTokens = Set<String>()

    init(http: any CanvasHTTPClient, storefront: String = Locale.current.region?.identifier ?? "US") {
        self.http = http
        self.storefront = storefront.count == 2 ? storefront.lowercased() : "us"
    }

    func canvas(title: String, artist: String, album: String?) async -> CanvasArtwork? {
        guard let bearer = await token() else { return nil }
        let term = [artist, title, album].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
        var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "extend", value: "editorialVideo"),
            URLQueryItem(name: "include", value: "albums")
        ]
        guard let url = components?.url,
              let root = await catalogJSON(url: url, bearer: bearer),
              let results = root["results"] as? [String: Any],
              let songs = results["songs"] as? [String: Any],
              let data = songs["data"] as? [[String: Any]] else { return nil }

        let ranked = data.compactMap { item -> (Int, [String: Any])? in
            guard let score = Self.score(item, title: title, artist: artist, album: album) else { return nil }
            return (score, item)
        }.sorted { $0.0 > $1.0 }

        for (score, song) in ranked where score >= Self.minimumScore {
            guard let attributes = song["attributes"] as? [String: Any] else { continue }
            let hitTitle = attributes["name"] as? String
            let hitArtist = attributes["artistName"] as? String
            let hitAlbum = attributes["albumName"] as? String
            if let editorial = attributes["editorialVideo"] as? [String: Any],
               let links = Self.motionURLs(editorial) {
                return CanvasArtwork(
                    url: links.0,
                    fallbackURL: links.1,
                    title: hitTitle,
                    artist: hitArtist,
                    album: hitAlbum,
                    source: .appleMusic
                )
            }
            guard let albumID = Self.albumID(song),
                  let found = await albumCanvas(
                    id: albumID,
                    bearer: bearer,
                    trackTitle: hitTitle,
                    trackArtist: hitArtist
                  ) else { continue }
            return found
        }
        return nil
    }

    func albumCanvas(album: String, artist: String) async -> CanvasArtwork? {
        guard let bearer = await token() else { return nil }
        let term = album.localizedCaseInsensitiveContains(artist) ? album : "\(artist) \(album)"
        var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "types", value: "albums"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "extend", value: "editorialVideo")
        ]
        guard let url = components?.url,
              let root = await catalogJSON(url: url, bearer: bearer),
              let results = root["results"] as? [String: Any],
              let albums = results["albums"] as? [String: Any],
              let rows = albums["data"] as? [[String: Any]] else { return nil }

        for row in rows {
            guard let attributes = row["attributes"] as? [String: Any],
                  let name = attributes["name"] as? String,
                  let credit = attributes["artistName"] as? String,
                  name.canvasNormalized == album.canvasNormalized,
                  Self.artistMatches(wanted: artist, credited: credit),
                  !Self.isCompilation(name),
                  let video = attributes["editorialVideo"] as? [String: Any],
                  let links = Self.motionURLs(video) else { continue }
            return CanvasArtwork(
                url: links.0,
                fallbackURL: links.1,
                title: name,
                artist: credit,
                album: name,
                source: .appleMusic
            )
        }
        return nil
    }

    private func albumCanvas(id: String, bearer: String, trackTitle: String?, trackArtist: String?) async -> CanvasArtwork? {
        var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/albums/\(id)")
        components?.queryItems = [URLQueryItem(name: "extend", value: "editorialVideo")]
        guard let url = components?.url,
              let root = await catalogJSON(url: url, bearer: bearer),
              let rows = root["data"] as? [[String: Any]],
              let attributes = rows.first?["attributes"] as? [String: Any],
              let video = attributes["editorialVideo"] as? [String: Any],
              let links = Self.motionURLs(video) else { return nil }
        let album = attributes["name"] as? String
        guard !Self.isCompilation(album ?? "") else { return nil }
        return CanvasArtwork(
            url: links.0,
            fallbackURL: links.1,
            title: trackTitle,
            artist: trackArtist ?? attributes["artistName"] as? String,
            album: album,
            source: .appleMusic
        )
    }

    private func token(now: Date = Date()) async -> String? {
        if let cachedToken, now < tokenExpiry.addingTimeInterval(-60) { return cachedToken }
        if now < retryAfter { return nil }
        guard let page = try? await http.get(Self.webPlayer, headers: ["User-Agent": CanvasUserAgent.browser]),
              (200..<300).contains(page.statusCode),
              let html = String(data: page.data, encoding: .utf8) else {
            retryAfter = now.addingTimeInterval(Self.tokenRetry)
            return nil
        }
        let scriptPattern = #"/assets/index(?:-legacy)?[~-][A-Za-z0-9_-]+\.js"#
        for path in html.regexMatches(scriptPattern).uniquedCanvas() {
            guard let scriptURL = URL(string: path, relativeTo: URL(string: "https://music.apple.com")),
                  let response = try? await http.get(scriptURL.absoluteURL, headers: ["User-Agent": CanvasUserAgent.browser]),
                  (200..<300).contains(response.statusCode),
                  let script = String(data: response.data, encoding: .utf8) else { continue }
            let candidates = script.regexMatches(#"ey[A-Za-z0-9_-]+\.ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#)
                .filter { !rejectedTokens.contains($0) }
                .compactMap { jwt -> (String, Date)? in
                    guard let expiry = Self.jwtExpiry(jwt), expiry > now else { return nil }
                    return (jwt, expiry)
                }
            guard let selected = candidates.first(where: { Self.isWebPlayerToken($0.0) }) ?? candidates.first else {
                continue
            }
            cachedToken = selected.0
            tokenExpiry = selected.1
            return selected.0
        }
        retryAfter = now.addingTimeInterval(Self.tokenRetry)
        return nil
    }

    private func catalogJSON(url: URL, bearer: String) async -> [String: Any]? {
        guard let response = try? await http.get(url, headers: [
            "Authorization": "Bearer \(bearer)",
            "Origin": "https://music.apple.com",
            "Referer": "https://music.apple.com/",
            "User-Agent": CanvasUserAgent.browser
        ]) else { return nil }
        if response.statusCode == 401 {
            rejectedTokens.insert(bearer)
            if cachedToken == bearer {
                cachedToken = nil
                tokenExpiry = .distantPast
            }
            return nil
        }
        guard (200..<300).contains(response.statusCode) else { return nil }
        return try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
    }

    static func score(_ item: [String: Any], title: String, artist: String, album: String?) -> Int? {
        guard let attributes = item["attributes"] as? [String: Any],
              let hitTitle = attributes["name"] as? String,
              let hitArtist = attributes["artistName"] as? String else { return nil }
        let hitAlbum = attributes["albumName"] as? String ?? ""
        guard !isCompilation(hitTitle), !isCompilation(hitAlbum) else { return nil }
        let wanted = CanvasMatching.splitArtists(artist)
        let credited = CanvasMatching.splitArtists(hitArtist)
        guard !wanted.isEmpty, !credited.isEmpty,
              wanted.allSatisfy({ credited.contains($0) }) else { return nil }

        var score = 10
        let wantedTitle = title.canvasNormalized
        let candidateTitle = hitTitle.canvasNormalized
        if candidateTitle == wantedTitle { score += 15 }
        else if candidateTitle.contains(wantedTitle) || wantedTitle.contains(candidateTitle) { score += 7 }
        else { score -= 10 }

        if let album, !album.isEmpty, !hitAlbum.isEmpty {
            let wantedAlbum = album.canvasNormalized
            let candidateAlbum = hitAlbum.canvasNormalized
            if candidateAlbum == wantedAlbum { score += 20 }
            else if candidateAlbum.contains(wantedAlbum) || wantedAlbum.contains(candidateAlbum) { score += 10 }
        }
        for word in ["deluxe", "expanded", "remastered", "remix", "version", "edit", "mix", "bonus"] {
            let wantedHasWord = title.localizedCaseInsensitiveContains(word)
            let candidateHasWord = hitTitle.localizedCaseInsensitiveContains(word)
            if wantedHasWord && candidateHasWord { score += 5 }
            else if candidateHasWord { score -= 3 }
        }
        return score
    }

    private static func artistMatches(wanted: String, credited: String) -> Bool {
        let wantedArtists = CanvasMatching.splitArtists(wanted)
        let creditedArtists = CanvasMatching.splitArtists(credited)
        return !wantedArtists.isEmpty && !creditedArtists.isEmpty &&
            wantedArtists.allSatisfy(creditedArtists.contains)
    }

    static func motionURLs(_ video: [String: Any]) -> (URL, URL?)? {
        func link(_ key: String) -> URL? {
            guard let asset = video[key] as? [String: Any] else { return nil }
            for field in ["video", "videoUrl", "hlsUrl", "url"] {
                if let value = asset[field] as? String, let url = URL(string: value) { return url }
            }
            return nil
        }
        let square = link("motionDetailSquare") ?? link("motionSquareVideo1x1")
        let raw = link("motionDetailRaw")
        let tall = link("motionDetailTall") ?? link("motionTallVideo3x4")
        guard let primary = square ?? raw ?? tall else { return nil }
        return (primary, [square, raw, tall].compactMap { $0 }.first(where: { $0 != primary }))
    }

    static func albumID(_ song: [String: Any]) -> String? {
        if let relationships = song["relationships"] as? [String: Any],
           let albums = relationships["albums"] as? [String: Any],
           let data = albums["data"] as? [[String: Any]],
           let id = data.first?["id"] as? String,
           !id.hasPrefix("pl.") { return id }
        guard let attributes = song["attributes"] as? [String: Any],
              let rawURL = attributes["url"] as? String,
              let path = URL(string: rawURL)?.pathComponents.last,
              path.allSatisfy(\.isNumber) else { return nil }
        return path
    }

    static func jwtExpiry(_ token: String) -> Date? {
        let pieces = token.split(separator: ".")
        guard pieces.count == 3,
              let data = Data(base64URLEncoded: String(pieces[1])),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seconds = payload["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func isWebPlayerToken(_ token: String) -> Bool {
        let pieces = token.split(separator: ".")
        guard pieces.count == 3,
              let headerData = Data(base64URLEncoded: String(pieces[0])),
              let payloadData = Data(base64URLEncoded: String(pieces[1])),
              let header = String(data: headerData, encoding: .utf8),
              let payload = String(data: payloadData, encoding: .utf8) else { return false }
        return header.contains("WebPlayKid") || payload.contains("AMPWebPlay")
    }

    private static func isCompilation(_ name: String) -> Bool {
        let value = name.lowercased()
        return ["playlist", "set list", "essentials", "dj mix", "mixed", "apple music", "today's hits", "session"]
            .contains { value.contains($0) }
    }
}

actor CanvasRepository {
    private struct Entry: Sendable {
        let artwork: CanvasArtwork?
        let withAlbum: Bool
    }

    private let providers: [any CanvasProvider]
    private var cache: [String: Entry] = [:]
    private var recency: [String] = []
    private let cacheLimit = 64

    init(http: any CanvasHTTPClient = URLSessionCanvasHTTPClient()) {
        providers = [
            AppleMusicCanvasProvider(http: http),
            TidalCanvasProvider(http: http),
            CommunityCanvasProvider(http: http),
            SpotifyCanvasProvider()
        ]
    }

    init(providers: [any CanvasProvider]) {
        self.providers = providers
    }

    func canvas(for track: Track) async -> CanvasArtwork? {
        guard !track.isLocal else { return nil }
        let title = CanvasMatching.cleanedTitle(track.title)
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        let key = "track|\(track.videoID ?? track.id)"
        let knowsAlbum = track.album?.isEmpty == false
        if let existing = cache[key], existing.artwork != nil || existing.withAlbum || !knowsAlbum {
            touch(key)
            return existing.artwork
        }

        var found: CanvasArtwork?
        for provider in providers {
            guard !Task.isCancelled else { return nil }
            guard let candidate = await provider.canvas(title: title, artist: artist, album: track.album) else { continue }
            guard candidate.matches(title: title, artist: artist, album: track.album) else { continue }
            found = candidate
            break
        }
        cache[key] = Entry(artwork: found, withAlbum: knowsAlbum)
        touch(key)
        prune()
        return found
    }

    func canvasForAlbum(album: String, artist: String) async -> CanvasArtwork? {
        let title = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let credit = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !credit.isEmpty else { return nil }
        let key = "album|\(title.canvasNormalized)|\(credit.canvasNormalized)"
        if let existing = cache[key] {
            touch(key)
            return existing.artwork
        }

        var found: CanvasArtwork?
        for provider in providers {
            guard !Task.isCancelled else { return nil }
            guard let candidate = await provider.albumCanvas(album: title, artist: credit) else { continue }
            guard candidate.matches(title: title, artist: credit, album: title) else { continue }
            found = candidate
            break
        }
        cache[key] = Entry(artwork: found, withAlbum: true)
        touch(key)
        prune()
        return found
    }

    private func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func prune() {
        while recency.count > cacheLimit {
            cache.removeValue(forKey: recency.removeFirst())
        }
    }
}

@MainActor
final class CanvasController: ObservableObject {
    @Published private(set) var artwork: CanvasArtwork?
    @Published private(set) var rendered = false
    @Published private(set) var loading = false

    private let repository: CanvasRepository
    private let clipCache: CanvasClipCache
    private var task: Task<Void, Never>?
    private var requestKey: String?

    init(
        repository: CanvasRepository = CanvasRepository(),
        clipCache: CanvasClipCache = CanvasClipCache()
    ) {
        self.repository = repository
        self.clipCache = clipCache
    }

    deinit {
        task?.cancel()
    }

    func load(track: Track?, allowed: Bool) {
        let key = allowed ? track.map { "\($0.id)|\($0.album ?? "")" } : nil
        guard requestKey != key else { return }
        requestKey = key
        task?.cancel()
        rendered = false
        artwork = nil
        guard allowed, let track, !track.isLocal else {
            loading = false
            return
        }
        loading = true
        task = Task { [weak self, repository, clipCache] in
            let found = await repository.canvas(for: track)
            guard let self, !Task.isCancelled, requestKey == key else { return }
            artwork = found
            loading = false
            guard let found else { return }
            let cached = await clipCache.materialize(found)
            guard !Task.isCancelled, requestKey == key else { return }
            artwork = cached
        }
    }

    func markRendered() {
        rendered = artwork != nil
    }
}

@MainActor
final class AlbumCanvasController: ObservableObject {
    @Published private(set) var artwork: CanvasArtwork?
    @Published private(set) var rendered = false

    private let repository: CanvasRepository
    private let clipCache: CanvasClipCache
    private var task: Task<Void, Never>?
    private var requestKey: String?

    init(repository: CanvasRepository, clipCache: CanvasClipCache) {
        self.repository = repository
        self.clipCache = clipCache
    }

    deinit { task?.cancel() }

    func load(album: String, artist: String, allowed: Bool) {
        let key = allowed ? "\(album)|\(artist)" : nil
        guard requestKey != key else { return }
        requestKey = key
        task?.cancel()
        artwork = nil
        rendered = false
        guard allowed else { return }
        task = Task { [weak self, repository, clipCache] in
            let found = await repository.canvasForAlbum(album: album, artist: artist)
            guard let self, !Task.isCancelled, requestKey == key else { return }
            artwork = found
            guard let found else { return }
            let cached = await clipCache.materialize(found)
            guard !Task.isCancelled, requestKey == key else { return }
            artwork = cached
        }
    }

    func markRendered() { rendered = artwork != nil }
}

struct CanvasVideoView: NSViewRepresentable {
    let artwork: CanvasArtwork
    let onReady: () -> Void

    func makeNSView(context: Context) -> LoopingCanvasNSView {
        let view = LoopingCanvasNSView()
        view.configure(artwork: artwork, onReady: onReady)
        return view
    }

    func updateNSView(_ nsView: LoopingCanvasNSView, context: Context) {
        nsView.configure(artwork: artwork, onReady: onReady)
    }

    static func dismantleNSView(_ nsView: LoopingCanvasNSView, coordinator: ()) {
        nsView.stop()
    }
}

final class LoopingCanvasNSView: NSView {
    private let playerLayer = AVPlayerLayer()
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var statusObservation: NSKeyValueObservation?
    private var displayObservation: NSKeyValueObservation?
    private var hlsResourceLoader: CanvasHLSResourceLoader?
    private var artwork: CanvasArtwork?
    private var onReady: (() -> Void)?
    private var attemptedFallback = false
    private var signalledReady = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        player.isMuted = true
        player.actionAtItemEnd = .none
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
        setAccessibilityLabel("Animated cover art")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func configure(artwork: CanvasArtwork, onReady: @escaping () -> Void) {
        self.onReady = onReady
        guard self.artwork != artwork else { return }
        self.artwork = artwork
        attemptedFallback = false
        play(artwork.playbackURL)
    }

    func stop() {
        statusObservation?.invalidate()
        statusObservation = nil
        displayObservation?.invalidate()
        displayObservation = nil
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
        hlsResourceLoader = nil
    }

    private func play(_ url: URL) {
        stop()
        signalledReady = false
        let item: AVPlayerItem
        let remoteExtension = url.pathExtension.lowercased()
        let shouldUseHLSCache = !url.isFileURL && (
            remoteExtension == "m3u8" ||
                (artwork?.source == .appleMusic && !["mp4", "mov"].contains(remoteExtension))
        )
        if shouldUseHLSCache {
            let loader = CanvasHLSResourceLoader()
            if let asset = loader.asset(for: url) {
                hlsResourceLoader = loader
                item = AVPlayerItem(asset: asset)
            } else {
                item = AVPlayerItem(url: url)
            }
        } else {
            item = AVPlayerItem(url: url)
        }
        looper = AVPlayerLooper(player: player, templateItem: item)

        if let playingItem = player.currentItem {
            statusObservation = playingItem.observe(\.status, options: [.initial, .new]) { [weak self, weak playingItem] _, _ in
                DispatchQueue.main.async {
                    guard let self, let playingItem, playingItem.status == .failed else { return }
                    if !self.attemptedFallback, let fallback = self.artwork?.playbackFallbackURL {
                        self.attemptedFallback = true
                        self.play(fallback)
                    }
                }
            }
        }
        displayObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            DispatchQueue.main.async {
                guard let self, layer.isReadyForDisplay, !self.signalledReady else { return }
                self.signalledReady = true
                self.onReady?()
            }
        }
        player.play()
    }
}

enum CanvasUserAgent {
    static let browser = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
}

private extension String {
    func regexMatches(_ pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(startIndex..<endIndex, in: self)
        return expression.matches(in: self, range: range).compactMap {
            Range($0.range, in: self).map { String(self[$0]) }
        }
    }
}

private extension Array where Element == String {
    func uniquedCanvas() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: normalized)
    }
}
