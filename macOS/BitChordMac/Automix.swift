import AVFoundation
import AudioToolbox
import Foundation
import os

struct AutomixEnergySample: Codable, Equatable, Sendable {
    let time: TimeInterval
    let energy: Double
}

struct AutomixCuePoint: Codable, Equatable, Sendable {
    let time: TimeInterval
    let score: Double
    let type: String
}

struct AutomixTrackAnalysis: Codable, Equatable, Sendable {
    let status: String
    let trackID: String
    let duration: TimeInterval
    let bpm: Double
    let beatInterval: TimeInterval
    let firstBeat: TimeInterval
    let beatConfidence: Double
    let beats: [TimeInterval]
    let downbeats: [TimeInterval]
    let phraseBoundaries: [TimeInterval]
    let key: String
    let keyConfidence: Double
    let audibleStartTime: TimeInterval
    let pickupTime: TimeInterval
    let introEndTime: TimeInterval
    let outroStartTime: TimeInterval
    let contentEndTime: TimeInterval
    let mixInTime: TimeInterval
    let mixOutTime: TimeInterval
    let vocalProbability: Double
    let vocalActivityMask: [Double]
    let energyCurve: [AutomixEnergySample]
    let lowEnergyCurve: [AutomixEnergySample]
    let mixInCandidates: [AutomixCuePoint]
    let mixOutCandidates: [AutomixCuePoint]

    var isUsable: Bool {
        status == "ready" && bpm >= 40 && bpm <= 220 && duration > 0
    }

    static func fixture(
        trackID: String,
        duration: TimeInterval = 180,
        bpm: Double = 120,
        confidence: Double = 0.7,
        firstBeat: TimeInterval = 0,
        mixIn: TimeInterval = 8,
        mixOut: TimeInterval = 176,
        key: String = "C major"
    ) -> AutomixTrackAnalysis {
        let beat = 60 / bpm
        let beats = stride(from: firstBeat, through: duration, by: beat).map { $0 }
        return AutomixTrackAnalysis(
            status: "ready",
            trackID: trackID,
            duration: duration,
            bpm: bpm,
            beatInterval: beat,
            firstBeat: firstBeat,
            beatConfidence: confidence,
            beats: beats,
            downbeats: beats.enumerated().compactMap { $0.offset.isMultiple(of: 4) ? $0.element : nil },
            phraseBoundaries: beats.enumerated().compactMap { $0.offset.isMultiple(of: 16) ? $0.element : nil },
            key: key,
            keyConfidence: 0.8,
            audibleStartTime: firstBeat,
            pickupTime: firstBeat,
            introEndTime: mixIn,
            outroStartTime: mixOut,
            contentEndTime: duration,
            mixInTime: mixIn,
            mixOutTime: mixOut,
            vocalProbability: 0,
            vocalActivityMask: [],
            energyCurve: [],
            lowEnergyCurve: [],
            mixInCandidates: [AutomixCuePoint(time: mixIn, score: 0.9, type: "main_drop")],
            mixOutCandidates: [AutomixCuePoint(time: mixOut, score: 0.9, type: "outro_start")]
        )
    }
}

private struct NativeAutomixPayload: Decodable {
    struct Energy: Decodable {
        let t: Double
        let e: Double
    }

    struct Cue: Decodable {
        let t: Double
        let s: Double
        let y: String
    }

    let duration: Double
    let bpm: Double
    let beatInterval: Double
    let firstBeat: Double
    let beatConfidence: Double
    let beats: [Double]
    let downbeats: [Double]
    let phraseBoundaries: [Double]
    let key: String
    let keyConfidence: Double
    let audibleStartTime: Double
    let pickupTime: Double
    let introEndTime: Double
    let outroStartTime: Double
    let contentEndTime: Double
    let mixInTime: Double
    let mixOutTime: Double
    let vocalProbability: Double
    let vocalActivityMask: [Double]
    let energyCurve: [Energy]
    let lowEnergyCurve: [Energy]
    let mixInCandidates: [Cue]
    let mixOutCandidates: [Cue]

