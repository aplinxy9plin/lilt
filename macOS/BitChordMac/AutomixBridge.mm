#import "AutomixBridge.h"

#include <cmath>
#include <vector>

#include "../../native/analyzer/audio_analysis.h"
#include "../../native/analyzer/resampler.h"

namespace {

NSNumber *Number(double value) {
    return std::isfinite(value) ? @(value) : @0;
}

NSArray *Numbers(const std::vector<double>& values) {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:values.size()];
    for (double value : values) {
        if (std::isfinite(value)) [result addObject:@(value)];
    }
    return result;
}

NSArray *EnergyCurve(const std::vector<bitchord::smart::EnergyPoint>& values) {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:values.size()];
    for (const auto& value : values) {
        if (!std::isfinite(value.time) || !std::isfinite(value.energy)) continue;
        [result addObject:@{ @"t": @(value.time), @"e": @(value.energy) }];
    }
    return result;
}

NSArray *CuePoints(const std::vector<bitchord::smart::MixCuePoint>& values) {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:values.size()];
    for (const auto& value : values) {
        if (!std::isfinite(value.time)) continue;
        NSString *type = [NSString stringWithUTF8String:value.type.c_str()] ?: @"";
        [result addObject:@{
            @"t": @(value.time),
            @"s": Number(value.score),
            @"y": type,
        }];
    }
    return result;
}

}  // namespace

NSData *BCAnalyzeAudio(
    const float *samples,
    NSUInteger count,
    double sampleRate,
    double duration
) {
    if (samples == nullptr || count == 0 || sampleRate <= 0 || duration <= 0) return nil;
    std::vector<float> input(samples, samples + count);
    const auto analysis = bitchord::smart::AnalyzeAudio(input, sampleRate, duration);
    NSString *key = [NSString stringWithUTF8String:analysis.key.c_str()] ?: @"";
    NSDictionary *payload = @{
        @"duration": Number(analysis.duration),
        @"bpm": Number(analysis.bpm),
        @"beatInterval": Number(analysis.beat_interval),
        @"firstBeat": Number(analysis.first_beat),
        @"beatConfidence": Number(analysis.beat_confidence),
        @"beats": Numbers(analysis.beats),
        @"downbeats": Numbers(analysis.downbeats),
        @"phraseBoundaries": Numbers(analysis.phrase_boundaries),
        @"key": key,
        @"keyConfidence": Number(analysis.key_confidence),
        @"audibleStartTime": Number(analysis.audible_start_time),
        @"pickupTime": Number(analysis.pickup_time),
        @"introEndTime": Number(analysis.intro_end_time),
        @"outroStartTime": Number(analysis.outro_start_time),
        @"contentEndTime": Number(analysis.content_end_time),
        @"mixInTime": Number(analysis.mix_in_time),
        @"mixOutTime": Number(analysis.mix_out_time),
        @"vocalProbability": Number(analysis.vocal_probability),
        @"vocalActivityMask": Numbers(analysis.vocal_activity_mask),
        @"energyCurve": EnergyCurve(analysis.energy_curve),
        @"lowEnergyCurve": EnergyCurve(analysis.low_energy_curve),
        @"mixInCandidates": CuePoints(analysis.mix_in_candidates),
        @"mixOutCandidates": CuePoints(analysis.mix_out_candidates),
    };
    return [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
}

NSData *BCResampleAudio(
    const float *samples,
    NSUInteger count,
    double inputRate,
    double outputRate
) {
    if (samples == nullptr || count == 0 || inputRate <= 0 || outputRate <= 0) return nil;
    std::vector<float> input(samples, samples + count);
    const auto output = bitchord::smart::Resample(input, inputRate, outputRate);
    if (output.empty()) return nil;
    return [NSData dataWithBytes:output.data() length:output.size() * sizeof(float)];
}
