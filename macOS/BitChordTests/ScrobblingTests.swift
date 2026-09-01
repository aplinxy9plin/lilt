import Foundation
import XCTest

final class ScrobblingTests: XCTestCase {
    func testLastFMSignatureSortsEveryArrayParameterUsingASCIINames() {
        let signature = LastFMClient.apiSignature(
            parameters: [
                "track[0]": "Title",
                "method": "track.scrobble",
                "timestamp[0]": "100",
                "artist[0]": "Artist",
                "sk": "session",
                "api_key": "abc"
            ],
            secret: "secret"
        )

        XCTAssertEqual(signature, "4ef2c704071128b7715ecf92a99348f3")
    }

    func testLastFMRequestSignsBodyButLeavesFormatOutOfSignature() throws {
        let endpoint = try XCTUnwrap(URL(string: LastFMClient.defaultEndpoint))
        let client = LastFMClient(
            credentials: LastFMCredentials(
                endpoint: endpoint,
                apiKey: "abc",
                secret: "secret",
                sessionKey: "session"
            ),
            transport: ScrobbleMockTransport()
        )
        let request = client.makeRequest(
            method: "track.scrobble",
            extra: [
                "artist[0]": "Artist",
                "track[0]": "Title",
                "timestamp[0]": "100"
            ],
            sessionKey: "session"
        )
        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        let components = URLComponents(string: "?\(body)")
        let values = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(values["format"], "json")
        XCTAssertEqual(values["api_sig"], "4ef2c704071128b7715ecf92a99348f3")
        XCTAssertEqual(values["artist[0]"], "Artist")
    }

    func testListenBrainzPlayingNowAndSinglePayloadsHaveDifferentTimestamps() throws {
        let client = ListenBrainzClient(transport: ScrobbleMockTransport())
        let track = ScrobbleTrack(
            track: Track(
                videoID: "youtube-id",
                title: "Song",
                artist: "Artist",
                album: "Album",
                artworkURL: nil,
                duration: 200,
                localPath: nil,
                sourceURL: nil
            ),
            duration: 200
        )

        let playing = try client.submissionRequest(
            token: "token",
            type: "playing_now",
            track: track,
            listenedAt: nil,
            position: 12.5
        )
        let single = try client.submissionRequest(
            token: "token",
            type: "single",
            track: track,
            listenedAt: 1_700_000_000,
            position: nil
        )
        let playingJSON = try jsonObject(playing.httpBody)
        let singleJSON = try jsonObject(single.httpBody)
        let playingListen = try firstListen(playingJSON)
        let singleListen = try firstListen(singleJSON)
        let playingInfo = try additionalInfo(playingListen)
        let singleInfo = try additionalInfo(singleListen)

        XCTAssertNil(playingListen["listened_at"])
        XCTAssertEqual(playingInfo["position_ms"] as? Int, 12_500)
        XCTAssertEqual(playingInfo["duration_ms"] as? Int, 200_000)
        XCTAssertEqual(playingInfo["music_service"] as? String, "music.youtube.com")
        XCTAssertEqual(singleListen["listened_at"] as? Int, 1_700_000_000)
        XCTAssertNil(singleInfo["position_ms"])
        XCTAssertEqual(playing.value(forHTTPHeaderField: "Authorization"), "Token token")
    }

    func testThresholdMatchesKotlinTimingAndRejectsShortTracks() {
        XCTAssertNil(ScrobbleThreshold.seconds(
            duration: 30,
            minimumSongDuration: 30,
            delayPercent: 0.5,
            maximumDelay: 180
        ))
        XCTAssertEqual(ScrobbleThreshold.seconds(
            duration: 200,
            minimumSongDuration: 30,
            delayPercent: 0.5,
            maximumDelay: 180
        ), 100)
        XCTAssertEqual(ScrobbleThreshold.seconds(
            duration: 600,
            minimumSongDuration: 30,
            delayPercent: 0.5,
            maximumDelay: 180
        ), 180)
    }

