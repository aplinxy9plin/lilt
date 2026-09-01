import AVFoundation
import XCTest

@MainActor
final class AutomixTests: XCTestCase {
    func testAndroidCompatibleSettingPersists() {
        let suite = "AutomixTests-\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // A value written by an older build is reset once so Automix requires
        // a visible, deliberate opt-in after this update.
        defaults.set(true, forKey: "smart_fade_enabled")
        let settings = PlaybackSettings(defaults: defaults, monitorNetwork: false)
        XCTAssertFalse(settings.smartFadeEnabled)
        settings.smartFadeEnabled = true
        XCTAssertEqual(defaults.object(forKey: "smart_fade_enabled") as? Bool, true)
        XCTAssertTrue(PlaybackSettings(defaults: defaults, monitorNetwork: false).smartFadeEnabled)
    }

    func testSharedNativeAnalyzerFindsBeatGridAndStructure() throws {
        let rate = AutomixAnalyzer.analysisSampleRate
        let samples = pulseTrack(duration: 55, bpm: 120, sampleRate: rate)
        let data: Data? = samples.withUnsafeBufferPointer {
            BCAnalyzeAudio($0.baseAddress, UInt($0.count), rate, Double($0.count) / rate)
        }
        let json = try XCTUnwrap(data)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let bpm = try XCTUnwrap(object["bpm"] as? Double)
        XCTAssertEqual(bpm, 120, accuracy: 8)
        XCTAssertGreaterThan((object["downbeats"] as? [Double])?.count ?? 0, 8)
        XCTAssertGreaterThan((object["energyCurve"] as? [[String: Double]])?.count ?? 0, 20)
    }

    func testAssetReaderAndNativeAnalyzerPipeline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomixTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("pulse.wav")
        let rate = 44_100.0
        let samples = pulseTrack(duration: 48, bpm: 100, sampleRate: rate)
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ))
            buffer.frameLength = AVAudioFrameCount(samples.count)
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            samples.withUnsafeBufferPointer { pointer in
                channel.update(from: pointer.baseAddress!, count: pointer.count)
            }
            try file.write(from: buffer)
        }

        let analysis = await AutomixAnalyzer.analyze(
            asset: AVURLAsset(url: url),
            trackID: "fixture:pulse",
            durationHint: 48
        )
        let result = try XCTUnwrap(analysis)
        XCTAssertEqual(result.trackID, "fixture:pulse")
        XCTAssertEqual(result.bpm, 100, accuracy: 8)
        XCTAssertTrue(result.isUsable)
        XCTAssertFalse(result.mixOutCandidates.isEmpty)
    }

    func testPlannerCuesIntroAndAppliesRealTempoMatch() throws {
        let outgoingTrack = track(id: "out", title: "Outgoing", duration: 180)
        let incomingTrack = track(id: "in", title: "Incoming", duration: 190)
        let outgoing = AutomixTrackAnalysis.fixture(
            trackID: outgoingTrack.id,
            duration: 180,
            bpm: 120,
            confidence: 0.8,
            mixOut: 176,
            key: "C major"
        )
        let incoming = AutomixTrackAnalysis.fixture(
            trackID: incomingTrack.id,
            duration: 190,
            bpm: 121,
            confidence: 0.8,
            mixIn: 12,
            mixOut: 186,
            key: "G major"
        )

        let plan = try XCTUnwrap(AutomixPlanner.plan(
            outgoing: outgoing,
            incoming: incoming,
            outgoingTrack: outgoingTrack,
            incomingTrack: incomingTrack,
            duration: 180,
            standardFade: 6
        ))
        XCTAssertEqual(plan.style, .beatmatched)
        XCTAssertEqual(plan.incomingPlaybackRate, 120 / 121, accuracy: 0.0001)
        XCTAssertEqual(plan.incomingCueTime, 0)
        XCTAssertEqual(
            plan.incomingCue(at: plan.transitionStart + 1.5),
            plan.incomingCueTime + 1.5 * plan.incomingPlaybackRate,
            accuracy: 0.0001
        )
        XCTAssertEqual(plan.transitionEnd, 176, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(plan.fadeDuration, 4)
    }

    func testPlannerUsesSafeFadeUntilAnalysisArrives() throws {
        let outgoing = track(id: "out", title: "Outgoing", duration: 180)
        let incoming = track(id: "in", title: "Incoming", duration: 180)
        let plan = try XCTUnwrap(AutomixPlanner.plan(
            outgoing: nil,
            incoming: nil,
            outgoingTrack: outgoing,
            incomingTrack: incoming,
            duration: 180,
            standardFade: 6
        ))
        XCTAssertEqual(plan.style, .equalPower)
        XCTAssertEqual(plan.transitionStart, 174, accuracy: 0.001)
        XCTAssertEqual(plan.incomingPlaybackRate, 1)
        XCTAssertEqual(plan.reason, "analysis-fallback")
    }

    private func pulseTrack(duration: Double, bpm: Double, sampleRate: Double) -> [Float] {
        let count = Int(duration * sampleRate)
        let beatSamples = Int((60 / bpm) * sampleRate)
        var result = [Float](repeating: 0, count: count)
        for start in stride(from: 0, to: count, by: beatSamples) {
            let length = min(Int(sampleRate * 0.08), count - start)
            for offset in 0..<length {
                let time = Double(offset) / sampleRate
                let envelope = exp(-time * 45)
                result[start + offset] = Float(sin(2 * .pi * 70 * time) * envelope * 0.9)
            }
        }
        return result
    }

    private func track(id: String, title: String, duration: TimeInterval) -> Track {
        Track(
            videoID: id,
            title: title,
            artist: "Artist",
            album: "Album",
            artworkURL: nil,
            duration: duration,
            localPath: nil,
            sourceURL: nil
        )
    }
}
