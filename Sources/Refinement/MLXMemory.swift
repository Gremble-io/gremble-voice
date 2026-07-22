import Foundation
import MLX

/// Central control over MLX's Metal buffer cache.
///
/// MLX retains freed Metal buffers in an allocator cache so subsequent
/// inference can reuse them. Nothing trims that cache when a model container
/// is released — repeated load/generate/unload cycles therefore ratchet wired
/// memory upward until the cache is bounded or cleared explicitly.
///
/// Host apps should call `setCacheLimit(megabytes:)` once at startup and
/// `clearCache()` after bursty batch work (e.g. post-session transcript
/// refinement) whose working set shouldn't stay resident.
public enum MLXMemory {

    /// Bound the Metal buffer cache. Buffers beyond the limit are returned to
    /// the OS on free instead of being retained for reuse.
    public static func setCacheLimit(megabytes: Int) {
        MLX.GPU.set(cacheLimit: megabytes * 1024 * 1024)
    }

    /// Release all cached Metal buffers back to the OS immediately.
    /// Safe to call at any time; the next inference simply re-allocates.
    public static func clearCache() {
        MLX.GPU.clearCache()
    }

    /// Current MLX memory readings in bytes: live tensor memory, cache size,
    /// and the peak since process start. Useful for diagnostics/logging.
    public static func snapshot() -> (active: Int, cache: Int, peak: Int) {
        let s = MLX.GPU.snapshot()
        return (active: s.activeMemory, cache: s.cacheMemory, peak: s.peakMemory)
    }
}
