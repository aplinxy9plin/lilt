import XCTest

@MainActor
final class SourceModuleTests: XCTestCase {
    private var defaults: UserDefaults!
    private var session: URLSession!

    override func setUp() async throws {
        let suite = "BitChordTests.SourceModules.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleFixtureURLProtocol.self]
        session = URLSession(configuration: configuration)
        ModuleFixtureURLProtocol.script = Self.moduleScript(streamURL: "https://audio.fixture/song.flac")
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        session = nil
        defaults = nil
    }

    func testCompatibleModuleResolvesMatchingLosslessTrackEndToEnd() async throws {
        let manager = SourceModuleManager(defaults: defaults, session: session, autoRefreshHealth: false)
        manager.save(url: "https://modules.fixture/index.json", label: "My Hi-Res", enabled: true)
        manager.setPlaybackQuality(.high)
        let target = Track(
            videoID: "youtube-id",
            title: "Night Drive (Official Audio)",
            artist: "Test Artist",
            album: "Test Album",
            artworkURL: nil,
            duration: 243,
            localPath: nil,
            sourceURL: nil
        )

        let resolved = await manager.resolveStream(for: target)
        let stream = try XCTUnwrap(resolved)

        XCTAssertEqual(stream.url.absoluteString, "https://audio.fixture/song.flac")
        XCTAssertEqual(stream.info?.sourceName, "My Hi-Res")
        XCTAssertEqual(stream.info?.codec, "FLAC")
        XCTAssertEqual(stream.info?.bitDepth, 24)
        XCTAssertEqual(stream.info?.sampleRate, 96_000)
        XCTAssertTrue(stream.info?.isLossless == true)
        XCTAssertEqual(manager.lastResolvedSource, "My Hi-Res")
    }

    func testModuleCannotSubstituteDifferentRecording() async {
        let manager = SourceModuleManager(defaults: defaults, session: session, autoRefreshHealth: false)
        manager.save(url: "https://modules.fixture/index.json", label: "Fixture", enabled: true)
        manager.setPlaybackQuality(.high)
        let target = Track(
            videoID: "youtube-id",
            title: "Completely Different Song",
            artist: "Another Artist",
            album: nil,
            artworkURL: nil,
            duration: 180,
            localPath: nil,
            sourceURL: nil
        )

        let stream = await manager.resolveStream(for: target)

        XCTAssertNil(stream, "A module result must pass title, artist and duration identity checks")
    }

    func testMeteredQualitySkipsLosslessModuleLookup() async {
        let manager = SourceModuleManager(defaults: defaults, session: session, autoRefreshHealth: false)
        manager.save(url: "https://modules.fixture/index.json", label: "Fixture", enabled: true)
        manager.setPlaybackQuality(.medium)
        let target = Track(
            videoID: "youtube-id",
            title: "Night Drive",
            artist: "Test Artist",
            album: nil,
            artworkURL: nil,
            duration: 243,
            localPath: nil,
            sourceURL: nil
        )

        let stream = await manager.resolveStream(for: target)
        XCTAssertNil(stream)
    }

    func testExplicitLosslessDownloadIgnoresMeteredPlaybackProfile() async throws {
        let manager = SourceModuleManager(defaults: defaults, session: session, autoRefreshHealth: false)
        manager.save(url: "https://modules.fixture/index.json", label: "Fixture", enabled: true)
        manager.setPlaybackQuality(.medium)
        let target = Track(
            videoID: "youtube-id",
            title: "Night Drive",
            artist: "Test Artist",
            album: nil,
            artworkURL: nil,
            duration: 243,
            localPath: nil,
            sourceURL: nil
        )

        let resolved = await manager.resolveDownloadStream(for: target)
        let stream = try XCTUnwrap(resolved)

        XCTAssertTrue(stream.info?.isLossless == true)
        XCTAssertEqual(stream.info?.sourceName, "Fixture")
    }

    func testDoubledOriginModuleURLIsRejected() async {
        ModuleFixtureURLProtocol.script = Self.moduleScript(
            streamURL: "https://audio.fixture/media/https://audio.fixture/media/song.flac"
        )
        let manager = SourceModuleManager(defaults: defaults, session: session, autoRefreshHealth: false)
        manager.save(url: "https://modules.fixture/index.json", label: "Fixture", enabled: true)
        manager.setPlaybackQuality(.high)
        let target = Track(
            videoID: "youtube-id",
            title: "Night Drive",
            artist: "Test Artist",
            album: nil,
            artworkURL: nil,
            duration: 243,
            localPath: nil,
            sourceURL: nil
        )

        let stream = await manager.resolveStream(for: target)
        XCTAssertNil(stream)
    }

