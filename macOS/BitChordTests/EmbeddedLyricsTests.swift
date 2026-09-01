import Foundation
import XCTest

final class EmbeddedLyricsTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUp() async throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChordEmbeddedLyricsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testM4AEmbedsPortableAndWordTimedLyricsWithoutBreakingChunkOffsets() async throws {
        let fileURL = temporaryRoot.appendingPathComponent("word-synced.m4a")
        let original = makeM4AFixture()
        try original.data.write(to: fileURL)

        let didEmbed = await EmbeddedLyricsStore.embed(sampleLyrics, in: fileURL)
        XCTAssertTrue(didEmbed)

        let rewritten = try Data(contentsOf: fileURL)
        XCTAssertNotNil(rewritten.range(of: Data([0xA9, 0x6C, 0x79, 0x72])))
        XCTAssertNotNil(rewritten.range(of: Data(EmbeddedLyricsStore.wordLyricsField.utf8)))
        XCTAssertEqual(
            try XCTUnwrap(chunkOffset(in: rewritten)),
            original.chunkOffset + UInt32(rewritten.count - original.data.count)
        )

        let embedded = await EmbeddedLyricsStore.load(from: fileURL)
        let loaded = try XCTUnwrap(embedded)
        XCTAssertEqual(loaded.source, "Embedded")
        XCTAssertEqual(loaded.lines.filter { !$0.isGap }.map(\.text), ["slow glow", "after light"])
        XCTAssertEqual(loaded.lines.first(where: { !$0.isGap })?.words.map(\.text), ["slow", "glow"])
        XCTAssertEqual(
            try XCTUnwrap(loaded.lines.first(where: { !$0.isGap })?.words.last?.end),
            5,
            accuracy: 0.01
        )
    }

    func testFLACEmbedsAndRestoresEnhancedLyricsWhilePreservingFrames() async throws {
        let fileURL = temporaryRoot.appendingPathComponent("word-synced.flac")
        let frameBytes = Data([0xFF, 0xF8, 0x69, 0x00, 0x01, 0x02])
        try makeFLACFixture(frames: frameBytes).write(to: fileURL)

        let didEmbed = await EmbeddedLyricsStore.embed(sampleLyrics, in: fileURL)
        XCTAssertTrue(didEmbed)

        let rewritten = try Data(contentsOf: fileURL)
        XCTAssertEqual(Data(rewritten.suffix(frameBytes.count)), frameBytes)
        XCTAssertNotNil(rewritten.range(of: Data("LYRICS=".utf8)))
        XCTAssertNotNil(rewritten.range(of: Data("BITCHORD_LYRICS=".utf8)))

        let embedded = await EmbeddedLyricsStore.load(from: fileURL)
        let loaded = try XCTUnwrap(embedded)
        XCTAssertTrue(loaded.isWordSynced)
        XCTAssertEqual(loaded.lines.filter { !$0.isGap }.first?.text, "slow glow")
    }

    @MainActor
    func testLocalPlaybackUsesEmbeddedLyricsBeforeCallingNetwork() async throws {
        let fileURL = temporaryRoot.appendingPathComponent("offline-first.m4a")
        try makeM4AFixture().data.write(to: fileURL)
        let didEmbed = await EmbeddedLyricsStore.embed(sampleLyrics, in: fileURL)
        XCTAssertTrue(didEmbed)

        let resolver = EmbeddedLyricsResolver(networkLyrics: nil)
        let player = PlaybackController(api: resolver)
        let track = Track(
            videoID: "offline-first",
            title: "Offline Song",
            artist: "BitChord Tests",
            album: nil,
            artworkURL: nil,
            duration: 12,
            localPath: fileURL.path,
            sourceURL: nil
        )

        player.play(track)
        try await waitUntil { !player.lyricsLoading }

        XCTAssertEqual(player.lyrics?.source, "Embedded")
        XCTAssertEqual(resolver.lyricRequests, 0)
    }

    @MainActor
    func testOlderDownloadIsBackfilledAfterOneNetworkLyricsLookup() async throws {
        let fileURL = temporaryRoot.appendingPathComponent("backfill.m4a")
        try makeM4AFixture().data.write(to: fileURL)
        let resolver = EmbeddedLyricsResolver(networkLyrics: sampleLyrics)
        let player = PlaybackController(api: resolver)
        let track = Track(
            videoID: "backfill",
            title: "Backfill Song",
            artist: "BitChord Tests",
            album: nil,
            artworkURL: nil,
            duration: 12,
            localPath: fileURL.path,
            sourceURL: nil
        )

        player.play(track)
        try await waitUntil { !player.lyricsLoading }

        XCTAssertEqual(resolver.lyricRequests, 1)
        let embedded = await EmbeddedLyricsStore.load(from: fileURL)
        XCTAssertEqual(embedded?.source, "Embedded")
        XCTAssertEqual(embedded?.lines.filter { !$0.isGap }.first?.text, "slow glow")
    }

    @MainActor
    func testDownloadIsNotPublishedUntilLyricsAreEmbedded() async throws {
        let downloadsDirectory = temporaryRoot.appendingPathComponent("Music", isDirectory: true)
        let metadataURL = temporaryRoot.appendingPathComponent("State/downloads.json")
        let manager = DownloadManager(
            downloader: EmbeddedFixtureDownloader(),
            lyricsProvider: EmbeddedFixtureLyricsProvider(lyrics: sampleLyrics),
            artworkProvider: EmbeddedFixtureArtworkProvider(),
            downloadsDirectory: downloadsDirectory,
            metadataURL: metadataURL
        )
        let track = Track(
            videoID: "embedded-download",
            title: "Offline Song",
            artist: "BitChord Tests",
            album: "Test Album",
            artworkURL: nil,
            duration: 12,
            localPath: nil,
            sourceURL: nil
        )

        manager.enqueue(track)
        try await waitUntil { manager.saved.count == 1 }

        let fileURL = try XCTUnwrap(manager.saved.first?.fileURL)
        let taggedFile = try Data(contentsOf: fileURL)
        XCTAssertNotNil(taggedFile.range(of: Data("Offline Song".utf8)))
        XCTAssertNotNil(taggedFile.range(of: Data("BitChord Tests".utf8)))
        XCTAssertNotNil(taggedFile.range(of: Data("Test Album".utf8)))
        XCTAssertNotNil(taggedFile.range(of: Data("covr".utf8)))
        XCTAssertNotNil(taggedFile.range(of: embeddedFixtureArtworkBytes))
        let embedded = await EmbeddedLyricsStore.load(from: fileURL)
        let loaded = try XCTUnwrap(embedded)
        XCTAssertEqual(loaded.source, "Embedded")
        XCTAssertEqual(loaded.lines.filter { !$0.isGap }.first?.words.map(\.text), ["slow", "glow"])
    }

    func testFLACTagsIdentityLyricsAndFrontCoverWhilePreservingFrames() async throws {
        let fileURL = temporaryRoot.appendingPathComponent("fully-tagged.flac")
        let frameBytes = Data([0xFF, 0xF8, 0x69, 0x00, 0x01, 0x02])
        try makeFLACFixture(frames: frameBytes).write(to: fileURL)
        let track = Track(
            videoID: "fully-tagged",
            title: "Offline Song",
            artist: "BitChord Tests",
            album: "Test Album",
            artworkURL: nil,
            duration: 12,
            localPath: nil,
            sourceURL: nil
        )
        let artwork = DownloadArtwork(
            data: embeddedFixtureArtworkBytes,
            mimeType: "image/jpeg",
            width: 1,
            height: 1,
            depth: 24
        )

        let didEmbed = await EmbeddedLyricsStore.embed(
            track: track,
            lyrics: sampleLyrics,
            artwork: artwork,
            in: fileURL
        )
        XCTAssertTrue(didEmbed)

        let rewritten = try Data(contentsOf: fileURL)
        XCTAssertEqual(Data(rewritten.suffix(frameBytes.count)), frameBytes)
        for field in ["TITLE=Offline Song", "ARTIST=BitChord Tests", "ALBUM=Test Album", "LYRICS=", "BITCHORD_LYRICS="] {
            XCTAssertNotNil(rewritten.range(of: Data(field.utf8)))
        }
        XCTAssertNotNil(rewritten.range(of: embeddedFixtureArtworkBytes))
    }

    @MainActor
    func testLegacyDownloadMetadataIsBackfilledWithoutRedownloading() async throws {
        let downloadsDirectory = temporaryRoot.appendingPathComponent("Music", isDirectory: true)
        let metadataURL = temporaryRoot.appendingPathComponent("State/downloads.json")
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fileURL = downloadsDirectory.appendingPathComponent("legacy.m4a")
        try makeM4AFixture().data.write(to: fileURL)
        let track = Track(
            videoID: "legacy-metadata",
            title: "Legacy Song",
            artist: "BitChord Tests",
            album: "Legacy Album",
            artworkURL: nil,
            duration: 12,
            localPath: nil,
            sourceURL: nil
        )
        let record = DownloadRecord(
            id: "legacy-metadata",
            track: track,
            filePath: fileURL.path,
            downloadedAt: Date()
        )
        try JSONEncoder().encode([record]).write(to: metadataURL)

        let manager = DownloadManager(
            downloader: EmbeddedFixtureDownloader(),
            artworkProvider: EmbeddedFixtureArtworkProvider(),
            downloadsDirectory: downloadsDirectory,
            metadataURL: metadataURL
        )
        try await waitUntil { manager.saved.first?.tagsVersion == 1 }

        let taggedFile = try Data(contentsOf: fileURL)
        XCTAssertNotNil(taggedFile.range(of: Data("Legacy Song".utf8)))
        XCTAssertNotNil(taggedFile.range(of: Data("BitChord Tests".utf8)))
        XCTAssertNotNil(taggedFile.range(of: Data("Legacy Album".utf8)))
        XCTAssertNotNil(taggedFile.range(of: Data("covr".utf8)))
        XCTAssertNotNil(taggedFile.range(of: embeddedFixtureArtworkBytes))

        let restored = DownloadManager(
            downloader: EmbeddedFixtureDownloader(),
            artworkProvider: EmbeddedFixtureArtworkProvider(),
            downloadsDirectory: downloadsDirectory,
            metadataURL: metadataURL
        )
        XCTAssertEqual(restored.saved.first?.tagsVersion, 1)
    }

    private var sampleLyrics: Lyrics {
        Lyrics(lines: [
            LyricLine(
                start: 1,
                text: "slow glow",
                end: 5,
                words: [
                    LyricWord(start: 1, end: 3, text: "slow"),
                    LyricWord(start: 3, end: 5, text: "glow")
                ]
            ),
            LyricLine(start: 7, text: "after light", end: 9)
        ], source: "Fixture")
    }

    @MainActor
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
        XCTFail("Timed out waiting for embedded download")
    }
}

