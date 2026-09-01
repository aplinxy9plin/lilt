import Foundation
import XCTest

@MainActor
final class ListeningStatsTests: XCTestCase {
    func testRecorderCountsAudibleWallTimeOnceAndCapsLongGaps() {
        var clock = Date(timeIntervalSince1970: 0)
        var events: [(seconds: TimeInterval, play: Bool)] = []
        var flushes = 0
        let recorder = ListeningRecorder(
            now: { clock },
            onRecord: { _, seconds, play, _ in events.append((seconds, play)) },
            onFlush: { flushes += 1 }
        )
        let track = makeTrack(id: "abcdefghijk", title: "A", artist: "Artist", duration: 100)

        recorder.onSample(track: track, duration: 100) // anchor only
        for _ in 0..<10 {
            clock.addTimeInterval(5)
            recorder.onSample(track: track, duration: 100)
        }

        XCTAssertEqual(events.reduce(0) { $0 + $1.seconds }, 50, accuracy: 0.001)
        XCTAssertEqual(events.filter(\.play).count, 1, "A play is counted once at half the track")

        clock.addTimeInterval(3_600)
        recorder.onSample(track: track, duration: 100)
        XCTAssertEqual(
            events.reduce(0) { $0 + $1.seconds },
            58,
            accuracy: 0.001,
            "A suspended/blocked sampler can contribute at most eight seconds"
        )

        recorder.onStopped()
        XCTAssertEqual(flushes, 1)
    }

    func testPauseAnchorsTheClockInsteadOfCreditingPausedTime() {
        var clock = Date(timeIntervalSince1970: 100)
        var recorded: TimeInterval = 0
        let recorder = ListeningRecorder(
            now: { clock },
            onRecord: { _, seconds, _, _ in recorded += seconds }
        )
        let track = makeTrack(id: "abcdefghijk", title: "A", artist: "Artist", duration: 180)

        recorder.onSample(track: track, duration: 180)
        clock.addTimeInterval(6)
        recorder.onSample(track: track, duration: 180)
        recorder.onStopped()
        clock.addTimeInterval(7_200)
        recorder.onSample(track: track, duration: 180)
        clock.addTimeInterval(4)
        recorder.onSample(track: track, duration: 180)
        recorder.onStopped()

        XCTAssertEqual(recorded, 10, accuracy: 0.001)
    }

    func testMonthlyStoreBuildsRankedReplayAndSurvivesReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChord-listening-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let store = ListeningStatsStore(directory: directory, calendar: calendar)
        let january = try date("2026-01-10T08:00:00Z")
        let february = try date("2026-02-12T21:00:00Z")
        let alpha = makeTrack(
            id: "alphaalpha1",
            title: "Alpha Song",
            artist: "Alpha feat. Guest",
            album: "First Album",
            duration: 200
        )
        let beta = makeTrack(
            id: "betabetabet",
            title: "Beta Song",
            artist: "Beta",
            album: "Second Album",
            duration: 300
        )

        await store.record(track: alpha, playedSeconds: 120, countsAsPlay: true, at: january)
        await store.record(track: alpha, playedSeconds: 60, countsAsPlay: false, at: february)
        await store.record(track: beta, playedSeconds: 300, countsAsPlay: true, at: february)
        await store.record(track: beta, playedSeconds: 10, countsAsPlay: true, at: february)

        let month = await store.summary(for: .thisMonth, now: february)
        XCTAssertEqual(month.totalMilliseconds, 370_000)
        XCTAssertEqual(month.totalPlays, 2)
        XCTAssertEqual(month.tracks.map(\.track.title), ["Beta Song", "Alpha Song"])
        XCTAssertEqual(month.busiestHour, 21)

        let year = await store.summary(for: .thisYear, now: february)
        XCTAssertEqual(year.totalMilliseconds, 490_000)
        XCTAssertEqual(year.totalPlays, 3)
        XCTAssertEqual(year.artists.first?.title, "Beta")
        XCTAssertEqual(year.artists.last?.title, "Alpha", "Featured credits are grouped under the lead artist")
        XCTAssertEqual(year.albums.count, 2)
        XCTAssertEqual(year.distinctSongs, 2)

        await store.flush()
        let reloaded = ListeningStatsStore(directory: directory, calendar: calendar)
        let restored = await reloaded.summary(for: .allTime, now: february)
        XCTAssertEqual(restored.totalMilliseconds, year.totalMilliseconds)
        XCTAssertEqual(restored.totalPlays, year.totalPlays)
        XCTAssertEqual(restored.tracks, year.tracks)
        XCTAssertEqual(restored.artists, year.artists)
        XCTAssertEqual(restored.albums, year.albums)
        XCTAssertEqual(restored.busiestHour, year.busiestHour)
        XCTAssertEqual(restored.busiestDay, year.busiestDay)
    }

    func testThisYearExcludesPreviousCalendarYear() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChord-listening-period-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let store = ListeningStatsStore(directory: directory, calendar: calendar)
        let track = makeTrack(id: "abcdefghijk", title: "A", artist: "Artist", duration: 180)

        await store.record(
            track: track,
            playedSeconds: 60,
            countsAsPlay: true,
            at: try date("2025-12-31T23:00:00Z")
        )
        let now = try date("2026-01-01T01:00:00Z")
        await store.record(track: track, playedSeconds: 30, countsAsPlay: false, at: now)

        let year = await store.summary(for: .thisYear, now: now)
        let all = await store.summary(for: .allTime, now: now)
        XCTAssertEqual(year.totalMilliseconds, 30_000)
        XCTAssertEqual(year.totalPlays, 0)
        XCTAssertEqual(all.totalMilliseconds, 90_000)
        XCTAssertEqual(all.totalPlays, 1)
    }

    private func makeTrack(
        id: String,
        title: String,
        artist: String,
        album: String? = nil,
        duration: TimeInterval
    ) -> Track {
        Track(
            videoID: id,
            title: title,
            artist: artist,
            album: album,
            artworkURL: "https://example.com/\(id).jpg",
            duration: duration,
            localPath: nil,
            sourceURL: nil
        )
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}