    func analysis(trackID: String) -> AutomixTrackAnalysis {
        AutomixTrackAnalysis(
            status: "ready",
            trackID: trackID,
            duration: duration,
            bpm: bpm,
            beatInterval: beatInterval,
            firstBeat: firstBeat,
            beatConfidence: beatConfidence,
            beats: beats,
            downbeats: downbeats,
            phraseBoundaries: phraseBoundaries,
            key: key,
            keyConfidence: keyConfidence,
            audibleStartTime: audibleStartTime,
            pickupTime: pickupTime,
            introEndTime: introEndTime,
            outroStartTime: outroStartTime,
            contentEndTime: contentEndTime,
            mixInTime: mixInTime,
            mixOutTime: mixOutTime,
            vocalProbability: vocalProbability,
            vocalActivityMask: vocalActivityMask,
            energyCurve: energyCurve.map { AutomixEnergySample(time: $0.t, energy: $0.e) },
            lowEnergyCurve: lowEnergyCurve.map { AutomixEnergySample(time: $0.t, energy: $0.e) },
            mixInCandidates: mixInCandidates.map { AutomixCuePoint(time: $0.t, score: $0.s, type: $0.y) },
            mixOutCandidates: mixOutCandidates.map { AutomixCuePoint(time: $0.t, score: $0.s, type: $0.y) }
        )
    }
}

