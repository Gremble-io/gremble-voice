import Foundation

// MARK: - Session

/// A complete record of one dictation session — every pipeline stage, its timing,
/// the text at each step, and any tags the user applied afterward.
public struct GrembleSession: Identifiable, Sendable, Codable {
    public let id: UUID
    public let startedAt: Date
    /// Wall-clock time the recording button was held, in seconds.
    public let recordingDuration: TimeInterval
    /// Frontmost app name at the moment stopRecording() was called.
    public let activeApp: String?
    /// Bundle ID of the frontmost app.
    public let activeBundleID: String?
    /// Human-readable engine name, e.g. "Parakeet v3", "Whisper base.en".
    public let asrEngine: String
    /// Human-readable refiner name, e.g. "Ollama gemma3:4b", "Claude haiku", "none".
    public let refiner: String
    /// True ASR output BEFORE ArtifactStripper runs. Used as training input so the
    /// model learns to handle real ASR artifacts (brackets, hallucinations, etc.).
    public let rawAsrOutput: String
    /// ASR output after artifact stripping. Used in Debug Log and dictionary processing.
    public let rawTranscript: String
    /// After DictionaryProcessor pass.
    public let dictionaryProcessed: String
    /// After LLM refinement (or same as dictionaryProcessed if refinement off/failed).
    public let refinedText: String
    /// What was actually pasted into the app. Set by DictationController after TextInjector runs.
    public var injectedText: String
    /// Ordered log of every pipeline event with timing.
    public let events: [PipelineEvent]
    /// User-applied tags for issue tracking.
    public var tags: [SessionTag]
    /// Free-text notes added in the Debug Log window.
    public var notes: String
    /// True when RefinementValidator rejected the LLM output and refinedText fell back to dictText.
    public let isRefinementFallback: Bool
    /// Reason for fallback: "length_ratio" / "word_overlap" / "refiner_error".
    public let fallbackReason: String?

#if TRAINING_FEATURES
    /// User-corrected gold output for Fix & Include training pairs.
    public var correctedText: String?
    /// Explicit training decision — nil while HUD is active, set to .exclude on auto-dismiss.
    public var trainingDecision: TrainingDecision?
    /// Per-dimension quality ratings from the HUD or Debug Log review.
    public var scoreCard: ScoreCard?
    /// Whether this session was captured in Script Mode or ambient dictation.
    public var captureMode: CaptureMode
    /// The reference script text used in Script Mode. nil for ambient sessions.
    public var scriptReference: String?
#endif

    // MARK: - Init

#if TRAINING_FEATURES
    public init(
        id: UUID = UUID(),
        startedAt: Date,
        recordingDuration: TimeInterval,
        activeApp: String?,
        activeBundleID: String?,
        asrEngine: String,
        refiner: String,
        rawAsrOutput: String = "",
        rawTranscript: String,
        dictionaryProcessed: String,
        refinedText: String,
        injectedText: String = "",
        events: [PipelineEvent],
        tags: [SessionTag] = [],
        notes: String = "",
        isRefinementFallback: Bool = false,
        fallbackReason: String? = nil,
        correctedText: String? = nil,
        trainingDecision: TrainingDecision? = nil,
        scoreCard: ScoreCard? = nil,
        captureMode: CaptureMode = .ambient,
        scriptReference: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.recordingDuration = recordingDuration
        self.activeApp = activeApp
        self.activeBundleID = activeBundleID
        self.asrEngine = asrEngine
        self.refiner = refiner
        self.rawAsrOutput = rawAsrOutput
        self.rawTranscript = rawTranscript
        self.dictionaryProcessed = dictionaryProcessed
        self.refinedText = refinedText
        self.injectedText = injectedText
        self.events = events
        self.tags = tags
        self.notes = notes
        self.isRefinementFallback = isRefinementFallback
        self.fallbackReason = fallbackReason
        self.correctedText = correctedText
        self.trainingDecision = trainingDecision
        self.scoreCard = scoreCard
        self.captureMode = captureMode
        self.scriptReference = scriptReference
    }
#else
    public init(
        id: UUID = UUID(),
        startedAt: Date,
        recordingDuration: TimeInterval,
        activeApp: String?,
        activeBundleID: String?,
        asrEngine: String,
        refiner: String,
        rawAsrOutput: String = "",
        rawTranscript: String,
        dictionaryProcessed: String,
        refinedText: String,
        injectedText: String = "",
        events: [PipelineEvent],
        tags: [SessionTag] = [],
        notes: String = "",
        isRefinementFallback: Bool = false,
        fallbackReason: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.recordingDuration = recordingDuration
        self.activeApp = activeApp
        self.activeBundleID = activeBundleID
        self.asrEngine = asrEngine
        self.refiner = refiner
        self.rawAsrOutput = rawAsrOutput
        self.rawTranscript = rawTranscript
        self.dictionaryProcessed = dictionaryProcessed
        self.refinedText = refinedText
        self.injectedText = injectedText
        self.events = events
        self.tags = tags
        self.notes = notes
        self.isRefinementFallback = isRefinementFallback
        self.fallbackReason = fallbackReason
    }
#endif

