import AVFoundation
import XCTest

@MainActor
final class EqualizerTests: XCTestCase {
    func testSettingsPersistPresetAndCustomBandShape() throws {
        let suiteName = "BitChordTests.Equalizer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = EqualizerSettings(defaults: defaults)
        var snapshots: [EqualizerSnapshot] = []
        settings.onChange = { snapshots.append($0) }

        settings.isEnabled = true
        settings.selectPreset(.rock)
        settings.setBandGain(6, at: 0)
        settings.setPreamp(-5)

        XCTAssertEqual(settings.preset, .custom)
        XCTAssertEqual(settings.bandGainsDB[0], 6)
        XCTAssertEqual(settings.preampDB, -5)
        XCTAssertEqual(snapshots.last, settings.snapshot)

        let restored = EqualizerSettings(defaults: defaults)
        XCTAssertTrue(restored.isEnabled)
        XCTAssertEqual(restored.preset, .custom)
        XCTAssertEqual(restored.bandGainsDB[0], 6)
        XCTAssertEqual(restored.preampDB, -5)
        XCTAssertEqual(restored.bandGainsDB.count, EqualizerSnapshot.frequencies.count)
    }

    func testSnapshotPadsAndClampsUntrustedValues() {
        let snapshot = EqualizerSnapshot(enabled: true, preampDB: 9, gainsDB: [-30, 30, 2])

        XCTAssertEqual(snapshot.preampDB, 0)
        XCTAssertEqual(snapshot.gainsDB.count, 10)
        XCTAssertEqual(Array(snapshot.gainsDB.prefix(4)), [-12, 12, 2, 0])
    }

    func testFlatDSPPreservesSamples() {
        let snapshot = EqualizerSnapshot(enabled: true, preampDB: 0, gainsDB: Array(repeating: 0, count: 10))
        let dsp = EqualizerDSP(snapshot: snapshot)
        dsp.prepare(sampleRate: 48_000, channelCount: 2)
        var samples: [Float] = [0.25, -0.5, 0.75, -0.125, -0.2, 0.4]
        let original = samples

        dsp.processInterleaved(&samples, channelCount: 2)

        for (actual, expected) in zip(samples, original) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
    }

    func testBassPresetRaisesLowFrequencyRelativeToMidrange() {
        let snapshot = EqualizerSnapshot(
            enabled: true,
            preampDB: -6,
            gainsDB: [6, 5, 4, 2, 0, -1, -1, 0, 1, 2]
        )
        let lowRMS = processedRMS(frequency: 62, snapshot: snapshot)
        let midRMS = processedRMS(frequency: 1_000, snapshot: snapshot)

        XCTAssertGreaterThan(lowRMS, midRMS * 1.7)
        XCTAssertTrue(lowRMS.isFinite)
        XCTAssertTrue(midRMS.isFinite)
    }

    func testStereoProcessingDoesNotLeakIntoSilentChannel() {
        let snapshot = EqualizerSnapshot(
            enabled: true,
            preampDB: -3,
            gainsDB: [4, 3, 2, 1, 0, -1, -2, -1, 0, 1]
        )
        let dsp = EqualizerDSP(snapshot: snapshot)
        dsp.prepare(sampleRate: 44_100, channelCount: 2)
        var samples = (0..<4_096).flatMap { frame -> [Float] in
            let left = Float(sin(2 * Double.pi * 250 * Double(frame) / 44_100)) * 0.25
            return [left, 0]
        }

        dsp.processInterleaved(&samples, channelCount: 2)

        let rightPeak = stride(from: 1, to: samples.count, by: 2).map { abs(samples[$0]) }.max() ?? 1
        XCTAssertEqual(rightPeak, 0, accuracy: 0.000_001)
    }

    func testSpatialAudioWidensStereoAndAddsDelayedLowPassedCrossfeed() {
        let dsp = SpatialAudioDSP(enabled: true)
        dsp.prepare(sampleRate: 48_000, channelCount: 2)
        var samples = Array(repeating: Float.zero, count: 2_000 * 2)
        samples[0] = 0.5

        dsp.processInterleaved(&samples, channelCount: 2)

        XCTAssertEqual(samples[0], 0.7175, accuracy: 0.000_1)
        XCTAssertEqual(samples[1], -0.3075, accuracy: 0.000_1)
        XCTAssertGreaterThan(samples[720 * 2 + 1], 0.02, "The far ear receives the delayed low-passed left channel")
        XCTAssertTrue(samples.allSatisfy { $0.isFinite && (-1...1).contains($0) })
    }

