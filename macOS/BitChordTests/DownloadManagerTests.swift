import XCTest

@MainActor
final class DownloadManagerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUp() async throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChordDownloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testCompletedDownloadPersistsAndRestores() async throws {
        let downloadsDirectory = temporaryRoot.appendingPathComponent("Music", isDirectory: true)
        let metadataURL = temporaryRoot.appendingPathComponent("State/downloads.json")
        let downloader = FakeTrackDownloader()
        let manager = DownloadManager(
            downloader: downloader,
            downloadsDirectory: downloadsDirectory,
            metadataURL: metadataURL
        )
        let track = sampleTrack(id: "persist-me")

        manager.enqueue(track)
        try await waitUntil { manager.saved.count == 1 }

        XCTAssertTrue(manager.queueItems.isEmpty)
        XCTAssertTrue(manager.isDownloaded(track))
        XCTAssertEqual(manager.saved.first?.track.title, track.title)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.saved[0].filePath))
        XCTAssertEqual(manager.playableTrack(for: track).localPath, manager.saved[0].filePath)
        XCTAssertEqual(manager.playableQueue([track]).first?.localPath, manager.saved[0].filePath)

        let restored = DownloadManager(
            downloader: downloader,
            downloadsDirectory: downloadsDirectory,
            metadataURL: metadataURL
        )
        XCTAssertEqual(restored.saved.count, 1)
        XCTAssertEqual(restored.saved.first?.id, "persist-me")
        XCTAssertEqual(restored.savedTracks.first?.localPath, manager.saved.first?.filePath)
    }

    func testCancellingActiveDownloadClearsQueueWithoutSaving() async throws {
        let downloader = FakeTrackDownloader(delay: .seconds(5))
        let manager = DownloadManager(
            downloader: downloader,
            downloadsDirectory: temporaryRoot.appendingPathComponent("Music", isDirectory: true),
            metadataURL: temporaryRoot.appendingPathComponent("State/downloads.json")
        )
        let track = sampleTrack(id: "cancel-me")

        manager.enqueue(track)
        try await waitUntil {
            if case .downloading = manager.state(for: track) { return true }
            return false
        }
        XCTAssertGreaterThan(
            downloader.activeCount,
            0,
            "A downloading state must mean the downloader has actually started"
        )
        manager.cancel(track)
        try await waitUntil { manager.queueItems.isEmpty && downloader.cancellationSeen }

        XCTAssertTrue(manager.saved.isEmpty)
        XCTAssertNil(manager.state(for: track))
    }

    func testBatchUsesSelectedQualityAndParallelWorkerLimit() async throws {
        let downloader = FakeTrackDownloader(delay: .milliseconds(80))
        let manager = DownloadManager(
            downloader: downloader,
            downloadsDirectory: temporaryRoot.appendingPathComponent("Music", isDirectory: true),
            metadataURL: temporaryRoot.appendingPathComponent("State/downloads.json")
        )
        manager.maximumParallelDownloads = 2
        manager.preferredQuality = .standard
        let tracks = (0..<5).map { sampleTrack(id: "parallel-\($0)") }

        manager.enqueue(tracks)
        try await waitUntil(timeout: .seconds(3)) { manager.saved.count == tracks.count }

        XCTAssertEqual(downloader.maximumActiveCount, 2)
        XCTAssertEqual(downloader.requestedQualities, Array(repeating: .standard, count: tracks.count))
        XCTAssertTrue(manager.queueItems.isEmpty)
    }

    func testMeteredPolicyRefusesNewDownloadUntilConnectionIsAllowed() async throws {
        var allowed = false
        let downloader = FakeTrackDownloader()
        let manager = DownloadManager(
            downloader: downloader,
            downloadsDirectory: temporaryRoot.appendingPathComponent("Music", isDirectory: true),
            metadataURL: temporaryRoot.appendingPathComponent("State/downloads.json"),
            downloadsAllowedNow: { allowed }
        )
        let track = sampleTrack(id: "metered-refusal")

        manager.enqueue(track)
        await Task.yield()

        XCTAssertTrue(manager.queueItems.isEmpty)
        XCTAssertTrue(manager.saved.isEmpty)
        XCTAssertTrue(downloader.requestedQualities.isEmpty)
        XCTAssertEqual(manager.networkRestrictionMessage, DownloadManager.wifiOnlyRefusal)

        allowed = true
        manager.enqueue(track)
        try await waitUntil { manager.saved.count == 1 }

        XCTAssertNil(manager.networkRestrictionMessage)
        XCTAssertEqual(downloader.requestedQualities, [.lossless])
    }

    func testNetworkPolicyChangeDoesNotCancelDownloadAlreadyInProgress() async throws {
        var allowed = true
        let downloader = FakeTrackDownloader(delay: .milliseconds(120))
        let manager = DownloadManager(
            downloader: downloader,
            downloadsDirectory: temporaryRoot.appendingPathComponent("Music", isDirectory: true),
            metadataURL: temporaryRoot.appendingPathComponent("State/downloads.json"),
            downloadsAllowedNow: { allowed }
        )
        let track = sampleTrack(id: "started-unmetered")

        manager.enqueue(track)
        try await waitUntil {
            if case .downloading = manager.state(for: track) { return true }
            return false
        }
        allowed = false
        try await waitUntil { manager.saved.count == 1 }

        XCTAssertTrue(manager.isDownloaded(track))
        XCTAssertEqual(downloader.requestedQualities, [.lossless])
        XCTAssertNil(manager.networkRestrictionMessage)
    }

    func testCollectionGroupingAndSettingsSurviveReload() async throws {
        let downloadsDirectory = temporaryRoot.appendingPathComponent("Music", isDirectory: true)
        let metadataURL = temporaryRoot.appendingPathComponent("State/downloads.json")
        let downloader = FakeTrackDownloader()
        let manager = DownloadManager(
            downloader: downloader,
            downloadsDirectory: downloadsDirectory,
            metadataURL: metadataURL
        )
        manager.preferredQuality = .high
        manager.maximumParallelDownloads = 4
        let tracks = [sampleTrack(id: "collection-a"), sampleTrack(id: "collection-b")]
        let item = BrowseItem(
            id: "VL-test-playlist",
            title: "Road Trip",
            subtitle: "Private playlist",
            artworkURL: "https://example.test/cover.jpg",
            kind: .playlist
        )

        manager.enqueue(tracks, from: item)
        try await waitUntil { manager.saved.count == tracks.count }

        let collection = try XCTUnwrap(manager.collections.first)
        XCTAssertEqual(collection.title, "Road Trip")
        XCTAssertEqual(manager.records(in: collection).map(\.id), tracks.compactMap(\.videoID))
        XCTAssertEqual(manager.status(for: collection).fraction, 1)

        let restored = DownloadManager(
            downloader: downloader,
            downloadsDirectory: downloadsDirectory,
            metadataURL: metadataURL
        )
        XCTAssertEqual(restored.collections.first?.id, item.id)
        XCTAssertEqual(restored.preferredQuality, .high)
        XCTAssertEqual(restored.maximumParallelDownloads, 4)
        XCTAssertEqual(restored.collections.first.map(restored.records(in:))?.count, 2)
    }

    func testLegacyDownloadArrayMigratesWithoutLosingFiles() throws {
        let downloadsDirectory = temporaryRoot.appendingPathComponent("Music", isDirectory: true)
        let metadataURL = temporaryRoot.appendingPathComponent("State/downloads.json")
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let track = sampleTrack(id: "legacy")
        let fileURL = downloadsDirectory.appendingPathComponent("legacy.m4a")
        try Data("legacy audio".utf8).write(to: fileURL)
        let record = DownloadRecord(id: "legacy", track: track, filePath: fileURL.path, downloadedAt: Date())
        try JSONEncoder().encode([record]).write(to: metadataURL)

        let restored = DownloadManager(
            downloader: FakeTrackDownloader(),
            downloadsDirectory: downloadsDirectory,
            metadataURL: metadataURL
        )

        XCTAssertEqual(restored.saved.map(\.id), ["legacy"])
        XCTAssertTrue(restored.isDownloaded(track))
        XCTAssertEqual(restored.preferredQuality, .lossless)
    }

    func testTransientFailureIsRetriedBeforeBecomingUserVisible() async throws {
        let downloader = FakeTrackDownloader(failuresRemaining: 1)
        let manager = DownloadManager(
            downloader: downloader,
            downloadsDirectory: temporaryRoot.appendingPathComponent("Music", isDirectory: true),
            metadataURL: temporaryRoot.appendingPathComponent("State/downloads.json")
        )
        let track = sampleTrack(id: "retry-once")

        manager.enqueue(track)
        try await waitUntil(timeout: .seconds(3)) { manager.saved.count == 1 }

        XCTAssertEqual(downloader.requestedQualities.count, 2)
        XCTAssertNil(manager.state(for: track))
        XCTAssertEqual(manager.failedCount, 0)
    }

    func testMusicVideoDownloadUsesCatalogueTrackButKeepsOriginalLookupIdentity() async throws {
        var video = sampleTrack(id: "video-upload")
        video.title = "Offline Song (Official Video)"
        video.isVideo = true
        var catalogue = sampleTrack(id: "catalogue-audio")
        catalogue.title = "Offline Song"
        catalogue.isVideo = false
        let downloader = CanonicalTrackDownloader(catalogueTrack: catalogue)
        let manager = DownloadManager(
            downloader: downloader,
            downloadsDirectory: temporaryRoot.appendingPathComponent("Music", isDirectory: true),
            metadataURL: temporaryRoot.appendingPathComponent("State/downloads.json")
        )

        manager.enqueue(video)
        try await waitUntil { manager.saved.count == 1 }

        XCTAssertEqual(downloader.downloadedTrack?.videoID, "catalogue-audio")
        XCTAssertEqual(manager.saved.first?.id, "video-upload")
        XCTAssertEqual(manager.saved.first?.track.videoID, "catalogue-audio")
        XCTAssertTrue(manager.isDownloaded(video))
        XCTAssertEqual(manager.playableTrack(for: video).videoID, "catalogue-audio")
        XCTAssertNotNil(manager.playableTrack(for: video).localPath)
    }

    private func sampleTrack(id: String) -> Track {
        Track(
            videoID: id,
            title: "Offline Song",
            artist: "BitChord Tests",
            album: "Test Album",
            artworkURL: nil,
            duration: 180,
            localPath: nil,
            sourceURL: nil
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for download state")
    }
}

