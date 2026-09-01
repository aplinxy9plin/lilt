import AVFoundation
import XCTest

@MainActor
final class PlaybackControllerTests: XCTestCase {
    func testYouTubeDurationOverridesAVFoundationDoubleTimeline() throws {
        let url = try XCTUnwrap(URL(
            string: "https://rr.example.googlevideo.com/videoplayback?clen=3646710&dur=225.279"
        ))
        let stream = ResolvedStream(url: url, headers: [:])
        let duration = try XCTUnwrap(stream.duration)

        XCTAssertEqual(duration, 225.279, accuracy: 0.001)
        XCTAssertEqual(
            PlaybackController.effectiveDuration(
                authoritative: duration,
                playerReported: 450.5121088435374
            ),
            225.279,
            accuracy: 0.001
        )
        XCTAssertTrue(PlaybackController.reachedAuthoritativeEnd(
            progress: 225.3,
            authoritativeDuration: duration,
            isPlaying: true
        ))
        XCTAssertFalse(PlaybackController.reachedAuthoritativeEnd(
            progress: 450.6,
            authoritativeDuration: nil,
            isPlaying: true
        ))
    }

    func testLateFirstResolveCannotReplaceSecondTrackLoadingState() async throws {
        let resolver = ControlledStreamResolver()
        let player = PlaybackController(api: resolver)
        let first = remoteTrack(id: "first", title: "First")
        let second = remoteTrack(id: "second", title: "Second")

        player.play(first)
        await resolver.waitUntilRequested(first)

        player.play(second)
        await resolver.waitUntilRequested(second)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(player.currentTrack, second)
        XCTAssertTrue(player.isLoading(second))
        XCTAssertFalse(player.isLoading(first))
        XCTAssertFalse(player.isPlaying)

        try await Task.sleep(nanoseconds: 120_000_000)
    }

    func testCanonicalizedTrackKeepsTheClickedPlaylistRowCurrentWhileLoading() async {
        var video = remoteTrack(id: "playlist-video", title: "Song (Official Video)")
        video.isVideo = true
        let catalogue = remoteTrack(id: "catalogue-audio", title: "Song")
        let resolver = DelayedCanonicalizingResolver(replacement: catalogue)
        let player = PlaybackController(api: resolver)

        player.play(video, queue: [video])
        await resolver.waitUntilStreamRequested()

        XCTAssertEqual(player.currentTrack?.videoID, catalogue.videoID)
        XCTAssertTrue(player.isLoading)
        XCTAssertTrue(player.isCurrent(video), "The row the user clicked must remain selected after catalogue replacement")
        XCTAssertTrue(player.isLoading(video), "The clicked row must keep its spinner until the replacement stream starts")
        XCTAssertFalse(player.isCurrent(remoteTrack(id: "other", title: "Other")))
    }

