import Foundation
import JavaScriptCore
import os

enum ModuleSourceHealth: Equatable, Sendable {
    case notConfigured
    case checking
    case connected(moduleCount: Int)
    case unreachable(String)
    case rejected(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var statusLine: String {
        switch self {
        case .notConfigured:
            "No compatible module index configured"
        case .checking:
            "Checking module index…"
        case .connected(let count):
            "Connected · \(count) module\(count == 1 ? "" : "s")"
        case .unreachable(let reason):
            "Can't reach it right now · \(reason)"
        case .rejected(let reason):
            reason
        }
    }
}

private struct SourceModuleDescriptor: Decodable, Sendable {
    let id: String
    let name: String
    let author: String?
    let version: String?
    let download: String
    let tags: [String]?
    let labels: [String]?

    var capabilities: [String] {
        if let tags, !tags.isEmpty { return tags }
        return labels ?? []
    }
}

private struct ModuleSearchResponse: Decodable {
    let tracks: [ModuleSearchTrack]
    let total: Int?
}

private struct ModuleSearchTrack: Decodable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let albumCover: String?
    let duration: Int?
    let audioQuality: String?
    let format: String?
    let availableQualities: [String]?
}

private struct ModuleStreamResponse: Decodable {
    let streamUrl: String
    let track: ModuleStreamTrack?
}

private struct ModuleStreamTrack: Decodable {
    let audioQuality: String?
    let mimeType: String?
    let bitDepth: Int?
    let sampleRate: Double?
}

private enum ModuleEvent: Sendable {
    case candidate(ResolvedStream)
    case finished
}

private enum ModuleSourceError: LocalizedError {
    case invalidIndexURL
    case invalidResponse
    case noModules
    case missingExport(String)
    case javaScript(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidIndexURL: "Enter a valid http or https module-index URL."
        case .invalidResponse: "The module index returned an invalid response."
        case .noModules: "The index answered but listed no compatible music modules."
        case .missingExport(let name): "The module does not export \(name)()."
        case .javaScript(let message): "Module error: \(message)"
        case .timedOut: "The module did not answer in time."
        }
    }
}

private enum ModuleIndexParser {
    static func parse(_ data: Data) throws -> [SourceModuleDescriptor] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModuleSourceError.invalidResponse
        }
        let excluded = Set(["category:artworks", "category:testing"])
        let decoder = JSONDecoder()
        var seen = Set<String>()
        var modules: [SourceModuleDescriptor] = []

        for key in root.keys.sorted() where key.hasPrefix("category:") && !excluded.contains(key) {
            guard let array = root[key] as? [Any],
                  let encoded = try? JSONSerialization.data(withJSONObject: array),
                  let decoded = try? decoder.decode([SourceModuleDescriptor].self, from: encoded) else {
                continue
            }
            for module in decoded where !module.id.isEmpty && !module.download.isEmpty {
                if seen.insert(module.id).inserted { modules.append(module) }
            }
        }
        return modules
    }
}

/// The same identity gate used by the Kotlin source resolver. Packaging such
/// as "Official Audio" and film names is ignored, while remix/live/acoustic
/// markers and a materially different duration remain hard vetoes.
enum SourceTrackMatcher {
    private struct TitleParts {
        let core: String
        let versions: Set<String>
    }

    static func queries(for track: Track) -> [String] {
        let title = searchableTitle(track.title)
        guard !title.isEmpty else { return [] }
        let artist = primaryArtist(track.artist)
        return artist.isEmpty ? [title] : ["\(title) \(artist)", title]
    }

