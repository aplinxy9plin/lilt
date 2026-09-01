import Combine
import CryptoKit
import Foundation

enum LyricsSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case lyricsPlus = "LYRICS_PLUS"
    case paxSenix = "PAXSENIX"
    case betterLyrics = "BETTER_LYRICS"
    case simpMusic = "SIMP_MUSIC"
    case kuGou = "KUGOU"
    case lrcLib = "LRCLIB"
    case musixmatch = "MUSIXMATCH"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lyricsPlus: "LyricsPlus"
        case .paxSenix: "PaxSenix"
        case .betterLyrics: "BetterLyrics"
        case .simpMusic: "SimpMusic"
        case .kuGou: "KuGou"
        case .lrcLib: "LRCLIB"
        case .musixmatch: "Musixmatch"
        }
    }

    var detail: String {
        switch self {
        case .lyricsPlus: "Syllable timing from community mirrors"
        case .paxSenix: "Apple Music timing through a second host"
        case .betterLyrics: "Apple Music words and syllables"
        case .simpMusic: "Matched against the exact YouTube video"
        case .kuGou: "Strong non-English line-synced catalogue"
        case .lrcLib: "Reliable community line-synced lyrics"
        case .musixmatch: "Large line-synced catalogue"
        }
    }

    var supportsWordTiming: Bool {
        switch self {
        case .lyricsPlus, .paxSenix, .betterLyrics, .simpMusic: true
        case .kuGou, .lrcLib, .musixmatch: false
        }
    }
}

struct LyricsPreferences: Sendable, Equatable {
    var enabled: Bool
    var enabledSources: Set<LyricsSource>
    var sourceOrder: [LyricsSource]
    var prioritizeWordTiming: Bool
}

@MainActor
final class LyricsSettings: ObservableObject {
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.enabledKey) } }
    @Published private(set) var enabledSources: Set<LyricsSource>
    @Published private(set) var sourceOrder: [LyricsSource]
    @Published var prioritizeWordTiming: Bool {
        didSet { defaults.set(prioritizeWordTiming, forKey: Self.prioritizeKey) }
    }

    private let defaults: UserDefaults
    private static let enabledKey = "BitChord.syncedLyrics"
    private static let sourcesKey = "BitChord.lyricsSources"
    private static let orderKey = "BitChord.lyricsSourceOrder"
    private static let prioritizeKey = "BitChord.prioritizeSyllableSync"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true

        if let saved = defaults.string(forKey: Self.sourcesKey) {
            enabledSources = Set(saved.split(separator: ",").compactMap { LyricsSource(rawValue: String($0)) })
        } else {
            enabledSources = Set(LyricsSource.allCases)
        }

        let savedOrder = defaults.string(forKey: Self.orderKey)?
            .split(separator: ",")
            .compactMap { LyricsSource(rawValue: String($0)) } ?? []
        sourceOrder = savedOrder + LyricsSource.allCases.filter { !savedOrder.contains($0) }
        prioritizeWordTiming = defaults.object(forKey: Self.prioritizeKey) as? Bool ?? false
    }

    var snapshot: LyricsPreferences {
        LyricsPreferences(
            enabled: enabled,
            enabledSources: enabledSources,
            sourceOrder: sourceOrder,
            prioritizeWordTiming: prioritizeWordTiming
        )
    }

    func isEnabled(_ source: LyricsSource) -> Bool { enabledSources.contains(source) }

    func setEnabled(_ source: LyricsSource, enabled: Bool) {
        if enabled { enabledSources.insert(source) } else { enabledSources.remove(source) }
        persistSources()
    }

    func move(_ source: LyricsSource, by offset: Int) {
        guard let index = sourceOrder.firstIndex(of: source) else { return }
        let destination = index + offset
        guard sourceOrder.indices.contains(destination) else { return }
        sourceOrder.swapAt(index, destination)
        defaults.set(sourceOrder.map(\.rawValue).joined(separator: ","), forKey: Self.orderKey)
    }

    func resetSources() {
        enabledSources = Set(LyricsSource.allCases)
        sourceOrder = LyricsSource.allCases
        prioritizeWordTiming = false
        persistSources()
        defaults.set(sourceOrder.map(\.rawValue).joined(separator: ","), forKey: Self.orderKey)
    }

    func applyPortableSettings(
        enabled: Bool,
        sources: Set<LyricsSource>,
        order: [LyricsSource],
        prioritizeWordTiming: Bool
    ) {
        self.enabled = enabled
        enabledSources = sources
        sourceOrder = order + LyricsSource.allCases.filter { !order.contains($0) }
        self.prioritizeWordTiming = prioritizeWordTiming
        persistSources()
        defaults.set(sourceOrder.map(\.rawValue).joined(separator: ","), forKey: Self.orderKey)
    }

    private func persistSources() {
        let ordered = LyricsSource.allCases.filter(enabledSources.contains)
        defaults.set(ordered.map(\.rawValue).joined(separator: ","), forKey: Self.sourcesKey)
    }
}

struct LyricsQuery: Sendable {
    let videoID: String
    let title: String
    let artist: String
    let duration: TimeInterval
    let album: String?
}

protocol LyricsFetching: Sendable {
    var source: LyricsSource { get }
    func fetch(_ query: LyricsQuery) async -> [LyricLine]?
}

