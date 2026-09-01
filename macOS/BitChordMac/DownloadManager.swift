import AppKit
import Foundation

enum DownloadQuality: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard
    case high
    case lossless

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .high: "High"
        case .lossless: "Lossless"
        }
    }

    var detail: String {
        switch self {
        case .standard: "~128 kbps AAC · about 4 MB per song"
        case .high: "Best AAC available · about 8 MB per song"
        case .lossless: "Lossless from a source module, best AAC otherwise"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: "leaf.fill"
        case .high: "waveform"
        case .lossless: "sparkles"
        }
    }
}

@MainActor
protocol TrackDownloading: AnyObject {
    func resolveDownloadTrack(_ track: Track) async -> Track
    func downloadTrack(
        _ track: Track,
        quality: DownloadQuality,
        to directory: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL
}

extension TrackDownloading {
    func resolveDownloadTrack(_ track: Track) async -> Track { track }
}

enum DownloadActivity: Equatable {
    case queued
    case downloading(Double)
    case failed(String)

    var progress: Double? {
        if case .downloading(let value) = self { return value }
        return nil
    }

    var statusText: String {
        switch self {
        case .queued: "Queued"
        case .downloading(let value): "Downloading · \(Int(value * 100))%"
        case .failed(let message): message
        }
    }
}

struct DownloadRecord: Identifiable, Codable, Hashable {
    let id: String
    let track: Track
    let filePath: String
    let downloadedAt: Date
    var tagsVersion: Int? = nil

    var fileURL: URL { URL(fileURLWithPath: filePath) }

    var playableTrack: Track {
        Track(
            videoID: track.videoID,
            title: track.title,
            artist: track.artist,
            album: track.album,
            artworkURL: track.artworkURL,
            duration: track.duration,
            localPath: filePath,
            sourceURL: track.sourceURL,
            artistBrowseID: track.artistBrowseID,
            albumBrowseID: track.albumBrowseID,
            setVideoID: track.setVideoID,
            isVideo: track.isVideo,
            catalogSource: track.catalogSource,
            catalogTrackID: track.catalogTrackID
        )
    }
}

struct DownloadCollectionRecord: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var subtitle: String
    var artworkURL: String?
    var kind: String
    var trackIDs: [String]
    var requestedAt: Date
}

struct DownloadCollectionStatus: Equatable {
    let completed: Int
    let total: Int
    let active: Int
    let failed: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    var statusText: String {
        if completed == total, total > 0 {
            return "Downloaded · \(completed) \(completed == 1 ? "song" : "songs")"
        }
        if failed > 0 { return "\(completed) of \(total) · \(failed) failed" }
        if active > 0 { return "\(completed) of \(total) · downloading" }
        return "\(completed) of \(total) \(total == 1 ? "song" : "songs")"
    }
}

struct DownloadQueueItem: Identifiable {
    let id: String
    let track: Track
    let quality: DownloadQuality
    let sourceLabel: String?
    let activity: DownloadActivity
}

struct DownloadSessionSummary: Equatable {
    let completed: Int
    let total: Int
    let running: Int
    let waiting: Int
    let failed: Int
    let fraction: Double
}

private struct DownloadRequest {
    let id: String
    let track: Track
    let quality: DownloadQuality
    let collectionID: String?
    let sourceLabel: String?
}

private struct DownloadLibraryState: Codable {
    var version = 3
    var saved: [DownloadRecord]
    var collections: [DownloadCollectionRecord]
    var preferredQuality: DownloadQuality
    var maximumParallelDownloads: Int
}

@MainActor
final class URLSessionDownloadArtworkProvider: DownloadArtworkProviding {
    private let session: URLSession
    private static let maximumBytes = 12 * 1024 * 1024
    private static let maximumSide = 1_000

    init(session: URLSession = .shared) {
        self.session = session
    }

