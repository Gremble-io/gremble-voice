import Foundation

/// Identifies a speaker in a diarization session.
///
/// Wraps the diarizer's integer slot index (0–3 for Sortformer's 4 fixed tracks)
/// with an optional human-readable name set via speaker enrollment.
public struct SpeakerLabel: Sendable, Hashable, Codable {
    /// Zero-based speaker slot in the diarizer output.
    public let index: Int

    /// Optional enrolled name (e.g. "Alice"). Nil if the speaker was not pre-enrolled.
    public let name: String?

    /// Returns `name` if set, otherwise "Speaker 1", "Speaker 2", etc.
    public var displayName: String {
        name ?? "Speaker \(index + 1)"
    }

    public init(index: Int, name: String? = nil) {
        self.index = index
        self.name = name
    }
}