struct LyricsHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

protocol LyricsHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> LyricsHTTPResponse
}

final class URLSessionLyricsTransport: LyricsHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 6
            configuration.timeoutIntervalForResource = 8
            self.session = URLSession(configuration: configuration)
        }
    }

    func send(_ request: URLRequest) async throws -> LyricsHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return LyricsHTTPResponse(data: data, statusCode: http.statusCode)
    }
}

struct LyricsRepository: Sendable {
    private let providers: [LyricsSource: any LyricsFetching]

    init(transport: any LyricsHTTPTransport = URLSessionLyricsTransport()) {
        providers = [
            .lyricsPlus: LyricsPlusProvider(transport: transport),
            .paxSenix: PaxSenixProvider(transport: transport),
            .betterLyrics: BetterLyricsProvider(transport: transport),
            .simpMusic: SimpMusicProvider(transport: transport),
            .kuGou: KuGouProvider(transport: transport),
            .lrcLib: LRCLibProvider(transport: transport),
            .musixmatch: MusixmatchProvider(transport: transport)
        ]
    }

    init(providers: [LyricsSource: any LyricsFetching]) {
        self.providers = providers
    }

    func lyrics(for track: Track, preferences: LyricsPreferences) async -> Lyrics? {
        guard preferences.enabled, !preferences.enabledSources.isEmpty else { return nil }
        let sequence = preferences.sourceOrder.filter(preferences.enabledSources.contains)
            + LyricsSource.allCases.filter {
                preferences.enabledSources.contains($0) && !preferences.sourceOrder.contains($0)
            }
        let query = LyricsQuery(
            videoID: track.videoID ?? "",
            title: track.title,
            artist: track.artist,
            duration: track.duration ?? 0,
            album: track.album
        )
        let jobs: [(LyricsSource, Task<[LyricLine]?, Never>)] = sequence.compactMap { source in
            guard let provider = providers[source] else { return nil }
            return (source, Task { await provider.fetch(query) })
        }
        defer { jobs.forEach { $0.1.cancel() } }

        var lineSyncedFallback: Lyrics?
        for (source, job) in jobs {
            guard !Task.isCancelled else { return nil }
            guard let rawLines = await job.value, !rawLines.isEmpty else { continue }
            let lines = LyricsParsers.withBackgroundVocals(rawLines)
            let result = Lyrics(lines: lines, source: source.title)
            if result.isWordSynced { return result }
            if !preferences.prioritizeWordTiming { return result }
            if lineSyncedFallback == nil { lineSyncedFallback = result }
        }
        return lineSyncedFallback
    }
}

enum LyricsParsers {
    static let minimumGap: TimeInterval = 4