@MainActor
private final class EmbeddedFixtureDownloader: TrackDownloading {
    func downloadTrack(
        _ track: Track,
        quality: DownloadQuality,
        to directory: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory
            .appendingPathComponent(track.videoID ?? UUID().uuidString)
            .appendingPathExtension("m4a")
        try makeM4AFixture().data.write(to: destination)
        progress(1)
        return destination
    }
}

@MainActor
private final class EmbeddedFixtureLyricsProvider: DownloadLyricsProviding {
    let lyrics: Lyrics

    init(lyrics: Lyrics) {
        self.lyrics = lyrics
    }

    func lyricsForDownload(_ track: Track) async -> Lyrics? {
        lyrics
    }
}

@MainActor
private final class EmbeddedFixtureArtworkProvider: DownloadArtworkProviding {
    func artworkForDownload(_ track: Track) async -> DownloadArtwork? {
        DownloadArtwork(
            data: embeddedFixtureArtworkBytes,
            mimeType: "image/jpeg",
            width: 1,
            height: 1,
            depth: 24
        )
    }
}

private let embeddedFixtureArtworkBytes = Data([0xFF, 0xD8, 0xFF, 0xD9])

@MainActor
private final class EmbeddedLyricsResolver: PlaybackStreamResolving {
    let networkLyrics: Lyrics?
    private(set) var lyricRequests = 0
    var isAuthenticated: Bool { true }

