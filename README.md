# GrembleVoice

A Swift package for end-to-end voice intelligence on Apple platforms: microphone capture, speech recognition, and LLM-powered text refinement. Local-first, with optional cloud-backed providers when you need them.

## About

GrembleVoice is the voice intelligence engine maintained by [Gremble.io](https://gremble.io). It powers speech recognition and LLM-based text refinement across Gremble's product line, and is published as a standalone Swift package so other developers building on Apple platforms can adopt the same pipeline.

Modular by design — adopt the full pipeline or any individual layer — and local-first by default, with cloud providers as an opt-in extension rather than a requirement.

## Highlights

- **Modular.** Pull in only what you need. Core types are zero-dependency and can be tested in isolation.
- **Local-first.** ASR and refinement run on-device by default. Cloud providers are opt-in.
- **Swift 6 strict-concurrency clean.** Actors for stateful managers, `Sendable` value types crossing actor boundaries, `AsyncStream<[Float]>` as the audio contract.
- **Pluggable backends.** Parakeet or Whisper for ASR; on-device MLX, local Ollama, or BYOK cloud APIs for refinement.
- **Two-phase pipeline.** Emit a transcript immediately, refine asynchronously — built for dictation latency.
- **Real text processing.** Hallucination filtering, phonetic dictionary correction, refinement validation, and prompt-injection-safe context capture.

## Modules

| Library | Purpose | Heavy dependencies |
|---|---|---|
| `GrembleVoiceCore` | Protocols, value types, text processing, audio utilities | none |
| `GrembleVoiceAudio` | Microphone capture, audio file playback | AVFoundation |
| `GrembleVoiceParakeet` | Parakeet ASR, VAD, speaker diarization | FluidAudio |
| `GrembleVoiceWhisper` | Whisper ASR | WhisperKit |
| `GrembleVoiceRefinement` | On-device LLM refinement | MLX, swift-transformers |
| `GrembleVoiceCloud` | BYOK cloud transcription + refinement | URLSession only |
| `GrembleVoiceEngine` | Pipeline facade — the typical entry point | (re-exports) |

## Requirements

- macOS 14+ / iOS 17+
- Swift 6 toolchain
- Apple Silicon recommended for full ASR + on-device LLM performance

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/Gremble-io/gremble-voice.git", from: "0.1.0"),
```

Add the libraries you need to your target. For most apps, `GrembleVoiceEngine` is the only product you need to import:

```swift
.product(name: "GrembleVoiceEngine", package: "gremble-voice"),
```

## Quick start

```swift
import GrembleVoiceEngine

let pipeline = GrembleVoicePipeline(config: .default)
try await pipeline.loadModel { progress in
    print("Loading model: \(progress)")
}

try await pipeline.startRecording()
// ...user speaks...
let session = try await pipeline.stopRecording()

print(session.refinedText)
```

### Two-phase pipeline (lower perceived latency)

For dictation use cases, return the transcript immediately and run refinement in the background:

```swift
let (session, input) = try await pipeline.stopRecordingFast()
inject(session.refinedText)  // dictionary-processed transcript, available immediately

if let input {
    Task.detached {
        let result = await pipeline.runRefinement(input)
        replaceInjectedText(with: result.refinedText)
    }
}
```

## Pipeline overview

```
mic / audio file
   │  AsyncStream<[Float]>  (16 kHz mono)
   ▼
ASR  (Parakeet or Whisper, streaming)
   │
   ▼
ArtifactStripper        →  remove ASR hallucinations / silence artifacts
   │
   ▼
DictionaryProcessor     →  exact alias replacement + phonetic fuzzy matching
   │
   ▼
Refinement              →  MLX / Ollama / Anthropic / OpenAI / Groq
   │  (with PreambleStripper + RefinementValidator safety nets)
   ▼
GrembleSession          →  raw, dictionary-processed, and refined text + timing
```

## Documentation

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — module specifications, design decisions, performance characteristics, and testing protocols.
- [`CHANGELOG.md`](CHANGELOG.md)

## License

Licensed under the Apache License, Version 2.0. See [`LICENSE`](LICENSE) for details.

Copyright © 2026 Gremble.io.