    static func parseLRC(_ lrc: String) -> [LyricLine] {
        let linePattern = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})[.:](\d{2,3})\]"#)
        let wordPattern = try! NSRegularExpression(pattern: #"<(\d{1,3}):(\d{2})[.:](\d{2,3})>"#)
        var lines: [LyricLine] = []

        for raw in lrc.components(separatedBy: .newlines) {
            let fullRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let match = linePattern.firstMatch(in: raw, range: fullRange),
                  let lineStart = stamp(match, in: raw) else { continue }
            let bodyStart = Range(match.range, in: raw)!.upperBound
            let body = String(raw[bodyStart...])
            let marks = wordPattern.matches(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body))
            var words: [LyricWord] = []
            for (index, mark) in marks.enumerated() {
                guard let wordStart = stamp(mark, in: body),
                      let markRange = Range(mark.range, in: body) else { continue }
                let endIndex = marks[safe: index + 1]
                    .flatMap { Range($0.range, in: body)?.lowerBound } ?? body.endIndex
                let text = String(body[markRange.upperBound..<endIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let wordEnd = marks[safe: index + 1].flatMap { stamp($0, in: body) } ?? wordStart
                words.append(LyricWord(start: wordStart, end: max(wordStart, wordEnd), text: text))
            }
            let plain = wordPattern.stringByReplacingMatches(
                in: body,
                range: NSRange(body.startIndex..<body.endIndex, in: body),
                withTemplate: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(LyricLine(start: lineStart, text: plain, words: words))
        }

        let sorted = lines.sorted { $0.start < $1.start }
        let kept = sorted.enumerated().compactMap { index, line -> LyricLine? in
            guard line.isGap else { return line }
            guard let next = sorted[safe: index + 1] else { return line }
            return next.start - line.start >= minimumGap ? line : nil
        }
        guard let first = kept.first else { return [] }
        return !first.isGap && first.start >= minimumGap
            ? [LyricLine(start: 0, text: "")] + kept
            : kept
    }

    static func parseEnhancedLRC(_ lrc: String) -> [LyricLine] {
        let linePattern = try! NSRegularExpression(pattern: #"^\[(\d{1,3}):(\d{2})[.:](\d{2,3})\](.*)$"#)
        let wordPattern = try! NSRegularExpression(pattern: #"<(\d{1,3}):(\d{2})[.:](\d{2,3})>([^<]*)"#)
        struct Row { let start: TimeInterval; let body: String; let words: [NSTextCheckingResult] }
        var rows: [Row] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let match = linePattern.firstMatch(in: raw, range: range),
                  let start = stamp(match, in: raw),
                  let bodyRange = Range(match.range(at: 4), in: raw) else { continue }
            let body = String(raw[bodyRange])
            let matches = wordPattern.matches(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body))
            rows.append(Row(start: start, body: body, words: matches))
        }
        rows.sort { $0.start < $1.start }
        guard rows.contains(where: { !$0.words.isEmpty }) else { return [] }

        let lines = rows.enumerated().compactMap { index, row -> LyricLine? in
            guard !row.words.isEmpty else {
                let text = decodeEntities(row.body).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : LyricLine(start: row.start, text: text)
            }
            let tail = rows[safe: index + 1]?.start
                ?? row.words.last.flatMap { stamp($0, in: row.body) }.map { $0 + 0.8 }
                ?? row.start + 0.8
            let words = row.words.enumerated().compactMap { wordIndex, match -> LyricWord? in
                guard let start = stamp(match, in: row.body),
                      let textRange = Range(match.range(at: 4), in: row.body) else { return nil }
                let text = decodeEntities(String(row.body[textRange]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let end = row.words[safe: wordIndex + 1].flatMap { stamp($0, in: row.body) } ?? tail
                return LyricWord(start: start, end: max(start, end), text: text)
            }
            guard let first = words.first else { return nil }
            return LyricLine(
                start: min(row.start, first.start),
                text: words.map(\.text).joined(separator: " "),
                words: words
            )
        }
        return withInstrumentalGaps(lines)
    }

    static func parseTTML(_ ttml: String) -> [LyricLine] {
        guard let document = try? XMLDocument(
            xmlString: ttml,
            options: [.nodePreserveWhitespace, .nodeLoadExternalEntitiesNever]
        ), let root = document.rootElement() else { return [] }
        let paragraphs = descendants(root).filter { localName($0) == "p" }
        let lines = paragraphs.compactMap(parseParagraph).sorted { $0.start < $1.start }
        return withInstrumentalGaps(lines)
    }

    static func withInstrumentalGaps(_ lines: [LyricLine]) -> [LyricLine] {
        guard !lines.isEmpty else { return [] }
        let sorted = lines.sorted { $0.start < $1.start }
        var result: [LyricLine] = []
        if let first = sorted.first, first.start >= minimumGap {
            result.append(LyricLine(start: 0, text: ""))
        }
        for (index, line) in sorted.enumerated() {
            result.append(line)
            guard line.hasKnownEnd, let next = sorted[safe: index + 1] else { continue }
            let silence = next.start - line.sungUntil
            if silence >= minimumGap, line.sungUntil > line.start {
                result.append(LyricLine(start: line.sungUntil, text: ""))
            }
        }
        return result
    }

    static func withBackgroundVocals(_ lines: [LyricLine]) -> [LyricLine] {
        lines.map(splitBackgroundVocal)
    }

    private enum Piece { case text(String); case timed(String, TimeInterval, TimeInterval) }

    private static func parseParagraph(_ paragraph: XMLElement) -> LyricLine? {
        var lead: [Piece] = []
        var backing: [Piece] = []
        collect(paragraph, into: &lead, backing: &backing, isBacking: false)
        let words = mergePieces(lead)
        let backgroundWords = mergePieces(backing)
        let background = backgroundWords.first.map { first in
            LyricBackground(
                start: first.start,
                text: backgroundWords.map(\.text).joined(separator: " "),
                words: backgroundWords
            )
        }

        if words.isEmpty {
            let text = paragraph.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty, let start = parseTTMLTime(attribute(paragraph, "begin")) else { return nil }
            let end = parseTTMLTime(attribute(paragraph, "end")).flatMap { $0 > start ? $0 : nil }
            return LyricLine(start: start, text: text, end: end)
        }
        let paragraphStart = parseTTMLTime(attribute(paragraph, "begin")) ?? words[0].start
        return LyricLine(
            start: min(paragraphStart, words[0].start),
            text: words.map(\.text).joined(separator: " "),
            words: words,
            background: background
        )
    }

    private static func collect(
        _ node: XMLNode,
        into lead: inout [Piece],
        backing: inout [Piece],
        isBacking: Bool
    ) {
        for child in node.children ?? [] {
            if let element = child as? XMLElement {
                let role = attribute(element, "role") ?? ""
                if role == "x-translation" || role == "x-roman" { continue }
                let childBacking = isBacking || role == "x-bg"
                let start = parseTTMLTime(attribute(element, "begin"))
                let end = parseTTMLTime(attribute(element, "end"))
                if let start, let end, !hasTimedDescendant(element) {
                    let piece = Piece.timed(element.stringValue ?? "", start, end)
                    if childBacking { backing.append(piece) } else { lead.append(piece) }
                } else {
                    collect(element, into: &lead, backing: &backing, isBacking: childBacking)
                }
            } else if child.kind == .text, let text = child.stringValue, !text.isEmpty {
                if isBacking { backing.append(.text(text)) } else { lead.append(.text(text)) }
            }
        }
    }

    private static func mergePieces(_ pieces: [Piece]) -> [LyricWord] {
        var result: [LyricWord] = []
        var text = ""
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var timed = false
        func flush() {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, timed { result.append(LyricWord(start: start, end: end, text: value)) }
            text = ""
            timed = false
        }
        for piece in pieces {
            switch piece {
            case .text(let value):
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { flush() }
                else if timed { text += value }
            case .timed(let value, let pieceStart, let pieceEnd):
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if value.first?.isWhitespace == true { flush() }
                if text.isEmpty { start = pieceStart }
                text += value.trimmingCharacters(in: .whitespacesAndNewlines)
                end = pieceEnd
                timed = true
                if value.last?.isWhitespace == true { flush() }
            }
        }
        flush()
        return result
    }

    private static func parseTTMLTime(_ value: String?) -> TimeInterval? {
        guard var raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasSuffix("ms") { return Double(raw.dropLast(2)).map { $0 / 1_000 } }
        if raw.hasSuffix("s") { raw.removeLast() }
        let parts = raw.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 1: return parts[0]
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3_600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }

    private static func descendants(_ element: XMLElement) -> [XMLElement] {
        [element] + (element.children ?? []).compactMap { $0 as? XMLElement }.flatMap(descendants)
    }

    private static func localName(_ element: XMLElement) -> String {
        element.localName ?? element.name?.split(separator: ":").last.map(String.init) ?? ""
    }

    private static func attribute(_ element: XMLElement, _ name: String) -> String? {
        element.attribute(forName: name)?.stringValue
            ?? element.attributes?.first(where: {
                $0.localName == name || $0.name?.split(separator: ":").last == Substring(name)
            })?.stringValue
    }

    private static func hasTimedDescendant(_ element: XMLElement) -> Bool {
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            if attribute(child, "begin") != nil || hasTimedDescendant(child) { return true }
        }
        return false
    }

    private static func splitBackgroundVocal(_ line: LyricLine) -> LyricLine {
        guard line.background == nil, !line.isGap, line.text.hasSuffix(")") else { return line }
        var depth = 0
        var opening: String.Index?
        for index in line.text.indices.reversed() {
            if line.text[index] == ")" { depth += 1 }
            if line.text[index] == "(" {
                depth -= 1
                if depth == 0 { opening = index; break }
            }
        }
        guard let opening, opening > line.text.startIndex else { return line }
        let leadText = String(line.text[..<opening]).trimmingCharacters(in: .whitespaces)
        let backingText = String(line.text[opening...]).trimmingCharacters(in: .whitespaces)
        guard !leadText.isEmpty, backingText.contains(where: { $0.isLetter || $0.isNumber }) else { return line }
        if line.words.isEmpty {
            return LyricLine(
                id: line.id,
                start: line.start,
                text: leadText,
                end: line.end,
                background: LyricBackground(start: line.start, text: backingText, end: line.end)
            )
        }
        let offset = line.text.distance(from: line.text.startIndex, to: opening)
        var at = 0
        var splitIndex: Int?
        for (index, word) in line.words.enumerated() {
            if at == offset { splitIndex = index; break }
            if at > offset { break }
            at += word.text.count + 1
        }
        guard let splitIndex, splitIndex > 0 else { return line }
        let backingWords = Array(line.words.dropFirst(splitIndex))
        guard let first = backingWords.first else { return line }
        return LyricLine(
            id: line.id,
            start: line.start,
            text: leadText,
            end: line.end,
            words: Array(line.words.prefix(splitIndex)),
            background: LyricBackground(start: first.start, text: backingText, words: backingWords)
        )
    }

    private static func stamp(_ match: NSTextCheckingResult, in string: String) -> TimeInterval? {
        func capture(_ index: Int) -> String? {
            guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: string) else { return nil }
            return String(string[range])
        }
        guard let minutes = capture(1).flatMap(Double.init),
              let seconds = capture(2).flatMap(Double.init),
              let fractionText = capture(3), let fraction = Double(fractionText) else { return nil }
        let milliseconds = fractionText.count == 3 ? fraction : fraction * 10
        return minutes * 60 + seconds + milliseconds / 1_000
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        let hex = try! NSRegularExpression(pattern: #"&#x([0-9a-fA-F]+);"#)
        let decimal = try! NSRegularExpression(pattern: #"&#(\d+);"#)
        for (regex, radix) in [(hex, 16), (decimal, 10)] {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..<result.endIndex, in: result)).reversed()
            for match in matches {
                guard let whole = Range(match.range, in: result),
                      let digits = Range(match.range(at: 1), in: result),
                      let value = UInt32(result[digits], radix: radix),
                      let scalar = UnicodeScalar(value) else { continue }
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return result
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

private let lyricsUserAgent = "Lilt macOS"

private func lyricsRequest(_ url: URL, bearer: String? = nil, appleHeaders: Bool = false) -> URLRequest {
    var request = URLRequest(url: url)
    request.timeoutInterval = 6
    request.setValue(lyricsUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
    if appleHeaders {
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")
    }
    return request
}

private func successfulData(_ response: LyricsHTTPResponse?) -> Data? {
    guard let response, (200..<300).contains(response.statusCode) else { return nil }
    return response.data
}

private func jsonObject(_ data: Data?) -> [String: Any]? {
    guard let data else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func jsonArray(_ data: Data?) -> [[String: Any]]? {
    guard let data else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
}

private func valueString(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
}

private func valueDouble(_ value: Any?) -> Double? {
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
}

private func url(_ base: String, _ query: [URLQueryItem]) -> URL? {
    guard var components = URLComponents(string: base) else { return nil }
    components.queryItems = query
    return components.url
}

private struct LRCLibProvider: LyricsFetching {
    let source = LyricsSource.lrcLib
    let transport: any LyricsHTTPTransport

    func fetch(_ query: LyricsQuery) async -> [LyricLine]? {
        let title = clean(query.title)
        let artist = clean(query.artist)
        let seconds = Int(query.duration.rounded())
        let exactURL = url("https://lrclib.net/api/get", [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "duration", value: seconds > 0 ? String(seconds) : nil)
        ])
        if let exactURL,
           let response = try? await transport.send(lyricsRequest(exactURL)),
           let synced = valueString(jsonObject(successfulData(response))?["syncedLyrics"]),
           !synced.isEmpty {
            let lines = LyricsParsers.parseLRC(synced)
            if !lines.isEmpty { return lines }
        }

        guard !Task.isCancelled,
              let searchURL = url("https://lrclib.net/api/search", [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist)
              ]),
              let response = try? await transport.send(lyricsRequest(searchURL)),
              let hits = jsonArray(successfulData(response)) else { return nil }
        let best = hits.filter { valueString($0["syncedLyrics"])?.isEmpty == false }.min {
            abs((valueDouble($0["duration"]) ?? 0) - Double(seconds))
                < abs((valueDouble($1["duration"]) ?? 0) - Double(seconds))
        }
        guard let synced = valueString(best?["syncedLyrics"]) else { return nil }
        return LyricsParsers.parseLRC(synced).nilIfEmpty
    }

    private func clean(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: #"\((?:from|feat\.?|official|lyrical|video|audio|remix)[^)]*\)|\[[^]]*\]|\b(?:official (?:video|audio|music video)|lyrical|full song|4k video)\b"#,
            with: " ",
            options: .regularExpression
        )
        .components(separatedBy: " | ").first?
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
    }
}

private struct BetterLyricsProvider: LyricsFetching {
    let source = LyricsSource.betterLyrics
    let transport: any LyricsHTTPTransport

    func fetch(_ query: LyricsQuery) async -> [LyricLine]? {
        var items = [
            URLQueryItem(name: "s", value: query.title),
            URLQueryItem(name: "a", value: query.artist)
        ]
        if query.duration > 0 { items.append(URLQueryItem(name: "d", value: String(Int(query.duration)))) }
        if let album = query.album, !album.isEmpty { items.append(URLQueryItem(name: "al", value: album)) }
        guard let endpoint = url("https://lyrics-api.boidu.dev/getLyrics", items),
              let response = try? await transport.send(lyricsRequest(endpoint)),
              let ttml = valueString(jsonObject(successfulData(response))?["ttml"]) else { return nil }
        return LyricsParsers.parseTTML(ttml).nilIfEmpty
    }
}

private struct SimpMusicProvider: LyricsFetching {
    let source = LyricsSource.simpMusic
    let transport: any LyricsHTTPTransport

    func fetch(_ query: LyricsQuery) async -> [LyricLine]? {
        guard !query.videoID.isEmpty,
              let endpoint = URL(string: "https://api-lyrics.simpmusic.org/v1/\(query.videoID)"),
              let response = try? await transport.send(lyricsRequest(endpoint)),
              let object = jsonObject(successfulData(response)),
              (object["success"] as? Bool) == true,
              let tracks = object["data"] as? [[String: Any]] else { return nil }
        let seconds = Int(query.duration)
        let best = tracks.filter {
            seconds <= 0 || abs(Int(valueDouble($0["duration"]) ?? 0) - seconds) <= 10
        }.min {
            abs(Int(valueDouble($0["duration"]) ?? 0) - seconds)
                < abs(Int(valueDouble($1["duration"]) ?? 0) - seconds)
        }
        guard let best else { return nil }
        if let rich = valueString(best["richSyncLyrics"]), !rich.isEmpty {
            let lines = LyricsParsers.parseEnhancedLRC(rich)
            if !lines.isEmpty { return lines }
        }
        guard let synced = valueString(best["syncedLyrics"]), !synced.isEmpty else { return nil }
        return LyricsParsers.parseLRC(synced).nilIfEmpty
    }
}

private struct LyricsPlusProvider: LyricsFetching {
    let source = LyricsSource.lyricsPlus
    let transport: any LyricsHTTPTransport
    private let mirrors = [
        "https://lyricsplus.prjktla.my.id",
        "https://lyricsplus.atomix.one",
        "https://lyricsplus.binimum.org",
        "https://lyricsplus.prjktla.workers.dev",
        "https://lyricsplus-seven.vercel.app",
        "https://lyrics-plus-backend.vercel.app"
    ]

    func fetch(_ query: LyricsQuery) async -> [LyricLine]? {
        await withTaskGroup(of: [LyricLine]?.self) { group in
            for mirror in mirrors {
                group.addTask { await fetch(mirror: mirror, query: query) }
            }
            while let lines = await group.next() {
                if let lines, !lines.isEmpty {
                    group.cancelAll()
                    return lines
                }
            }
            return nil
        }
    }

    private func fetch(mirror: String, query: LyricsQuery) async -> [LyricLine]? {
        var items = [
            URLQueryItem(name: "title", value: query.title),
            URLQueryItem(name: "artist", value: query.artist)
        ]
        if query.duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(query.duration)))) }
        if let album = query.album, !album.isEmpty { items.append(URLQueryItem(name: "album", value: album)) }
        guard let endpoint = url("\(mirror)/v2/lyrics/get", items),
              let response = try? await transport.send(lyricsRequest(endpoint)),
              let object = jsonObject(successfulData(response)),
              let rows = object["lyrics"] as? [[String: Any]] else { return nil }
        let lines = rows.compactMap { row -> LyricLine? in
            guard let startMs = valueDouble(row["time"]) else { return nil }
            let syllables = row["syllabus"] as? [[String: Any]] ?? []
            var words: [LyricWord] = []
            var current = ""
            var wordStart: TimeInterval = 0
            var wordEnd: TimeInterval = 0
            for syllable in syllables {
                guard let text = valueString(syllable["text"]), !text.trimmingCharacters(in: .whitespaces).isEmpty,
                      let timeMs = valueDouble(syllable["time"]) else { continue }
                if current.isEmpty { wordStart = timeMs / 1_000 }
                current += text.trimmingCharacters(in: .whitespacesAndNewlines)
                wordEnd = (timeMs + (valueDouble(syllable["duration"]) ?? 0)) / 1_000
                if text.last?.isWhitespace == true {
                    words.append(LyricWord(start: wordStart, end: wordEnd, text: current))
                    current = ""
                }
            }
            if !current.isEmpty { words.append(LyricWord(start: wordStart, end: wordEnd, text: current)) }
            if let first = words.first {
                return LyricLine(
                    start: min(startMs / 1_000, first.start),
                    text: words.map(\.text).joined(separator: " "),
                    words: words
                )
            }
            guard let text = valueString(row["text"])?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let duration = valueDouble(row["duration"]).map { (startMs + $0) / 1_000 }
            return LyricLine(start: startMs / 1_000, text: text, end: duration)
        }
        return LyricsParsers.withInstrumentalGaps(lines).nilIfEmpty
    }
}