actor AutomixAnalyzer {
    static let analysisSampleRate = 11_025.0
    private static let logger = Logger(subsystem: "com.bitchord.mac", category: "Automix")

    private var memory: [String: AutomixTrackAnalysis] = [:]
    private var running: [String: Task<AutomixTrackAnalysis?, Never>] = [:]
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("BitChord", isDirectory: true)
            .appendingPathComponent("AutomixAnalysis", isDirectory: true)
    }

    func analysis(
        for trackID: String,
        asset: AVAsset,
        durationHint: TimeInterval?
    ) async -> AutomixTrackAnalysis? {
        if let cached = memory[trackID] { return cached }
        if let stored = load(trackID: trackID) {
            memory[trackID] = stored
            return stored
        }
        if let task = running[trackID] { return await task.value }

        let task = Task.detached(priority: .utility) {
            await Self.analyze(asset: asset, trackID: trackID, durationHint: durationHint)
        }
        running[trackID] = task
        let result = await task.value
        running[trackID] = nil
        if let result {
            memory[trackID] = result
            save(result)
        }
        return result
    }

    static func analyze(
        asset: AVAsset,
        trackID: String,
        durationHint: TimeInterval? = nil
    ) async -> AutomixTrackAnalysis? {
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            logger.debug("Analysis stopped: the asset has no readable audio track")
            return nil
        }
        let assetDuration = (try? await asset.load(.duration).seconds).flatMap { validDuration($0) }
        let expectedDuration = validDuration(durationHint) ?? assetDuration
        guard let pcm = decodeMonoPCM(track: audioTrack, asset: asset), !pcm.samples.isEmpty else {
            logger.debug("Analysis stopped: AVAssetReader produced no PCM")
            return nil
        }
        let decodedDuration = Double(pcm.samples.count) / pcm.sampleRate
        if let expectedDuration, expectedDuration > 8,
           decodedDuration < min(expectedDuration * 0.85, expectedDuration - 3) {
            logger.debug(
                "Analysis stopped: decoded \(decodedDuration, format: .fixed(precision: 2))s of expected \(expectedDuration, format: .fixed(precision: 2))s"
            )
            return nil
        }
        let analysisPCM: (samples: [Float], rate: Double)
        if abs(pcm.sampleRate - analysisSampleRate) < 0.5 {
            analysisPCM = (pcm.samples, pcm.sampleRate)
        } else {
            guard let raw = pcm.samples.withUnsafeBufferPointer({ pointer in
                BCResampleAudio(pointer.baseAddress, UInt(pointer.count), pcm.sampleRate, analysisSampleRate)
            }) else {
                logger.debug("Analysis stopped: native resampling failed")
                return nil
            }
            var converted = [Float](repeating: 0, count: raw.count / MemoryLayout<Float>.size)
            _ = converted.withUnsafeMutableBytes { destination in
                raw.copyBytes(to: destination)
            }
            analysisPCM = (converted, analysisSampleRate)
        }
        guard let data = analysisPCM.samples.withUnsafeBufferPointer({ pointer in
            BCAnalyzeAudio(pointer.baseAddress, UInt(pointer.count), analysisPCM.rate, decodedDuration)
        }),
        let payload = try? JSONDecoder().decode(NativeAutomixPayload.self, from: data) else {
            logger.debug("Analysis stopped: native analyzer returned an invalid payload")
            return nil
        }
        return payload.analysis(trackID: trackID)
    }

    private nonisolated static func decodeMonoPCM(
        track: AVAssetTrack,
        asset: AVAsset
    ) -> (samples: [Float], sampleRate: Double)? {
        guard let reader = try? AVAssetReader(asset: asset) else {
            logger.debug("PCM decode stopped: AVAssetReader could not be created")
            return nil
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            logger.debug("PCM decode stopped: AVAssetReader rejected the audio output")
            return nil
        }
        reader.add(output)
        guard reader.startReading() else {
            logger.debug("PCM decode stopped at start: \(reader.error?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }

        var samples: [Float] = []
        var decodedRate = analysisSampleRate
        samples.reserveCapacity(Int(240 * analysisSampleRate))
        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                return nil
            }
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  basic.mSampleRate > 0,
                  basic.mFormatID == kAudioFormatLinearPCM,
                  basic.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
                reader.cancelReading()
                return nil
            }
            decodedRate = basic.mSampleRate

            var retainedBlockBuffer: CMBlockBuffer?
            var requiredSize = 0
            _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: &requiredSize,
                bufferListOut: nil,
                bufferListSize: 0,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
                blockBufferOut: &retainedBlockBuffer
            )
            guard requiredSize >= MemoryLayout<AudioBufferList>.size else {
                logger.debug("PCM decode stopped: no AudioBufferList storage was reported")
                reader.cancelReading()
                return nil
            }
            let storage = UnsafeMutableRawPointer.allocate(
                byteCount: requiredSize,
                alignment: 16
            )
            let audioBufferList = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
            let bufferStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: audioBufferList,
                bufferListSize: requiredSize,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
                blockBufferOut: &retainedBlockBuffer
            )
            guard bufferStatus == noErr else {
                storage.deallocate()
                logger.debug("PCM decode stopped: AudioBufferList failed with \(bufferStatus)")
                reader.cancelReading()
                return nil
            }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frameCount = buffers.map { buffer in
                let channels = max(1, Int(buffer.mNumberChannels))
                return Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            }.min() ?? 0
            if buffers.count == 1,
               buffers[0].mNumberChannels == 1,
               let data = buffers[0].mData {
                let pointer = data.assumingMemoryBound(to: Float.self)
                samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: frameCount))
            } else {
                for frame in 0..<frameCount {
                    var sum: Float = 0
                    var mixedChannels = 0
                    for buffer in buffers {
                        guard let data = buffer.mData else { continue }
                        let channels = max(1, Int(buffer.mNumberChannels))
                        let pointer = data.assumingMemoryBound(to: Float.self)
                        for channel in 0..<channels {
                            sum += pointer[frame * channels + channel]
                            mixedChannels += 1
                        }
                    }
                    if mixedChannels > 0 { samples.append(sum / Float(mixedChannels)) }
                }
            }
            storage.deallocate()
        }
        guard reader.status == .completed else {
            logger.debug("PCM decode stopped at status \(reader.status.rawValue): \(reader.error?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
        return (samples, decodedRate)
    }

    private func load(trackID: String) -> AutomixTrackAnalysis? {
        let url = fileURL(for: trackID)
        guard let data = try? Data(contentsOf: url),
              let analysis = try? JSONDecoder().decode(AutomixTrackAnalysis.self, from: data),
              analysis.trackID == trackID else { return nil }
        return analysis
    }

    private func save(_ analysis: AutomixTrackAnalysis) {
        guard let data = try? JSONEncoder().encode(analysis) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: analysis.trackID), options: .atomic)
    }

    private func fileURL(for trackID: String) -> URL {
        directory.appendingPathComponent(Self.stableHash(trackID) + ".json")
    }

    private nonisolated static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private nonisolated static func validDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