    private static func moduleScript(streamURL: String) -> String {
        """
        module.exports = {
          searchTracks: async function(query, limit, context) {
            return {
              tracks: [{
                id: 'fixture-track',
                title: 'Night Drive',
                artist: 'Test Artist',
                album: 'Test Album',
                albumCover: null,
                duration: 243,
                audioQuality: 'FLAC 24-bit / 96kHz',
                format: 'flac',
                availableQualities: ['LOW', 'HIGH', 'LOSSLESS']
              }],
              total: 1
            };
          },
          getTrackStreamUrl: async function(trackId, preferredQuality, context) {
            if (preferredQuality !== 'LOSSLESS') throw new Error('LOSSLESS was not requested');
            if (context.settings.quality.value !== 'LOSSLESS') throw new Error('quality context missing');
            if (context.settings.fallbackMode.value !== 'strict') throw new Error('strict fallback missing');
            return {
              streamUrl: '\(streamURL)',
              track: {
                id: trackId,
                audioQuality: 'LOSSLESS',
                mimeType: 'audio/flac',
                bitDepth: 24,
                sampleRate: 96000
              }
            };
          }
        };
        """
    }
}

@MainActor
final class JioSaavnTests: XCTestCase {
    private var session: URLSession!

    override func setUp() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JioSaavnFixtureURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        session = nil
    }

    func testSearchAnd320KbpsStreamResolutionMatchAndroidProtocol() async throws {
        let service = JioSaavnService(
            session: session,
            endpoint: try XCTUnwrap(URL(string: "https://jiosaavn.fixture/api.php"))
        )

        let tracks = try await service.search(query: "Night Drive", limit: 10)
        let track = try XCTUnwrap(tracks.first)
        XCTAssertEqual(track.title, "Night & Drive")
        XCTAssertEqual(track.artist, "Test Artist")
        XCTAssertEqual(track.album, "Fixture Album")
        XCTAssertEqual(track.duration, 243)
        XCTAssertEqual(track.catalogSource, .jioSaavn)
        XCTAssertEqual(track.catalogTrackID, "fixture-song")
        XCTAssertEqual(track.downloadIdentifier, "jioSaavn:fixture-song")
        XCTAssertNil(track.youtubeURL)
        XCTAssertEqual(track.artworkURL, "https://images.fixture/500x500.jpg")

        let stream = try await service.stream(
            trackID: "fixture-song",
            cacheID: track.downloadIdentifier,
            quality: .high
        )
        XCTAssertEqual(stream.url.absoluteString, "https://aac.saavncdn.com/001/song_320.mp4")
        XCTAssertEqual(stream.info?.bitrateKbps, 320)
        XCTAssertEqual(stream.info?.codec, "AAC")
        XCTAssertEqual(stream.info?.sourceName, "JioSaavn")
        XCTAssertEqual(stream.videoID, "jioSaavn:fixture-song")
        XCTAssertEqual(stream.duration, 243)
        XCTAssertTrue(JioSaavnFixtureURLProtocol.receivedAndroidContext)
        XCTAssertTrue(JioSaavnFixtureURLProtocol.receivedRegionalHeaders)
    }

    func testDESFixtureAndConditionalBitrateRewrite() throws {
        let encrypted = "ID2ieOjCrwfgWvL5sXl4B1ImC5QfbsDyz1GicRnauRWTd2rpdPMbYJTfaQv+DMIi"
        XCTAssertEqual(
            JioSaavnService.decryptMediaURL(encrypted),
            "https://aac.saavncdn.com/001/song_160.mp4"
        )
        XCTAssertEqual(
            JioSaavnService.bestStream(encryptedMediaURL: encrypted, supports320: true),
            JioSaavnStream(url: try XCTUnwrap(URL(string: "https://aac.saavncdn.com/001/song_320.mp4")), kbps: 320)
        )
        XCTAssertEqual(
            JioSaavnService.bestStream(encryptedMediaURL: encrypted, supports320: false),
            JioSaavnStream(url: try XCTUnwrap(URL(string: "https://aac.saavncdn.com/001/song_160.mp4")), kbps: 160)
        )
    }

    func testSourceTogglePersists() throws {
        let suite = "BitChordTests.JioSaavn.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = JioSaavnService(
            session: session,
            endpoint: try XCTUnwrap(URL(string: "https://jiosaavn.fixture/api.php"))
        )
        let manager = SourceModuleManager(
            defaults: defaults,
            session: session,
            jioSaavnService: service,
            autoRefreshHealth: false
        )
        XCTAssertFalse(manager.jioSaavnEnabled)
        manager.setJioSaavnEnabled(true)
        XCTAssertTrue(manager.jioSaavnEnabled)

        let restored = SourceModuleManager(
            defaults: defaults,
            session: session,
            jioSaavnService: service,
            autoRefreshHealth: false
        )
        XCTAssertTrue(restored.jioSaavnEnabled)
    }

    func testYouTubeRowNeverRacesATextMatchedJioSaavnStream() async throws {
        JioSaavnFixtureURLProtocol.requestCount = 0
        let suite = "BitChordTests.ExactYouTube.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = JioSaavnService(
            session: session,
            endpoint: try XCTUnwrap(URL(string: "https://jiosaavn.fixture/api.php"))
        )
        let manager = SourceModuleManager(
            defaults: defaults,
            session: session,
            jioSaavnService: service,
            autoRefreshHealth: false
        )
        manager.setJioSaavnEnabled(true)
        manager.setPlaybackQuality(.high)
        let youtube = ExactYouTubeResolver()
        let resolver = SourceAwarePlaybackResolver(youtube: youtube, sources: manager)
        let target = Track(
            videoID: "youtube-video-id",
            title: "Night Drive",
            artist: "Test Artist",
            album: nil,
            artworkURL: nil,
            duration: 243,
            localPath: nil,
            sourceURL: nil
        )

        let stream = try await resolver.resolveStream(for: target)

        XCTAssertEqual(stream.url.absoluteString, "https://youtube.fixture/exact-video.m4a")
        XCTAssertEqual(JioSaavnFixtureURLProtocol.requestCount, 0)
    }
}