    func testSpatialAudioLeavesMonoMaterialUntouched() {
        let dsp = SpatialAudioDSP(enabled: true)
        dsp.prepare(sampleRate: 44_100, channelCount: 1)
        var samples: [Float] = [0.5, -0.25, 0.125]
        let original = samples

        dsp.processInterleaved(&samples, channelCount: 1)

        XCTAssertEqual(samples, original)
    }

    func testAudioMixCreatesRealMediaToolboxTap() throws {
        let composition = AVMutableComposition()
        let track = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        let snapshot = EqualizerSnapshot(
            enabled: true,
            preampDB: -3,
            gainsDB: [3, 2, 1, 0, 0, 0, 1, 2, 3, 4]
        )

        let mix = try XCTUnwrap(EqualizerAudioMix.make(snapshot: snapshot, track: track))
        let parameters = try XCTUnwrap(mix.inputParameters.first)

        XCTAssertEqual(parameters.trackID, track.trackID)
        XCTAssertNotNil(parameters.audioTapProcessor)
        XCTAssertNil(EqualizerAudioMix.make(snapshot: .disabled, track: track))

        let spatialOnly = try XCTUnwrap(EqualizerAudioMix.make(
            equalizer: .disabled,
            spatialAudioEnabled: true,
            track: track
        ))
        XCTAssertNotNil(spatialOnly.inputParameters.first?.audioTapProcessor)
        XCTAssertNil(EqualizerAudioMix.make(
            equalizer: .disabled,
            spatialAudioEnabled: false,
            track: track
        ))
    }

    func testMediaToolboxTapProcessesExportedAudio() async throws {
        let snapshot = EqualizerSnapshot(
            enabled: true,
            preampDB: -6,
            gainsDB: [6, 5, 4, 2, 0, -1, -1, 0, 1, 2]
        )

        let lowRMS = try await exportedRMS(frequency: 62, snapshot: snapshot)
        let midRMS = try await exportedRMS(frequency: 1_000, snapshot: snapshot)

        XCTAssertGreaterThan(lowRMS, midRMS * 1.55)
    }

    private func processedRMS(frequency: Double, snapshot: EqualizerSnapshot) -> Float {
        let sampleRate = 48_000.0
        let frameCount = 24_000
        var samples = (0..<frameCount).map { frame in
            Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate)) * 0.25
        }
        let dsp = EqualizerDSP(snapshot: snapshot)
        dsp.prepare(sampleRate: sampleRate, channelCount: 1)
        dsp.processInterleaved(&samples, channelCount: 1)
        let settled = samples.dropFirst(4_096)
        let meanSquare = settled.reduce(Float.zero) { $0 + $1 * $1 } / Float(settled.count)
        return sqrt(meanSquare)
    }

    private func exportedRMS(frequency: Double, snapshot: EqualizerSnapshot) async throws -> Float {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChordEqualizerExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.wav")
        let outputURL = root.appendingPathComponent("filtered.m4a")
        let sampleRate = 48_000.0
        let frameCount = AVAudioFrameCount(sampleRate * 1.2)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        do {
            let file = try AVAudioFile(forWriting: sourceURL, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<Int(frameCount) {
                samples[frame] = Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate)) * 0.25
            }
            try file.write(from: buffer)
        }

        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let mix = try XCTUnwrap(EqualizerAudioMix.make(snapshot: snapshot, track: track))
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A))
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.audioMix = mix
        await withCheckedContinuation { continuation in
            exporter.exportAsynchronously { continuation.resume() }
        }
        guard exporter.status == .completed else {
            throw try XCTUnwrap(exporter.error)
        }

        let filtered = try AVAudioFile(forReading: outputURL)
        let capacity = AVAudioFrameCount(filtered.length)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: filtered.processingFormat,
            frameCapacity: capacity
        ))
        try filtered.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let first = min(Int(buffer.frameLength), Int(sampleRate * 0.15))
        let count = Int(buffer.frameLength) - first
        guard count > 0 else { return 0 }
        var sum = Float.zero
        for index in first..<Int(buffer.frameLength) {
            sum += samples[index] * samples[index]
        }
        return sqrt(sum / Float(count))
    }
}