enum AutomixTransitionStyle: String, Equatable, Sendable {
    case equalPower
    case beatmatched

    var title: String {
        switch self {
        case .equalPower: "Smart fade"
        case .beatmatched: "Beatmatched"
        }
    }
}

struct AutomixTransitionPlan: Equatable, Sendable {
    let transitionStart: TimeInterval
    let transitionEnd: TimeInterval
    let fadeDuration: TimeInterval
    let incomingCueTime: TimeInterval
    let incomingPlaybackRate: Double
    let style: AutomixTransitionStyle
    let bassSwapFraction: Double
    let reason: String

    var isRealMix: Bool { style != .equalPower || incomingCueTime > 0.05 }

    func incomingCue(at outgoingPosition: TimeInterval) -> TimeInterval {
        let lateness = max(0, outgoingPosition - transitionStart)
        return max(0, incomingCueTime + lateness * incomingPlaybackRate)
    }
}

enum AutomixAnalysisStatus: Equatable, Sendable {
    case off
    case analyzing
    case ready(bpm: Int)
    case waiting
    case fallback
    case transitioning(String)

    var title: String {
        switch self {
        case .off: "Automix off"
        case .analyzing: "Analyzing next mix…"
        case .ready(let bpm): "Automix ready · \(bpm) BPM"
        case .waiting: "Automix · waiting for next track"
        case .fallback: "Automix · safe fade"
        case .transitioning(let title): title
        }
    }
}

enum AutomixPlanner {
    private static let minimumSmartDuration: TimeInterval = 45
    private static let minimumBeatmatchConfidence = 0.55
    private static let minimumDJConfidence = 0.2
    private static let maximumStretchDeviation = 0.04
    private static let maximumDiscardedMusic: TimeInterval = 12
    private static let blockedText = try! NSRegularExpression(
        pattern: #"\b(podcast|episode|audiobook|live|concert|performance)\b"#,
        options: .caseInsensitive
    )