    fileprivate static func ranked(_ candidates: [ModuleSearchTrack], for target: Track) -> [ModuleSearchTrack] {
        candidates.compactMap { candidate in
            score(candidate, target: target).map { (candidate, $0) }
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// Used by the YouTube video→catalogue-audio path. It deliberately shares
    /// the module identity gate so neither resolver can substitute a cover,
    /// remix, live take or materially different edit under the requested row.
    static func best(_ candidates: [Track], for target: Track) -> Track? {
        candidates.compactMap { candidate in
            score(
                title: candidate.title,
                artist: candidate.artist,
                duration: candidate.duration,
                target: target
            ).map { (candidate, $0) }
        }
        .max { $0.1 < $1.1 }?
        .0
    }

    private static func score(_ candidate: ModuleSearchTrack, target: Track) -> Int? {
        score(
            title: candidate.title,
            artist: candidate.artist,
            duration: candidate.duration.map(TimeInterval.init),
            target: target
        )
    }

    private static func score(
        title: String,
        artist: String,
        duration: TimeInterval?,
        target: Track
    ) -> Int? {
        let wanted = titleParts(target.title)
        let got = titleParts(title)
        guard !wanted.core.isEmpty, wanted.core == got.core, wanted.versions == got.versions else {
            return nil
        }

        var score = 100
        if let wantedDuration = target.duration, wantedDuration > 0,
           let duration, duration > 0 {
            let drift = abs(Int(wantedDuration.rounded()) - Int(duration.rounded()))
            guard drift <= 12 else { return nil }
            score += drift <= 2 ? 40 : 15
        }

        let wantedArtists = artistNames(target.artist)
        let candidateArtists = artistNames(artist)
        if !wantedArtists.isEmpty && !candidateArtists.isEmpty {
            let sharesCredit = wantedArtists.contains { wanted in
                candidateArtists.contains { candidate in
                    containsWords(wanted, candidate) || containsWords(candidate, wanted)
                }
            }
            if !sharesCredit {
                guard let wantedDuration = target.duration,
                      let duration,
                      abs(Int(wantedDuration.rounded()) - Int(duration.rounded())) <= 2 else { return nil }
                score -= 15
            } else {
                score += wantedArtists == candidateArtists ? 25 : 10
            }
        }
        return score
    }

    private static func searchableTitle(_ title: String) -> String {
        let parts = titleParts(title)
        let rawWords = title
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: #"\([^)]*\)|\[[^]]*\]"#, with: " ", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let significantWords = rawWords.filter { !noiseWords.contains($0) }
        let words = significantWords.isEmpty ? rawWords : significantWords
        return (words + parts.versions.sorted()).joined(separator: " ")
    }

    private static func titleParts(_ raw: String) -> TitleParts {
        let lower = raw.lowercased().replacingOccurrences(of: "&", with: " and ")
        var versions = Set<String>()
        for marker in versionWords where lower.range(of: "\\b\(NSRegularExpression.escapedPattern(for: marker))\\b", options: .regularExpression) != nil {
            versions.insert(marker)
        }

        var cleaned = lower
            .replacingOccurrences(of: #"\([^)]*\)|\[[^]]*\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(feat|featuring|ft)\.?\s+.*$"#, with: " ", options: [.regularExpression, .caseInsensitive])
        if let split = cleaned.range(of: #"\s[-–—|]\s"#, options: .regularExpression) {
            cleaned = String(cleaned[..<split.lowerBound])
        }
        var words = cleaned
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !joiningWords.contains($0) }
        while words.count > 1, let last = words.last, noiseWords.contains(last) {
            words.removeLast()
        }
        return TitleParts(core: words.joined(), versions: versions)
    }

    private static func primaryArtist(_ value: String) -> String {
        artistNames(value).first?.joined(separator: " ") ?? ""
    }

    private static func artistNames(_ value: String) -> [[String]] {
        value.lowercased()
            .replacingOccurrences(of: #"\b(feat|featuring|ft)\.?\b"#, with: ",", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: ",&;/+"))
            .map {
                $0.components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count > 1 }
            }
            .filter { !$0.isEmpty }
    }

    private static func containsWords(_ outer: [String], _ inner: [String]) -> Bool {
        guard !inner.isEmpty, inner.count <= outer.count else { return false }
        return (0...(outer.count - inner.count)).contains { index in
            Array(outer[index..<(index + inner.count)]) == inner
        }
    }

    private static let versionWords = Set([
        "remix", "live", "acoustic", "instrumental", "karaoke", "sped", "slowed", "reverb"
    ])
    private static let joiningWords = Set(["a", "an", "the"])
    private static let noiseWords = Set([
        "official", "audio", "video", "lyrics", "lyric", "song", "full", "music", "hd", "remastered"
    ])
}

private final class SynchronousFetchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<(Int, String), Error>?

    func set(_ value: Result<(Int, String), Error>) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func get() -> Result<(Int, String), Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// JavaScriptCore host for the CommonJS-compatible modules used by BitChord's
/// Android app. The module can access only the web-shaped helpers installed
/// here; no AppKit or filesystem object is exposed to JavaScript.
private final class ModuleJavaScriptRuntime: @unchecked Sendable {
    private let queue: DispatchQueue
    private let context: JSContext
    private let session: URLSession
    private let fetchBase: URL
    private let logger = Logger(subsystem: "com.bitchord.mac", category: "SourceModuleJS")

    init(moduleID: String, code: String, fetchBase: URL, session: URLSession) throws {
        guard let context = JSContext() else { throw ModuleSourceError.javaScript("Could not create JavaScriptCore context") }
        self.queue = DispatchQueue(label: "com.bitchord.mac.source-module.\(moduleID)")
        self.context = context
        self.session = session
        self.fetchBase = fetchBase
        try queue.sync { try install(code: code) }
    }

    func call(function: String, arguments: [Any], timeout: TimeInterval = 30) throws -> Data {
        try queue.sync {
            let argumentData = try JSONSerialization.data(withJSONObject: arguments)
            let argumentJSON = String(decoding: argumentData, as: UTF8.self)
            context.setObject(argumentJSON, forKeyedSubscript: "__bitchordArgsJSON" as NSString)
            context.setObject(function, forKeyedSubscript: "__bitchordFunction" as NSString)
            context.evaluateScript(
                """
                var __bitchordDone = false;
                var __bitchordResult = null;
                var __bitchordCallError = null;
                (function() {
                    try {
                        var fn = __bitchordModule[__bitchordFunction];
                        if (typeof fn !== 'function') throw new Error(__bitchordFunction + ' is not exported');
                        Promise.resolve(fn.apply(null, JSON.parse(__bitchordArgsJSON))).then(function(value) {
                            __bitchordResult = typeof value === 'string' ? value : JSON.stringify(value);
                            __bitchordDone = true;
                        }, function(error) {
                            __bitchordCallError = error && error.message ? error.message : String(error);
                            __bitchordDone = true;
                        });
                    } catch (error) {
                        __bitchordCallError = error && error.message ? error.message : String(error);
                        __bitchordDone = true;
                    }
                })();
                """
            )

            let deadline = Date().addingTimeInterval(timeout)
            while context.objectForKeyedSubscript("__bitchordDone")?.toBool() != true {
                if Date() >= deadline { throw ModuleSourceError.timedOut }
                _ = context.evaluateScript("void 0")
                Thread.sleep(forTimeInterval: 0.002)
            }
            if let message = context.objectForKeyedSubscript("__bitchordCallError")?.toString(),
               !message.isEmpty, message != "null" {
                throw ModuleSourceError.javaScript(message)
            }
            guard let result = context.objectForKeyedSubscript("__bitchordResult")?.toString(),
                  let data = result.data(using: .utf8) else {
                throw ModuleSourceError.invalidResponse
            }
            return data
        }
    }

    private func install(code: String) throws {
        var exceptionMessage: String?
        context.exceptionHandler = { [weak self] _, exception in
            exceptionMessage = exception?.toString() ?? "Unknown JavaScript exception"
            self?.logger.error("Module JS exception: \(exceptionMessage ?? "unknown", privacy: .public)")
        }

        let nativeFetch: @convention(block) (String, String, String, String) -> String = { [weak self] url, method, headers, body in
            guard let self else { return #"{"status":599,"ok":false,"body":"Runtime released"}"# }
            do {
                let response = try self.fetch(url: url, method: method, headersJSON: headers, body: body)
                let object: [String: Any] = [
                    "status": response.0,
                    "ok": (200..<300).contains(response.0),
                    "body": response.1
                ]
                let data = try JSONSerialization.data(withJSONObject: object)
                return String(decoding: data, as: UTF8.self)
            } catch {
                let object: [String: Any] = ["status": 599, "ok": false, "body": error.localizedDescription]
                let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
                return String(decoding: data, as: UTF8.self)
            }
        }
        let nativeSleep: @convention(block) (Double) -> Void = { milliseconds in
            Thread.sleep(forTimeInterval: min(max(milliseconds, 0), 30_000) / 1_000)
        }
        context.setObject(nativeFetch, forKeyedSubscript: "__bitchordNativeFetch" as NSString)
        context.setObject(nativeSleep, forKeyedSubscript: "__bitchordNativeSleep" as NSString)

        _ = context.evaluateScript(Self.polyfills)
        let cleanCode = Self.preprocess(code)
        context.setObject(cleanCode, forKeyedSubscript: "__bitchordModuleCode" as NSString)
        _ = context.evaluateScript(
            """
            var __bitchordInitError = null;
            var __bitchordModule = (function() {
                try {
                    var module = { exports: {} };
                    var exports = module.exports;
                    var self = {};
                    eval(__bitchordModuleCode);
                    if (!module.exports.searchTracks && typeof searchTracks === 'function') module.exports.searchTracks = searchTracks;
                    if (!module.exports.getTrackStreamUrl && typeof getTrackStreamUrl === 'function') module.exports.getTrackStreamUrl = getTrackStreamUrl;
                    return module.exports;
                } catch (error) {
                    __bitchordInitError = error && error.message ? error.message : String(error);
                    return {};
                }
            })();
            "ok";
            """
        )
        if let message = context.objectForKeyedSubscript("__bitchordInitError")?.toString(),
           !message.isEmpty, message != "null" {
            throw ModuleSourceError.javaScript(message)
        }
        if let exceptionMessage { throw ModuleSourceError.javaScript(exceptionMessage) }
    }

    private func fetch(url rawURL: String, method: String, headersJSON: String, body: String) throws -> (Int, String) {
        let resolved: URL?
        if let absolute = URL(string: rawURL), absolute.scheme != nil {
            resolved = absolute
        } else {
            resolved = URL(string: rawURL, relativeTo: fetchBase)?.absoluteURL
        }
        guard let url = resolved, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw ModuleSourceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        request.timeoutInterval = 20
        if let data = headersJSON.data(using: .utf8),
           let headers = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (name, value) in headers { request.setValue(String(describing: value), forHTTPHeaderField: name) }
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/130 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
        }
        if !body.isEmpty, !["GET", "HEAD"].contains(request.httpMethod ?? "GET") {
            request.httpBody = body.data(using: .utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = SynchronousFetchBox()
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.set(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                box.set(.failure(ModuleSourceError.invalidResponse))
                return
            }
            box.set(.success((http.statusCode, String(decoding: data ?? Data(), as: UTF8.self))))
        }.resume()
        guard semaphore.wait(timeout: .now() + 22) == .success,
              let result = box.get() else { throw ModuleSourceError.timedOut }
        return try result.get()
    }

    private static func preprocess(_ raw: String) -> String {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = code.range(of: #"^export\s+const\s+\w+\s*=\s*`"#, options: .regularExpression) {
            let start = match.upperBound
            var index = start
            while index < code.endIndex {
                if code[index] == "`" {
                    let previous = index > start ? code.index(before: index) : index
                    if previous == index || code[previous] != "\\" {
                        return String(code[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                index = code.index(after: index)
            }
        }
        return code
            .replacingOccurrences(of: #"\bexport\s+default\s+(?=(function|class|const|let|var|async))"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\bexport\s+(const|let|var|function|class|async)\b"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\bexport\s*\{[^}]*\}\s*;?"#, with: "", options: .regularExpression)
    }

    private static let polyfills = #"""
        var globalThis = this;
        var console = {
            log: function() {}, info: function() {}, warn: function() {}, error: function() {}
        };
        if (typeof AbortController === 'undefined') {
            var AbortController = function() { this.signal = { aborted: false }; };
            AbortController.prototype.abort = function() { this.signal.aborted = true; };
        }
        if (typeof Object.assign !== 'function') {
            Object.assign = function(target) {
                for (var i = 1; i < arguments.length; i++) {
                    var source = arguments[i] || {};
                    for (var key in source) if (Object.prototype.hasOwnProperty.call(source, key)) target[key] = source[key];
                }
                return target;
            };
        }
        if (typeof Promise.allSettled !== 'function') {
            Promise.allSettled = function(values) {
                return Promise.all(values.map(function(value) {
                    return Promise.resolve(value).then(
                        function(result) { return { status: 'fulfilled', value: result }; },
                        function(error) { return { status: 'rejected', reason: error }; }
                    );
                }));
            };
        }
        if (typeof URL === 'undefined') {
            var URL = function(value, base) {
                var raw = String(value);
                if (base && !/^https?:\/\//i.test(raw)) raw = String(base).replace(/\/$/, '') + '/' + raw.replace(/^\//, '');
                this.href = raw;
                var match = raw.match(/^https?:\/\/([^/]+)(\/.*)?$/i);
                this.hostname = match ? match[1] : '';
                this.pathname = match ? (match[2] || '/') : raw;
                this.toString = function() { return this.href; };
            };
        }
        if (typeof atob === 'undefined') {
            var atob = function(input) {
                var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
                var str = String(input).replace(/=+$/, '');
                var output = '';
                for (var bc = 0, bs, buffer, idx = 0; buffer = str.charAt(idx++); ~buffer &&
                    (bs = bc % 4 ? bs * 64 + buffer : buffer, bc++ % 4) ?
                    output += String.fromCharCode(255 & bs >> (-2 * bc & 6)) : 0) {
                    buffer = chars.indexOf(buffer);
                }
                return output;
            };
        }
        var fetch = function(url, options) {
            options = options || {};
            if (options.signal && options.signal.aborted) throw new Error('Aborted');
            var headers = '{}';
            try { headers = typeof options.headers === 'string' ? options.headers : JSON.stringify(options.headers || {}); } catch (_) {}
            var body = options.body == null ? '' : (typeof options.body === 'string' ? options.body : JSON.stringify(options.body));
            var raw = JSON.parse(__bitchordNativeFetch(String(url), options.method || 'GET', headers, body));
            var responseBody = raw.body || '';
            return {
                ok: !!raw.ok,
                status: raw.status,
                statusText: raw.ok ? 'OK' : 'Error',
                json: function() { return JSON.parse(responseBody); },
                text: function() { return responseBody; },
                clone: function() { return this; },
                headers: { get: function(_) { return null; } }
            };
        };
        var setTimeout = function(fn, ms) {
            __bitchordNativeSleep(Number(ms || 0));
            if (typeof fn === 'function') fn();
            return 0;
        };
        var clearTimeout = function(_) {};
    """#
}

private final class ModuleSourceService: @unchecked Sendable {
    private struct CachedIndex {
        let modules: [SourceModuleDescriptor]
        let fetchedAt: Date
    }

    private let session: URLSession
    private let lock = NSLock()
    private var indexCache: [URL: CachedIndex] = [:]
    private var runtimes: [String: ModuleJavaScriptRuntime] = [:]
    private let decoder = JSONDecoder()

    init(session: URLSession) {
        self.session = session
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func health(indexURL: URL) async throws -> Int {
        let modules = try await fetchIndex(indexURL)
        guard !modules.isEmpty else { throw ModuleSourceError.noModules }
        return modules.count
    }

    func resolve(track: Track, indexURL: URL, sourceLabel: String) async -> ResolvedStream? {
        guard let modules = try? await fetchIndex(indexURL), !modules.isEmpty else { return nil }
        let stream = AsyncStream<ModuleEvent> { continuation in
            for module in modules {
                Task {
                    if let candidate = try? await self.resolve(
                        track: track,
                        module: module,
                        indexURL: indexURL,
                        sourceLabel: sourceLabel
                    ) {
                        continuation.yield(.candidate(candidate))
                    }
                    continuation.yield(.finished)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(25))
                continuation.finish()
            }
        }

        var finished = 0
        for await event in stream {
            switch event {
            case .candidate(let candidate):
                return candidate
            case .finished:
                finished += 1
                if finished == modules.count { return nil }
            }
        }
        return nil
    }

    private func fetchIndex(_ url: URL) async throws -> [SourceModuleDescriptor] {
        let cached = withStateLock { indexCache[url] }
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < 10 * 60 {
            return cached.modules
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModuleSourceError.invalidResponse
        }
        let modules = try ModuleIndexParser.parse(data)
        withStateLock { indexCache[url] = CachedIndex(modules: modules, fetchedAt: Date()) }
        return modules
    }

    private func resolve(
        track: Track,
        module: SourceModuleDescriptor,
        indexURL: URL,
        sourceLabel: String
    ) async throws -> ResolvedStream? {
        let runtime = try await loadRuntime(module: module, indexURL: indexURL)
        let context: [String: Any] = ["settings": [:]]
        var allCandidates: [ModuleSearchTrack] = []
        for query in SourceTrackMatcher.queries(for: track) {
            let data = try runtime.call(function: "searchTracks", arguments: [query, 15, context])
            guard let response = decodeSearchResponse(data) else { continue }
            allCandidates += response.tracks
            if !SourceTrackMatcher.ranked(allCandidates, for: track).isEmpty { break }
        }

        let ranked = SourceTrackMatcher.ranked(allCandidates, for: track)
        guard !ranked.isEmpty else { return nil }
        let preferred = ranked.sorted { qualityRank($0) > qualityRank($1) }
        let settings: [String: Any] = [
            "settings": [
                "quality": ["value": "LOSSLESS"],
                "fallbackMode": ["value": "strict"]
            ]
        ]

        var lossyFloor: ResolvedStream?
        for candidate in preferred.prefix(3) {
            let data = try runtime.call(
                function: "getTrackStreamUrl",
                arguments: [candidate.id, "LOSSLESS", settings]
            )
            guard let response = try? decoder.decode(ModuleStreamResponse.self, from: data),
                  let streamURL = URL(string: response.streamUrl),
                  !Self.malformed(streamURL) else { continue }
            let info = streamInfo(
                response: response,
                candidate: candidate,
                streamURL: streamURL,
                sourceName: sourceLabel.isEmpty ? module.name : sourceLabel
            )
            let stream = ResolvedStream(url: streamURL, headers: [:], info: info)
            if info.isLossless || (info.codec == nil && info.bitrateKbps == nil) { return stream }
            if lossyFloor == nil || info.isMeaningfullyBetter(than: lossyFloor?.info) { lossyFloor = stream }
        }
        return lossyFloor
    }

    private func loadRuntime(module: SourceModuleDescriptor, indexURL: URL) async throws -> ModuleJavaScriptRuntime {
        let key = "\(indexURL.absoluteString)|\(module.id)|\(module.version ?? "")"
        let cached = withStateLock { runtimes[key] }
        if let cached { return cached }

        let directory = indexURL.deletingLastPathComponent()
        guard let downloadURL = URL(string: module.download, relativeTo: directory)?.absoluteURL else {
            throw ModuleSourceError.invalidResponse
        }
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let code = String(data: data, encoding: .utf8) else {
            throw ModuleSourceError.invalidResponse
        }
        let runtime = try ModuleJavaScriptRuntime(
            moduleID: module.id,
            code: code,
            fetchBase: downloadURL.deletingLastPathComponent(),
            session: session
        )
        withStateLock { runtimes[key] = runtime }
        return runtime
    }

    private func decodeSearchResponse(_ data: Data) -> ModuleSearchResponse? {
        if let direct = try? decoder.decode(ModuleSearchResponse.self, from: data) { return direct }
        guard let string = String(data: data, encoding: .utf8),
              let nested = string.data(using: .utf8) else { return nil }
        return try? decoder.decode(ModuleSearchResponse.self, from: nested)
    }

    private func qualityRank(_ track: ModuleSearchTrack) -> Int {
        let stated = "\(track.audioQuality ?? "") \(track.format ?? "")"
        if Self.qualityTier(stated) == "LOSSLESS" { return 3 }
        if Self.qualityTier(stated) == "HIGH" { return 2 }
        let available = track.availableQualities ?? []
        if available.contains(where: { Self.qualityTier($0) == "LOSSLESS" }) { return 3 }
        if available.contains(where: { Self.qualityTier($0) == "HIGH" }) { return 2 }
        return 1
    }

    private func streamInfo(
        response: ModuleStreamResponse,
        candidate: ModuleSearchTrack,
        streamURL: URL,
        sourceName: String
    ) -> AudioStreamInfo {
        let quality = response.track?.audioQuality ?? candidate.audioQuality ?? ""
        let mimeCodec = response.track?.mimeType?
            .split(separator: "/").last?
            .split(separator: ";").first
            .map(String.init)
        let extensionCodec = streamURL.pathExtension.isEmpty ? nil : streamURL.pathExtension
        let codec: String?
        if let mimeCodec, !mimeCodec.isEmpty {
            codec = mimeCodec.lowercased()
        } else if Self.qualityTier(quality) == "LOSSLESS" {
            codec = "flac"
        } else {
            codec = extensionCodec?.lowercased()
        }
        return AudioStreamInfo(
            requestedQuality: .high,
            bitrateKbps: Self.kbps(in: quality) ?? Self.kbps(in: streamURL.absoluteString),
            codec: codec?.uppercased(),
            sampleRate: response.track?.sampleRate.map { Int($0.rounded()) },
            channels: 2,
            bitDepth: response.track?.bitDepth,
            sourceName: sourceName
        )
    }

    static func qualityTier(_ value: String) -> String? {
        let text = value.uppercased()
        if ["LOSSLESS", "FLAC", "ALAC", "HI-RES", "HI_RES", "HIRES", "24-BIT", "16-BIT", "WAV"].contains(where: text.contains) {
            return "LOSSLESS"
        }
        if ["LOW", "128", "96KBPS", "64"].contains(where: text.contains) { return "LOW" }
        if ["HIGH", "320", "MP3", "AAC", "M4A", "OPUS", "OGG"].contains(where: text.contains) { return "HIGH" }
        return nil
    }

    private static func kbps(in value: String) -> Int? {
        let patterns = [#"(\d{2,4})\s*kbps"#, #"\.(\d{2,4})\.(?:mp3|m4a|aac|ogg)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = Range(match.range(at: 1), in: value),
                  let number = Int(value[range]), (8...2_000).contains(number) else { continue }
            return number
        }
        return nil
    }

    static func malformed(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return true }
        let origin = "\(url.scheme ?? "https")://\(host)"
        let absolute = url.absoluteString
        guard let first = absolute.range(of: origin) else { return true }
        return absolute.range(of: origin, range: first.upperBound..<absolute.endIndex) != nil
    }
}

@MainActor
final class SourceModuleManager: ObservableObject {
    @Published private(set) var indexURLString: String
    @Published private(set) var label: String
    @Published private(set) var enabled: Bool
    @Published private(set) var jioSaavnEnabled: Bool
    @Published private(set) var health: ModuleSourceHealth
    @Published private(set) var lastResolvedSource: String?

    private static let urlKey = "BitChord.sources.customModuleURL"
    private static let labelKey = "BitChord.sources.customModuleLabel"
    private static let enabledKey = "BitChord.sources.customModuleEnabled"
    private static let jioSaavnEnabledKey = "BitChord.sources.jioSaavnEnabled"

    private let defaults: UserDefaults
    private let service: ModuleSourceService
    private let jioSaavn: JioSaavnService
    private let autoRefreshHealth: Bool
    private var playbackQuality: AudioQuality = .high

    init(
        defaults: UserDefaults = .standard,
        session: URLSession? = nil,
        jioSaavnService: JioSaavnService? = nil,
        autoRefreshHealth: Bool = true
    ) {
        self.defaults = defaults
        self.autoRefreshHealth = autoRefreshHealth
        let storedURL = defaults.string(forKey: Self.urlKey) ?? ""
        indexURLString = storedURL
        label = defaults.string(forKey: Self.labelKey) ?? ""
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        // A text match from a different catalogue must never silently replace
        // the exact YouTube Music video the user selected. JioSaavn remains an
        // explicit catalogue/search option, but starts disabled.
        jioSaavnEnabled = defaults.object(forKey: Self.jioSaavnEnabledKey) as? Bool ?? false
        health = storedURL.isEmpty ? .notConfigured : .checking
        if let session {
            service = ModuleSourceService(session: session)
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            service = ModuleSourceService(session: URLSession(configuration: configuration))
        }
        if let jioSaavnService {
            jioSaavn = jioSaavnService
        } else if let session {
            jioSaavn = JioSaavnService(session: session)
        } else {
            jioSaavn = JioSaavnService()
        }
        if autoRefreshHealth, !storedURL.isEmpty {
            Task { await refreshHealth() }
        }
    }

    var displayName: String {
        if !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return label }
        return URL(string: indexURLString)?.host ?? "Custom module"
    }

    var canResolve: Bool {
        enabled && playbackQuality == .high && validatedURL(indexURLString) != nil
    }

    var canResolveDownloads: Bool {
        enabled && validatedURL(indexURLString) != nil
    }

    var canResolveJioSaavn: Bool {
        jioSaavnEnabled && playbackQuality == .high
    }

    func setPlaybackQuality(_ quality: AudioQuality) {
        playbackQuality = quality
    }

    func setJioSaavnEnabled(_ enabled: Bool) {
        jioSaavnEnabled = enabled
        defaults.set(enabled, forKey: Self.jioSaavnEnabledKey)
    }

    func save(url: String, label: String, enabled: Bool) {
        let cleanedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanedURL.isEmpty || validatedURL(cleanedURL) != nil else {
            health = .rejected("Enter a valid http or https module-index URL.")
            return
        }
        indexURLString = cleanedURL
        self.label = cleanedLabel
        self.enabled = enabled
        defaults.set(cleanedURL, forKey: Self.urlKey)
        defaults.set(cleanedLabel, forKey: Self.labelKey)
        defaults.set(enabled, forKey: Self.enabledKey)
        health = cleanedURL.isEmpty ? .notConfigured : .checking
        if autoRefreshHealth, !cleanedURL.isEmpty { Task { await refreshHealth() } }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    func remove() {
        save(url: "", label: "", enabled: true)
        lastResolvedSource = nil
    }

    func probe(url: String) async -> ModuleSourceHealth {
        guard let url = validatedURL(url) else {
            return .rejected("Enter a valid http or https module-index URL.")
        }
        do {
            return .connected(moduleCount: try await service.health(indexURL: url))
        } catch let error as ModuleSourceError {
            return .rejected(error.localizedDescription)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    func refreshHealth() async {
        guard let url = validatedURL(indexURLString) else {
            health = indexURLString.isEmpty ? .notConfigured : .rejected("Enter a valid module-index URL.")
            return
        }
        health = .checking
        health = await probe(url: url.absoluteString)
    }

    func resolveStream(for track: Track) async -> ResolvedStream? {
        guard canResolve, let url = validatedURL(indexURLString) else { return nil }
        let stream = await service.resolve(track: track, indexURL: url, sourceLabel: displayName)
        if let source = stream?.info?.sourceName { lastResolvedSource = source }
        return stream
    }

    func searchJioSaavn(query: String, limit: Int = 10) async -> [Track] {
        guard jioSaavnEnabled else { return [] }
        return (try? await jioSaavn.search(query: query, limit: limit)) ?? []
    }

    func resolveJioSaavnStream(for track: Track) async -> ResolvedStream? {
        guard jioSaavnEnabled else { return nil }
        let stream: ResolvedStream?
        if track.catalogSource == .jioSaavn, let trackID = track.catalogTrackID {
            stream = try? await jioSaavn.stream(
                trackID: trackID,
                cacheID: track.downloadIdentifier,
                quality: playbackQuality
            )
        } else {
            guard canResolveJioSaavn else { return nil }
            stream = await jioSaavn.resolveMatch(for: track, quality: playbackQuality)
        }
        if stream != nil { lastResolvedSource = "JioSaavn" }
        return stream
    }

    /// JioSaavn is useful for permanent High downloads and as the best lossy
    /// fallback when a requested module lossless copy is unavailable.
    func resolveJioSaavnDownloadStream(for track: Track) async -> ResolvedStream? {
        guard jioSaavnEnabled else { return nil }
        let stream: ResolvedStream?
        if track.catalogSource == .jioSaavn, let trackID = track.catalogTrackID {
            stream = try? await jioSaavn.stream(
                trackID: trackID,
                cacheID: track.downloadIdentifier,
                quality: .high
            )
        } else {
            stream = await jioSaavn.resolveMatch(for: track, quality: .high)
        }
        guard let stream,
              stream.info?.isLossless != true,
              (stream.info?.bitrateKbps ?? 0) > 132 else { return nil }
        lastResolvedSource = "JioSaavn"
        return stream
    }

    /// Permanent lossless downloads are an explicit user choice and therefore
    /// do not inherit the active metered-network playback profile.
    func resolveDownloadStream(for track: Track) async -> ResolvedStream? {
        guard canResolveDownloads, let url = validatedURL(indexURLString) else { return nil }
        let stream = await service.resolve(track: track, indexURL: url, sourceLabel: displayName)
        guard stream?.info?.isLossless == true else { return nil }
        if let source = stream?.info?.sourceName { lastResolvedSource = source }
        return stream
    }

    private func validatedURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }
}

@MainActor
final class SourceAwarePlaybackResolver: PlaybackStreamResolving {
    private let youtube: any PlaybackStreamResolving
    private let sources: SourceModuleManager

    init(youtube: any PlaybackStreamResolving, sources: SourceModuleManager) {
        self.youtube = youtube
        self.sources = sources
    }

    var isAuthenticated: Bool { youtube.isAuthenticated }

    func resolvePlaybackTrack(for track: Track) async -> Track {
        if track.catalogSource != nil { return track }
        return await youtube.resolvePlaybackTrack(for: track)
    }

    func resolveStream(for track: Track) async throws -> ResolvedStream {
        if track.catalogSource == .jioSaavn {
            guard let stream = await sources.resolveJioSaavnStream(for: track) else {
                throw JioSaavnError.noPlayableStream
            }
            return stream
        }

        // A YouTube row owns a stable videoId. Resolving it through a textual
        // search in another catalogue can return a cover, edit or an entirely
        // different recording under the correct artwork and lyrics. Keep that
        // identity strict; source modules are still available for explicit
        // lossless downloads and JioSaavn rows play from their own catalogue.
        return try await youtube.resolveStream(for: track)
    }

    func invalidateResolvedStream(for track: Track) {
        guard track.catalogSource == nil else { return }
        youtube.invalidateResolvedStream(for: track)
    }

    func cacheResolvedStream(_ stream: ResolvedStream) async {
        await youtube.cacheResolvedStream(stream)
    }

    func downloadPlaybackFallback(for track: Track) async throws -> URL {
        try await youtube.downloadPlaybackFallback(for: track)
    }

    func lyrics(for track: Track) async throws -> Lyrics? {
        try await youtube.lyrics(for: track)
    }
}