    @MainActor
    func testListenBrainzConnectionIsValidatedAndAudibleClockSubmitsOnce() async throws {
        let transport = ScrobbleMockTransport(responses: [
            .json(#"{"valid":true,"user_name":"musicbrainz-user"}"#),
            .json(#"{"status":"ok"}"#),
            .json(#"{"status":"ok"}"#)
        ])
        let credentials = MemoryScrobbleCredentialStore()
        let suite = "BitChordTests.Scrobbling.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let manager = ScrobblingManager(
            defaults: defaults,
            credentials: credentials,
            transport: transport
        )
        manager.minimumSongDuration = 15
        manager.delayPercent = 0.1
        manager.maximumDelay = 30
        let connected = await manager.connectListenBrainz(token: "private-token")
        XCTAssertTrue(connected)
        XCTAssertEqual(manager.listenBrainzUsername, "musicbrainz-user")
        XCTAssertTrue(manager.listenBrainzConnected)

        let track = Track(
            videoID: "abcdefghijk",
            title: "Audible Song",
            artist: "Artist",
            album: "Album",
            artworkURL: nil,
            duration: 20,
            localPath: nil,
            sourceURL: nil
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        manager.playbackStarted(track: track, duration: 20, position: 0, now: start)
        for _ in 0..<20 where transport.requestCount < 2 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(transport.requestCount, 2, "Validation and now-playing are sent at start")
        manager.playbackSample(track: track, duration: 20, position: 1, now: start.addingTimeInterval(1))
        manager.playbackPaused(now: start.addingTimeInterval(1.2))
        manager.playbackStarted(track: track, duration: 20, position: 1, now: start.addingTimeInterval(100))
        manager.playbackSample(track: track, duration: 20, position: 1.9, now: start.addingTimeInterval(100.9))
        XCTAssertEqual(transport.requestCount, 2, "No single listen is sent before the audible threshold")
        manager.playbackSample(track: track, duration: 20, position: 2.2, now: start.addingTimeInterval(101.2))

        for _ in 0..<20 where transport.requestCount < 3 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(transport.requestCount, 3)
        manager.playbackSample(track: track, duration: 20, position: 10, now: start.addingTimeInterval(110))
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(transport.requestCount, 3, "A track is never submitted twice")

        let requests = transport.requests
        XCTAssertEqual(requests[0].url?.path, "/1/validate-token")
        XCTAssertEqual(requests[1].url?.path, "/1/submit-listens")
        XCTAssertEqual(requests[2].url?.path, "/1/submit-listens")
        let finalBody = try jsonObject(requests[2].httpBody)
        XCTAssertEqual(finalBody["listen_type"] as? String, "single")
        XCTAssertFalse(String(data: requests[2].httpBody ?? Data(), encoding: .utf8)?.contains("private-token") ?? true)
    }

    private func jsonObject(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    private func firstListen(_ root: [String: Any]) throws -> [String: Any] {
        let payload = try XCTUnwrap(root["payload"] as? [[String: Any]])
        return try XCTUnwrap(payload.first)
    }

    private func additionalInfo(_ listen: [String: Any]) throws -> [String: Any] {
        let metadata = try XCTUnwrap(listen["track_metadata"] as? [String: Any])
        return try XCTUnwrap(metadata["additional_info"] as? [String: Any])
    }
}

private final class MemoryScrobbleCredentialStore: ScrobbleCredentialStoring {
    private var values: [String: String] = [:]

    func string(for key: String) -> String? { values[key] }

    func set(_ value: String?, for key: String) throws {
        values[key] = value
    }
}

private final class ScrobbleMockTransport: ScrobbleHTTPTransport, @unchecked Sendable {
    struct Response {
        let status: Int
        let data: Data

        static func json(_ string: String, status: Int = 200) -> Response {
            Response(status: status, data: Data(string.utf8))
        }
    }

    private let lock = NSLock()
    private var queued: [Response]
    private var captured: [URLRequest] = []

    init(responses: [Response] = []) {
        queued = responses
    }

    var requests: [URLRequest] {
        lock.withLock { captured }
    }

    var requestCount: Int {
        lock.withLock { captured.count }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response: Response = lock.withLock {
            captured.append(request)
            return queued.isEmpty ? .json(#"{"status":"ok"}"#) : queued.removeFirst()
        }
        let http = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response.data, http)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
