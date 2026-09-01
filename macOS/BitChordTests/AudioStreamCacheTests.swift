import XCTest
@testable import BitChord

final class AudioStreamCacheTests: XCTestCase {
    func testBoundedRangesProduceStableCachedFile() async throws {
        RangeCacheURLProtocol.payload = Data("abcdefghijklmnop".utf8)
        RangeCacheURLProtocol.requestedRanges = []
        RangeCacheURLProtocol.responseDelay = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeCacheURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AudioStreamCache(
            directory: directory,
            session: session,
            limitBytes: 100,
            chunkBytes: 5,
            allowedLimits: 1...100
        )
        let stream = ResolvedStream(
            url: URL(string: "https://cache.test/audio?clen=16")!,
            headers: ["X-Test": "present"],
            videoID: "video_1"
        )

        try await cache.store(stream, quality: .high)

        let cached = await cache.cachedURL(videoID: "video_1", quality: .high)
        XCTAssertNotNil(cached)
        XCTAssertEqual(try cached.map { try Data(contentsOf: $0) }, RangeCacheURLProtocol.payload)
        let snapshot = await cache.snapshot()
        XCTAssertEqual(snapshot, .init(usedBytes: 16, fileCount: 1))
        XCTAssertEqual(RangeCacheURLProtocol.requestedRanges, ["bytes=0-65535"])
        XCTAssertTrue(RangeCacheURLProtocol.receivedTestHeader)
    }

    func testClearInvalidatesAnInFlightCacheFill() async throws {
        RangeCacheURLProtocol.payload = Data(repeating: 7, count: 128)
        RangeCacheURLProtocol.requestedRanges = []
        RangeCacheURLProtocol.responseDelay = 0.08
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeCacheURLProtocol.self]
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AudioStreamCache(
            directory: directory,
            session: URLSession(configuration: configuration),
            limitBytes: 1_000,
            allowedLimits: 1...1_000
        )
        let stream = ResolvedStream(
            url: URL(string: "https://cache.test/slow?clen=128")!,
            headers: [:],
            videoID: "slow-video"
        )
        let fill = Task { try await cache.store(stream, quality: .high) }
        while RangeCacheURLProtocol.requestedRanges.isEmpty {
            try await Task.sleep(for: .milliseconds(2))
        }

        _ = await cache.clear()

        do {
            try await fill.value
            XCTFail("A clear should invalidate the in-flight file before it is published")
        } catch is CancellationError {
            // Expected.
        }
        let cached = await cache.cachedURL(videoID: "slow-video", quality: .high)
        XCTAssertNil(cached)
        RangeCacheURLProtocol.responseDelay = 0
    }

    func testLRUPrunesByBytesAndClearRemovesBothCacheKinds() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = directory.appendingPathComponent("fallback-old-high.m4a")
        let recent = directory.appendingPathComponent("stream-new-high.m4a")
        try Data(repeating: 1, count: 6).write(to: old)
        try Data(repeating: 2, count: 6).write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: recent.path)
        let cache = AudioStreamCache(
            directory: directory,
            limitBytes: 12,
            allowedLimits: 1...100
        )

        let pruned = await cache.updateLimit(8)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertEqual(pruned, .init(usedBytes: 6, fileCount: 1))
        let cleared = await cache.clear()
        XCTAssertEqual(cleared, .init(usedBytes: 0, fileCount: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recent.path))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChordAudioCacheTests-\(UUID().uuidString)", isDirectory: true)
    }
}

private final class RangeCacheURLProtocol: URLProtocol {
    static var payload = Data()
    static var requestedRanges: [String] = []
    static var receivedTestHeader = false
    static var responseDelay: TimeInterval = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let rangeHeader = request.value(forHTTPHeaderField: "Range") ?? ""
        Self.requestedRanges.append(rangeHeader)
        Self.receivedTestHeader = request.value(forHTTPHeaderField: "X-Test") == "present"
        guard let range = Self.range(from: rangeHeader), range.lowerBound < Self.payload.count else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let end = min(range.upperBound, Self.payload.count - 1)
        let body = Self.payload.subdata(in: range.lowerBound..<(end + 1))
        let headers = [
            "Content-Type": "audio/mp4",
            "Content-Range": "bytes \(range.lowerBound)-\(end)/\(Self.payload.count)",
            "Content-Length": "\(body.count)"
        ]
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        let send = { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if Self.responseDelay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.responseDelay, execute: send)
        } else {
            send()
        }
    }

    override func stopLoading() {}

    private static func range(from value: String) -> ClosedRange<Int>? {
        guard value.hasPrefix("bytes=") else { return nil }
        let pieces = value.dropFirst(6).split(separator: "-", maxSplits: 1)
        guard pieces.count == 2, let start = Int(pieces[0]), let end = Int(pieces[1]) else { return nil }
        return start...end
    }
}
