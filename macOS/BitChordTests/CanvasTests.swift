import Foundation
import XCTest

final class CanvasTests: XCTestCase {
    func testMatchingFoldsAccentsPunctuationAndArtistSeparators() throws {
        let artwork = try XCTUnwrap(CanvasArtwork(
            url: URL(string: "https://cdn.example.com/canvas.mp4")!,
            title: "CRAZY IN LOVE (feat. JAY-Z)",
            artist: "Beyoncé & JAY-Z",
            album: "Dangerously in Love",
            source: .tidal
        ))

        XCTAssertTrue(artwork.matches(
            title: "Crazy in Love feat JAY Z",
            artist: "Beyonce feat. Jay-Z",
            album: "Dangerously In Love"
        ))
        XCTAssertFalse(artwork.matches(
            title: "Déjà Vu",
            artist: "Beyoncé feat. JAY-Z",
            album: "Dangerously In Love"
        ))
        XCTAssertFalse(artwork.matches(
            title: "Crazy in Love feat JAY Z",
            artist: "Another Artist",
            album: "Dangerously In Love"
        ))
    }

    func testArtworkRejectsUnsafeAndNonVideoURLs() {
        XCTAssertNil(CanvasArtwork(
            url: URL(string: "http://example.com/canvas.mp4")!,
            source: .community
        ))
        XCTAssertNil(CanvasArtwork(
            url: URL(string: "https://user:secret@example.com/canvas.mp4")!,
            source: .community
        ))
        XCTAssertNil(CanvasArtwork(
            url: URL(string: "https://example.com/not-video.exe")!,
            source: .community
        ))
    }