    // MARK: - Codable
    //
    // Explicit implementation required because #if TRAINING_FEATURES guards around
    // struct members prevent auto-synthesis of CodingKeys. Without this, decoding a
    // session serialized with TRAINING_FEATURES in a build without the flag would
    // crash with DecodingError.keyNotFound.

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, recordingDuration
        case activeApp, activeBundleID
        case asrEngine, refiner
        case rawAsrOutput, rawTranscript, dictionaryProcessed, refinedText, injectedText
        case events, tags, notes
        case isRefinementFallback, fallbackReason
#if TRAINING_FEATURES
        case correctedText, trainingDecision, scoreCard, captureMode, scriptReference
#endif
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(recordingDuration, forKey: .recordingDuration)
        try c.encodeIfPresent(activeApp, forKey: .activeApp)
        try c.encodeIfPresent(activeBundleID, forKey: .activeBundleID)
        try c.encode(asrEngine, forKey: .asrEngine)
        try c.encode(refiner, forKey: .refiner)
        try c.encode(rawAsrOutput, forKey: .rawAsrOutput)
        try c.encode(rawTranscript, forKey: .rawTranscript)
        try c.encode(dictionaryProcessed, forKey: .dictionaryProcessed)
        try c.encode(refinedText, forKey: .refinedText)
        try c.encode(injectedText, forKey: .injectedText)
        try c.encode(events, forKey: .events)
        try c.encode(tags, forKey: .tags)
        try c.encode(notes, forKey: .notes)
        try c.encode(isRefinementFallback, forKey: .isRefinementFallback)
        try c.encodeIfPresent(fallbackReason, forKey: .fallbackReason)
#if TRAINING_FEATURES
        try c.encodeIfPresent(correctedText, forKey: .correctedText)
        try c.encodeIfPresent(trainingDecision, forKey: .trainingDecision)
        try c.encodeIfPresent(scoreCard, forKey: .scoreCard)
        try c.encode(captureMode, forKey: .captureMode)
        try c.encodeIfPresent(scriptReference, forKey: .scriptReference)
#endif
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        recordingDuration = try c.decode(TimeInterval.self, forKey: .recordingDuration)
        activeApp = try c.decodeIfPresent(String.self, forKey: .activeApp)
        activeBundleID = try c.decodeIfPresent(String.self, forKey: .activeBundleID)
        asrEngine = try c.decode(String.self, forKey: .asrEngine)
        refiner = try c.decode(String.self, forKey: .refiner)
        // rawAsrOutput is new — absent in sessions saved by old builds; default to ""
        rawAsrOutput = (try? c.decode(String.self, forKey: .rawAsrOutput)) ?? ""
        rawTranscript = try c.decode(String.self, forKey: .rawTranscript)
        dictionaryProcessed = try c.decode(String.self, forKey: .dictionaryProcessed)
        refinedText = try c.decode(String.self, forKey: .refinedText)
        injectedText = (try? c.decode(String.self, forKey: .injectedText)) ?? ""
        events = try c.decode([PipelineEvent].self, forKey: .events)
        tags = (try? c.decode([SessionTag].self, forKey: .tags)) ?? []
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
        // isRefinementFallback / fallbackReason are new — default for old sessions
        isRefinementFallback = (try? c.decode(Bool.self, forKey: .isRefinementFallback)) ?? false
        fallbackReason = try? c.decodeIfPresent(String.self, forKey: .fallbackReason)
#if TRAINING_FEATURES
        correctedText = try? c.decodeIfPresent(String.self, forKey: .correctedText)
        trainingDecision = try? c.decodeIfPresent(TrainingDecision.self, forKey: .trainingDecision)
        scoreCard = try? c.decodeIfPresent(ScoreCard.self, forKey: .scoreCard)
        captureMode = (try? c.decode(CaptureMode.self, forKey: .captureMode)) ?? .ambient
        scriptReference = try? c.decodeIfPresent(String.self, forKey: .scriptReference)
#endif
    }

    // MARK: - Computed

    /// Convenience: total pipeline duration from recordingStarted to final event.
    public var totalPipelineMs: Int {
        guard let first = events.first, let last = events.last else { return 0 }
        return Int(last.timestamp.timeIntervalSince(first.timestamp) * 1000)
    }

    /// Duration of a specific stage, in milliseconds.
    public func duration(of stage: PipelineStage) -> Int? {
        events.first { $0.stage == stage }?.durationMs
    }
}