    func testStreamResolutionRaceReturnsBeforeASlowerMediaGate() async throws {
        let slow = ResolvedStream(
            url: try XCTUnwrap(URL(string: "https://example.com/slow.m4a")),
            headers: [:]
        )
        let fast = ResolvedStream(
            url: try XCTUnwrap(URL(string: "https://example.com/fast.m4a")),
            headers: [:]
        )
        let started = ContinuousClock.now
        let gatedCandidate: @Sendable () async -> ResolvedStream? = {
            do {
                try await Task.sleep(for: .milliseconds(600))
                return slow
            } catch {
                return nil
            }
        }
        let directCandidate: @Sendable () async -> ResolvedStream? = {
            try? await Task.sleep(for: .milliseconds(20))
            return fast
        }

        let resolved = await YouTubeMusicAPI.firstSuccessful([
            gatedCandidate,
            directCandidate
        ])

        XCTAssertEqual(resolved?.url, fast.url)
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(250))
    }

    func testMusicVideoBecomesCatalogueTrackBeforeItsStreamStarts() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChord-catalogue-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try writeSilentAudio(to: audioURL, duration: 3)
        var video = remoteTrack(id: "video-upload", title: "Song (Official Video)")
        video.isVideo = true
        video.setVideoID = "playlist-video-token"
        var catalogue = remoteTrack(id: "catalogue-audio", title: "Song")
        catalogue.isVideo = false
        catalogue.albumBrowseID = "MPREcatalogue"
        let resolver = CanonicalizingFileResolver(url: audioURL, replacements: ["video-upload": catalogue])
        let player = PlaybackController(api: resolver)

        player.play(video, queue: [video])
        XCTAssertTrue(player.isLoading)
        XCTAssertEqual(player.currentTrack?.videoID, "video-upload")
        await waitUntil { player.currentTrack?.videoID == "catalogue-audio" && player.isPlaying }

        XCTAssertEqual(resolver.streamRequests, ["catalogue-audio"])
        XCTAssertEqual(player.queue.first?.videoID, "catalogue-audio")
        XCTAssertEqual(player.currentTrack?.albumBrowseID, "MPREcatalogue")
        XCTAssertNil(player.currentTrack?.setVideoID, "The old playlist token does not belong to the replacement video ID")
        player.togglePlayback()
    }

    func testNextMusicVideoIsCanonicalizedBeforeGaplessPreload() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChord-catalogue-preload-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try writeSilentAudio(to: audioURL, duration: 4)
        let first = remoteTrack(id: "first-audio", title: "First")
        var video = remoteTrack(id: "next-video", title: "Next (Official Video)")
        video.isVideo = true
        let catalogue = remoteTrack(id: "next-audio", title: "Next")
        let resolver = CanonicalizingFileResolver(url: audioURL, replacements: ["next-video": catalogue])
        let player = PlaybackController(api: resolver)

        player.play(first, queue: [first, video])
        await waitUntil { player.isPlaying }
        await waitUntil { player.queue.last?.videoID == "next-audio" }

        XCTAssertTrue(resolver.streamRequests.contains("first-audio"))
        XCTAssertTrue(resolver.streamRequests.contains("next-audio"))
        XCTAssertFalse(resolver.streamRequests.contains("next-video"))
        player.togglePlayback()
    }

    func testPlayNextAddRemoveAndMoveKeepQueueConsistent() async throws {
        let resolver = ControlledStreamResolver()
        let player = PlaybackController(api: resolver)
        let first = remoteTrack(id: "one", title: "One")
        let second = remoteTrack(id: "two", title: "Two")
        let third = remoteTrack(id: "three", title: "Three")
        let inserted = remoteTrack(id: "next", title: "Play Next")
        let appended = remoteTrack(id: "last", title: "Added Last")

        player.play(first, queue: [first, second, third])
        player.playNext(inserted)
        player.addToQueue(appended)

        XCTAssertEqual(player.queue, [first, inserted, second, third, appended])
        XCTAssertEqual(player.queueIndex, 0)

        player.moveQueueItem(from: 4, to: 2)
        XCTAssertEqual(player.queue, [first, inserted, appended, second, third])
        XCTAssertEqual(player.queueIndex, 0)

        player.removeFromQueue(at: 1)
        XCTAssertEqual(player.queue, [first, appended, second, third])
        player.removeFromQueue(at: 0)
        XCTAssertEqual(player.queue, [first, appended, second, third], "The playing item cannot be removed")

        player.next()
        XCTAssertEqual(player.currentTrack, appended)
        XCTAssertEqual(player.queueIndex, 1)
        try await Task.sleep(nanoseconds: 30_000_000)
    }

    func testLastPlayedStoreKeepsBoundedWindowAndTrackProvenance() throws {
        let suiteName = "BitChordTests.LastPlayed.Window.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PlaybackQueueStore(defaults: defaults)
        var tracks = (0..<100).map { remoteTrack(id: "queue-\($0)", title: "Track \($0)") }
        tracks[40].localPath = "/Music/BitChord/queue-40.m4a"
        tracks[40].artistBrowseID = "UCqueue40"
        tracks[40].albumBrowseID = "MPREqueue40"
        tracks[45].fromAutoplay = true

        store.save(tracks: tracks, index: 40, position: 73.25)
        let snapshot = try XCTUnwrap(store.load())

        XCTAssertEqual(snapshot.tracks.count, PlaybackQueueStore.maximumTracks)
        XCTAssertEqual(snapshot.tracks.first?.videoID, "queue-30")
        XCTAssertEqual(snapshot.tracks.last?.videoID, "queue-89")
        XCTAssertEqual(snapshot.index, PlaybackQueueStore.keepBehind)
        XCTAssertEqual(snapshot.tracks[snapshot.index].videoID, "queue-40")
        XCTAssertEqual(snapshot.tracks[snapshot.index].localPath, "/Music/BitChord/queue-40.m4a")
        XCTAssertEqual(snapshot.tracks[snapshot.index].artistBrowseID, "UCqueue40")
        XCTAssertEqual(snapshot.tracks[snapshot.index].albumBrowseID, "MPREqueue40")
        XCTAssertTrue(snapshot.tracks[15].isFromAutoplay)
        XCTAssertEqual(snapshot.position, 73.25, accuracy: 0.001)
    }

    func testLastPlayedStoreIgnoresEmptySaveAndRejectsCorruptPayload() throws {
        let suiteName = "BitChordTests.LastPlayed.Corrupt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PlaybackQueueStore(defaults: defaults)
        let track = remoteTrack(id: "kept", title: "Kept")

        store.save(tracks: [track], index: 0, position: .nan)
        store.save(tracks: [], index: 0, position: 99)
        XCTAssertEqual(store.load(), PlaybackQueueStore.Snapshot(tracks: [track], index: 0, position: 0))

        defaults.set(Data("not a queue".utf8), forKey: PlaybackQueueStore.storageKey)
        XCTAssertNil(store.load())
    }

    func testColdStartRestoresPausedQueueAndResumesFromSavedPositionLazily() async throws {
        let suiteName = "BitChordTests.LastPlayed.Resume.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PlaybackQueueStore(defaults: defaults)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChord-resume-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try writeSilentAudio(to: audioURL, duration: 10)

        let first = remoteTrack(id: "before-resume", title: "Before")
        var current = remoteTrack(id: "resume-current", title: "Resume Current")
        current.duration = 10
        var suggestion = remoteTrack(id: "resume-auto", title: "AutoPlay")
        suggestion.fromAutoplay = true
        store.save(tracks: [first, current, suggestion], index: 1, position: 0.75)
        let resolver = ImmediateFileResolver(url: audioURL)

        let player = PlaybackController(api: resolver, queueStore: store)

        XCTAssertEqual(player.currentTrack, current)
        XCTAssertEqual(player.queue, [first, current, suggestion])
        XCTAssertEqual(player.queueIndex, 1)
        XCTAssertEqual(player.progress, 0.75, accuracy: 0.001)
        XCTAssertEqual(player.duration, 10, accuracy: 0.001)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
        XCTAssertTrue(resolver.requests.isEmpty, "Cold restore must not resolve or prepare a stream")

        player.togglePlayback()
        await waitUntil(attempts: 2_000) {
            resolver.requests.first == current.id && player.currentTrack == current && player.isPlaying
        }

        XCTAssertEqual(player.currentTrack, current)
        XCTAssertEqual(player.queueIndex, 1)
        XCTAssertGreaterThanOrEqual(player.progress, 0.65)
        XCTAssertLessThan(player.progress, 1.8)
        player.togglePlayback()
    }

    func testPlaybackStateFlushPersistsMeasuredDurationForColdStartUI() async throws {
        let suiteName = "BitChordTests.LastPlayed.Duration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PlaybackQueueStore(defaults: defaults)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChord-duration-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try writeSilentAudio(to: audioURL, duration: 10)

        var track = remoteTrack(id: "measured-duration", title: "Measured Duration")
        track.duration = nil
        let resolver = ImmediateFileResolver(url: audioURL, duration: 10)
        let player = PlaybackController(api: resolver, queueStore: store)

        player.play(track)
        await waitUntil { player.isPlaying && player.duration == 10 }
        player.seek(to: 2)
        player.savePlaybackState()
        player.togglePlayback()

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.tracks.first?.duration, 10)
        XCTAssertEqual(snapshot.position, 2, accuracy: 0.001)
    }

    func testSpatialAudioAttachesAndDetachesFromPlayingStereoTrack() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChord-spatial-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try writeSilentAudio(to: audioURL, duration: 3, channels: 2)

        var track = remoteTrack(id: "spatial-current", title: "Spatial Current")
        track.duration = 3
        let player = PlaybackController(api: ImmediateFileResolver(url: audioURL, duration: 3))
        player.play(track)
        await waitUntil { player.isPlaying }

        player.setSpatialAudio(enabled: true)
        await waitUntil { player.spatialAudioActive }
        XCTAssertTrue(player.spatialAudioActive)

        player.setSpatialAudio(enabled: false)
        await waitUntil { !player.spatialAudioActive }
        XCTAssertFalse(player.spatialAudioActive)
        player.togglePlayback()
    }

    func testCollectionQueueActionsKeepTrackOrderAheadOfAutoplay() async throws {
        let player = PlaybackController(api: ControlledStreamResolver())
        let current = remoteTrack(id: "collection-current", title: "Current")
        let existing = remoteTrack(id: "collection-existing", title: "Existing")
        var autoplay = remoteTrack(id: "collection-auto", title: "AutoPlay")
        autoplay.fromAutoplay = true
        let next = [
            remoteTrack(id: "collection-next-one", title: "Next One"),
            remoteTrack(id: "collection-next-two", title: "Next Two")
        ]
        let appended = [
            remoteTrack(id: "collection-last-one", title: "Last One"),
            remoteTrack(id: "collection-last-two", title: "Last Two")
        ]

        player.play(current, queue: [current, existing, autoplay])
        player.playNext(next)
        player.addToQueue(appended)

        XCTAssertEqual(
            player.queue.map(\.videoID),
            [
                "collection-current", "collection-next-one", "collection-next-two",
                "collection-existing", "collection-last-one", "collection-last-two", "collection-auto"
            ]
        )
        XCTAssertTrue(player.queue.last?.isFromAutoplay == true)
        XCTAssertTrue(player.queue.dropFirst().dropLast().allSatisfy { !$0.isFromAutoplay })
        try await Task.sleep(nanoseconds: 30_000_000)
    }

    func testRepeatModeCyclesAndRepeatAllWrapsFiniteQueue() async throws {
        let player = PlaybackController(api: ControlledStreamResolver())
        let first = remoteTrack(id: "repeat-one", title: "First")
        let second = remoteTrack(id: "repeat-two", title: "Second")
        let queue = [first, second]

        player.play(first, queue: queue)
        XCTAssertEqual(player.repeatMode, .off)

        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .all)
        player.playFromQueue(at: 1)
        player.next()

        XCTAssertEqual(player.currentTrack, first)
        XCTAssertEqual(player.queueIndex, 0)
        XCTAssertEqual(player.queue, queue)

        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .one)
        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .off)
        try await Task.sleep(nanoseconds: 30_000_000)
    }

    func testRepeatOneRestartsCurrentTrackWithoutAdvancingQueue() async throws {
        let player = PlaybackController(api: ControlledStreamResolver())
        let first = remoteTrack(id: "repeat-current", title: "Current")
        let second = remoteTrack(id: "repeat-next", title: "Next")
        let queue = [first, second]

        player.play(first, queue: queue)
        player.setRepeatMode(.one)
        player.handleTrackEnded()

        XCTAssertEqual(player.currentTrack, first)
        XCTAssertEqual(player.queueIndex, 0)
        XCTAssertEqual(player.queue, queue)
        XCTAssertTrue(player.isLoading(first))
        try await Task.sleep(nanoseconds: 30_000_000)
    }

    func testShufflePreservesPlayedPrefixAndSeparatesManualFromAutoplay() async throws {
        let player = PlaybackController(api: ControlledStreamResolver())
        let played = remoteTrack(id: "played", title: "Played")
        let current = remoteTrack(id: "current", title: "Current")
        let manualOne = remoteTrack(id: "manual-one", title: "Manual One")
        let manualTwo = remoteTrack(id: "manual-two", title: "Manual Two")
        var autoplayOne = remoteTrack(id: "autoplay-one", title: "AutoPlay One")
        var autoplayTwo = remoteTrack(id: "autoplay-two", title: "AutoPlay Two")
        autoplayOne.fromAutoplay = true
        autoplayTwo.fromAutoplay = true
        let original = [played, current, manualOne, manualTwo, autoplayOne, autoplayTwo]

        player.play(current, queue: original, at: 1, preservingQueueOrder: true)
        player.setShuffle(true)

        XCTAssertTrue(player.shuffleEnabled)
        XCTAssertEqual(Array(player.queue.prefix(2)), [played, current])
        XCTAssertEqual(Set(player.queue[2..<4].map(\.id)), Set([manualOne.id, manualTwo.id]))
        XCTAssertEqual(Set(player.queue[4..<6].map(\.id)), Set([autoplayOne.id, autoplayTwo.id]))
        XCTAssertEqual(player.autoplaySectionStart, 4)

        let newlyQueued = remoteTrack(id: "new-manual", title: "New Manual")
        player.addToQueue(newlyQueued)
        player.setShuffle(false)

        XCTAssertFalse(player.shuffleEnabled)
        XCTAssertEqual(
            player.queue,
            [played, current, manualOne, manualTwo, newlyQueued, autoplayOne, autoplayTwo],
            "Played tracks stay fixed, original order is restored, and new manual entries trail before AutoPlay"
        )
        try await Task.sleep(nanoseconds: 30_000_000)
    }

    func testPlayShuffledStartsSelectedTrackAndKeepsModeEnabled() async throws {
        let player = PlaybackController(api: ControlledStreamResolver())
        let tracks = [
            remoteTrack(id: "shuffle-one", title: "One"),
            remoteTrack(id: "shuffle-two", title: "Two"),
            remoteTrack(id: "shuffle-three", title: "Three")
        ]

        player.playShuffled(tracks)

        XCTAssertTrue(player.shuffleEnabled)
        XCTAssertEqual(player.queueIndex, 0)
        XCTAssertEqual(player.currentTrack, player.queue.first)
        XCTAssertEqual(Set(player.queue.map(\.id)), Set(tracks.map(\.id)))

        player.setShuffle(false)
        XCTAssertEqual(player.queue.first, player.currentTrack)
        XCTAssertEqual(Set(player.queue.map(\.id)), Set(tracks.map(\.id)))
        try await Task.sleep(nanoseconds: 30_000_000)
    }

    func testClearUpcomingQueuePreservesPlayedAndCurrentTracks() async throws {
        let player = PlaybackController(api: ControlledStreamResolver())
        let first = remoteTrack(id: "clear-first", title: "First")
        let current = remoteTrack(id: "clear-current", title: "Current")
        let upcoming = remoteTrack(id: "clear-upcoming", title: "Upcoming")

        player.play(current, queue: [first, current, upcoming], at: 1, preservingQueueOrder: true)
        XCTAssertTrue(player.hasUpcomingTracks)
        player.clearUpcomingQueue()

        XCTAssertEqual(player.queue, [first, current])
        XCTAssertEqual(player.currentTrack, current)
        XCTAssertEqual(player.queueIndex, 1)
        XCTAssertFalse(player.hasUpcomingTracks)
        try await Task.sleep(nanoseconds: 30_000_000)
    }

    func testAutoplayDeduplicatesRadioAndKeepsManualQueueAheadOfSuggestions() async throws {
        let resolver = ControlledStreamResolver()
        let autoplay = RecordingAutoplayProvider()
        var seed = remoteTrack(id: "seed", title: "Seed")
        seed.localPath = "/tmp/downloaded-seed.m4a"
        let remoteSeed = remoteTrack(id: "seed", title: "Seed")
        let manual = remoteTrack(id: "manual", title: "Manual")
        let firstSuggestion = remoteTrack(id: "suggestion-1", title: "Suggestion One")
        let secondSuggestion = remoteTrack(id: "suggestion-2", title: "Suggestion Two")
        autoplay.responses["seed"] = [remoteSeed, manual, firstSuggestion, firstSuggestion, secondSuggestion]
        let player = PlaybackController(api: resolver, autoplayAPI: autoplay)

        player.play(seed, queue: [seed, manual])
        await waitUntil { !player.autoplayLoading && player.queue.count == 4 }

        XCTAssertEqual(player.queue.map(\.videoID), ["seed", "manual", "suggestion-1", "suggestion-2"])
        XCTAssertEqual(player.autoplaySectionStart, 2)
        XCTAssertFalse(player.queue[1].isFromAutoplay)
        XCTAssertTrue(player.queue[2].isFromAutoplay)

        let added = remoteTrack(id: "added", title: "Added")
        player.addToQueue(added)
        XCTAssertEqual(player.queue.map(\.videoID), ["seed", "manual", "added", "suggestion-1", "suggestion-2"])
        XCTAssertEqual(player.autoplaySectionStart, 3)
    }

    func testDisablingAutoplayDropsOnlyUnplayedSuggestions() async throws {
        let resolver = ControlledStreamResolver()
        let autoplay = RecordingAutoplayProvider()
        let seed = remoteTrack(id: "seed", title: "Seed")
        autoplay.responses["seed"] = [
            remoteTrack(id: "suggestion-1", title: "Suggestion One"),
            remoteTrack(id: "suggestion-2", title: "Suggestion Two")
        ]
        let player = PlaybackController(api: resolver, autoplayAPI: autoplay)

        player.play(seed)
        await waitUntil { !player.autoplayLoading && player.queue.count == 3 }
        player.playFromQueue(at: 1)
        player.setAutoplay(enabled: false, avoidRepeatedSuggestions: false)

        XCTAssertEqual(player.currentTrack?.videoID, "suggestion-1")
        XCTAssertEqual(player.queue.map(\.videoID), ["seed", "suggestion-1"])
        XCTAssertTrue(player.queue[1].isFromAutoplay, "The already-playing recommendation stays in playback history")
    }

    func testRepeatAllStashesAndRestoresUpcomingAutoplayTracks() async throws {
        let autoplay = RecordingAutoplayProvider()
        let seed = remoteTrack(id: "repeat-seed", title: "Seed")
        let manual = remoteTrack(id: "repeat-manual", title: "Manual")
        autoplay.responses["repeat-seed"] = [
            remoteTrack(id: "repeat-auto-one", title: "AutoPlay One"),
            remoteTrack(id: "repeat-auto-two", title: "AutoPlay Two")
        ]
        let player = PlaybackController(
            api: ControlledStreamResolver(),
            autoplayAPI: autoplay
        )

        player.play(seed, queue: [seed, manual])
        await waitUntil { !player.autoplayLoading && player.queue.count == 4 }

        player.setRepeatMode(.all)
        XCTAssertEqual(player.queue.map(\.videoID), ["repeat-seed", "repeat-manual"])
        XCTAssertFalse(player.queue.contains(where: \.isFromAutoplay))

        player.setRepeatMode(.one)
        XCTAssertEqual(
            player.queue.map(\.videoID),
            ["repeat-seed", "repeat-manual", "repeat-auto-one", "repeat-auto-two"]
        )
        XCTAssertEqual(player.autoplaySectionStart, 2)
        await waitUntil { !player.autoplayLoading }
    }

    func testLateAutoplayResponseCannotContaminateReplacementQueue() async throws {
        let resolver = ControlledStreamResolver()
        let autoplay = RecordingAutoplayProvider()
        autoplay.ignoreCancellationFor = "first-seed"
        autoplay.delayNanoseconds = 80_000_000
        autoplay.responses["first-seed"] = [remoteTrack(id: "stale", title: "Stale")]
        autoplay.responses["second-seed"] = [remoteTrack(id: "fresh", title: "Fresh")]
        let player = PlaybackController(api: resolver, autoplayAPI: autoplay)

        player.play(remoteTrack(id: "first-seed", title: "First"))
        await waitUntil { autoplay.requests.contains("first-seed") }
        player.play(remoteTrack(id: "second-seed", title: "Second"))
        await waitUntil { !player.autoplayLoading && player.queue.contains { $0.videoID == "fresh" } }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(player.queue.map(\.videoID), ["second-seed", "fresh"])
        XCTAssertFalse(player.queue.contains { $0.videoID == "stale" })
    }

    func testPlayFromQueueSelectsExactDuplicatePosition() async throws {
        let resolver = ControlledStreamResolver()
        let player = PlaybackController(api: resolver)
        let first = remoteTrack(id: "one", title: "One")
        let duplicate = remoteTrack(id: "duplicate", title: "Duplicate")
        let queue = [first, duplicate, duplicate]

        player.play(first, queue: queue)
        player.playFromQueue(at: 2)

        XCTAssertEqual(player.currentTrack, duplicate)
        XCTAssertEqual(player.queueIndex, 2)
        XCTAssertEqual(player.queue, queue)
        player.next()
        XCTAssertEqual(player.queueIndex, 2, "The exact duplicate occurrence is the queue position, so it has no next item")
        try await Task.sleep(nanoseconds: 30_000_000)
    }

    func testPlaybackRateAndSleepTimerState() async throws {
        let player = PlaybackController(api: ControlledStreamResolver())

        player.setPlaybackRate(1.5)
        XCTAssertEqual(player.playbackRate, 1.5)

        player.setStopAfterCurrent()
        XCTAssertTrue(player.stopAfterCurrent)
        XCTAssertNil(player.sleepTimerEnd)
        player.handleTrackEnded()
        XCTAssertFalse(player.stopAfterCurrent)

        player.scheduleSleepTimer(after: 0.025)
        XCTAssertNotNil(player.sleepTimerEnd)
        XCTAssertFalse(player.stopAfterCurrent)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertNil(player.sleepTimerEnd)

        player.setPlaybackRate(20)
        XCTAssertEqual(player.playbackRate, 2, "Playback rate is clamped to the supported range")
    }

    func testPlaybackSettingsPersistProfilesAndNotifyImmediately() throws {
        let suiteName = "BitChordTests.PlaybackSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settings = PlaybackSettings(defaults: defaults, monitorNetwork: false)
        var changes: [(AudioQuality, Bool, Int)] = []
        var spatialChanges: [Bool] = []
        var conversionChanges: [Bool] = []
        var speedChanges: [Double] = []
        var cacheLimitChanges: [Int64] = []
        settings.onChange = { changes.append(($0, $1, $2)) }
        settings.onSpatialAudioChange = { spatialChanges.append($0) }
        settings.onVideoAudioConversionChange = { conversionChanges.append($0) }
        settings.onPlaybackSpeedChange = { speedChanges.append($0) }
        settings.onAudioCacheLimitChange = { cacheLimitChanges.append($0) }

        settings.themeMode = .light
        settings.unmeteredQuality = .low
        settings.meteredQuality = .medium
        settings.skipSilence = true
        settings.spatialAudio = true
        settings.convertVideoToAudio = false
        settings.playbackSpeed = 1.5
        settings.crossfadeSeconds = 7
        settings.showNerdStats = true
        settings.hideVolumeBar = true
        settings.wifiOnlyDownloads = false
        settings.dynamicArtworkTheme = false
        settings.reduceAnimation = true
        settings.reduceDynamicBlur = true
        settings.fullBleedArtwork = false
        settings.autoplay = false
        settings.dontRepeatSuggestions = true
        settings.audioCacheLimitBytes = 2 * 1_024 * 1_024 * 1_024

        XCTAssertEqual(settings.effectiveQuality, .low)
        XCTAssertEqual(changes.last?.0, .low)
        XCTAssertEqual(changes.last?.1, true)
        XCTAssertEqual(changes.last?.2, 7)
        XCTAssertEqual(spatialChanges, [true])
        XCTAssertEqual(conversionChanges, [false])
        XCTAssertEqual(speedChanges, [1.5])
        XCTAssertEqual(cacheLimitChanges, [2 * 1_024 * 1_024 * 1_024])

        let restored = PlaybackSettings(defaults: defaults, monitorNetwork: false)
        XCTAssertEqual(restored.themeMode, .light)
        XCTAssertEqual(restored.unmeteredQuality, .low)
        XCTAssertEqual(restored.meteredQuality, .medium)
        XCTAssertTrue(restored.skipSilence)
        XCTAssertTrue(restored.spatialAudio)
        XCTAssertFalse(restored.convertVideoToAudio)
        XCTAssertEqual(restored.playbackSpeed, 1.5)
        XCTAssertEqual(restored.crossfadeSeconds, 7)
        XCTAssertTrue(restored.showNerdStats)
        XCTAssertTrue(restored.hideVolumeBar)
        XCTAssertFalse(restored.wifiOnlyDownloads)
        XCTAssertFalse(restored.dynamicArtworkTheme)
        XCTAssertTrue(restored.reduceAnimation)
        XCTAssertTrue(restored.reduceDynamicBlur)
        XCTAssertFalse(restored.fullBleedArtwork)
        XCTAssertEqual(restored.audioCacheLimitBytes, 2 * 1_024 * 1_024 * 1_024)
        XCTAssertFalse(restored.autoplay)
        XCTAssertTrue(restored.dontRepeatSuggestions)

        settings.playbackSpeed = 20
        XCTAssertEqual(settings.playbackSpeed, 2)
        XCTAssertEqual(speedChanges.last, 2)
        XCTAssertFalse(PlaybackSettings.downloadsAllowed(wifiOnly: true, networkIsMetered: true))
        XCTAssertTrue(PlaybackSettings.downloadsAllowed(wifiOnly: true, networkIsMetered: false))
        XCTAssertTrue(PlaybackSettings.downloadsAllowed(wifiOnly: false, networkIsMetered: true))
    }

    func testMasterVolumeClampsPersistsAndRestoresMuteLevel() throws {
        let suiteName = "BitChordTests.PlayerVolume.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let player = PlaybackController(
            api: ControlledStreamResolver(),
            volumeDefaults: defaults
        )

        player.setVolume(0.42)
        XCTAssertEqual(player.volume, 0.42, accuracy: 0.001)
        XCTAssertFalse(player.isMuted)

        player.toggleMute()
        XCTAssertTrue(player.isMuted)
        player.toggleMute()
        XCTAssertEqual(player.volume, 0.42, accuracy: 0.001)

        player.setVolume(2)
        XCTAssertEqual(player.volume, 1)
        let restored = PlaybackController(
            api: ControlledStreamResolver(),
            volumeDefaults: defaults
        )
        XCTAssertEqual(restored.volume, 1)
        XCTAssertEqual(PlaybackController.clampedVolume(.nan), 1)
        XCTAssertEqual(PlaybackController.outputVolume(master: 0.4, gain: 0.5), 0.2, accuracy: 0.001)
    }

    func testStatsForNerdsDescriptionUsesOnlyMeasuredFormatValues() {
        let aac = AudioStreamInfo(
            requestedQuality: .high,
            bitrateKbps: 256,
            codec: "audio/mp4a-latm",
            sampleRate: 44_100,
            channels: 2
        )
        XCTAssertEqual(aac.technicalDescription, "AAC · 256 kbps · 44.1 kHz · Stereo")

        let flac = AudioStreamInfo(
            requestedQuality: .high,
            bitrateKbps: 2_940,
            codec: "FLAC",
            sampleRate: 96_000,
            channels: 2,
            bitDepth: 24,
            sourceName: "Lossless module"
        )
        XCTAssertEqual(
            flac.technicalDescription,
            "FLAC · 24-bit · 96.0 kHz · Stereo",
            "Lossless bitrate is real but deliberately omitted like the Kotlin player"
        )

        let unknown = AudioStreamInfo(
            requestedQuality: .medium,
            bitrateKbps: nil,
            codec: nil,
            sampleRate: nil,
            channels: nil
        )
        XCTAssertNil(unknown.technicalDescription)
    }

    func testStatsForNerdsInspectsLocalAudioInsteadOfLeavingFormatBlank() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChord-local-stats-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(4_410)
        ))
        buffer.frameLength = buffer.frameCapacity
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let inspectedInfo = await PlaybackController.inspectAudioFile(at: url)
        let info = try XCTUnwrap(inspectedInfo)

        XCTAssertEqual(
            try XCTUnwrap(PlaybackController.audioFileDuration(at: url)),
            0.1,
            accuracy: 0.001
        )
        XCTAssertEqual(info.codec, "PCM")
        XCTAssertEqual(info.sampleRate, 44_100)
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.bitDepth, 32)
        XCTAssertEqual(info.sourceName, "Local file")
        XCTAssertEqual(info.technicalDescription, "PCM · 32-bit · 44.1 kHz · Mono")
    }

    func testSilenceDetectorOnlyReturnsIntervalsAtLeastOneSecondLong() {
        var detector = SilenceDetector(minimumDuration: 1, amplitudeThreshold: 0.03)

        XCTAssertNil(detector.consume(peakAmplitude: 0.01, start: 0, duration: 0.4))
        XCTAssertNil(detector.consume(peakAmplitude: 0.02, start: 0.4, duration: 0.4))
        XCTAssertNil(detector.consume(peakAmplitude: 0.01, start: 0.8, duration: 0.4))
        XCTAssertEqual(
            detector.consume(peakAmplitude: 0.2, start: 1.2, duration: 0.1),
            SilenceInterval(start: 0, end: 1.2)
        )

        XCTAssertNil(detector.consume(peakAmplitude: 0.01, start: 2, duration: 0.2))
        XCTAssertNil(detector.consume(peakAmplitude: 0.2, start: 2.2, duration: 0.1))
    }

    func testSilenceAnalyzerFindsLongSilenceInRealAudioFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChord-silence-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let sampleRate = 44_100.0
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let frameCount = AVAudioFrameCount(sampleRate * 2)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let toneStart = Int(sampleRate * 1.2)
        for index in 0..<Int(frameCount) {
            samples[index] = index < toneStart
                ? 0
                : sin(Float(index - toneStart) * 2 * .pi * 440 / Float(sampleRate)) * 0.25
        }
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        var intervals: [SilenceInterval] = []
        for await interval in SilenceAnalyzer.intervals(for: AVURLAsset(url: url)) {
            intervals.append(interval)
        }

        let leadingSilence = try XCTUnwrap(intervals.first)
        XCTAssertEqual(leadingSilence.start, 0, accuracy: 0.03)
        XCTAssertEqual(leadingSilence.end, 1.2, accuracy: 0.08)
    }

    func testAudioQualityUsesContainerToleranceForNominal128KbpsAAC() {
        XCTAssertEqual(AudioQuality.low.selectionCeilingKbps, 64)
        XCTAssertEqual(AudioQuality.medium.selectionCeilingKbps, 132)
        XCTAssertEqual(AudioQuality.high.selectionCeilingKbps, .greatestFiniteMagnitude)
    }

    func testCrossfadeCurveKeepsConstantPowerAndClampsDuration() {
        let start = CrossfadeCurve.gains(at: 0)
        let middle = CrossfadeCurve.gains(at: 0.5)
        let end = CrossfadeCurve.gains(at: 1)

        XCTAssertEqual(start.outgoing, 1, accuracy: 0.0001)
        XCTAssertEqual(start.incoming, 0, accuracy: 0.0001)
        XCTAssertEqual(end.outgoing, 0, accuracy: 0.0001)
        XCTAssertEqual(end.incoming, 1, accuracy: 0.0001)
        XCTAssertEqual(
            middle.outgoing * middle.outgoing + middle.incoming * middle.incoming,
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            CrossfadeCurve.duration(
                configuredSeconds: 12,
                outgoingDuration: 9,
                incomingDuration: 6
            ),
            2
        )
        XCTAssertEqual(
            CrossfadeCurve.duration(
                configuredSeconds: 0,
                outgoingDuration: 180,
                incomingDuration: 180
            ),
            0
        )
    }

    func testLocalStreamProxyCapsOnlyLargeSingleRanges() {
        XCTAssertEqual(
            LocalStreamProxy.cappedRange("bytes=0-9999999"),
            "bytes=0-2097151"
        )
        XCTAssertEqual(
            LocalStreamProxy.cappedRange("bytes=524288-"),
            "bytes=524288-2621439"
        )
        XCTAssertEqual(LocalStreamProxy.cappedRange("bytes=10-20"), "bytes=10-20")
        XCTAssertEqual(
            LocalStreamProxy.cappedRange("bytes=0-10,20-30"),
            "bytes=0-10,20-30"
        )
    }

    func testHeaderlessStreamsBypassYouTubeHeaderProxy() throws {
        let direct = ResolvedStream(
            url: try XCTUnwrap(URL(string: "https://aac.saavncdn.com/audio.mp4")),
            headers: [:]
        )
        let authenticated = ResolvedStream(
            url: try XCTUnwrap(URL(string: "https://rr.example.googlevideo.com/videoplayback")),
            headers: ["User-Agent": "BitChord"]
        )

        XCTAssertFalse(direct.requiresLocalPlaybackProxy)
        XCTAssertTrue(authenticated.requiresLocalPlaybackProxy)
    }

    func testYTDLPStreamMetadataPreservesMediaGateAndRequiredHeaders() throws {
        let payload = Data(#"""
        {
          "url": "https://rr.example.googlevideo.com/videoplayback?expire=2000&clen=4000000&dur=245.125",
          "headers": {"User-Agent": "Fixture UA", "Accept": "*/*"},
          "availableAt": "106.0",
          "abr": 129.5,
          "tbr": 130.0,
          "acodec": "mp4a.40.2",
          "asr": 44100,
          "audio_channels": 2
        }
        """#.utf8)

        let parsed = try YouTubeMusicAPI.parseYTDLPStream(
            payload,
            videoID: "abcdefghijk",
            cookieHeader: "SAPISID=fixture",
            quality: .high
        )

        XCTAssertEqual(parsed.availableAt, 106)
        XCTAssertEqual(parsed.stream.videoID, "abcdefghijk")
        XCTAssertEqual(parsed.stream.headers["User-Agent"], "Fixture UA")
        XCTAssertEqual(parsed.stream.headers["Cookie"], "SAPISID=fixture")
        XCTAssertEqual(parsed.stream.info?.bitrateKbps, 130)
        XCTAssertEqual(parsed.stream.info?.codec, "AAC")
        XCTAssertEqual(parsed.stream.info?.sampleRate, 44_100)
        XCTAssertEqual(parsed.stream.info?.channels, 2)
        XCTAssertEqual(try XCTUnwrap(parsed.stream.duration), 245.125, accuracy: 0.001)
    }

    func testYTDLPProbeWaitsForAvailableAtWithoutAcceptingUnboundedDelay() {
        XCTAssertEqual(
            YouTubeMusicAPI.streamReadinessDelay(availableAt: 106, now: 100),
            6.35,
            accuracy: 0.001
        )
        XCTAssertEqual(
            YouTubeMusicAPI.streamReadinessDelay(availableAt: 99, now: 100),
            0
        )
        XCTAssertEqual(
            YouTubeMusicAPI.streamReadinessDelay(availableAt: 10_000, now: 100),
            12,
            "Malformed extractor metadata must not hang playback indefinitely"
        )
        XCTAssertEqual(
            YouTubeMusicAPI.streamReadinessDelay(availableAt: nil, now: 100),
            0
        )
    }

    func testDirectStreamClientPreferenceMovesOnlyKnownWinnerToFront() {
        let clients = ["ANDROID_MUSIC", "TVHTML5", "ANDROID_VR"]

        XCTAssertEqual(
            YouTubeMusicAPI.preferredFirst(clients, preferred: "ANDROID_VR"),
            ["ANDROID_VR", "ANDROID_MUSIC", "TVHTML5"]
        )
        XCTAssertEqual(
            YouTubeMusicAPI.preferredFirst(clients, preferred: "WEB_EMBEDDED"),
            clients,
            "An extractor fallback must never displace the direct device-client order"
        )
    }

    func testAuthenticatedExtractorRaceUsesGateFreeTVBeforeReliableWebFallback() {
        XCTAssertEqual(
            YouTubeMusicAPI.authenticatedExtractorClients,
            ["tv_downgraded", "web_embedded"]
        )
        XCTAssertEqual(
            YouTubeMusicAPI.ytdlpExtractorArguments(for: "tv_downgraded"),
            "youtube:player_client=tv_downgraded;player_skip=webpage,configs"
        )
        XCTAssertEqual(
            YouTubeMusicAPI.ytdlpExtractorArguments(for: "web_embedded"),
            "youtube:player_client=web_embedded"
        )
    }

    func testYTDLPExtractorCarriesTheActiveYouTubeAccountScope() {
        XCTAssertEqual(
            YouTubeMusicAPI.ytdlpExtractorArguments(
                for: "tv_downgraded",
                dataSyncID: "active-account-scope"
            ),
            "youtube:player_client=tv_downgraded;player_skip=webpage,configs;data_sync_id=active-account-scope"
        )
        XCTAssertEqual(
            YouTubeMusicAPI.ytdlpExtractorArguments(
                for: "web_embedded",
                dataSyncID: "active-account-scope"
            ),
            "youtube:player_client=web_embedded;data_sync_id=active-account-scope"
        )
        XCTAssertEqual(
            YouTubeMusicAPI.ytdlpExtractorArguments(
                for: "web_embedded",
                dataSyncID: "invalid;player_client=web"
            ),
            "youtube:player_client=web_embedded",
            "Account scope must not be able to inject another extractor option"
        )
    }

    func testCompactNowPlayingSizingFitsTheMinimumAppWidth() {
        let sizing = NowPlayingLayoutSizing(compact: true)

        XCTAssertLessThanOrEqual(sizing.minimumWidth, 390)
        XCTAssertLessThanOrEqual(sizing.idealWidth, 390)
        XCTAssertEqual(sizing.maximumWidth, 390)
        XCTAssertEqual(NowPlayingLayoutSizing(compact: false).minimumWidth, 900)
    }

    func testPlaybackHelperResolverFallsBackToBundledExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChordHelperTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("BitChord.app", isDirectory: true)
        let helperURL = bundleURL
            .appendingPathComponent("Contents/Resources/PlaybackHelpers/yt-dlp/yt-dlp")
        try FileManager.default.createDirectory(
            at: helperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: helperURL.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperURL.path
        )

        let resolved = YouTubeMusicAPI.playbackHelperExecutablePath(
            bundledRelativePath: "Contents/Resources/PlaybackHelpers/yt-dlp/yt-dlp",
            bundleURL: bundleURL,
            externalCandidates: [root.appendingPathComponent("missing-yt-dlp").path]
        )

        XCTAssertEqual(resolved, helperURL.path)
    }

    func testPlaybackHelperResolverPrefersBundledExecutableOverHostInstall() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChordHelperPriorityTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("Lilt.app", isDirectory: true)
        let bundled = bundleURL.appendingPathComponent("Contents/Resources/PlaybackHelpers/yt-dlp/yt-dlp")
        let external = root.appendingPathComponent("host-yt-dlp")
        try FileManager.default.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: bundled.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: external.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: external.path)

        let resolved = YouTubeMusicAPI.playbackHelperExecutablePath(
            bundledRelativePath: "Contents/Resources/PlaybackHelpers/yt-dlp/yt-dlp",
            bundleURL: bundleURL,
            externalCandidates: [external.path]
        )

        XCTAssertEqual(resolved, bundled.path)
    }

    func testPlaybackFallbackTriesAuthenticatedThenCookieFreeYouTubeClients() {
        XCTAssertEqual(
            YouTubeMusicAPI.playbackFallbackAttempts(hasCookies: true),
            [
                PlaybackFallbackAttempt(extractorClient: "tv_downgraded", includesCookies: true),
                PlaybackFallbackAttempt(extractorClient: "web_embedded", includesCookies: true),
                PlaybackFallbackAttempt(extractorClient: "tv_downgraded", includesCookies: false),
                PlaybackFallbackAttempt(extractorClient: "web_embedded", includesCookies: false)
            ]
        )
        XCTAssertEqual(
            YouTubeMusicAPI.playbackFallbackAttempts(hasCookies: false),
            [
                PlaybackFallbackAttempt(extractorClient: "tv_downgraded", includesCookies: false),
                PlaybackFallbackAttempt(extractorClient: "web_embedded", includesCookies: false)
            ]
        )
    }

    func testYTDLPReceivesExplicitBundledJavaScriptRuntime() {
        XCTAssertEqual(
            YouTubeMusicAPI.ytdlpRuntimeArguments(
                denoPath: "/Applications/BitChord.app/Contents/Resources/PlaybackHelpers/deno"
            ),
            [
                "--js-runtimes",
                "deno:/Applications/BitChord.app/Contents/Resources/PlaybackHelpers/deno"
            ]
        )
        XCTAssertEqual(YouTubeMusicAPI.ytdlpRuntimeArguments(denoPath: nil), [])
    }

    func testSignatureCipherParsingDecodesNestedMediaURLAndParameterName() throws {
        let mediaURL = "https://rr.example.googlevideo.com/videoplayback?n=encrypted-n&cver=old&clen=123"
        var components = URLComponents(string: "https://cipher.invalid/")
        components?.queryItems = [
            URLQueryItem(name: "url", value: mediaURL),
            URLQueryItem(name: "s", value: "encrypted-signature"),
            URLQueryItem(name: "sp", value: "sig")
        ]
        let rawCipher = try XCTUnwrap(components?.percentEncodedQuery)

        let cipher = try XCTUnwrap(YouTubeMusicAPI.parseSignatureCipher(rawCipher))

        XCTAssertEqual(cipher.url.absoluteString, mediaURL)
        XCTAssertEqual(cipher.encryptedSignature, "encrypted-signature")
        XCTAssertEqual(cipher.signatureParameter, "sig")
    }

    func testUnlockedCipherURLAppliesSignatureNTransformAndCurrentClientVersion() throws {
        let cipher = YouTubeSignatureCipher(
            url: try XCTUnwrap(URL(string: "https://rr.example.googlevideo.com/videoplayback?n=old-n&cver=old&clen=123")),
            encryptedSignature: "encrypted-signature",
            signatureParameter: "sig"
        )

        let unlocked = try XCTUnwrap(YouTubeMusicAPI.unlockedCipherURL(
            cipher,
            solvedSignature: "solved-signature",
            solvedN: "solved-n",
            clientVersion: "5.20260114"
        ))
        let query = Dictionary(
            try XCTUnwrap(URLComponents(url: unlocked, resolvingAgainstBaseURL: false)?.queryItems)
                .compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { _, last in last }
        )

        XCTAssertEqual(query["sig"], "solved-signature")
        XCTAssertEqual(query["n"], "solved-n")
        XCTAssertEqual(query["cver"], "5.20260114")
        XCTAssertEqual(query["clen"], "123")
    }

    func testAuthenticatedDirectMediaRequestKeepsSessionCookies() {
        let base = ["User-Agent": "BitChord fixture", "Origin": "https://www.youtube.com"]

        XCTAssertEqual(
            YouTubeMusicAPI.resolvedMediaHeaders(
                base,
                cookieHeader: "SAPISID=secret-fixture",
                authenticated: true
            )["Cookie"],
            "SAPISID=secret-fixture"
        )
        XCTAssertNil(YouTubeMusicAPI.resolvedMediaHeaders(
            base,
            cookieHeader: "SAPISID=secret-fixture",
            authenticated: false
        )["Cookie"])
    }

    func testCipheredPlayerRequestIncludesCurrentSignatureTimestamp() throws {
        let body = YouTubeMusicAPI.playerRequestBody(
            videoID: "video-fixture",
            signatureTimestamp: 20401
        )
        let playbackContext = try XCTUnwrap(body["playbackContext"] as? [String: Any])
        let contentContext = try XCTUnwrap(
            playbackContext["contentPlaybackContext"] as? [String: Any]
        )

        XCTAssertEqual(body["videoId"] as? String, "video-fixture")
        XCTAssertEqual(contentContext["signatureTimestamp"] as? Int, 20401)
        XCTAssertEqual(contentContext["html5Preference"] as? String, "HTML5_PREF_WANTS")
        XCTAssertNil(YouTubeMusicAPI.playerRequestBody(
            videoID: "plain-fixture",
            signatureTimestamp: nil
        )["playbackContext"])
    }

    func testYTDLPCookieJarIsNetscapeFormattedAndRejectsControlCharacters() throws {
        let data = try XCTUnwrap(YouTubeMusicAPI.netscapeCookieFile(
            cookieHeader: "SAPISID=fixture==; __Secure-3PAPISID=second; broken; bad=line\nfeed"
        ))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.hasPrefix("# Netscape HTTP Cookie File\n"))
        XCTAssertTrue(text.contains(".youtube.com\tTRUE\t/\tTRUE\t0\tSAPISID\tfixture=="))
        XCTAssertTrue(text.contains(".youtube.com\tTRUE\t/\tTRUE\t0\t__Secure-3PAPISID\tsecond"))
        XCTAssertFalse(text.contains("broken"))
        XCTAssertFalse(text.contains("line\nfeed"))
    }

    func testYTDLPDownloadsReferenceCookieJarInsteadOfPuttingCookieInArguments() throws {
        let cookieFile = try XCTUnwrap(URL(string: "file:///tmp/BitChord-test.cookies"))

        let arguments = YouTubeMusicAPI.ytdlpCookieArguments(cookieFile: cookieFile)

        XCTAssertEqual(arguments, ["--cookies", "/tmp/BitChord-test.cookies"])
        XCTAssertFalse(arguments.joined(separator: " ").contains("SAPISID"))
        XCTAssertTrue(YouTubeMusicAPI.ytdlpCookieArguments(cookieFile: nil).isEmpty)
    }

    func testResolutionFailureStartsAuthenticatedExtractorFallback() async {
        let resolver = RecordingFallbackResolver()
        let player = PlaybackController(api: resolver)
        let track = remoteTrack(id: "fallback", title: "Fallback")

        player.play(track)
        await waitUntil { resolver.fallbackRequests == [track.id] }

        XCTAssertEqual(player.currentTrack, track)
        XCTAssertTrue(player.isLoading(track))
        XCTAssertEqual(player.statusMessage, "Preparing compatible audio…")
    }

    func testHistoryTrackerSendsStartATRPeriodicAndFinalPingsWithOneNonce() async throws {
        let api = RecordingHistoryAPI()
        let tracker = PlaybackHistoryTracker(
            api: api,
            reportIntervalSeconds: 30,
            openAttempts: 1,
            retryNanoseconds: 1
        )
        var registrations = 0
        tracker.onRegisteredPlay = { registrations += 1 }

        tracker.onPlaying(videoID: "abcdefghijk")
        await waitUntil { api.playbackPings.count == 1 }
        XCTAssertEqual(registrations, 1)

        tracker.onPlaying(videoID: "abcdefghijk")
        try await Task.sleep(nanoseconds: 2_000_000)
        XCTAssertEqual(api.trackingRequests, ["abcdefghijk"], "Resume must not create a second history entry")

        tracker.onProgress(videoID: "abcdefghijk", position: 5)
        await waitUntil { api.atrPings.count == 1 }
        tracker.onProgress(videoID: "abcdefghijk", position: 35)
        await waitUntil { api.watchtimePings.count == 1 }
        tracker.onTrackChanged(position: 42)
        await waitUntil { api.watchtimePings.count == 2 }

        let cpn = try XCTUnwrap(api.playbackPings.first?.cpn)
        XCTAssertEqual(api.atrPings.first?.cpn, cpn)
        XCTAssertEqual(api.watchtimePings.map(\.cpn), [cpn, cpn])
        XCTAssertEqual(api.watchtimePings.map(\.seconds), [35, 42])
        XCTAssertEqual(api.watchtimePings.map(\.final), [false, true])
    }

    func testHistoryTrackerIgnoresNonYouTubeIDsAndSignedOutSessions() async throws {
        let api = RecordingHistoryAPI()
        let tracker = PlaybackHistoryTracker(api: api, openAttempts: 1, retryNanoseconds: 1)

        tracker.onPlaying(videoID: "local:/Music/song.m4a")
        api.isAuthenticated = false
        tracker.onPlaying(videoID: "abcdefghijk")
        try await Task.sleep(nanoseconds: 2_000_000)

        XCTAssertTrue(api.trackingRequests.isEmpty)
        XCTAssertTrue(api.playbackPings.isEmpty)
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for playback history operation")
    }

    private func remoteTrack(id: String, title: String) -> Track {
        Track(
            videoID: id,
            title: title,
            artist: "Test Artist",
            album: nil,
            artworkURL: nil,
            duration: 180,
            localPath: nil,
            sourceURL: nil
        )
    }

    private func writeSilentAudio(
        to url: URL,
        duration: TimeInterval,
        channels: AVAudioChannelCount = 1
    ) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: channels,
            interleaved: false
        ))
        let frameCount = AVAudioFrameCount(44_100 * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
    }

}

@MainActor
private final class RecordingHistoryAPI: PlaybackHistoryAPI {
    struct Ping: Equatable {
        let url: String
        let cpn: String
    }

    struct WatchtimePing: Equatable {
        let url: String
        let cpn: String
        let seconds: Int
        let final: Bool
    }

    var isAuthenticated = true
    var trackingRequests: [String] = []
    var playbackPings: [Ping] = []
    var atrPings: [Ping] = []
    var watchtimePings: [WatchtimePing] = []

    func playbackTracking(for videoID: String) async throws -> PlaybackTrackingURLs? {
        trackingRequests.append(videoID)
        return PlaybackTrackingURLs(
            playbackURL: "https://s.youtube.com/start",
            watchtimeURL: "https://s.youtube.com/watchtime",
            atrURL: "https://s.youtube.com/atr",
            atrAfterSeconds: 5
        )
    }

    func pingPlayback(_ baseURL: String, cpn: String) async throws {
        playbackPings.append(Ping(url: baseURL, cpn: cpn))
    }

    func pingATR(_ baseURL: String, cpn: String) async throws {
        atrPings.append(Ping(url: baseURL, cpn: cpn))
    }

    func pingWatchtime(_ baseURL: String, cpn: String, seconds: Int, final: Bool) async throws {
        watchtimePings.append(WatchtimePing(url: baseURL, cpn: cpn, seconds: seconds, final: final))
    }
}

@MainActor
private final class ControlledStreamResolver: PlaybackStreamResolving {
    private var requested = Set<String>()
    var isAuthenticated: Bool { true }

    func resolveStream(for track: Track) async throws -> ResolvedStream {
        requested.insert(track.id)
        if track.videoID == "first" {
            // Deliberately ignore cancellation and complete late, like an
            // already-running external resolver process.
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return ResolvedStream(url: URL(string: "https://example.com/first.m4a")!, headers: [:])
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        throw YouTubeMusicAPIError.noPlayableStream
    }

    func lyrics(for track: Track) async throws -> Lyrics? { nil }

    func downloadPlaybackFallback(for track: Track) async throws -> URL {
        throw YouTubeMusicAPIError.noPlayableStream
    }

    func waitUntilRequested(_ track: Track) async {
        for _ in 0..<100 where !requested.contains(track.id) { await Task.yield() }
        XCTAssertTrue(requested.contains(track.id), "Resolver was never called for \(track.title)")
    }
}

@MainActor
private final class DelayedCanonicalizingResolver: PlaybackStreamResolving {
    let replacement: Track
    private var streamRequested = false
    var isAuthenticated: Bool { true }

    init(replacement: Track) {
        self.replacement = replacement
    }

    func resolvePlaybackTrack(for track: Track) async -> Track {
        replacement
    }

    func resolveStream(for track: Track) async throws -> ResolvedStream {
        streamRequested = true
        try await Task.sleep(for: .seconds(2))
        throw YouTubeMusicAPIError.noPlayableStream
    }

    func lyrics(for track: Track) async throws -> Lyrics? { nil }

    func downloadPlaybackFallback(for track: Track) async throws -> URL {
        throw YouTubeMusicAPIError.noPlayableStream
    }

    func waitUntilStreamRequested() async {
        for _ in 0..<100 where !streamRequested { await Task.yield() }
        XCTAssertTrue(streamRequested, "Replacement stream resolution never started")
    }
}

@MainActor
private final class ImmediateFileResolver: PlaybackStreamResolving {
    let url: URL
    let duration: TimeInterval?
    var requests: [String] = []
    var isAuthenticated: Bool { true }

    init(url: URL, duration: TimeInterval? = nil) {
        self.url = url
        self.duration = duration
    }

    func resolveStream(for track: Track) async throws -> ResolvedStream {
        requests.append(track.id)
        return ResolvedStream(url: url, headers: [:], duration: duration)
    }

    func lyrics(for track: Track) async throws -> Lyrics? { nil }

    func downloadPlaybackFallback(for track: Track) async throws -> URL {
        throw YouTubeMusicAPIError.noPlayableStream
    }
}

@MainActor
private final class CanonicalizingFileResolver: PlaybackStreamResolving {
    let url: URL
    let replacements: [String: Track]
    private(set) var streamRequests: [String] = []
    var isAuthenticated: Bool { true }

    init(url: URL, replacements: [String: Track]) {
        self.url = url
        self.replacements = replacements
    }

    func resolvePlaybackTrack(for track: Track) async -> Track {
        track.videoID.flatMap { replacements[$0] } ?? track
    }

    func resolveStream(for track: Track) async throws -> ResolvedStream {
        streamRequests.append(track.videoID ?? track.id)
        return ResolvedStream(url: url, headers: [:], duration: track.duration)
    }

    func lyrics(for track: Track) async throws -> Lyrics? { nil }

    func downloadPlaybackFallback(for track: Track) async throws -> URL {
        throw YouTubeMusicAPIError.noPlayableStream
    }
}

@MainActor
private final class RecordingFallbackResolver: PlaybackStreamResolving {
    var fallbackRequests: [String] = []
    var isAuthenticated: Bool { true }

    func resolveStream(for track: Track) async throws -> ResolvedStream {
        throw YouTubeMusicAPIError.noPlayableStream
    }

    func lyrics(for track: Track) async throws -> Lyrics? { nil }

    func downloadPlaybackFallback(for track: Track) async throws -> URL {
        fallbackRequests.append(track.id)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        throw YouTubeMusicAPIError.noPlayableStream
    }
}

@MainActor
private final class RecordingAutoplayProvider: AutoplayTrackProviding {
    var responses: [String: [Track]] = [:]
    var requests: [String] = []
    var delayNanoseconds: UInt64 = 0
    var ignoreCancellationFor: String?

    func autoplayTracks(for videoID: String) async throws -> [Track] {
        requests.append(videoID)
        if delayNanoseconds > 0 {
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                guard ignoreCancellationFor == videoID else { throw error }
            }
        }
        return responses[videoID] ?? []
    }
}
