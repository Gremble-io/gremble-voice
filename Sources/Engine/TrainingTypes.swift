import Foundation

#if TRAINING_FEATURES

// MARK: - Training Decision

/// Explicit user decision about whether a session should be exported as a training pair.
public enum TrainingDecision: String, Codable, Sendable {
    case include   // user explicitly approved — goes to export
    case exclude   // user explicitly rejected — never exports
    case fix       // user provided correctedText — exports with correction
}

// MARK: - Capture Mode

/// How this dictation session was captured.
public enum CaptureMode: String, Codable, Sendable {
    case ambient   // regular dictation use
    case script    // user reading a prepared reference script
}

// MARK: - Score Card

/// Per-dimension quality ratings for a training pair.
/// All fields are optional — users can rate any subset of dimensions.
public struct ScoreCard: Codable, Sendable {
    public var fillersRemoved: Bool?
    public var punctuationCorrect: Bool?
    public var intentPreserved: Bool?
    public var overallClean: Bool?

    /// Number of dimensions explicitly rated (0–3, excluding overallClean).
    public var ratedDimensionCount: Int {
        [fillersRemoved, punctuationCorrect, intentPreserved].compactMap { $0 }.count
    }

    public init(
        fillersRemoved: Bool? = nil,
        punctuationCorrect: Bool? = nil,
        intentPreserved: Bool? = nil,
        overallClean: Bool? = nil
    ) {
        self.fillersRemoved = fillersRemoved
        self.punctuationCorrect = punctuationCorrect
        self.intentPreserved = intentPreserved
        self.overallClean = overallClean
    }
}

// MARK: - Training Prompt

/// Versioned system prompt used for LoRA training pairs.
///
/// IMPORTANT: Production inference MUST use the same version string that was
/// used to assemble the training data. Check `system_prompt_version` in JSONL
/// metadata to verify alignment before deploying a fine-tuned model.
public enum TrainingPrompt {
    public static let v1 = "Clean the following dictation transcription by removing filler words, fixing punctuation, handling self-corrections, and preserving the speaker's intent and tone."
    public static let current = v1
    public static let currentVersion = "1"
}

#endif