@MainActor
private final class FakeTrackDownloader: TrackDownloading {
    private let delay: Duration
    private var failuresRemaining: Int
    private(set) var cancellationSeen = false
    private(set) var activeCount = 0
    private(set) var maximumActiveCount = 0
    private(set) var requestedQualities: [DownloadQuality] = []

    init(delay: Duration = .milliseconds(30), failuresRemaining: Int = 0) {
        self.delay = delay
        self.failuresRemaining = failuresRemaining
    }

    func downloadTrack(
        _ track: Track,
        quality: DownloadQuality,
        to directory: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        requestedQualities.append(quality)
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        defer { activeCount -= 1 }
        progress(0.25)
        do {
            try await Task.sleep(for: delay)
        } catch {
            cancellationSeen = true
            throw error
        }
        try Task.checkCancellation()
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw FakeDownloadError.transient
        }
        progress(0.8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory
            .appendingPathComponent(track.videoID ?? UUID().uuidString)
            .appendingPathExtension("m4a")
        try Data("test audio".utf8).write(to: destination)
        progress(1)
        return destination
    }
}

@MainActor
private final class CanonicalTrackDownloader: TrackDownloading {
    let catalogueTrack: Track
    private(set) var downloadedTrack: Track?

    init(catalogueTrack: Track) {
        self.catalogueTrack = catalogueTrack
    }

    func resolveDownloadTrack(_ track: Track) async -> Track {
        track.isMusicVideo ? catalogueTrack : track
    }

    func downloadTrack(
        _ track: Track,
        quality: DownloadQuality,
        to directory: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        downloadedTrack = track
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("catalogue.m4a")
        try Data("catalogue audio".utf8).write(to: destination)
        progress(1)
        return destination
    }
}

private enum FakeDownloadError: LocalizedError {
    case transient

    var errorDescription: String? { "Temporary extractor failure" }
}
