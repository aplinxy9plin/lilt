import AVFoundation
import AudioToolbox
import Foundation
import MediaToolbox

enum EqualizerPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case flat
    case bassBoost
    case electronic
    case rock
    case vocal
    case acoustic
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: "Flat"
        case .bassBoost: "Bass Boost"
        case .electronic: "Electronic"
        case .rock: "Rock"
        case .vocal: "Vocal"
        case .acoustic: "Acoustic"
        case .custom: "Custom"
        }
    }

    fileprivate var values: (preamp: Float, gains: [Float]) {
        switch self {
        case .flat:
            (0, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        case .bassBoost:
            (-6, [6, 5, 4, 2, 0, -1, -1, 0, 1, 2])
        case .electronic:
            (-5, [5, 4, 1, -2, -2, 0, 2, 3, 4, 5])
        case .rock:
            (-4, [4, 3, 1, -1, -2, 0, 2, 3, 4, 4])
        case .vocal:
            (-4, [-3, -2, -1, 1, 3, 4, 3, 1, -1, -2])
        case .acoustic:
            (-3, [3, 2, 1, 0, 1, 2, 3, 3, 2, 1])
        case .custom:
            (0, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        }
    }
}

struct EqualizerSnapshot: Equatable, Sendable {
    static let frequencies: [Float] = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    static let gainRange: ClosedRange<Float> = -12...12
    static let preampRange: ClosedRange<Float> = -12...0
    static let disabled = EqualizerSnapshot(enabled: false, preampDB: 0, gainsDB: [])

    let enabled: Bool
    let preampDB: Float
    let gainsDB: [Float]

    init(enabled: Bool, preampDB: Float, gainsDB: [Float]) {
        self.enabled = enabled
        self.preampDB = min(max(preampDB, Self.preampRange.lowerBound), Self.preampRange.upperBound)
        let normalized = Array(gainsDB.prefix(Self.frequencies.count))
        self.gainsDB = (normalized + repeatElement(0, count: max(0, Self.frequencies.count - normalized.count)))
            .map { min(max($0, Self.gainRange.lowerBound), Self.gainRange.upperBound) }
    }
}

@MainActor
final class EqualizerSettings: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            notifyChange()
        }
    }
    @Published private(set) var preset: EqualizerPreset
    @Published private(set) var preampDB: Float
    @Published private(set) var bandGainsDB: [Float]

    var onChange: ((EqualizerSnapshot) -> Void)?

    private static let enabledKey = "mac_equalizer_enabled"
    private static let presetKey = "mac_equalizer_preset"
    private static let preampKey = "mac_equalizer_preamp"
    private static let gainsKey = "mac_equalizer_gains"
    private let defaults: UserDefaults
    private var applyingValues = false

    var snapshot: EqualizerSnapshot {
        EqualizerSnapshot(enabled: isEnabled, preampDB: preampDB, gainsDB: bandGainsDB)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
        preset = defaults.string(forKey: Self.presetKey)
            .flatMap(EqualizerPreset.init(rawValue:)) ?? .flat
        preampDB = Float(defaults.object(forKey: Self.preampKey) as? Double ?? 0)
        let stored = defaults.array(forKey: Self.gainsKey) as? [NSNumber]
        bandGainsDB = stored?.map(\.floatValue) ?? EqualizerPreset.flat.values.gains

        let normalized = EqualizerSnapshot(enabled: isEnabled, preampDB: preampDB, gainsDB: bandGainsDB)
        preampDB = normalized.preampDB
        bandGainsDB = normalized.gainsDB
    }

    func selectPreset(_ value: EqualizerPreset) {
        guard value != .custom else { return }
        let values = value.values
        apply(preset: value, preampDB: values.preamp, gainsDB: values.gains, enabled: isEnabled)
    }

    func setPreamp(_ value: Float) {
        let clamped = min(max(value, EqualizerSnapshot.preampRange.lowerBound), EqualizerSnapshot.preampRange.upperBound)
        guard preampDB != clamped else { return }
        applyingValues = true
        preampDB = clamped
        preset = .custom
        applyingValues = false
        persistShape()
        notifyChange()
    }

    func setBandGain(_ value: Float, at index: Int) {
        guard bandGainsDB.indices.contains(index) else { return }
        let clamped = min(max(value, EqualizerSnapshot.gainRange.lowerBound), EqualizerSnapshot.gainRange.upperBound)
        guard bandGainsDB[index] != clamped else { return }
        applyingValues = true
        bandGainsDB[index] = clamped
        preset = .custom
        applyingValues = false
        persistShape()
        notifyChange()
    }

    func applyPortable(enabled: Bool, presetRaw: String, preampDB: Float, gainsDB: [Float]) {
        let preset = EqualizerPreset(rawValue: presetRaw) ?? .custom
        apply(preset: preset, preampDB: preampDB, gainsDB: gainsDB, enabled: enabled)
    }

    func applyCurrentSettings() {
        notifyChange()
    }

    private func apply(preset: EqualizerPreset, preampDB: Float, gainsDB: [Float], enabled: Bool) {
        let normalized = EqualizerSnapshot(enabled: enabled, preampDB: preampDB, gainsDB: gainsDB)
        applyingValues = true
        self.preset = preset
        self.preampDB = normalized.preampDB
        bandGainsDB = normalized.gainsDB
        isEnabled = enabled
        applyingValues = false
        persistShape()
        defaults.set(enabled, forKey: Self.enabledKey)
        notifyChange()
    }

    private func persistShape() {
        guard !applyingValues else { return }
        defaults.set(preset.rawValue, forKey: Self.presetKey)
        defaults.set(Double(preampDB), forKey: Self.preampKey)
        defaults.set(bandGainsDB.map(Double.init), forKey: Self.gainsKey)
    }

    private func notifyChange() {
        guard !applyingValues else { return }
        onChange?(snapshot)
    }
}