    init(networkLyrics: Lyrics?) {
        self.networkLyrics = networkLyrics
    }

    func resolveStream(for track: Track) async throws -> ResolvedStream {
        throw YouTubeMusicAPIError.noPlayableStream
    }

    func downloadPlaybackFallback(for track: Track) async throws -> URL {
        throw YouTubeMusicAPIError.noPlayableStream
    }

    func lyrics(for track: Track) async throws -> Lyrics? {
        lyricRequests += 1
        return networkLyrics
    }
}

private func makeM4AFixture() -> (data: Data, chunkOffset: UInt32) {
    let ftyp = atom("ftyp", Data("M4A \0\0\0\0M4A isom".utf8))
    let placeholder = chunkOffsetAtom(offset: 0)
    let moov = atom("moov", atom("trak", atom("mdia", atom("minf", atom("stbl", placeholder)))))
    let chunkOffset = UInt32(ftyp.count + moov.count + 8)
    let finalMoov = atom(
        "moov",
        atom("trak", atom("mdia", atom("minf", atom("stbl", chunkOffsetAtom(offset: chunkOffset)))))
    )
    let mdat = atom("mdat", Data([0x21, 0x10, 0x56, 0xE5, 0x00, 0x00, 0x00, 0x08]))
    var result = ftyp
    result.append(finalMoov)
    result.append(mdat)
    return (result, chunkOffset)
}

private func makeFLACFixture(frames: Data) -> Data {
    var result = Data("fLaC".utf8)
    result.append(0x80)
    result.append(contentsOf: [0x00, 0x00, 0x22])
    result.append(Data(repeating: 0, count: 34))
    result.append(frames)
    return result
}

private func chunkOffsetAtom(offset: UInt32) -> Data {
    var payload = Data(repeating: 0, count: 12)
    writeFixtureU32(&payload, at: 4, value: 1)
    writeFixtureU32(&payload, at: 8, value: offset)
    return atom("stco", payload)
}

private func atom(_ type: String, _ payload: Data) -> Data {
    var result = Data(repeating: 0, count: 8)
    writeFixtureU32(&result, at: 0, value: UInt32(payload.count + 8))
    result.replaceSubrange(4..<8, with: Data(type.utf8))
    result.append(payload)
    return result
}

private func chunkOffset(in data: Data) -> UInt32? {
    guard let typeRange = data.range(of: Data("stco".utf8)) else { return nil }
    return readFixtureU32(data, at: typeRange.lowerBound + 12)
}

private func readFixtureU32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 |
        UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
}

private func writeFixtureU32(_ data: inout Data, at offset: Int, value: UInt32) {
    data[offset] = UInt8((value >> 24) & 0xFF)
    data[offset + 1] = UInt8((value >> 16) & 0xFF)
    data[offset + 2] = UInt8((value >> 8) & 0xFF)
    data[offset + 3] = UInt8(value & 0xFF)
}