    static func plan(
        outgoing: AutomixTrackAnalysis?,
        incoming: AutomixTrackAnalysis?,
        outgoingTrack: Track,
        incomingTrack: Track,
        duration: TimeInterval,
        standardFade: TimeInterval
    ) -> AutomixTransitionPlan? {
        guard duration >= minimumSmartDuration else { return nil }
        let joinedText = [outgoingTrack.title, outgoingTrack.artist, outgoingTrack.album,
                          incomingTrack.title, incomingTrack.artist, incomingTrack.album]
            .compactMap { $0 }.joined(separator: " ")
        let range = NSRange(joinedText.startIndex..., in: joinedText)
        guard blockedText.firstMatch(in: joinedText, range: range) == nil else { return nil }

        let fallbackDuration = clampedFade(standardFade > 0 ? standardFade : 6, duration: duration)
        guard let outgoing, let incoming,
              outgoing.trackID == outgoingTrack.id,
              incoming.trackID == incomingTrack.id,
              outgoing.isUsable,
              incoming.isUsable else {
            return AutomixTransitionPlan(
                transitionStart: max(0, duration - fallbackDuration),
                transitionEnd: duration,
                fadeDuration: fallbackDuration,
                incomingCueTime: 0,
                incomingPlaybackRate: 1,
                style: .equalPower,
                bassSwapFraction: 0.7,
                reason: "analysis-fallback"
            )
        }

        let mixEnd = min(duration, mixOutAnchor(outgoing, duration: duration))
        let confidence = min(outgoing.beatConfidence, incoming.beatConfidence)
        let alignedIncomingBPM = alignTempoOctave(outgoing: outgoing.bpm, incoming: incoming.bpm)
        let stretch = alignedIncomingBPM > 0 ? outgoing.bpm / alignedIncomingBPM : 1
        let canBeatmatch = confidence >= minimumBeatmatchConfidence &&
            abs(stretch - 1) <= maximumStretchDeviation
        let canDJ = outgoing.beatConfidence >= minimumDJConfidence ||
            incoming.beatConfidence >= minimumDJConfidence

        guard canDJ else {
            let fade = min(fallbackDuration, mixEnd)
            return AutomixTransitionPlan(
                transitionStart: max(0, mixEnd - fade),
                transitionEnd: mixEnd,
                fadeDuration: fade,
                incomingCueTime: 0,
                incomingPlaybackRate: 1,
                style: .equalPower,
                bassSwapFraction: 0.7,
                reason: "beat-confidence"
            )
        }

        let outgoingBeat = outgoing.beatInterval > 0 ? outgoing.beatInterval : 60 / outgoing.bpm
        var transitionBeats = shouldUseLongBlend(outgoing: outgoing, incoming: incoming, stretch: stretch) ? 16 : 8
        if vocalConflict(outgoing, incoming) { transitionBeats = 4 }
        let desired = min(max(Double(transitionBeats) * outgoingBeat, 4), 12)
        let maximum = max(1, min(min(mixEnd * 0.4, incoming.duration * 0.4), 12))
        let overlap = min(desired, maximum)
        let targetStart = max(0, mixEnd - overlap)
        let transitionStart = nearestAtOrBefore(
            outgoing.phraseBoundaries.isEmpty ? outgoing.downbeats : outgoing.phraseBoundaries,
            target: targetStart,
            minimum: max(0, mixEnd - maximum)
        ) ?? nearestAtOrBefore(outgoing.downbeats, target: targetStart, minimum: max(0, mixEnd - maximum))
            ?? targetStart
        let actualOverlap = max(0.15, mixEnd - transitionStart)
        let rate = canBeatmatch ? min(max(stretch, 0.9), 1.1) : 1
        let sameGrid = abs(stretch - 1) <= 0.05
        return AutomixTransitionPlan(
            transitionStart: transitionStart,
            transitionEnd: mixEnd,
            fadeDuration: actualOverlap,
            // Never discard the opening of the incoming song. The previous
            // cue-point seek could begin a track 20–30 seconds in.
            incomingCueTime: 0,
            incomingPlaybackRate: rate,
            style: canBeatmatch && sameGrid ? .beatmatched : .equalPower,
            bassSwapFraction: bassSwapFraction(outgoing: outgoing, incoming: incoming),
            reason: canBeatmatch ? "beatmatched" : "dj-assisted"
        )
    }

    static func alignTempoOctave(outgoing: Double, incoming: Double) -> Double {
        guard outgoing > 0, incoming > 0 else { return incoming }
        var value = incoming
        while value / outgoing > 1.5 { value /= 2 }
        while value / outgoing < 0.67 { value *= 2 }
        return value
    }

    private static func mixOutAnchor(_ analysis: AutomixTrackAnalysis, duration: TimeInterval) -> TimeInterval {
        let contentEnd = analysis.contentEndTime > 0 ? min(duration, analysis.contentEndTime) : duration
        let candidates = analysis.mixOutCandidates
            .filter { $0.time > 0 && $0.time <= contentEnd }
            .sorted { weightedOutScore($0) > weightedOutScore($1) }
        for candidate in candidates {
            if discardedMusic(analysis, from: candidate.time, to: contentEnd) <= maximumDiscardedMusic {
                return candidate.time
            }
        }
        if analysis.mixOutTime > 0,
           discardedMusic(analysis, from: analysis.mixOutTime, to: contentEnd) <= maximumDiscardedMusic {
            return analysis.mixOutTime
        }
        return contentEnd
    }