struct EqualizerBiquadCoefficients: Equatable, Sendable {
    let b0: Float
    let b1: Float
    let b2: Float
    let a1: Float
    let a2: Float

    static let identity = EqualizerBiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    static func peaking(frequency: Float, gainDB: Float, sampleRate: Float, q: Float = 1.4) -> Self {
        guard abs(gainDB) > 0.0001, sampleRate > 0 else { return .identity }
        let frequency = min(max(frequency, 10), sampleRate * 0.45)
        let amplitude = powf(10, gainDB / 40)
        let omega = 2 * Float.pi * frequency / sampleRate
        let alpha = sinf(omega) / (2 * q)
        let cosine = cosf(omega)
        let a0 = 1 + alpha / amplitude
        return Self(
            b0: (1 + alpha * amplitude) / a0,
            b1: (-2 * cosine) / a0,
            b2: (1 - alpha * amplitude) / a0,
            a1: (-2 * cosine) / a0,
            a2: (1 - alpha / amplitude) / a0
        )
    }
}

private struct EqualizerBiquadState {
    var z1: Float = 0
    var z2: Float = 0

    mutating func process(_ input: Float, using coefficient: EqualizerBiquadCoefficients) -> Float {
        let output = coefficient.b0 * input + z1
        z1 = coefficient.b1 * input - coefficient.a1 * output + z2
        z2 = coefficient.b2 * input - coefficient.a2 * output
        return output
    }
}

final class EqualizerDSP {
    private let snapshot: EqualizerSnapshot
    private var preamp: Float = 1
    private var coefficients: [EqualizerBiquadCoefficients] = []
    private var states: [EqualizerBiquadState] = []
    private var channels = 0
    private var supportsFloat32 = false
    private var nonInterleaved = false

    init(snapshot: EqualizerSnapshot) {
        self.snapshot = snapshot
    }

    func prepare(sampleRate: Double, channelCount: Int) {
        channels = max(channelCount, 1)
        preamp = powf(10, snapshot.preampDB / 20)
        coefficients = zip(EqualizerSnapshot.frequencies, snapshot.gainsDB).map {
            EqualizerBiquadCoefficients.peaking(
                frequency: $0.0,
                gainDB: $0.1,
                sampleRate: Float(sampleRate)
            )
        }
        states = Array(
            repeating: EqualizerBiquadState(),
            count: channels * EqualizerSnapshot.frequencies.count
        )
    }

    func prepare(format: AudioStreamBasicDescription) {
        supportsFloat32 = format.mFormatID == kAudioFormatLinearPCM
            && format.mBitsPerChannel == 32
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        prepare(sampleRate: format.mSampleRate, channelCount: Int(format.mChannelsPerFrame))
    }