// MARK: - Pipeline Event

/// A single timestamped event within a pipeline run.
public struct PipelineEvent: Sendable, Codable {
    public let timestamp: Date
    public let stage: PipelineStage
    /// Milliseconds since the previous event (nil for the first event).
    public let durationMs: Int?
    /// Human-readable description logged to Console.app.
    public let message: String
    /// Error description if this event represents a failure.
    public let error: String?

    public init(
        timestamp: Date = Date(),
        stage: PipelineStage,
        durationMs: Int? = nil,
        message: String,
        error: String? = nil
    ) {
        self.timestamp = timestamp
        self.stage = stage
        self.durationMs = durationMs
        self.message = message
        self.error = error
    }
}

// MARK: - Pipeline Stage

public enum PipelineStage: String, Codable, CaseIterable, Sendable {
    case recordingStarted  = "recording_started"
    case asrComplete       = "asr_complete"
    case dictComplete      = "dict_complete"
    case refineStarted     = "refine_started"
    case refineComplete    = "refine_complete"
    case refineFallback    = "refine_fallback"
    case validationFailed  = "validation_failed"
    case error             = "error"

    public var displayName: String {
        switch self {
        case .recordingStarted: return "Recording"
        case .asrComplete:      return "ASR"
        case .dictComplete:     return "Dictionary"
        case .refineStarted:    return "Refine (start)"
        case .refineComplete:   return "Refine"
        case .refineFallback:   return "Refine (fallback)"
        case .validationFailed: return "Validation"
        case .error:            return "Error"
        }
    }
}

// MARK: - Session Tag

public enum SessionTag: String, CaseIterable, Codable, Sendable {
    case wrongWord       = "wrong_word"
    case badFormatting   = "bad_formatting"
    case missedFiller    = "missed_filler"
    case overTrimmed     = "over_trimmed"
    case injectionFailed = "injection_failed"
    case hallucination   = "hallucination"
    case slowPipeline    = "slow_pipeline"
    case dictionaryMiss  = "dictionary_miss"
    case excellent       = "excellent"

    public var displayName: String {
        switch self {
        case .wrongWord:       return "Wrong word"
        case .badFormatting:   return "Bad formatting"
        case .missedFiller:    return "Missed filler"
        case .overTrimmed:     return "Over-trimmed"
        case .injectionFailed: return "Injection failed"
        case .hallucination:   return "Hallucination"
        case .slowPipeline:    return "Slow pipeline"
        case .dictionaryMiss:  return "Dictionary miss"
        case .excellent:       return "Excellent"
        }
    }

    public var emoji: String {
        switch self {
        case .wrongWord:       return "🔤"
        case .badFormatting:   return "📐"
        case .missedFiller:    return "🗣️"
        case .overTrimmed:     return "✂️"
        case .injectionFailed: return "💉"
        case .hallucination:   return "👻"
        case .slowPipeline:    return "🐢"
        case .dictionaryMiss:  return "📖"
        case .excellent:       return "✅"
        }
    }
}