private final class ModuleFixtureURLProtocol: URLProtocol {
    static var script = ""

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "modules.fixture"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body: Data
        if url.path == "/index.json" {
            body = Data(
                """
                {
                  "category:music": [{
                    "id": "fixture-lossless",
                    "name": "Fixture Lossless",
                    "author": "BitChord Tests",
                    "version": "1",
                    "download": "fixture.js",
                    "labels": ["FLAC", "Lossless", "Hi-Res"]
                  }],
                  "category:artworks": [{
                    "id": "ignored",
                    "name": "Ignored",
                    "download": "ignored.js"
                  }]
                }
                """.utf8
            )
        } else {
            body = Data(Self.script.utf8)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": url.pathExtension == "json" ? "application/json" : "text/javascript"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class JioSaavnFixtureURLProtocol: URLProtocol {
    static var receivedAndroidContext = false
    static var receivedRegionalHeaders = false
    static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "jiosaavn.fixture"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        Self.receivedAndroidContext = query["ctx"] == "android"
        Self.receivedRegionalHeaders = request.value(forHTTPHeaderField: "X-Forwarded-For") == "49.36.0.1"
            && request.value(forHTTPHeaderField: "Cookie") == "explicit_content=1"

        let song = """
        {
          "id": "fixture-song",
          "title": "Night &amp; Drive",
          "image": "http://images.fixture/150x150.jpg",
          "more_info": {
            "album": "Fixture Album",
            "encrypted_media_url": "ID2ieOjCrwfgWvL5sXl4B1ImC5QfbsDyz1GicRnauRWTd2rpdPMbYJTfaQv+DMIi",
            "duration": "243",
            "320kbps": "true",
            "artistMap": { "primary_artists": [{ "id": "artist", "name": "Test Artist" }] }
          }
        }
        """
        let body: String
        if query["__call"] == "search.getResults" {
            body = "{\"results\":[\(song)]}"
        } else {
            body = "{\"fixture-song\":\(song)}"
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private final class ExactYouTubeResolver: PlaybackStreamResolving {
    var isAuthenticated: Bool { true }

    func resolveStream(for track: Track) async throws -> ResolvedStream {
        ResolvedStream(
            url: URL(string: "https://youtube.fixture/exact-video.m4a")!,
            headers: [:],
            videoID: track.videoID,
            info: AudioStreamInfo(
                requestedQuality: .high,
                bitrateKbps: 128,
                codec: "AAC",
                sampleRate: 44_100,
                channels: 2,
                sourceName: "YouTube Music"
            )
        )
    }

    func downloadPlaybackFallback(for track: Track) async throws -> URL {
        throw YouTubeMusicAPIError.noPlayableStream
    }

    func lyrics(for track: Track) async throws -> Lyrics? { nil }
}
