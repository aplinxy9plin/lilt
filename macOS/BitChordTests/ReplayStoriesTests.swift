import AppKit
import Foundation
import XCTest

@MainActor
final class ReplayStoriesTests: XCTestCase {
    func testStoryPagesSkipEmptyRankingsWithoutLeavingBlankCards() {
        let summary = makeSummary(includeAlbum: false)

        XCTAssertEqual(
            summary.storyPages,
            [.intro, .minutes, .artists, .songs, .habits, .summary]
        )
    }

    func testHeadlinesUseTheSameFactAsThePoster() {
        let summary = makeSummary()
        let headline = summary.storyHeadline(for: .minutes)
            .map(\.text)
            .joined()
            .replacingOccurrences(of: "\n", with: " ")
        let payload = ReplayPosterPayload(summary: summary)

        XCTAssertEqual(headline, "You listened to 125 minutes of music.")
        XCTAssertEqual(payload.minutes, "125")
        XCTAssertEqual(payload.topSong, "Neon Skyline")
        XCTAssertEqual(payload.topArtist, "Night Drive")
        XCTAssertEqual(payload.topAlbum, "After Hours")
        XCTAssertEqual(payload.favoriteHour, "9 pm")
        XCTAssertFalse(try XCTUnwrap(payload.biggestDay).isEmpty, "The day label follows the Mac's locale")
    }

    func testStoryArtworkPinsTheRankingTheCardDescribes() {
        let summary = makeSummary()

        XCTAssertEqual(summary.storyArtworkURL(for: .songs), "https://example.com/song.jpg")
        XCTAssertEqual(summary.storyArtworkURL(for: .artists), "https://example.com/artist.jpg")
        XCTAssertEqual(summary.storyArtworkURL(for: .albums), "https://example.com/album.jpg")
    }

    func testPosterRendererCreatesARealStorySizedPNG() async throws {
        let url = try await ReplayPosterRenderer.render(summary: makeSummary(usesRemoteArtwork: false), page: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, 1080)
        XCTAssertEqual(bitmap.pixelsHigh, 1920)
        XCTAssertGreaterThan(data.count, 25_000)
    }

    private func makeSummary(
        includeAlbum: Bool = true,
        usesRemoteArtwork: Bool = true
    ) -> ReplaySummary {
        let artwork = usesRemoteArtwork ? "https://example.com/song.jpg" : nil
        let track = Track(
            videoID: "abcdefghijk",
            title: "Neon Skyline",
            artist: "Night Drive",
            album: includeAlbum ? "After Hours" : nil,
            artworkURL: artwork,
            duration: 240,
            localPath: nil,
            sourceURL: nil
        )
        let artist = ReplayNamedStat(
            id: "night-drive",
            title: "Night Drive",
            subtitle: nil,
            artworkURL: usesRemoteArtwork ? "https://example.com/artist.jpg" : nil,
            milliseconds: 7_200_000,
            plays: 31
        )
        let albums = includeAlbum ? [
            ReplayNamedStat(
                id: "after-hours",
                title: "After Hours",
                subtitle: "Night Drive",
                artworkURL: usesRemoteArtwork ? "https://example.com/album.jpg" : nil,
                milliseconds: 5_000_000,
                plays: 22
            )
        ] : []
        return ReplaySummary(
            period: .thisYear,
            totalMilliseconds: 7_500_000,
            totalPlays: 34,
            tracks: [ReplayTrackStat(track: track, milliseconds: 7_500_000, plays: 34)],
            artists: [artist],
            albums: albums,
            genres: [],
            busiestHour: 21,
            busiestHourMilliseconds: 2_000_000,
            busiestDay: "2026-08-14",
            busiestDayMilliseconds: 3_600_000,
            memberSince: Date(timeIntervalSince1970: 1_704_067_200)
        )
    }
}
