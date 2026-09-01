import Foundation
import XCTest

final class ArtistFactsTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUp() async throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChordArtistFactsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
        temporaryRoot = nil
    }

    func testCanonicalGenresUseAndroidAliasesVocabularyAndTagRank() {
        let genres = ArtistFactsStore.canonicalGenres(from: [
            ("seen live", 500),
            ("r&b", 400),
            ("hiphop", 300),
            ("awesome", 200),
            ("rhythm and blues", 100)
        ])

        XCTAssertEqual(genres, ["R&B", "Hip-Hop"])
    }

    func testLastFMIsPrimaryAndGenreTimeIsAggregated() async throws {
        let transport = ArtistFactsFixtureTransport { request in
            XCTAssertEqual(request.url?.host, "ws.audioscrobbler.com")
            return .json(#"{"toptags":{"tag":[{"name":"seen live"},{"name":"r&b"},{"name":"hiphop"}],"@attr":{"artist":"Beyoncé"}}}"#)
        }
        let store = ArtistFactsStore(
            directory: temporaryRoot,
            transport: transport,
            lastFMConfigurationProvider: {
                (URL(string: LastFMClient.defaultEndpoint)!, "fixture-key")
            },
            requestSpacingNanoseconds: 0
        )
        let summary = makeSummary(artists: [
            named("Beyoncé", milliseconds: 180_000, plays: 2)
        ])

        await store.warm(artists: ["Beyoncé"])
        let enriched = try await waitForGenres(in: store, summary: summary)
        let requestCount = await transport.requestCount()
        let status = await store.status()

        XCTAssertEqual(enriched.genres.map(\.title), ["Hip-Hop", "R&B"])
        XCTAssertEqual(enriched.genres.map(\.milliseconds), [180_000, 180_000])
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(status.lastSource, .lastFM)
    }

    func testMusicBrainzIsUsedWhenLastFMFails() async throws {
        let transport = ArtistFactsFixtureTransport { request in
            switch request.url?.host {
            case "ws.audioscrobbler.com":
                return .json("{}", status: 503)
            case "musicbrainz.org":
                return .json(#"{"artists":[{"id":"exact","name":"SZA","score":100,"tags":[{"count":30,"name":"r&b"},{"count":20,"name":"electronic"},{"count":10,"name":"seen live"}]},{"id":"wrong","name":"SZA Tribute","score":100,"tags":[{"count":99,"name":"rock"}]}]}"#)
            default:
                throw URLError(.badURL)
            }
        }
        let store = ArtistFactsStore(
            directory: temporaryRoot,
            transport: transport,
            lastFMConfigurationProvider: {
                (URL(string: LastFMClient.defaultEndpoint)!, "fixture-key")
            },
            requestSpacingNanoseconds: 0
        )
        let summary = makeSummary(artists: [named("SZA", milliseconds: 240_000, plays: 4)])

        await store.warm(artists: ["SZA"])
        let enriched = try await waitForGenres(in: store, summary: summary)
        let requestCount = await transport.requestCount()
        let status = await store.status()

        XCTAssertEqual(enriched.genres.map(\.title), ["Electronic", "R&B"])
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(status.lastSource, .musicBrainz)
    }

    func testGenresAreReadFromPersistentCacheWithoutAnotherRequest() async throws {
        let firstTransport = ArtistFactsFixtureTransport { _ in
            .json(#"{"artists":[{"name":"Massive Attack","score":100,"tags":[{"count":20,"name":"trip hop"},{"count":10,"name":"electronic"}]}]}"#)
        }
        let summary = makeSummary(artists: [named("Massive Attack", milliseconds: 300_000, plays: 3)])
        let firstStore = ArtistFactsStore(
            directory: temporaryRoot,
            transport: firstTransport,
            requestSpacingNanoseconds: 0
        )
        await firstStore.warm(artists: ["Massive Attack"])
        _ = try await waitForGenres(in: firstStore, summary: summary)

        let offlineTransport = ArtistFactsFixtureTransport { _ in
            throw URLError(.notConnectedToInternet)
        }
        let restoredStore = ArtistFactsStore(
            directory: temporaryRoot,
            transport: offlineTransport,
            requestSpacingNanoseconds: 0
        )
        let restored = await restoredStore.applyingGenres(to: summary)
        let requestCount = await offlineTransport.requestCount()

        XCTAssertEqual(restored.genres.map(\.title), ["Downtempo", "Electronic"])
        XCTAssertEqual(requestCount, 0)
    }

    func testExactArtistMissIsCachedForFourteenDays() async throws {
        let missingTransport = ArtistFactsFixtureTransport { _ in
            .json(#"{"artists":[]}"#)
        }
        let lookupDate = Date(timeIntervalSince1970: 1_800_000_000)
        let firstStore = ArtistFactsStore(
            directory: temporaryRoot,
            transport: missingTransport,
            now: { lookupDate },
            requestSpacingNanoseconds: 0
        )
        await firstStore.warm(artists: ["Unknown Fixture Artist"])
        try await waitUntilSettled(firstStore)

        let secondTransport = ArtistFactsFixtureTransport { _ in
            .json(#"{"artists":[{"name":"Unknown Fixture Artist","score":100,"tags":[{"count":1,"name":"rock"}]}]}"#)
        }
        let secondStore = ArtistFactsStore(
            directory: temporaryRoot,
            transport: secondTransport,
            now: { lookupDate.addingTimeInterval(13 * 24 * 60 * 60) },
            requestSpacingNanoseconds: 0
        )
        await secondStore.warm(artists: ["Unknown Fixture Artist"])
        try await Task.sleep(nanoseconds: 20_000_000)
        let requestCount = await secondTransport.requestCount()

        XCTAssertEqual(requestCount, 0)
    }

    private func waitForGenres(
        in store: ArtistFactsStore,
        summary: ReplaySummary
    ) async throws -> ReplaySummary {
        for _ in 0..<200 {
            let enriched = await store.applyingGenres(to: summary)
            let status = await store.status()
            if !enriched.genres.isEmpty, status.queuedArtists == 0 { return enriched }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for artist genre enrichment")
        return await store.applyingGenres(to: summary)
    }

    private func waitUntilSettled(_ store: ArtistFactsStore) async throws {
        for _ in 0..<200 {
            if await store.status().queuedArtists == 0 { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for artist genre lookup")
    }

    private func makeSummary(artists: [ReplayNamedStat]) -> ReplaySummary {
        ReplaySummary(
            period: .allTime,
            totalMilliseconds: artists.reduce(0) { $0 + $1.milliseconds },
            totalPlays: artists.reduce(0) { $0 + $1.plays },
            tracks: [],
            artists: artists,
            albums: [],
            genres: [],
            busiestHour: nil,
            busiestHourMilliseconds: 0,
            busiestDay: nil,
            busiestDayMilliseconds: 0,
            memberSince: nil
        )
    }

    private func named(_ title: String, milliseconds: Int64, plays: Int) -> ReplayNamedStat {
        ReplayNamedStat(
            id: title.lowercased(),
            title: title,
            subtitle: nil,
            artworkURL: nil,
            milliseconds: milliseconds,
            plays: plays
        )
    }
}

private actor ArtistFactsFixtureTransport: ArtistFactsHTTPTransport {
    struct FixtureResponse: Sendable {
        let data: Data
        let status: Int

        static func json(_ body: String, status: Int = 200) -> FixtureResponse {
            FixtureResponse(data: Data(body.utf8), status: status)
        }
    }

    typealias Handler = @Sendable (URLRequest) throws -> FixtureResponse

    private let handler: Handler
    private var requests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let fixture = try handler(request)
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: fixture.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            throw ArtistFactsError.invalidResponse
        }
        return (fixture.data, response)
    }

    func requestCount() -> Int { requests.count }
}
