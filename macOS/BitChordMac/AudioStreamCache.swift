import Foundation

/// On-disk cache for complete playback renditions.
///
/// YouTube media URLs expire, so entries are keyed by the stable video ID and
/// selected quality profile. The current track gets an eight-second grace
/// period in `PlaybackController` before this store is asked to fetch it; the
/// fetch itself uses bounded ranges so Google's paced whole-file response does
/// not turn a four-minute song into a four-minute cache fill.
actor AudioStreamCache {
    struct Snapshot: Equatable, Sendable {
        let usedBytes: Int64
        let fileCount: Int
    }

    static let defaultLimitBytes: Int64 = 512 * 1_024 * 1_024
    static let maximumLimitBytes: Int64 = 10 * 1_024 * 1_024 * 1_024
    static let defaultChunkBytes: Int64 = 2 * 1_024 * 1_024

    private let directory: URL
    private let session: URLSession
    private let chunkBytes: Int64
    private let allowedLimits: ClosedRange<Int64>
    private var limitBytes: Int64
    private var activeKeys = Set<String>()
    private var cacheGeneration = 0

    init(
        directory: URL? = nil,
        session: URLSession? = nil,
        limitBytes: Int64 = AudioStreamCache.defaultLimitBytes,
        chunkBytes: Int64 = AudioStreamCache.defaultChunkBytes,
        allowedLimits: ClosedRange<Int64> = AudioStreamCache.defaultLimitBytes...AudioStreamCache.maximumLimitBytes
    ) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitChord/Streams", isDirectory: true)
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
        self.allowedLimits = allowedLimits
        self.limitBytes = min(max(limitBytes, allowedLimits.lowerBound), allowedLimits.upperBound)
        self.chunkBytes = max(64 * 1_024, chunkBytes)
    }

    func cachedURL(videoID: String, quality: AudioQuality) -> URL? {
        let url = destinationURL(videoID: videoID, quality: quality)
        guard Self.fileSize(url) > 0 else { return nil }
        touch(url)
        return url
    }

    func store(_ stream: ResolvedStream, quality: AudioQuality) async throws {
        guard !stream.url.isFileURL, let videoID = stream.videoID else { return }
        let key = cacheKey(videoID: videoID, quality: quality)
        guard !activeKeys.contains(key) else { return }
        let destination = destinationURL(videoID: videoID, quality: quality)
        if Self.fileSize(destination) > 0 {
            touch(destination)
            return
        }

        activeKeys.insert(key)
        defer { activeKeys.remove(key) }
        let generation = cacheGeneration

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory
            .appendingPathComponent("partial-cache-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: temporary) }

        do {
            try await fetch(stream, to: temporary, generation: generation)
            try Task.checkCancellation()
            guard generation == cacheGeneration else { throw CancellationError() }
            guard Self.fileSize(temporary) > 0 else { throw URLError(.zeroByteResource) }

            if Self.fileSize(destination) > 0 {
                touch(destination)
                return
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            touch(destination)
            _ = pruneToLimit()
        } catch {
            throw error
        }
    }

    @discardableResult
    func updateLimit(_ bytes: Int64) -> Snapshot {
        limitBytes = min(max(bytes, allowedLimits.lowerBound), allowedLimits.upperBound)
        return pruneToLimit()
    }

    @discardableResult
    func registerCompletedFile(_ url: URL) -> Snapshot {
        if Self.isCompletedCacheFile(url), Self.fileSize(url) > 0 { touch(url) }
        return pruneToLimit()
    }

    @discardableResult
    func clear() -> Snapshot {
        cacheGeneration &+= 1
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return Snapshot(usedBytes: 0, fileCount: 0) }
        for url in files where Self.isCompletedCacheFile(url) {
            try? FileManager.default.removeItem(at: url)
        }
        return snapshot()
    }

    func snapshot() -> Snapshot {
        let files = completedFiles()
        return Snapshot(
            usedBytes: files.reduce(Int64(0)) { $0 + Self.fileSize($1) },
            fileCount: files.count
        )
    }

    private func fetch(_ stream: ResolvedStream, to destination: URL, generation: Int) async throws {
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var offset: Int64 = 0
        var totalLength = Self.resourceLengthHint(stream.url)

        while totalLength == nil || offset < totalLength! {
            try Task.checkCancellation()
            guard generation == cacheGeneration else { throw CancellationError() }
            var request = URLRequest(url: stream.url)
            request.timeoutInterval = 45
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
            for (name, value) in stream.headers { request.setValue(value, forHTTPHeaderField: name) }
            let requestedEnd = offset + chunkBytes - 1
            request.setValue("bytes=\(offset)-\(requestedEnd)", forHTTPHeaderField: "Range")

            let (data, response) = try await session.data(for: request)
            guard generation == cacheGeneration else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty else { throw URLError(.badServerResponse) }

            if http.statusCode == 200 {
                guard offset == 0 else { throw URLError(.cannotParseResponse) }
                try handle.write(contentsOf: data)
                return
            }

            guard http.statusCode == 206,
                  let range = Self.contentRange(http.value(forHTTPHeaderField: "Content-Range")),
                  range.start == offset else { throw URLError(.cannotParseResponse) }
            if let responseTotal = range.total { totalLength = responseTotal }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)

            guard offset == range.end + 1 else { throw URLError(.cannotParseResponse) }
            if let totalLength, offset >= totalLength { return }
        }
    }

    @discardableResult
    private func pruneToLimit() -> Snapshot {
        var files = completedFiles().map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return (url, Self.fileSize(url), values?.contentModificationDate ?? .distantPast)
        }
        var used = files.reduce(Int64(0)) { $0 + $1.1 }
        files.sort { $0.2 < $1.2 }
        var count = files.count
        for (url, size, _) in files where used > limitBytes {
            guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
            used -= size
            count -= 1
        }
        return Snapshot(usedBytes: max(0, used), fileCount: max(0, count))
    }

    private func completedFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?.filter(Self.isCompletedCacheFile) ?? []
    }

    private func destinationURL(videoID: String, quality: AudioQuality) -> URL {
        directory.appendingPathComponent(cacheKey(videoID: videoID, quality: quality)).appendingPathExtension("m4a")
    }

    private func cacheKey(videoID: String, quality: AudioQuality) -> String {
        let safeVideoID = videoID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        // v2 deliberately abandons files written by the old source race. That
        // race could cache a JioSaavn text match under a YouTube video ID and
        // keep replaying the wrong recording even after the resolver was fixed.
        return "stream-youtube-v2-\(safeVideoID)-\(quality.rawValue)"
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private static func isCompletedCacheFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return url.pathExtension == "m4a" && (name.hasPrefix("stream-") || name.hasPrefix("fallback-"))
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    private static func resourceLengthHint(_ url: URL) -> Int64? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "clen" })?
            .value
            .flatMap(Int64.init)
    }

    private static func contentRange(_ value: String?) -> (start: Int64, end: Int64, total: Int64?)? {
        guard let value,
              value.lowercased().hasPrefix("bytes "),
              let slash = value.lastIndex(of: "/"),
              let dash = value[..<slash].lastIndex(of: "-") else { return nil }
        let startText = value[value.index(value.startIndex, offsetBy: 6)..<dash]
        let endText = value[value.index(after: dash)..<slash]
        let totalText = value[value.index(after: slash)...]
        guard let start = Int64(startText), let end = Int64(endText), end >= start else { return nil }
        return (start, end, totalText == "*" ? nil : Int64(totalText))
    }

}