    func artworkForDownload(_ track: Track) async -> DownloadArtwork? {
        guard let rawURL = track.artworkURL else { return nil }
        for url in Self.artworkURLs(rawURL) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            do {
                let (data, response) = try await session.data(for: request)
                guard !Task.isCancelled else { return nil }
                guard !data.isEmpty,
                      data.count <= Self.maximumBytes,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let source = NSImage(data: data) else { continue }
                if let artwork = Self.jpegArtwork(from: source) { return artwork }
            } catch is CancellationError {
                return nil
            } catch {
                continue
            }
        }
        return nil
    }

    private static func artworkURLs(_ rawURL: String) -> [URL] {
        var upgraded = replacing(#"=w\d+-h\d+"#, with: "=w1000-h1000", in: rawURL)
        upgraded = replacing(#"\d+x\d+(?=\.[A-Za-z]+(?:\?|$))"#, with: "500x500", in: upgraded)
        return [upgraded, rawURL]
            .uniqued()
            .compactMap(URL.init(string:))
    }

    private static func replacing(_ pattern: String, with replacement: String, in value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: replacement
        )
    }

    private static func jpegArtwork(from source: NSImage) -> DownloadArtwork? {
        let representationSize = source.representations.reduce(CGSize.zero) { result, representation in
            CGSize(
                width: max(result.width, CGFloat(representation.pixelsWide)),
                height: max(result.height, CGFloat(representation.pixelsHigh))
            )
        }
        let sourceSize = representationSize.width > 0 && representationSize.height > 0
            ? representationSize
            : source.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let scale = min(1, CGFloat(maximumSide) / max(sourceSize.width, sourceSize.height))
        let width = max(1, Int((sourceSize.width * scale).rounded()))
        let height = max(1, Int((sourceSize.height * scale).rounded()))
        let resized = NSImage(size: NSSize(width: width, height: height))
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.9]
              ) else { return nil }
        return DownloadArtwork(
            data: jpeg,
            mimeType: "image/jpeg",
            width: width,
            height: height,
            depth: 24
        )
    }
}

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var saved: [DownloadRecord] = []
    @Published private(set) var collections: [DownloadCollectionRecord] = []
    @Published private(set) var activity: [String: DownloadActivity] = [:]
    @Published var networkRestrictionMessage: String?
    @Published var preferredQuality: DownloadQuality = .lossless {
        didSet { persistUnlessLoading() }
    }
    @Published var maximumParallelDownloads: Int = 3 {
        didSet {
            let clamped = min(max(maximumParallelDownloads, 1), 4)
            if maximumParallelDownloads != clamped {
                maximumParallelDownloads = clamped
                return
            }
            persistUnlessLoading()
            startNextIfNeeded()
        }
    }

    let downloadsDirectory: URL

    private let downloader: any TrackDownloading
    private let lyricsProvider: (any DownloadLyricsProviding)?
    private let artworkProvider: (any DownloadArtworkProviding)?
    private let downloadsAllowedNow: @MainActor () -> Bool
    private let metadataURL: URL
    private var requestsByID: [String: DownloadRequest] = [:]
    private var activityOrder: [String] = []
    private var pending: [DownloadRequest] = []
    private var runningTasks: [String: Task<Void, Never>] = [:]
    private var sessionIDs = Set<String>()
    private var sessionCompletedIDs = Set<String>()
    private var isLoading = true
    private var metadataBackfillTask: Task<Void, Never>?

    private static let currentTagsVersion = 1

    init(
        downloader: any TrackDownloading,
        lyricsProvider: (any DownloadLyricsProviding)? = nil,
        artworkProvider: (any DownloadArtworkProviding)? = nil,
        downloadsDirectory: URL? = nil,
        metadataURL: URL? = nil,
        downloadsAllowedNow: @escaping @MainActor () -> Bool = { true }
    ) {
        self.downloader = downloader
        self.lyricsProvider = lyricsProvider
        self.artworkProvider = artworkProvider
        self.downloadsAllowedNow = downloadsAllowedNow

        let fileManager = FileManager.default
        let defaultDownloads = fileManager.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitChord", isDirectory: true)
        self.downloadsDirectory = downloadsDirectory ?? defaultDownloads

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitChord", isDirectory: true)
        self.metadataURL = metadataURL ?? appSupport.appendingPathComponent("downloads.json")

        try? fileManager.createDirectory(at: self.downloadsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(
            at: self.metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        loadSaved()
        isLoading = false
        scheduleMetadataBackfill()
    }

    deinit {
        runningTasks.values.forEach { $0.cancel() }
        metadataBackfillTask?.cancel()
    }

    var queueItems: [DownloadQueueItem] {
        activityOrder.compactMap { id in
            guard let request = requestsByID[id], let state = activity[id] else { return nil }
            return DownloadQueueItem(
                id: id,
                track: request.track,
                quality: request.quality,
                sourceLabel: request.sourceLabel,
                activity: state
            )
        }
    }

    var savedTracks: [Track] {
        saved.map(\.playableTrack)
    }

    var runningCount: Int { runningTasks.count }

    var failedCount: Int {
        activity.values.reduce(into: 0) { count, state in
            if case .failed = state { count += 1 }
        }
    }

    var aggregateProgress: Double {
        let items = queueItems.filter {
            if case .failed = $0.activity { return false }
            return true
        }
        guard !items.isEmpty else { return 0 }
        let total = items.reduce(0.0) { result, item in
            switch item.activity {
            case .queued: result
            case .downloading(let value): result + value
            case .failed: result
            }
        }
        return total / Double(items.count)
    }

    var sessionSummary: DownloadSessionSummary? {
        guard !sessionIDs.isEmpty else { return nil }
        let failed = sessionIDs.reduce(into: 0) { count, id in
            if case .failed = activity[id] { count += 1 }
        }
        let progress = sessionIDs.reduce(0.0) { result, id in
            if sessionCompletedIDs.contains(id) { return result + 1 }
            if case .downloading(let value) = activity[id] { return result + value }
            return result
        }
        return DownloadSessionSummary(
            completed: sessionCompletedIDs.count,
            total: sessionIDs.count,
            running: runningTasks.count,
            waiting: pending.count,
            failed: failed,
            fraction: progress / Double(sessionIDs.count)
        )
    }

    func identifier(for track: Track) -> String? {
        track.downloadIdentifier
    }

    func isDownloaded(_ track: Track) -> Bool {
        guard let id = identifier(for: track),
              let record = saved.first(where: { $0.id == id }) else { return false }
        return FileManager.default.fileExists(atPath: record.filePath)
    }

    func playableTrack(for track: Track) -> Track {
        guard track.localPath == nil,
              let id = identifier(for: track),
              let record = saved.first(where: { $0.id == id }),
              FileManager.default.fileExists(atPath: record.filePath) else { return track }
        return record.playableTrack
    }

    func playableQueue(_ tracks: [Track]) -> [Track] {
        tracks.map(playableTrack(for:))
    }

    func state(for track: Track) -> DownloadActivity? {
        guard let id = identifier(for: track) else { return nil }
        return activity[id]
    }

    func enqueue(_ track: Track) {
        guard allowNewDownload() else { return }
        enqueueUnchecked(track, quality: preferredQuality, collectionID: nil, sourceLabel: nil)
    }

    func enqueue(_ tracks: [Track]) {
        guard allowNewDownload() else { return }
        tracks.forEach {
            enqueueUnchecked($0, quality: preferredQuality, collectionID: nil, sourceLabel: nil)
        }
    }

    func enqueue(_ tracks: [Track], from item: BrowseItem) {
        guard allowNewDownload() else { return }
        let trackIDs = tracks.compactMap(\.videoID).uniqued()
        guard !trackIDs.isEmpty else { return }

        let collection = DownloadCollectionRecord(
            id: item.id,
            title: item.title,
            subtitle: item.subtitle,
            artworkURL: item.artworkURL,
            kind: item.kind.rawValue,
            trackIDs: trackIDs,
            requestedAt: Date()
        )
        collections.removeAll { $0.id == item.id }
        collections.insert(collection, at: 0)
        persist()

        tracks.forEach {
            enqueueUnchecked(
                $0,
                quality: preferredQuality,
                collectionID: item.id,
                sourceLabel: item.title
            )
        }
    }

    func cancel(_ track: Track) {
        guard let id = identifier(for: track) else { return }
        pending.removeAll { $0.id == id }
        activity.removeValue(forKey: id)
        activityOrder.removeAll { $0 == id }
        requestsByID.removeValue(forKey: id)
        runningTasks[id]?.cancel()
    }

    func retry(_ track: Track) {
        guard allowNewDownload() else { return }
        guard let id = identifier(for: track),
              case .failed = activity[id],
              let request = requestsByID[id] else { return }
        activity[id] = .queued
        pending.append(request)
        startNextIfNeeded()
    }

    func retryFailed() {
        guard allowNewDownload() else { return }
        queueItems.forEach { item in
            if case .failed = item.activity { retry(item.track) }
        }
    }

    func cancelAllActive() {
        queueItems.forEach { item in
            if case .failed = item.activity { return }
            cancel(item.track)
        }
    }

    func clearFailures() {
        queueItems.forEach { item in
            if case .failed = item.activity { dismissFailure(item.track) }
        }
    }

    func dismissFailure(_ track: Track) {
        guard let id = identifier(for: track), case .failed = activity[id] else { return }
        activity.removeValue(forKey: id)
        activityOrder.removeAll { $0 == id }
        requestsByID.removeValue(forKey: id)
    }

    func records(in collection: DownloadCollectionRecord) -> [DownloadRecord] {
        let recordsByID = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        return collection.trackIDs.compactMap { recordsByID[$0] }
    }

    func status(for collection: DownloadCollectionRecord) -> DownloadCollectionStatus {
        let completed = records(in: collection).count
        let states = collection.trackIDs.compactMap { activity[$0] }
        let failed = states.reduce(into: 0) { count, state in
            if case .failed = state { count += 1 }
        }
        return DownloadCollectionStatus(
            completed: completed,
            total: collection.trackIDs.count,
            active: states.count - failed,
            failed: failed
        )
    }

    func progress(for collection: DownloadCollectionRecord) -> Double {
        guard !collection.trackIDs.isEmpty else { return 0 }
        let savedIDs = Set(saved.map(\.id))
        let total = collection.trackIDs.reduce(0.0) { result, id in
            if savedIDs.contains(id) { return result + 1 }
            if case .downloading(let value) = activity[id] { return result + value }
            return result
        }
        return total / Double(collection.trackIDs.count)
    }

    func forget(_ collection: DownloadCollectionRecord) {
        collections.removeAll { $0.id == collection.id }
        persist()
    }

    @discardableResult
    func remove(_ record: DownloadRecord) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: record.filePath) {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: record.fileURL, resultingItemURL: &trashedURL)
            }
            saved.removeAll { $0.id == record.id }
            persist()
            return true
        } catch {
            return false
        }
    }

    func reveal(_ record: DownloadRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.fileURL])
    }

    func openDownloadsFolder() {
        try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(downloadsDirectory)
    }

    private func allowNewDownload() -> Bool {
        guard downloadsAllowedNow() else {
            networkRestrictionMessage = Self.wifiOnlyRefusal
            return false
        }
        networkRestrictionMessage = nil
        return true
    }

    private func enqueueUnchecked(
        _ track: Track,
        quality: DownloadQuality,
        collectionID: String?,
        sourceLabel: String?
    ) {
        guard let id = identifier(for: track), track.localPath == nil else { return }

        if let recordIndex = saved.firstIndex(where: { $0.id == id }) {
            if FileManager.default.fileExists(atPath: saved[recordIndex].filePath) { return }
            saved.remove(at: recordIndex)
            persist()
        }
        guard activity[id] == nil else { return }

        if activity.isEmpty, runningTasks.isEmpty, pending.isEmpty, !sessionIDs.isEmpty {
            sessionIDs.removeAll()
            sessionCompletedIDs.removeAll()
        }

        let request = DownloadRequest(
            id: id,
            track: track,
            quality: quality,
            collectionID: collectionID,
            sourceLabel: sourceLabel
        )
        requestsByID[id] = request
        activity[id] = .queued
        activityOrder.append(id)
        pending.append(request)
        sessionIDs.insert(id)
        startNextIfNeeded()
    }

    private func startNextIfNeeded() {
        while runningTasks.count < maximumParallelDownloads, !pending.isEmpty {
            let request = pending.removeFirst()
            guard activity[request.id] != nil, runningTasks[request.id] == nil else { continue }
            start(request)
        }
    }

    private func start(_ request: DownloadRequest) {
        let id = request.id
        runningTasks[id] = Task { [weak self, downloader, downloadsDirectory] in
            guard let self else { return }
            let resolvedTrack = await downloader.resolveDownloadTrack(request.track)
            guard !Task.isCancelled, activity[id] != nil else {
                finish(id: id, removingRequest: true)
                startNextIfNeeded()
                return
            }
            activity[id] = .downloading(0)
            let lyricsLookup = lyricsProvider.map { provider in
                Task { await provider.lyricsForDownload(resolvedTrack) }
            }
            let artworkLookup = artworkProvider.map { provider in
                Task { await provider.artworkForDownload(resolvedTrack) }
            }
            defer {
                lyricsLookup?.cancel()
                artworkLookup?.cancel()
            }
            for attempt in 0..<2 {
                do {
                    let fileURL = try await downloader.downloadTrack(
                        resolvedTrack,
                        quality: request.quality,
                        to: downloadsDirectory
                    ) { [weak self] value in
                        guard let self,
                              self.runningTasks[id] != nil,
                              self.activity[id] != nil else { return }
                        self.activity[id] = .downloading(min(max(value, 0), 1))
                    }
                    try Task.checkCancellation()
                    guard activity[id] != nil else { return }

                    let embeddedLyrics = await lyricsLookup?.value
                    let embeddedArtwork = await artworkLookup?.value
                    let didTag = await EmbeddedLyricsStore.embed(
                        track: resolvedTrack,
                        lyrics: embeddedLyrics,
                        artwork: embeddedArtwork,
                        in: fileURL
                    )
                    try Task.checkCancellation()
                    guard activity[id] != nil else { return }

                    var record = DownloadRecord(
                        id: id,
                        track: resolvedTrack,
                        filePath: fileURL.path,
                        downloadedAt: Date()
                    )
                    if didTag { record.tagsVersion = Self.currentTagsVersion }
                    saved.removeAll { $0.id == id }
                    saved.insert(record, at: 0)
                    sessionCompletedIDs.insert(id)
                    finish(id: id, removingRequest: true)
                    persist()
                    startNextIfNeeded()
                    return
                } catch is CancellationError {
                    finish(id: id, removingRequest: true)
                    startNextIfNeeded()
                    return
                } catch {
                    if attempt == 0, activity[id] != nil {
                        activity[id] = .queued
                        do {
                            try await Task.sleep(for: .milliseconds(750))
                            try Task.checkCancellation()
                        } catch {
                            finish(id: id, removingRequest: true)
                            startNextIfNeeded()
                            return
                        }
                        guard activity[id] != nil else { return }
                        activity[id] = .downloading(0)
                        continue
                    }
                    activity[id] = .failed(error.localizedDescription)
                    runningTasks.removeValue(forKey: id)
                }
            }

            startNextIfNeeded()
        }
    }

    private func finish(id: String, removingRequest: Bool) {
        activity.removeValue(forKey: id)
        activityOrder.removeAll { $0 == id }
        runningTasks.removeValue(forKey: id)
        if removingRequest { requestsByID.removeValue(forKey: id) }
    }

    private func loadSaved() {
        guard let data = try? Data(contentsOf: metadataURL) else { return }
        let decoder = JSONDecoder()
        if let state = try? decoder.decode(DownloadLibraryState.self, from: data) {
            saved = state.saved
            collections = state.collections
            preferredQuality = state.preferredQuality
            maximumParallelDownloads = min(max(state.maximumParallelDownloads, 1), 4)
        } else if let legacy = try? decoder.decode([DownloadRecord].self, from: data) {
            saved = legacy
            collections = []
        } else {
            return
        }

        let before = saved.count
        saved = saved.filter { FileManager.default.fileExists(atPath: $0.filePath) }
        if saved.count != before { persist() }
    }

    private func scheduleMetadataBackfill() {
        guard saved.contains(where: { ($0.tagsVersion ?? 0) < Self.currentTagsVersion }) else { return }
        metadataBackfillTask = Task { [weak self] in
            await self?.backfillDownloadMetadata()
        }
    }

    private func backfillDownloadMetadata() async {
        let identifiers = saved
            .filter { ($0.tagsVersion ?? 0) < Self.currentTagsVersion }
            .map(\.id)
        for id in identifiers {
            guard !Task.isCancelled,
                  let record = saved.first(where: { $0.id == id }),
                  FileManager.default.fileExists(atPath: record.filePath) else { continue }
            let artwork = await artworkProvider?.artworkForDownload(record.track)
            guard !Task.isCancelled else { return }
            let didTag = await EmbeddedLyricsStore.embed(
                track: record.track,
                lyrics: nil,
                artwork: artwork,
                in: record.fileURL
            )
            guard !Task.isCancelled, didTag,
                  let index = saved.firstIndex(where: { $0.id == id }) else { continue }
            saved[index].tagsVersion = Self.currentTagsVersion
            persist()
        }
        metadataBackfillTask = nil
    }

    private func persistUnlessLoading() {
        guard !isLoading else { return }
        persist()
    }

    private func persist() {
        guard !isLoading else { return }
        let state = DownloadLibraryState(
            saved: saved,
            collections: collections,
            preferredQuality: preferredQuality,
            maximumParallelDownloads: maximumParallelDownloads
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }

    static let wifiOnlyRefusal = "Downloads are limited to unmetered networks. Connect through Wi-Fi or Ethernet, or change the Downloads setting."
}

