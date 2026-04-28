# Changelog

All notable changes to GrembleVoice are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Two-phase pipeline API: `stopRecordingFast()` returns the dictionary-processed transcript
  immediately; `runRefinement(_:)` performs LLM refinement asynchronously. Designed
  for dictation apps that want to inject text first and refine in the background.
- `GrembleSession` model capturing the full lifecycle of a recording — raw ASR
  output, post-processed transcript, refined text, per-stage timing, and event log.
- Optional training-data capture (`captureMode`, `correctedText`, `trainingDecision`,
  `scoreCard`) gated behind the `TRAINING_FEATURES` Swift setting on
  `GrembleVoiceEngine`.

## [0.1.0]

Initial release.

### Modules
- **`GrembleVoiceCore`** — protocols (`ASREngine`, `StreamingASREngine`, `TextRefiner`,
  `AudioSource`), value types (`TranscriptionResult`, `StreamingTextUpdate`,
  `RefinementContext`, `DictionaryEntry`, `AudioSampleBuffer`), and pure-Swift
  utilities for text processing (`ArtifactStripper`, `PhoneticMatcher`,
  `DictionaryProcessor`, `PreambleStripper`, `RefinementValidator`,
  `SensitiveDataFilter`), audio (`AudioResampler`, `AudioLevelMeter`, `WordDiff`,
  `AudioDeviceManager`), and context capture (`ContextCapture`,
  `ContextAwarePromptBuilder`).
- **`GrembleVoiceParakeet`** — Parakeet TDT v3 adapter built on FluidAudio:
  batch and streaming engines, Silero VAD segmentation, and offline speaker
  diarization.
- **`GrembleVoiceWhisper`** — WhisperKit adapter with batch and streaming engines.
- **`GrembleVoiceRefinement`** — on-device LLM refinement via MLX
  (`mlx-community/gemma-3-4b-it-4bit` by default), local Ollama HTTP, and a
  `SmartRouter` actor that chains a primary backend with an optional fallback.
- **`GrembleVoiceCloud`** — BYOK cloud transcription
  (`OpenAITranscriber`, `GroqTranscriber`, `DeepgramTranscriber`) and refinement
  (`ClaudeRefiner`, `OpenAIRefiner`, `GroqRefiner`), plus a `KeychainStore` for
  API key storage. URLSession only — no third-party HTTP dependencies.
- **`GrembleVoiceAudio`** — `MicCaptureSource` and `AudioFileSource` producing
  16 kHz mono Float32 `AsyncStream<[Float]>`.
- **`GrembleVoiceEngine`** — `GrembleVoicePipeline` facade (`@Observable @MainActor`),
  `PipelineConfig`, and structured event logging. The typical entry point for apps.
- **`GrembleVoiceDebug`** — interactive SwiftUI test harness for the pipeline.

### Architectural commitments
- Zero external dependencies in `GrembleVoiceCore`.
- Adapter modules own their heavy dependencies (FluidAudio, WhisperKit, MLX) so
  callers compile only what they use.
- Actors for any type that holds a loaded model, an active audio session, or
  mutable pipeline state.
- `Sendable` value types for everything that crosses an actor boundary.
- `AsyncStream<[Float]>` as the audio contract — `AVAudioPCMBuffer` never crosses
  isolation boundaries.

### Tests
Unit tests cover all of Core, Audio, Cloud, and Refinement (network calls mocked
via a custom `URLProtocol`). ASR adapter integration tests are guarded behind
`GREMBLE_INTEGRATION=1` because they require model downloads.
