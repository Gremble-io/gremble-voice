import Foundation

/// A partial result from streaming speaker diarization.
///
/// Mirrors the confirmed/tentative pattern of `StreamingTextUpdate`:
/// finalized segments are stable across consecutive updates, while
/// tentative segments may change as the diarizer receives more audio.
public struct StreamingDiarizationUpdate: Sendable {
    /// Segments that have been confirmed and will not change.
    public let finalizedSegments: [DiarizedSegment]

    /// Segments still being refined — may change in the next update.
    public let tentativeSegments: [DiarizedSegment]

    public init(
        finalizedSegments: [DiarizedSegment] = [],
        tentativeSegments: [DiarizedSegment] = []
    ) {
        self.finalizedSegments = finalizedSegments
        self.tentativeSegments = tentativeSegments
    }
}