@MainActor
final class SourceAwareTrackDownloader: TrackDownloading {
    private let youtube: any TrackDownloading
    private let sources: SourceModuleManager

    init(youtube: any TrackDownloading, sources: SourceModuleManager) {
        self.youtube = youtube
        self.sources = sources
    }

    func resolveDownloadTrack(_ track: Track) async -> Track {
        if track.catalogSource != nil { return track }
        guard let resolver = youtube as? any PlaybackStreamResolving else { return track }
        return await resolver.resolvePlaybackTrack(for: track)
    }

    func downloadTrack(
        _ track: Track,
        quality: DownloadQuality,
        to directory: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        if track.catalogSource == .jioSaavn {
            guard let stream = await sources.resolveJioSaavnDownloadStream(for: track) else {
                throw JioSaavnError.noPlayableStream
            }
            return try await download(stream: stream, track: track, to: directory, progress: progress)
        }
        if quality == .lossless,
           let stream = await sources.resolveDownloadStream(for: track),
           stream.info?.isLossless == true {
            do {
                return try await download(
                    stream: stream,
                    track: track,
                    to: directory,
                    progress: progress
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A module stream can expire between lookup and transfer. The
                // permanent download still succeeds through YouTube fallback.
            }
        }
        if quality != .standard,
           let stream = await sources.resolveJioSaavnDownloadStream(for: track) {
            do {
                return try await download(
                    stream: stream,
                    track: track,
                    to: directory,
                    progress: progress
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Keep the same reliable YouTube fallback as playback when a
                // short-lived JioSaavn CDN URL expires during transfer.
            }
        }
        return try await youtube.downloadTrack(
            track,
            quality: quality,
            to: directory,
            progress: progress
        )
    }

    private func download(
        stream: ResolvedStream,
        track: Track,
        to directory: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileExtension = Self.fileExtension(for: stream)
        let destination = directory
            .appendingPathComponent(Self.fileStem(for: track))
            .appendingPathExtension(fileExtension)
        if FileManager.default.fileExists(atPath: destination.path) {
            progress(1)
            return destination
        }

        var request = URLRequest(url: stream.url)
        stream.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        progress(0.03)
        let transfer = StreamFileTransfer(request: request, destination: destination, progress: progress)
        return try await transfer.start()
    }

    private static func fileExtension(for stream: ResolvedStream) -> String {
        let codec = stream.info?.codec?.lowercased() ?? ""
        if ["flac", "alac", "wav", "aiff", "m4a"].contains(codec) { return codec }
        if ["aac", "mp4", "mp4a"].contains(codec) { return "m4a" }
        let pathExtension = stream.url.pathExtension.lowercased()
        if ["flac", "alac", "wav", "aiff", "m4a"].contains(pathExtension) { return pathExtension }
        if ["aac", "mp4"].contains(pathExtension) { return "m4a" }
        return "flac"
    }

    private static func fileStem(for track: Track) -> String {
        let suffix = track.downloadIdentifier.map { " [\($0)]" } ?? ""
        let raw = "\(track.artist) - \(track.title)\(suffix)"
        let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters)
        let cleaned = raw.components(separatedBy: illegal).joined(separator: " ")
        return String(cleaned.split(whereSeparator: \Character.isWhitespace).joined(separator: " ").prefix(180))
    }
}

private final class StreamFileTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let destination: URL
    private let progress: @MainActor (Double) -> Void
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var downloadedURL: URL?
    private var finished = false
    private var cancelled = false
    private lazy var session = URLSession(
        configuration: .ephemeral,
        delegate: self,
        delegateQueue: nil
    )

    init(
        request: URLRequest,
        destination: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) {
        self.request = request
        self.destination = destination
        self.progress = progress
    }

    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let task = session.downloadTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        let continuation = finishLocked()
        lock.unlock()
        task?.cancel()
        continuation?.resume(throwing: CancellationError())
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0.03), 0.98)
        Task { @MainActor [progress] in progress(value) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                throw URLError(.badServerResponse)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock()
            downloadedURL = destination
            lock.unlock()
        } catch {
            complete(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            complete(.failure(cancelled ? CancellationError() : error))
            return
        }
        lock.lock()
        let downloadedURL = downloadedURL
        lock.unlock()
        guard let downloadedURL else {
            complete(.failure(URLError(.cannotCreateFile)))
            return
        }
        complete(.success(downloadedURL))
    }

    private func complete(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = finishLocked()
        lock.unlock()
        guard let continuation else { return }
        Task { @MainActor [progress] in
            if case .success = result { progress(1) }
        }
        continuation.resume(with: result)
        session.finishTasksAndInvalidate()
    }

    private func finishLocked() -> CheckedContinuation<URL, Error>? {
        guard !finished else { return nil }
        finished = true
        defer { continuation = nil }
        return continuation
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