    func testTidalProviderFindsExactTrackAndBuildsCoverURL() async throws {
        let response = #"""
        {
          "tracks": {"items": [
            {
              "title": "Another Song",
              "artists": [{"name": "SZA"}],
              "album": {"title": "SOS", "videoCover": "11111111-2222-3333-4444-555555555555"}
            },
            {
              "title": "Kill Bill",
              "artists": [{"name": "SZA"}],
              "album": {"title": "SOS", "videoCover": "ad774f0b-2e3f-41f0-b8e9-2c9db0f9ac72"}
            }
          ]}
        }
        """#.data(using: .utf8)!
        let http = CanvasFixtureHTTPClient(response: CanvasHTTPResponse(data: response, statusCode: 200))
        let provider = TidalCanvasProvider(http: http, countryCode: "US")

        let providerResult = await provider.canvas(title: "Kill Bill", artist: "SZA", album: "SOS")
        let artwork = try XCTUnwrap(providerResult)

        XCTAssertEqual(artwork.source, .tidal)
        XCTAssertEqual(artwork.title, "Kill Bill")
        XCTAssertEqual(
            artwork.url.absoluteString,
            "https://resources.tidal.com/videos/ad774f0b/2e3f/41f0/b8e9/2c9db0f9ac72/1280x1280.mp4"
        )
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].absoluteString.contains("types=TRACKS"))
    }

    func testTidalProviderFallsBackToUSCatalogAfterRegionalMiss() async throws {
        let miss = #"{"tracks":{"items":[]}}"#.data(using: .utf8)!
        let hit = #"""
        {
          "tracks": {"items": [{
            "title": "Kill Bill",
            "artists": [{"name": "SZA"}],
            "album": {"title": "SOS", "videoCover": "ad774f0b-2e3f-41f0-b8e9-2c9db0f9ac72"}
          }]}
        }
        """#.data(using: .utf8)!
        let http = CanvasSequenceHTTPClient(responses: [
            CanvasHTTPResponse(data: miss, statusCode: 200),
            CanvasHTTPResponse(data: hit, statusCode: 200)
        ])
        let provider = TidalCanvasProvider(http: http, countryCode: "RU")

        let result = await provider.canvas(title: "Kill Bill", artist: "SZA", album: "SOS")
        let artwork = try XCTUnwrap(result)
        let requests = await http.requests

        XCTAssertEqual(artwork.source, .tidal)
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].absoluteString.contains("countryCode=RU"))
        XCTAssertTrue(requests[1].absoluteString.contains("countryCode=US"))
    }

    func testRepositoryRetriesProvisionalMissWhenAlbumArrivesThenCachesHit() async throws {
        let provider = AlbumAwareCanvasProvider()
        let repository = CanvasRepository(providers: [provider])
        var track = Track(
            videoID: "canvas-track",
            title: "Kill Bill (Official Audio)",
            artist: "SZA",
            album: nil,
            artworkURL: nil,
            duration: 153,
            localPath: nil,
            sourceURL: nil
        )

        let provisional = await repository.canvas(for: track)
        XCTAssertNil(provisional)
        track.album = "SOS"
        let resolved = await repository.canvas(for: track)
        let cachedResult = await repository.canvas(for: track)
        let found = try XCTUnwrap(resolved)
        let cached = try XCTUnwrap(cachedResult)
        let calls = await provider.calls
        let lastTitle = await provider.lastTitle

        XCTAssertEqual(found, cached)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(lastTitle, "Kill Bill")
    }

    func testRepositoryNeverLooksUpLocalFiles() async {
        let provider = AlbumAwareCanvasProvider()
        let repository = CanvasRepository(providers: [provider])
        let local = Track(
            videoID: nil,
            title: "Local Song",
            artist: "Local Artist",
            album: "Local Album",
            artworkURL: nil,
            duration: 12,
            localPath: "/tmp/local.m4a",
            sourceURL: nil
        )

        let result = await repository.canvas(for: local)
        let calls = await provider.calls
        XCTAssertNil(result)
        XCTAssertEqual(calls, 0)
    }

    func testAppleScoringRejectsWrongArtistAndPrefersExactAlbum() throws {
        let exact: [String: Any] = ["attributes": [
            "name": "Blinding Lights",
            "artistName": "The Weeknd",
            "albumName": "After Hours"
        ]]
        let wrongArtist: [String: Any] = ["attributes": [
            "name": "Blinding Lights",
            "artistName": "Cover Band",
            "albumName": "After Hours"
        ]]

        XCTAssertEqual(
            AppleMusicCanvasProvider.score(
                exact,
                title: "Blinding Lights",
                artist: "The Weeknd",
                album: "After Hours"
            ),
            45
        )
        XCTAssertNil(AppleMusicCanvasProvider.score(
            wrongArtist,
            title: "Blinding Lights",
            artist: "The Weeknd",
            album: "After Hours"
        ))
    }

    func testTidalAlbumProviderUsesAlbumSearchAndReturnsMotionCover() async throws {
        let response = #"""
        {
          "albums": {"items": [{
            "title": "SOS",
            "artists": [{"name": "SZA"}],
            "videoCover": "ad774f0b-2e3f-41f0-b8e9-2c9db0f9ac72"
          }]}
        }
        """#.data(using: .utf8)!
        let http = CanvasFixtureHTTPClient(response: CanvasHTTPResponse(data: response, statusCode: 200))
        let provider = TidalCanvasProvider(http: http, countryCode: "US")

        let result = await provider.albumCanvas(album: "SOS", artist: "SZA")
        let artwork = try XCTUnwrap(result)
        let requests = await http.requests

        XCTAssertEqual(artwork.source, .tidal)
        XCTAssertEqual(artwork.album, "SOS")
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].absoluteString.contains("types=ALBUMS"))
    }

    func testSpotifyCanvasProtobufRoundTripAndExactTrackSelection() async throws {
        let uri = "spotify:track:kill-bill"
        let wrongURI = "spotify:track:wrong"
        let search = #"""
        {"tracks":{"items":[
          {"name":"Wrong Song","uri":"spotify:track:wrong-search","artists":[{"name":"SZA"}],"album":{"name":"SOS"}},
          {"name":"Kill Bill","uri":"spotify:track:kill-bill","artists":[{"name":"SZA"}],"album":{"name":"SOS"}}
        ]}}
        """#.data(using: .utf8)!
        let response = spotifyCanvasResponse([
            ("wrong", "https://cdn.example.com/wrong.cnvs.mp4", wrongURI),
            ("right", "https://cdn.example.com/kill-bill.cnvs.mp4", uri)
        ])
        let transport = SpotifyFixtureTransport(stubs: [
            .init(method: "GET", path: "/v1/search", data: search),
            .init(method: "POST", path: "/canvaz-cache/v0/canvases", data: response)
        ])
        let provider = SpotifyCanvasProvider(
            tokenProvider: FixedSpotifyTokens(value: SpotifyCanvasTokens(accessToken: "access", clientToken: nil)),
            transport: transport
        )

        let result = await provider.canvas(title: "Kill Bill", artist: "SZA", album: "SOS")
        let artwork = try XCTUnwrap(result)
        let requests = await transport.requests

        XCTAssertEqual(artwork.source, .spotify)
        XCTAssertEqual(artwork.url.absoluteString, "https://cdn.example.com/kill-bill.cnvs.mp4")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].httpBody, SpotifyCanvasProvider.encodeCanvasRequest(trackURI: uri))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer access")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Content-Type"), "application/protobuf")

        let decoded = SpotifyCanvasProvider.decodeCanvasResponse(response)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[1], SpotifyCanvasHit(
            id: "right",
            url: "https://cdn.example.com/kill-bill.cnvs.mp4",
            trackURI: uri
        ))
    }

    func testSpotifyAlbumCanvasUsesFirstTrackAndCanvasEndpoint() async throws {
        let albums = #"""
        {"albums":{"items":[{
          "id":"sos-id","name":"SOS","artists":[{"name":"SZA"}]
        }]}}
        """#.data(using: .utf8)!
        let tracks = #"{"items":[{"uri":"spotify:track:first-sos"}]}"#.data(using: .utf8)!
        let canvas = spotifyCanvasResponse([
            ("sos", "https://cdn.example.com/sos.cnvs.mp4", "spotify:track:first-sos")
        ])
        let transport = SpotifyFixtureTransport(stubs: [
            .init(method: "GET", path: "/v1/search", data: albums),
            .init(method: "GET", path: "/v1/albums/sos-id/tracks", data: tracks),
            .init(method: "POST", path: "/canvaz-cache/v0/canvases", data: canvas)
        ])
        let provider = SpotifyCanvasProvider(
            tokenProvider: FixedSpotifyTokens(value: SpotifyCanvasTokens(accessToken: "access", clientToken: "client")),
            transport: transport
        )

        let result = await provider.albumCanvas(album: "SOS", artist: "SZA")
        let artwork = try XCTUnwrap(result)
        let requests = await transport.requests

        XCTAssertEqual(artwork.url.absoluteString, "https://cdn.example.com/sos.cnvs.mp4")
        XCTAssertEqual(artwork.album, "SOS")
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[2].httpBody, SpotifyCanvasProvider.encodeCanvasRequest(trackURI: "spotify:track:first-sos"))
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Client-Token"), "client")
    }

    func testSpotifyTrackLookupPrefersWebPlayerPathfinderWhenClientTokenExists() async throws {
        let uri = "spotify:track:pathfinder-hit"
        let pathfinder = #"""
        {"data":{"searchV2":{"tracksV2":{"items":[{"item":{"data":{
          "uri":"spotify:track:pathfinder-hit"
        }}}]}}}}
        """#.data(using: .utf8)!
        let canvas = spotifyCanvasResponse([
            ("pathfinder", "https://cdn.example.com/pathfinder.cnvs.mp4", uri)
        ])
        let transport = SpotifyFixtureTransport(stubs: [
            .init(method: "GET", path: "/pathfinder/v1/query", data: pathfinder),
            .init(method: "POST", path: "/canvaz-cache/v0/canvases", data: canvas)
        ])
        let provider = SpotifyCanvasProvider(
            tokenProvider: FixedSpotifyTokens(value: SpotifyCanvasTokens(
                accessToken: "access",
                clientToken: "client"
            )),
            transport: transport
        )

        let result = await provider.canvas(title: "Kill Bill", artist: "SZA", album: "SOS")
        let artwork = try XCTUnwrap(result)
        let requests = await transport.requests

        XCTAssertEqual(artwork.url.absoluteString, "https://cdn.example.com/pathfinder.cnvs.mp4")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Client-Token"), "client")
        XCTAssertTrue(requests[0].url?.query?.contains("operationName=searchTracks") == true)
        XCTAssertEqual(requests[1].httpBody, SpotifyCanvasProvider.encodeCanvasRequest(trackURI: uri))
    }

    func testSpotifyProviderDoesNoNetworkWorkWithoutPersonalSession() async {
        let transport = SpotifyFixtureTransport(stubs: [])
        let provider = SpotifyCanvasProvider(
            tokenProvider: FixedSpotifyTokens(value: nil),
            transport: transport
        )

        let result = await provider.canvas(title: "Kill Bill", artist: "SZA", album: "SOS")
        let requests = await transport.requests

        XCTAssertNil(result)
        XCTAssertTrue(requests.isEmpty)
    }

    func testSpotifyTokenManagerMintsClientTokenThenReusesBothTokens() async throws {
        let credentialMemory = MemorySpotifyCredentialStore()
        try credentialMemory.set("personal-session-cookie", for: SpotifyCanvasCredentialStore.key)
        let credentials = SpotifyCanvasCredentialStore(store: credentialMemory)
        let harvester = SpotifyFixtureHarvester(result: SpotifyHarvestedAccessToken(
            token: "web-access-token",
            expiresAt: Date().addingTimeInterval(3_600),
            clientID: "web-client-id"
        ))
        let config = try JSONSerialization.data(withJSONObject: ["clientVersion": "1.2.3"])
            .base64EncodedString()
        let page = Data((#"<script id="appServerConfig" type="text/plain">"# + config + "</script>").utf8)
        let grant = #"""
        {"response_type":"RESPONSE_GRANTED_TOKEN_RESPONSE","granted_token":{
          "token":"client-token","expires_after_seconds":3600
        }}
        """#.data(using: .utf8)!
        let transport = SpotifyFixtureTransport(stubs: [
            .init(method: "GET", host: "open.spotify.com", path: "/", data: page,
                  headers: ["Set-Cookie": "sp_t=device-from-cookie; Path=/; Secure"]),
            .init(method: "POST", host: "clienttoken.spotify.com", path: "/v1/clienttoken", data: grant)
        ])
        let manager = SpotifyCanvasTokenManager(
            credentials: credentials,
            harvester: harvester,
            transport: transport
        )

        let first = await manager.tokens()
        let second = await manager.tokens()
        let harvestCalls = await harvester.calls
        let requests = await transport.requests

        XCTAssertEqual(first, SpotifyCanvasTokens(accessToken: "web-access-token", clientToken: "client-token"))
        XCTAssertEqual(second, first)
        XCTAssertEqual(harvestCalls, 1)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Content-Type"), "application/json")
        let payload = try XCTUnwrap(requests[1].httpBody)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let client = try XCTUnwrap(root["client_data"] as? [String: Any])
        let sdk = try XCTUnwrap(client["js_sdk_data"] as? [String: Any])
        XCTAssertEqual(client["client_version"] as? String, "1.2.3")
        XCTAssertEqual(sdk["device_id"] as? String, "device-from-cookie")
        XCTAssertEqual(sdk["os"] as? String, "osx")
    }

    func testCanvasDiskCacheDownloadsOnceAndReusesLocalClip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChordCanvasTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = URL(string: "https://cdn.example.com/loop.mp4")!
        let downloader = CanvasFixtureDownloader(
            stagingDirectory: root.appendingPathComponent("downloads", isDirectory: true),
            clips: [remote: Data(repeating: 0x2A, count: 96)]
        )
        let cache = CanvasClipCache(
            directory: root.appendingPathComponent("cache", isDirectory: true),
            limitBytes: 1_024,
            downloader: downloader
        )
        let artwork = try XCTUnwrap(CanvasArtwork(url: remote, source: .spotify))

        let first = await cache.materialize(artwork)
        let second = await cache.materialize(artwork)
        let calls = await downloader.calls

        let local = try XCTUnwrap(first.cachedURL)
        XCTAssertTrue(local.isFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
        XCTAssertEqual(second.cachedURL, local)
        XCTAssertEqual(calls, 1)
    }

    func testHLSResourceLoaderRewritesEveryAbsoluteSegmentThroughItsCacheScheme() throws {
        let remote = try XCTUnwrap(URL(string: "https://cdn.example.com/path/loop.m3u8?token=abc"))
        let proxy = try XCTUnwrap(CanvasHLSResourceLoader.proxyURL(for: remote))
        XCTAssertEqual(proxy.scheme, CanvasHLSResourceLoader.scheme)
        XCTAssertEqual(CanvasHLSResourceLoader.remoteURL(for: proxy), remote)

        let playlist = #"""
        #EXTM3U
        #EXT-X-MAP:URI="https://cdn.example.com/path/init.mp4?token=abc"
        #EXTINF:2.0,
        https://cdn.example.com/path/segment-1.m4s?token=abc
        #EXTINF:2.0,
        segment-2.m4s
        """#
        let rewritten = try XCTUnwrap(String(
            data: CanvasHLSResourceLoader.rewritePlaylist(Data(playlist.utf8)),
            encoding: .utf8
        ))

        XCTAssertTrue(rewritten.contains("bitchord-canvas://cdn.example.com/path/init.mp4?token=abc"))
        XCTAssertTrue(rewritten.contains("bitchord-canvas://cdn.example.com/path/segment-1.m4s?token=abc"))
        XCTAssertTrue(rewritten.contains("segment-2.m4s"))
        XCTAssertFalse(rewritten.contains("https://cdn.example.com"))
    }

    func testCanvasDiskCacheEvictsLeastRecentlyUsedClip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChordCanvasLRU-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = URL(string: "https://cdn.example.com/first.mp4")!
        let secondURL = URL(string: "https://cdn.example.com/second.mp4")!
        let downloader = CanvasFixtureDownloader(
            stagingDirectory: root.appendingPathComponent("downloads", isDirectory: true),
            clips: [
                firstURL: Data(repeating: 0x01, count: 70),
                secondURL: Data(repeating: 0x02, count: 70)
            ]
        )
        let cache = CanvasClipCache(
            directory: root.appendingPathComponent("cache", isDirectory: true),
            limitBytes: 100,
            downloader: downloader
        )
        let first = try XCTUnwrap(CanvasArtwork(url: firstURL, source: .tidal))
        let second = try XCTUnwrap(CanvasArtwork(url: secondURL, source: .tidal))

        _ = await cache.materialize(first)
        try await Task.sleep(nanoseconds: 20_000_000)
        _ = await cache.materialize(second)
        let evicted = await cache.cachedURL(for: firstURL)
        let retained = await cache.cachedURL(for: secondURL)

        XCTAssertNil(evicted)
        XCTAssertNotNil(retained)
    }
}

private actor CanvasFixtureHTTPClient: CanvasHTTPClient {
    let response: CanvasHTTPResponse
    private(set) var requests: [URL] = []

    init(response: CanvasHTTPResponse) {
        self.response = response
    }

    func get(_ url: URL, headers: [String: String]) async throws -> CanvasHTTPResponse {
        requests.append(url)
        return response
    }
}

private actor CanvasSequenceHTTPClient: CanvasHTTPClient {
    let responses: [CanvasHTTPResponse]
    private(set) var requests: [URL] = []

    init(responses: [CanvasHTTPResponse]) {
        self.responses = responses
    }

    func get(_ url: URL, headers: [String: String]) async throws -> CanvasHTTPResponse {
        requests.append(url)
        let index = min(requests.count - 1, responses.count - 1)
        return responses[index]
    }
}

private actor AlbumAwareCanvasProvider: CanvasProvider {
    private(set) var calls = 0
    private(set) var lastTitle: String?

    func canvas(title: String, artist: String, album: String?) async -> CanvasArtwork? {
        calls += 1
        lastTitle = title
        guard album == "SOS" else { return nil }
        return CanvasArtwork(
            url: URL(string: "https://cdn.example.com/kill-bill.mp4")!,
            title: title,
            artist: artist,
            album: album,
            source: .tidal
        )
    }
}

private struct FixedSpotifyTokens: SpotifyCanvasTokenProviding {
    let value: SpotifyCanvasTokens?

    func tokens() async -> SpotifyCanvasTokens? { value }
}

private struct SpotifyFixtureStub: Sendable {
    let method: String
    let host: String?
    let path: String
    let data: Data
    let statusCode: Int
    let headers: [String: String]

    init(
        method: String,
        host: String? = nil,
        path: String,
        data: Data,
        statusCode: Int = 200,
        headers: [String: String] = [:]
    ) {
        self.method = method
        self.host = host
        self.path = path
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }
}

private actor SpotifyFixtureTransport: SpotifyCanvasHTTPTransport {
    let stubs: [SpotifyFixtureStub]
    private(set) var requests: [URLRequest] = []

    init(stubs: [SpotifyFixtureStub]) { self.stubs = stubs }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let method = request.httpMethod ?? "GET"
        guard let url = request.url,
              let stub = stubs.first(where: {
                  $0.method == method &&
                      ($0.host == nil || $0.host == url.host) &&
                      url.path.contains($0.path)
              }),
              let response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"].merging(stub.headers) { _, fixture in fixture }
              ) else { throw URLError(.badServerResponse) }
        return (stub.data, response)
    }
}

private actor SpotifyFixtureHarvester: SpotifyAccessTokenHarvesting {
    let result: SpotifyHarvestedAccessToken?
    private(set) var calls = 0

    init(result: SpotifyHarvestedAccessToken?) { self.result = result }

    func harvest(cookie: String) async -> SpotifyHarvestedAccessToken? {
        calls += 1
        return result
    }
}

private final class MemorySpotifyCredentialStore: ScrobbleCredentialStoring {
    private var values: [String: String] = [:]

    func string(for key: String) -> String? { values[key] }

    func set(_ value: String?, for key: String) throws {
        values[key] = value
    }
}

private actor CanvasFixtureDownloader: CanvasClipDownloading {
    let stagingDirectory: URL
    let clips: [URL: Data]
    private(set) var calls = 0

    init(stagingDirectory: URL, clips: [URL: Data]) {
        self.stagingDirectory = stagingDirectory
        self.clips = clips
    }

    func download(_ url: URL) async throws -> CanvasDownloadedClip {
        calls += 1
        guard let data = clips[url] else { throw URLError(.fileDoesNotExist) }
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let temporaryURL = stagingDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try data.write(to: temporaryURL, options: .atomic)
        return CanvasDownloadedClip(
            temporaryURL: temporaryURL,
            responseURL: url,
            mimeType: "video/mp4",
            expectedLength: Int64(data.count)
        )
    }
}

private func spotifyCanvasResponse(_ rows: [(String, String, String)]) -> Data {
    rows.reduce(into: Data()) { output, row in
        var canvas = spotifyProtobufField(number: 1, bytes: Data(row.0.utf8))
        canvas.append(spotifyProtobufField(number: 2, bytes: Data(row.1.utf8)))
        canvas.append(spotifyProtobufField(number: 5, bytes: Data(row.2.utf8)))
        output.append(spotifyProtobufField(number: 1, bytes: canvas))
    }
}

private func spotifyProtobufField(number: Int, bytes: Data) -> Data {
    var output = spotifyProtobufVarint(UInt64(number << 3 | 2))
    output.append(spotifyProtobufVarint(UInt64(bytes.count)))
    output.append(bytes)
    return output
}

private func spotifyProtobufVarint(_ input: UInt64) -> Data {
    var input = input
    var output = Data()
    repeat {
        var byte = UInt8(input & 0x7F)
        input >>= 7
        if input != 0 { byte |= 0x80 }
        output.append(byte)
    } while input != 0
    return output
}