    func reset() {
        states = Array(repeating: EqualizerBiquadState(), count: states.count)
    }

    func processInterleaved(_ samples: inout [Float], channelCount: Int) {
        guard snapshot.enabled, channelCount > 0 else { return }
        if channels != channelCount || states.isEmpty {
            prepare(sampleRate: 44_100, channelCount: channelCount)
        }
        samples.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            process(base: base, frames: pointer.count / channelCount, channelsInBuffer: channelCount, channelOffset: 0)
        }
    }

    func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard snapshot.enabled, supportsFloat32, frames > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var channelOffset = 0
        for buffer in buffers {
            let bufferChannels = max(Int(buffer.mNumberChannels), 1)
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                channelOffset += bufferChannels
                continue
            }
            process(
                base: data,
                frames: frames,
                channelsInBuffer: nonInterleaved ? bufferChannels : channels,
                channelOffset: nonInterleaved ? channelOffset : 0
            )
            channelOffset += bufferChannels
        }
    }

    private func process(base: UnsafeMutablePointer<Float>, frames: Int, channelsInBuffer: Int, channelOffset: Int) {
        let bandCount = coefficients.count
        guard bandCount > 0, channelsInBuffer > 0 else { return }
        for frame in 0..<frames {
            for localChannel in 0..<channelsInBuffer {
                let channel = min(channelOffset + localChannel, channels - 1)
                let sampleIndex = frame * channelsInBuffer + localChannel
                var sample = base[sampleIndex] * preamp
                let stateOffset = channel * bandCount
                for band in 0..<bandCount {
                    sample = states[stateOffset + band].process(sample, using: coefficients[band])
                }
                base[sampleIndex] = sample
            }
        }
    }
}

/// Kotlin-compatible stereo widening and delayed low-passed crossfeed.
///
/// This is intentionally a decoded-PCM effect instead of an OS virtualizer:
/// it behaves the same for YouTube streams, downloads and imported files and
/// cannot be swallowed by a device-specific output chain. Mono and surround
/// material pass through unchanged because mid/side widening only has a clear
/// meaning for two-channel audio.
final class SpatialAudioDSP {
    private let enabled: Bool
    private let widthGain: Float = 2.5
    private let outputGain: Float = 0.82
    private let crossfeedGain: Float = 0.2
    private let lowpassCoefficient: Float = 0.3
    private let delaySeconds = 0.015

    private var supportsFloat32 = false
    private var nonInterleaved = false
    private var channels = 0
    private var sampleRate = 0.0
    private var delayLeft: [Float] = []
    private var delayRight: [Float] = []
    private var delayIndex = 0
    private var lowpassLeft: Float = 0
    private var lowpassRight: Float = 0

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func prepare(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        channels = channelCount
        guard enabled, channelCount == 2, sampleRate > 0 else {
            delayLeft = []
            delayRight = []
            reset()
            return
        }
        let delaySamples = max(1, Int((sampleRate * delaySeconds).rounded()))
        delayLeft = Array(repeating: 0, count: delaySamples)
        delayRight = Array(repeating: 0, count: delaySamples)
        reset()
    }

    func prepare(format: AudioStreamBasicDescription) {
        supportsFloat32 = format.mFormatID == kAudioFormatLinearPCM
            && format.mBitsPerChannel == 32
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        prepare(sampleRate: format.mSampleRate, channelCount: Int(format.mChannelsPerFrame))
    }

    func reset() {
        delayLeft = Array(repeating: 0, count: delayLeft.count)
        delayRight = Array(repeating: 0, count: delayRight.count)
        delayIndex = 0
        lowpassLeft = 0
        lowpassRight = 0
    }

