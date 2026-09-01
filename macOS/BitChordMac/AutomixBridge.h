#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs BitChord's shared Kotlin/native whole-track DSP analyzer and returns
/// its portable JSON representation. Samples are contiguous mono Float32 PCM.
FOUNDATION_EXPORT NSData * _Nullable BCAnalyzeAudio(
    const float * _Nullable samples,
    NSUInteger count,
    double sampleRate,
    double duration
);

/// Shared windowed-sinc converter used by the Kotlin analyzer before DSP.
FOUNDATION_EXPORT NSData * _Nullable BCResampleAudio(
    const float * _Nullable samples,
    NSUInteger count,
    double inputRate,
    double outputRate
);

NS_ASSUME_NONNULL_END
