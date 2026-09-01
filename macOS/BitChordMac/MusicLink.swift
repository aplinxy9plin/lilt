import Foundation

/// A YouTube Music destination handed to Lilt from another app or pasted
/// into the native Open Link sheet. The shapes intentionally match Android's
/// MusicLink relay, minus voice-assistant intents that do not exist on macOS.
enum MusicLinkRequest: Equatable, Sendable {
    case track(videoID: String)
    case page(browseID: String)
    case search(query: String)
}

enum MusicLinkParser {
    static func parse(_ text: String) -> MusicLinkRequest? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        if let url = URL(string: cleaned), let request = parse(url) {
            return request
        }
        guard let match = cleaned.range(of: #"https?://[^\s<>\"']+"#, options: .regularExpression) else {
            return nil
        }
        let wrappedURL = String(cleaned[match]).trimmingCharacters(in: trailingSharedTextPunctuation)
        guard let url = URL(string: wrappedURL) else { return nil }
        return parse(url)
    }

    static func parse(_ url: URL) -> MusicLinkRequest? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased() else { return nil }

        if scheme == "lilt" || scheme == "bitchord" {
            return parseAppURL(components)
        }
        guard scheme == "http" || scheme == "https" else { return nil }

        let rawHost = components.host?.lowercased() ?? ""
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let segments = components.path.split(separator: "/").map(String.init)
        let query = Dictionary(
            components.queryItems?.compactMap { item in
                item.value.map { (item.name, $0) }
            } ?? [],
            uniquingKeysWith: { first, _ in first }
        )

        if host == "youtu.be" {
            return segments.first.flatMap(track)
        }
        guard host == "youtube.com" || host == "music.youtube.com" || host == "m.youtube.com" else {
            return nil
        }

        let listID = query["list"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch segments.first?.lowercased() {
        case "watch":
            return query["v"].flatMap(track) ?? playlist(listID)
        case "playlist":
            return playlist(listID)
        case "shorts", "embed", "v":
            return segments.dropFirst().first.flatMap(track)
        case "channel", "browse":
            return segments.dropFirst().first.flatMap(page)
        case "search":
            return query["q"].flatMap(search)
        case "results":
            return query["search_query"].flatMap(search)
        default:
            return playlist(listID)
        }
    }

    private static func parseAppURL(_ components: URLComponents) -> MusicLinkRequest? {
        let action = components.host?.lowercased() ?? ""
        let segments = components.path.split(separator: "/").map(String.init)
        let query = Dictionary(
            components.queryItems?.compactMap { item in
                item.value.map { (item.name, $0) }
            } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        switch action {
        case "open":
            return query["url"].flatMap(parse) ?? query["text"].flatMap(parse)
        case "track":
            return (segments.first ?? query["id"]).flatMap(track)
        case "browse", "page":
            return (segments.first ?? query["id"]).flatMap(page)
        case "search":
            return query["q"].flatMap(search)
        default:
            return nil
        }
    }

    private static func track(_ raw: String) -> MusicLinkRequest? {
        nonEmpty(raw).map { .track(videoID: $0) }
    }

    private static func page(_ raw: String) -> MusicLinkRequest? {
        nonEmpty(raw).map { .page(browseID: $0) }
    }

    private static func playlist(_ raw: String) -> MusicLinkRequest? {
        guard let id = nonEmpty(raw) else { return nil }
        return .page(browseID: id.hasPrefix("VL") ? id : "VL\(id)")
    }

    private static func search(_ raw: String) -> MusicLinkRequest? {
        nonEmpty(raw).map { .search(query: $0) }
    }

    private static func nonEmpty(_ raw: String) -> String? {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static let trailingSharedTextPunctuation = CharacterSet(charactersIn: ".,;:!?)]}")
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
