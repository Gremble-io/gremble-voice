import Foundation
import OSLog

// MARK: - Pipeline Loggers
//
// One os.Logger per pipeline stage, all under the same subsystem.
//
// Filter in Console.app:   subsystem == "io.gremble.voice"
// Stream live in Terminal: log stream --predicate 'subsystem == "io.gremble.voice"'
// Filter by stage:         log stream --predicate 'subsystem == "io.gremble.voice" AND category == "asr"'
//
// Categories: audio · asr · dict · llm · inject · session

enum PipelineLogger {
    static let subsystem = "io.gremble.voice"

    /// Audio capture: device selection, mic start/stop, level metering anomalies.
    static let audio   = Logger(subsystem: subsystem, category: "audio")

    /// ASR: engine selection, model load, transcription start/complete, WER hints.
    static let asr     = Logger(subsystem: subsystem, category: "asr")

    /// Dictionary: entries checked, substitutions applied, phonetic match details.
    static let dict    = Logger(subsystem: subsystem, category: "dict")

    /// LLM refinement: refiner chosen, request sent, response received, validation result.
    static let llm     = Logger(subsystem: subsystem, category: "llm")

    /// Text injection: strategy (AX / poll / fallback), success/failure.
    static let inject  = Logger(subsystem: subsystem, category: "inject")

    /// Session lifecycle: session started, completed, tagged, exported.
    static let session = Logger(subsystem: subsystem, category: "session")
}

// MARK: - Event Builder

/// Builds up a list of PipelineEvents during a pipeline run.
/// Not an actor — always accessed from a single Task.
final class EventLog: @unchecked Sendable {
    private var events: [PipelineEvent] = []
    private var lastTimestamp: Date = Date()

    func record(
        stage: PipelineStage,
        message: String,
        error: String? = nil,
        at timestamp: Date = Date()
    ) {
        let durationMs = events.isEmpty
            ? nil
            : Int(timestamp.timeIntervalSince(lastTimestamp) * 1000)
        lastTimestamp = timestamp
        events.append(PipelineEvent(
            timestamp: timestamp,
            stage: stage,
            durationMs: durationMs,
            message: message,
            error: error
        ))
    }

    func finish() -> [PipelineEvent] { events }
}