    private static func discardedMusic(
        _ analysis: AutomixTrackAnalysis,
        from start: TimeInterval,
        to end: TimeInterval
    ) -> TimeInterval {
        let curve = analysis.energyCurve
        guard curve.count > 1, end > start else { return max(0, end - start) }
        let energies = curve.map(\.energy).filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !energies.isEmpty else { return max(0, end - start) }
        let reference = energies[Int(Double(energies.count - 1) * 0.85)]
        guard reference > 0 else { return 0 }
        let sampleSeconds = (curve.last!.time - curve.first!.time) / Double(curve.count - 1)
        return curve.reduce(0) { result, point in
            result + (point.time >= start && point.time <= end && point.energy >= reference * 0.1
                      ? sampleSeconds : 0)
        }
    }

    private static func shouldUseLongBlend(
        outgoing: AutomixTrackAnalysis,
        incoming: AutomixTrackAnalysis,
        stretch: Double
    ) -> Bool {
        let keyMismatch = outgoing.keyConfidence >= 0.25 && incoming.keyConfidence >= 0.25 &&
            !harmonicallyCompatible(outgoing.key, incoming.key)
        return abs(1 - stretch) > 0.07 || keyMismatch
    }

    private static func vocalConflict(
        _ outgoing: AutomixTrackAnalysis,
        _ incoming: AutomixTrackAnalysis
    ) -> Bool {
        outgoing.vocalProbability >= 0.62 && incoming.vocalProbability >= 0.62
    }

    private static func bassSwapFraction(
        outgoing: AutomixTrackAnalysis,
        incoming: AutomixTrackAnalysis
    ) -> Double {
        guard !outgoing.lowEnergyCurve.isEmpty || !incoming.lowEnergyCurve.isEmpty else { return 0.7 }
        return 0.65
    }

    private static func nearestAtOrBefore(
        _ values: [TimeInterval],
        target: TimeInterval,
        minimum: TimeInterval
    ) -> TimeInterval? {
        values.filter { $0.isFinite && $0 >= minimum && $0 <= target }.max()
    }

    private static func clampedFade(_ fade: TimeInterval, duration: TimeInterval) -> TimeInterval {
        min(min(max(fade, 1), 12), duration / 3)
    }

    private static func weightedOutScore(_ cue: AutomixCuePoint) -> Double {
        let weights = ["energy_cliff": 0.95, "interior_mix_out": 0.95,
                       "outro_start": 0.9, "content_end": 0.75]
        return cue.score + (weights[cue.type] ?? 0)
    }

    private static func harmonicallyCompatible(_ left: String, _ right: String) -> Bool {
        let names = ["C": 0, "C#": 1, "C♯": 1, "D♭": 1, "D": 2, "D#": 3, "D♯": 3, "E♭": 3,
                     "E": 4, "F": 5, "F#": 6, "G♭": 6, "G": 7, "G#": 8,
                     "A♭": 8, "A": 9, "A#": 10, "A♯": 10, "B♭": 10, "B": 11]
        let leftParts = left.split(separator: " ").map(String.init)
        let rightParts = right.split(separator: " ").map(String.init)
        guard let leftValue = leftParts.first.flatMap({ names[$0] }),
              let rightValue = rightParts.first.flatMap({ names[$0] }) else { return false }
        let distance = min((leftValue - rightValue + 12) % 12, (rightValue - leftValue + 12) % 12)
        let differentMode = leftParts.count > 1 && rightParts.count > 1 && leftParts[1] != rightParts[1]
        return differentMode ? distance <= 1 : (distance <= 2 || distance == 5)
    }
}