    func processInterleaved(_ samples: inout [Float], channelCount: Int) {
        guard enabled, channelCount == 2 else { return }
        if channels != channelCount || delayLeft.isEmpty {
            prepare(sampleRate: sampleRate > 0 ? sampleRate : 44_100, channelCount: channelCount)
        }
        samples.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            processInterleaved(base, frames: pointer.count / channelCount)
        }
    }

    func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard enabled, supportsFloat32, channels == 2, frames > 0, !delayLeft.isEmpty else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        if nonInterleaved {
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
            processPlanar(left: left, right: right, frames: frames)
        } else {
            guard let buffer = buffers.first,
                  buffer.mNumberChannels == 2,
                  let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
            processInterleaved(data, frames: frames)
        }
    }

    private func processInterleaved(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        for frame in 0..<frames {
            let index = frame * 2
            let output = processFrame(left: samples[index], right: samples[index + 1])
            samples[index] = output.left
            samples[index + 1] = output.right
        }
    }

    private func processPlanar(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        for frame in 0..<frames {
            let output = processFrame(left: left[frame], right: right[frame])
            left[frame] = output.left
            right[frame] = output.right
        }
    }

    private func processFrame(left: Float, right: Float) -> (left: Float, right: Float) {
        let mid = (left + right) * 0.5
        let side = (left - right) * 0.5 * widthGain
        var widenedLeft = mid + side
        var widenedRight = mid - side

        let delayedRight = delayRight[delayIndex]
        let delayedLeft = delayLeft[delayIndex]
        lowpassLeft += lowpassCoefficient * (delayedRight - lowpassLeft)
        lowpassRight += lowpassCoefficient * (delayedLeft - lowpassRight)
        widenedLeft += lowpassLeft * crossfeedGain
        widenedRight += lowpassRight * crossfeedGain

        delayLeft[delayIndex] = left
        delayRight[delayIndex] = right
        delayIndex = (delayIndex + 1) % delayLeft.count

        return (
            min(max(widenedLeft * outputGain, -1), 1),
            min(max(widenedRight * outputGain, -1), 1)
        )
    }
}

private final class AudioEffectsDSP {
    private let equalizer: EqualizerDSP
    private let spatial: SpatialAudioDSP

    init(equalizer: EqualizerSnapshot, spatialAudioEnabled: Bool) {
        self.equalizer = EqualizerDSP(snapshot: equalizer)
        spatial = SpatialAudioDSP(enabled: spatialAudioEnabled)
    }

    func prepare(format: AudioStreamBasicDescription) {
        spatial.prepare(format: format)
        equalizer.prepare(format: format)
    }

    func reset() {
        spatial.reset()
        equalizer.reset()
    }

    func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        spatial.process(bufferList, frames: frames)
        equalizer.process(bufferList, frames: frames)
    }
}

enum EqualizerAudioMix {
    static func make(snapshot: EqualizerSnapshot, track: AVAssetTrack) -> AVAudioMix? {
        make(equalizer: snapshot, spatialAudioEnabled: false, track: track)
    }

    static func make(
        equalizer snapshot: EqualizerSnapshot,
        spatialAudioEnabled: Bool,
        track: AVAssetTrack
    ) -> AVAudioMix? {
        guard snapshot.enabled || spatialAudioEnabled,
              let tap = makeTap(equalizer: snapshot, spatialAudioEnabled: spatialAudioEnabled) else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    private static func makeTap(
        equalizer: EqualizerSnapshot,
        spatialAudioEnabled: Bool
    ) -> MTAudioProcessingTap? {
        let processor = AudioEffectsDSP(
            equalizer: equalizer,
            spatialAudioEnabled: spatialAudioEnabled
        )
        let retained = Unmanaged.passRetained(processor)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained.toOpaque(),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<AudioEffectsDSP>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let processor = Unmanaged<AudioEffectsDSP>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                processor.prepare(format: format.pointee)
            },
            unprepare: { tap in
                let processor = Unmanaged<AudioEffectsDSP>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                processor.reset()
            },
            process: { tap, frameCount, _, bufferList, framesOut, flagsOut in
                var sourceFlags = MTAudioProcessingTapFlags()
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap,
                    frameCount,
                    bufferList,
                    &sourceFlags,
                    nil,
                    framesOut
                )
                flagsOut.pointee = sourceFlags
                guard status == noErr else {
                    framesOut.pointee = 0
                    return
                }
                let processor = Unmanaged<AudioEffectsDSP>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                if sourceFlags & UInt32(kMTAudioProcessingTapFlag_StartOfStream) != 0 {
                    processor.reset()
                }
                processor.process(bufferList, frames: Int(framesOut.pointee))
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tap
        )
        if status != noErr {
            retained.release()
            return nil
        }
        return tap
    }
}
