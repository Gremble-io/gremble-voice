import Foundation
import Accelerate

/// Computes audio level metrics using vDSP for SIMD-accelerated performance.
public enum AudioLevelMeter {

    /// Root-mean-square level of `samples`. Returns 0 for empty input.
    ///
    /// Uses `vDSP_rmsqv` — equivalent to `sqrt(sum(x²) / n)`.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_rmsqv(samples, 1, &result, vDSP_Length(samples.count))
        return result
    }

    /// Peak absolute value of `samples`. Returns 0 for empty input.
    public static func peak(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_maxmgv(samples, 1, &result, vDSP_Length(samples.count))
        return result
    }

    /// Convert a linear amplitude (0–1) to decibels full scale (dBFS).
    ///
    /// Returns `-160` for values at or below zero.
    public static func toDBFS(_ amplitude: Float) -> Float {
        guard amplitude > 0 else { return -160 }
        return 20 * log10f(amplitude)
    }
}
