import Foundation
import XCTest

final class MusicLinkTests: XCTestCase {
    func testWatchLinkPrefersTappedTrackOverPlaylistContext() {
        XCTAssertEqual(
            MusicLinkParser.parse("https://music.youtube.com/watch?v=abcdefghijk&list=PL-context"),
            .track(videoID: "abcdefghijk")
        )
    }

    func testShortAndEmbeddedLinksResolveTracks() {
        XCTAssertEqual(
            MusicLinkParser.parse("https://youtu.be/abcdefghijk?t=31"),
            .track(videoID: "abcdefghijk")
        )
        XCTAssertEqual(
            MusicLinkParser.parse("https://www.youtube.com/embed/lmnopqrstuv"),
            .track(videoID: "lmnopqrstuv")
        )
    }

    func testPlaylistShareIDGetsBrowsePrefixExactlyOnce() {
        XCTAssertEqual(
            MusicLinkParser.parse("https://music.youtube.com/playlist?list=PL123"),
            .page(browseID: "VLPL123")
        )
        XCTAssertEqual(
            MusicLinkParser.parse("https://music.youtube.com/playlist?list=VLOLAK5uy_album"),
            .page(browseID: "VLOLAK5uy_album")
        )
    }

    func testBrowseChannelAndSearchLinksStayInsideLilt() {
        XCTAssertEqual(
            MusicLinkParser.parse("https://music.youtube.com/browse/MPREb_album"),
            .page(browseID: "MPREb_album")
        )
        XCTAssertEqual(
            MusicLinkParser.parse("https://www.youtube.com/channel/UC_artist"),
            .page(browseID: "UC_artist")
        )
        XCTAssertEqual(
            MusicLinkParser.parse("https://music.youtube.com/search?q=Massive%20Attack"),
            .search(query: "Massive Attack")
        )
    }

    func testSharedSentenceExtractsFirstSupportedURL() {
        XCTAssertEqual(
            MusicLinkParser.parse("Listen to this:\nhttps://music.youtube.com/watch?v=abcdefghijk). Enjoy!"),
            .track(videoID: "abcdefghijk")
        )
    }

    func testLiltSchemeSupportsNativeTrackPageAndSearchRoutes() {
        XCTAssertEqual(
            MusicLinkParser.parse("lilt://track/abcdefghijk"),
            .track(videoID: "abcdefghijk")
        )
        XCTAssertEqual(
            MusicLinkParser.parse("lilt://browse/VLLM"),
            .page(browseID: "VLLM")
        )
        XCTAssertEqual(
            MusicLinkParser.parse("lilt://search?q=Portishead"),
            .search(query: "Portishead")
        )
    }

    func testLiltOpenRouteCanWrapAWebLink() {
        XCTAssertEqual(
            MusicLinkParser.parse("lilt://open?url=https%3A%2F%2Fmusic.youtube.com%2Fwatch%3Fv%3Dabcdefghijk"),
            .track(videoID: "abcdefghijk")
        )
    }

    func testLegacyBitChordSchemeStillWorksAfterRename() {
        XCTAssertEqual(
            MusicLinkParser.parse("bitchord://track/abcdefghijk"),
            .track(videoID: "abcdefghijk")
        )
    }

    func testUnsupportedAndEmptyLinksAreRejected() {
        XCTAssertNil(MusicLinkParser.parse(""))
        XCTAssertNil(MusicLinkParser.parse("https://example.com/watch?v=abcdefghijk"))
        XCTAssertNil(MusicLinkParser.parse("lilt://track/"))
        XCTAssertNil(MusicLinkParser.parse("not a link"))
    }
}
