import Foundation
import XCTest

final class LyricsParserTests: XCTestCase {
    func testEnhancedLRCParsesWordBoundariesEntitiesAndEnds() {
        let input = """
        [00:05.00]<00:05.00>I <00:05.20>can&#x27;t <00:05.80>wait<00:06.50>
        [00:10.00]<00:10.00>Next <00:10.40>line<00:11.00>
        """

        let lines = LyricsParsers.parseEnhancedLRC(input)

        XCTAssertEqual(try! XCTUnwrap(lines.first?.start), 0, accuracy: 0.001)
        let sung = try! XCTUnwrap(lines.first(where: { !$0.isGap }))
        XCTAssertEqual(sung.text, "I can't wait")
        XCTAssertEqual(sung.words.map(\.text), ["I", "can't", "wait"])
        XCTAssertEqual(sung.words[1].start, 5.2, accuracy: 0.001)
        XCTAssertEqual(sung.words[2].end, 6.5, accuracy: 0.001)
    }

    func testTTMLMergesSyllablesSkipsTranslationAndPreservesBackingVocal() {
        let input = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body><div>
            <p begin="5.0" end="8.0">
              <span begin="5.1" end="5.3">e</span><span begin="5.3" end="5.8">nough </span>
              <span begin="6.0" end="6.5">now</span>
              <span ttm:role="x-bg"><span begin="6.2" end="7.0">(ooh)</span></span>
              <span ttm:role="x-translation" begin="5.0" end="8.0">translation</span>
            </p>
          </div></body>
        </tt>
        """

        let lines = LyricsParsers.parseTTML(input)
        let sung = try! XCTUnwrap(lines.first(where: { !$0.isGap }))

        XCTAssertEqual(sung.text, "enough now")
        XCTAssertEqual(sung.words.map(\.text), ["enough", "now"])
        XCTAssertEqual(sung.words[0].start, 5.1, accuracy: 0.001)
        XCTAssertEqual(sung.words[0].end, 5.8, accuracy: 0.001)
        XCTAssertEqual(sung.background?.text, "(ooh)")
        XCTAssertEqual(try! XCTUnwrap(sung.background?.words.first?.start), 6.2, accuracy: 0.001)
    }

    func testPlainLRCMarksLongInstrumentalGapsButNotShortOnes() {
        let lines = LyricsParsers.parseLRC("""
        [00:02.00]First
        [00:03.00]
        [00:05.00]Second
        [00:12.00]
        [00:18.00]Third
        """)

        XCTAssertEqual(lines.filter(\.isGap).map { Int($0.start) }, [12])
        XCTAssertEqual(lines.filter { !$0.isGap }.map(\.text), ["First", "Second", "Third"])
    }

    func testWordRevealMovesThroughWordAndWhitespace() {
        let line = LyricLine(
            start: 1,
            text: "slow glow",
            words: [
                LyricWord(start: 1, end: 3, text: "slow"),
                LyricWord(start: 4, end: 5, text: "glow")
            ]
        )

        XCTAssertEqual(line.revealedCharacterCount(at: 2), 2, accuracy: 0.001)
        XCTAssertEqual(line.revealedCharacterCount(at: 3.5), 4.5, accuracy: 0.001)
        XCTAssertEqual(line.revealedCharacterCount(at: 4.5), 7, accuracy: 0.001)
    }
}

final class LyricsRepositoryTests: XCTestCase {
    private let track = Track(
        videoID: "video",
        title: "Song",
        artist: "Artist",
        album: "Album",
        artworkURL: nil,
        duration: 180,
        localPath: nil,
        sourceURL: nil
    )

    func testPriorityWaitsForHigherSourceEvenWhenLowerFinishesFirst() async {
        let high = FixtureLyricsProvider(
            source: .lrcLib,
            delay: 80_000_000,
            lines: [LyricLine(start: 1, text: "Higher priority")]
        )
        let lower = FixtureLyricsProvider(
            source: .simpMusic,
            delay: 0,
            lines: [wordLine("Lower word timing")]
        )
        let repository = LyricsRepository(providers: [.lrcLib: high, .simpMusic: lower])
        let preferences = LyricsPreferences(
            enabled: true,
            enabledSources: [.lrcLib, .simpMusic],
            sourceOrder: [.lrcLib, .simpMusic],
            prioritizeWordTiming: false
        )

        let result = await repository.lyrics(for: track, preferences: preferences)

        XCTAssertEqual(result?.source, "LRCLIB")
        XCTAssertEqual(result?.lines.first?.text, "Higher priority")
    }

    func testWordTimingCanOutrankLineSyncedFallback() async {
        let high = FixtureLyricsProvider(
            source: .lrcLib,
            delay: 0,
            lines: [LyricLine(start: 1, text: "Line fallback")]
        )
        let lower = FixtureLyricsProvider(
            source: .simpMusic,
            delay: 20_000_000,
            lines: [wordLine("Exact words")]
        )
        let repository = LyricsRepository(providers: [.lrcLib: high, .simpMusic: lower])
        let preferences = LyricsPreferences(
            enabled: true,
            enabledSources: [.lrcLib, .simpMusic],
            sourceOrder: [.lrcLib, .simpMusic],
            prioritizeWordTiming: true
        )

        let result = await repository.lyrics(for: track, preferences: preferences)

        XCTAssertEqual(result?.source, "SimpMusic")
        XCTAssertTrue(result?.isWordSynced == true)
    }

    func testDisabledSourceIsNeverContacted() async {
        let enabled = FixtureLyricsProvider(
            source: .lrcLib,
            delay: 0,
            lines: [LyricLine(start: 1, text: "Allowed")]
        )
        let disabled = FixtureLyricsProvider(
            source: .simpMusic,
            delay: 0,
            lines: [wordLine("Must not run")]
        )
        let repository = LyricsRepository(providers: [.lrcLib: enabled, .simpMusic: disabled])
        let preferences = LyricsPreferences(
            enabled: true,
            enabledSources: [.lrcLib],
            sourceOrder: [.simpMusic, .lrcLib],
            prioritizeWordTiming: true
        )

        _ = await repository.lyrics(for: track, preferences: preferences)

        let enabledCalls = await enabled.calls()
        let disabledCalls = await disabled.calls()
        XCTAssertEqual(enabledCalls, 1)
        XCTAssertEqual(disabledCalls, 0)
    }

    private func wordLine(_ text: String) -> LyricLine {
        LyricLine(
            start: 1,
            text: text,
            words: [LyricWord(start: 1, end: 2, text: text)]
        )
    }
}

@MainActor
final class LyricsSettingsTests: XCTestCase {
    func testSettingsPersistAndroidNamesAndRepairIncompleteOrder() throws {
        let suite = "BitChordLyricsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("LRCLIB,SIMP_MUSIC", forKey: "BitChord.lyricsSources")
        defaults.set("SIMP_MUSIC,LRCLIB", forKey: "BitChord.lyricsSourceOrder")

        let settings = LyricsSettings(defaults: defaults)

        XCTAssertEqual(settings.enabledSources, [.lrcLib, .simpMusic])
        XCTAssertEqual(Array(settings.sourceOrder.prefix(2)), [.simpMusic, .lrcLib])
        XCTAssertEqual(settings.sourceOrder.count, LyricsSource.allCases.count)
    }
}

private actor FixtureLyricsProvider: LyricsFetching {
    nonisolated let source: LyricsSource
    private let delay: UInt64
    private let lines: [LyricLine]?
    private var callCount = 0

    init(source: LyricsSource, delay: UInt64, lines: [LyricLine]?) {
        self.source = source
        self.delay = delay
        self.lines = lines
    }

    func fetch(_ query: LyricsQuery) async -> [LyricLine]? {
        callCount += 1
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return Task.isCancelled ? nil : lines
    }

    func calls() -> Int { callCount }
}