private actor PaxSenixProvider: LyricsFetching {
    nonisolated let source = LyricsSource.paxSenix
    let transport: any LyricsHTTPTransport
    private var cachedToken: String?

    init(transport: any LyricsHTTPTransport) { self.transport = transport }

    func fetch(_ query: LyricsQuery) async -> [LyricLine]? {
        guard let token = await appleToken(), let trackID = await findTrack(query, token: token) else { return nil }
        guard let endpoint = url("https://lyrics.paxsenix.org/apple-music/lyrics", [URLQueryItem(name: "id", value: trackID)]),
              let response = try? await transport.send(lyricsRequest(endpoint)),
              let object = jsonObject(successfulData(response)) else { return nil }
        if let ttml = valueString(object["ttmlContent"]), !ttml.isEmpty {
            let lines = LyricsParsers.parseTTML(ttml)
            if !lines.isEmpty { return lines }
        }
        for key in ["elrcMultiPerson", "elrc"] {
            if let enhanced = valueString(object[key]), !enhanced.isEmpty {
                let lines = LyricsParsers.parseEnhancedLRC(enhanced)
                if !lines.isEmpty { return lines }
            }
        }
        return nil
    }

    private func findTrack(_ query: LyricsQuery, token: String) async -> String? {
        let cleanTitle = cleaned(query.title)
        let cleanArtist = cleaned(query.artist)
        let term = [cleanTitle, cleanArtist].filter { !$0.isEmpty }.joined(separator: " ")
        guard let endpoint = url("https://amp-api.music.apple.com/v1/catalog/us/search", [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "l", value: "en-US")
        ]), let response = try? await transport.send(lyricsRequest(endpoint, bearer: token, appleHeaders: true)) else { return nil }
        if response.statusCode == 401 || response.statusCode == 403 { cachedToken = nil; return nil }
        guard let root = jsonObject(successfulData(response)),
              let results = root["results"] as? [String: Any],
              let songs = results["songs"] as? [String: Any],
              let tracks = songs["data"] as? [[String: Any]] else { return nil }
        let seconds = Int(query.duration)
        let scored = tracks.compactMap { track -> (String, Double)? in
            guard let id = valueString(track["id"]), let attributes = track["attributes"] as? [String: Any] else { return nil }
            let duration = Int((valueDouble(attributes["durationInMillis"]) ?? 0) / 1_000)
            if seconds > 0, duration > 0, abs(duration - seconds) > 10 { return nil }
            let title = valueString(attributes["name"])?.lowercased() ?? ""
            let artist = valueString(attributes["artistName"])?.lowercased() ?? ""
            let targetTitle = query.title.lowercased()
            let targetArtist = query.artist.lowercased()
            var score = title == targetTitle ? 80.0 : (title.contains(targetTitle) || targetTitle.contains(title) ? 40 : 0)
            if artist.contains(targetArtist) || targetArtist.contains(artist) { score += 40 }
            return (id, score)
        }
        return scored.max(by: { $0.1 < $1.1 })?.0
    }

    private func appleToken() async -> String? {
        if let cachedToken { return cachedToken }
        guard let home = URL(string: "https://music.apple.com/us/new"),
              let homeResponse = try? await transport.send(lyricsRequest(home)),
              let html = String(data: successfulData(homeResponse) ?? Data(), encoding: .utf8),
              let scriptPath = html.firstMatch(#"/assets/index~[^\"]+\.js"#),
              let scriptURL = URL(string: "https://music.apple.com\(scriptPath)"),
              let scriptResponse = try? await transport.send(lyricsRequest(scriptURL)),
              let script = String(data: successfulData(scriptResponse) ?? Data(), encoding: .utf8),
              let token = script.firstMatch(#"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#) else { return nil }
        cachedToken = token
        return token
    }

    private func cleaned(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: #"\s*[(\[](official|video|audio|lyrics?|visualizer|hd|hq|4k|remaster\w*|live|version|feat\.?|ft\.?)[^)\]]*[)\]]"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct KuGouProvider: LyricsFetching {
    let source = LyricsSource.kuGou
    let transport: any LyricsHTTPTransport

    func fetch(_ query: LyricsQuery) async -> [LyricLine]? {
        let keyword = [stripParenthetical(query.title), stripParenthetical(query.artist), query.album]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - ")
        let seconds = Int(query.duration)
        var candidates: [[String: Any]] = []
        if let songURL = url("https://mobileservice.kugou.com/api/v3/search/song", [
            URLQueryItem(name: "version", value: "9108"), URLQueryItem(name: "plat", value: "0"),
            URLQueryItem(name: "pagesize", value: "8"), URLQueryItem(name: "showtype", value: "0"),
            URLQueryItem(name: "keyword", value: keyword)
        ]), let response = try? await transport.send(lyricsRequest(songURL)),
           let data = jsonObject(successfulData(response))?["data"] as? [String: Any],
           let info = data["info"] as? [[String: Any]] {
            let hashes = info.filter {
                seconds <= 0 || abs(Int(valueDouble($0["duration"]) ?? -1) - seconds) <= 8
            }.sorted {
                abs(Int(valueDouble($0["duration"]) ?? -1) - seconds) < abs(Int(valueDouble($1["duration"]) ?? -1) - seconds)
            }.compactMap { valueString($0["hash"]) }
            for hash in hashes {
                if let found = await searchCandidates([URLQueryItem(name: "hash", value: hash)]), !found.isEmpty {
                    candidates = found
                    break
                }
            }
        }
        if candidates.isEmpty {
            var items = [URLQueryItem(name: "keyword", value: keyword)]
            if seconds > 0 { items.append(URLQueryItem(name: "duration", value: String(seconds * 1_000))) }
            candidates = await searchCandidates(items) ?? []
        }
        guard let candidate = candidates.first,
              let id = valueString(candidate["id"]), let accessKey = valueString(candidate["accesskey"]),
              let endpoint = url("https://lyrics.kugou.com/download", [
                URLQueryItem(name: "fmt", value: "lrc"), URLQueryItem(name: "charset", value: "utf8"),
                URLQueryItem(name: "client", value: "pc"), URLQueryItem(name: "ver", value: "1"),
                URLQueryItem(name: "id", value: id), URLQueryItem(name: "accesskey", value: accessKey)
              ]), let response = try? await transport.send(lyricsRequest(endpoint)),
              let content = valueString(jsonObject(successfulData(response))?["content"]),
              let decoded = Data(base64Encoded: content).flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        return LyricsParsers.parseLRC(stripCredits(decoded)).nilIfEmpty
    }

    private func searchCandidates(_ extra: [URLQueryItem]) async -> [[String: Any]]? {
        let fixed = [URLQueryItem(name: "ver", value: "1"), URLQueryItem(name: "man", value: "yes"), URLQueryItem(name: "client", value: "pc")]
        guard let endpoint = url("https://lyrics.kugou.com/search", fixed + extra),
              let response = try? await transport.send(lyricsRequest(endpoint)) else { return nil }
        return jsonObject(successfulData(response))?["candidates"] as? [[String: Any]]
    }

    private func stripParenthetical(_ value: String?) -> String? {
        value?.replacingOccurrences(of: #"[(（].*?[)）]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripCredits(_ raw: String) -> String {
        let stamped = raw.components(separatedBy: .newlines).filter {
            $0.range(of: #"^\[\d{2}:\d{2}\.\d{2,3}\].*"#, options: .regularExpression) != nil
        }
        guard !stamped.isEmpty else { return "" }
        func isCredit(_ line: String) -> Bool {
            line.range(of: #".+\][^\[]+[:：].+"#, options: .regularExpression) != nil
        }
        let headLimit = min(30, stamped.count - 1)
        let headCut = stride(from: headLimit, through: 0, by: -1).first { isCredit(stamped[$0]) }.map { $0 + 1 } ?? 0
        let body = Array(stamped.dropFirst(headCut))
        guard !body.isEmpty else { return "" }
        let tailLimit = min(30, body.count - 1)
        let tailCut = (0...tailLimit).first { isCredit(body[body.count - 1 - $0]) }.map { $0 + 1 } ?? 0
        return body.dropLast(tailCut).joined(separator: "\n")
    }
}

private actor MusixmatchProvider: LyricsFetching {
    nonisolated let source = LyricsSource.musixmatch
    let transport: any LyricsHTTPTransport
    private var token: String?
    private let base = "https://apic.musixmatch.com/ws/1.1"
    private let secret = "RJDefUswhwjkZDeM"

    init(transport: any LyricsHTTPTransport) { self.transport = transport }

    func fetch(_ query: LyricsQuery) async -> [LyricLine]? {
        guard let track = await bestTrack(query),
              Int(valueDouble(track["has_subtitles"]) ?? 0) == 1,
              let trackID = valueString(track["track_id"]),
              let response = await signedResponse(path: "track.subtitle.get", items: [
                URLQueryItem(name: "app_id", value: "web-desktop-app-v1.0"),
                URLQueryItem(name: "track_id", value: trackID),
                URLQueryItem(name: "subtitle_format", value: "mxm")
              ]),
              let message = response["message"] as? [String: Any],
              let body = message["body"] as? [String: Any],
              let subtitle = body["subtitle"] as? [String: Any],
              let subtitleBody = valueString(subtitle["subtitle_body"]),
              let data = subtitleBody.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let lines = rows.compactMap { row -> LyricLine? in
            guard let text = valueString(row["text"])?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let time = row["time"] as? [String: Any], let total = valueDouble(time["total"]) else { return nil }
            return LyricLine(start: total, text: text)
        }
        return LyricsParsers.withInstrumentalGaps(lines).nilIfEmpty
    }

    private func bestTrack(_ query: LyricsQuery) async -> [String: Any]? {
        guard let response = await signedResponse(path: "track.search", items: [
            URLQueryItem(name: "app_id", value: "web-desktop-app-v1.0"),
            URLQueryItem(name: "q_track", value: query.title), URLQueryItem(name: "q_artist", value: query.artist),
            URLQueryItem(name: "f_has_lyrics", value: "1"), URLQueryItem(name: "s_track_rating", value: "desc"),
            URLQueryItem(name: "quorum_factor", value: "1"), URLQueryItem(name: "page_size", value: "10"),
            URLQueryItem(name: "page", value: "1")
        ]), let message = response["message"] as? [String: Any],
              let body = message["body"] as? [String: Any],
              let wrappers = body["track_list"] as? [[String: Any]] else { return nil }
        let tracks = wrappers.compactMap { $0["track"] as? [String: Any] }
        return tracks.max { score($0, query) < score($1, query) }
    }

    private func score(_ track: [String: Any], _ query: LyricsQuery) -> Double {
        let name = valueString(track["track_name"])?.lowercased() ?? ""
        let target = query.title.lowercased()
        var score = name == target ? 80.0 : (name.contains(target) || target.contains(name) ? 40 : 0)
        let artist = valueString(track["artist_name"])?.lowercased() ?? ""
        if artist.contains(query.artist.lowercased()) { score += 40 }
        if let length = valueDouble(track["track_length"]), query.duration > 0 {
            let difference = abs(length - query.duration)
            score += difference <= 2 ? 30 : difference <= 5 ? 15 : difference <= 10 ? 5 : -20
        }
        return score
    }

    private func signedResponse(path: String, items: [URLQueryItem], retry: Bool = true) async -> [String: Any]? {
        guard let token = await userToken(),
              let unsigned = url("\(base)/\(path)", items + [URLQueryItem(name: "usertoken", value: token)]),
              let signed = signedURL(unsigned),
              let raw = try? await transport.send(lyricsRequest(signed)),
              let object = jsonObject(successfulData(raw)) else { return nil }
        let status = ((object["message"] as? [String: Any])?["header"] as? [String: Any])
            .flatMap { valueDouble($0["status_code"]) }.map(Int.init) ?? 0
        if retry, status == 401 || status == 402 {
            self.token = nil
            return await signedResponse(path: path, items: items, retry: false)
        }
        return object
    }

    private func userToken() async -> String? {
        if let token { return token }
        guard let unsigned = url("\(base)/token.get", [URLQueryItem(name: "app_id", value: "web-desktop-app-v1.0")]),
              let signed = signedURL(unsigned),
              let response = try? await transport.send(lyricsRequest(signed)),
              let message = jsonObject(successfulData(response))?["message"] as? [String: Any],
              let body = message["body"] as? [String: Any],
              let token = valueString(body["user_token"]) else { return nil }
        self.token = token
        return token
    }

    private func signedURL(_ unsigned: URL) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        let payload = Data((unsigned.absoluteString + formatter.string(from: Date())).utf8)
        let key = SymmetricKey(data: Data(secret.utf8))
        let signature = Data(HMAC<SHA256>.authenticationCode(for: payload, using: key)).base64EncodedString()
        guard var components = URLComponents(url: unsigned, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "signature", value: signature),
            URLQueryItem(name: "signature_protocol", value: "sha256")
        ]
        return components.url
    }
}

private extension Collection {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

private extension String {
    func firstMatch(_ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..<endIndex, in: self)),
              let range = Range(match.range, in: self) else { return nil }
        return String(self[range])
    }
}
