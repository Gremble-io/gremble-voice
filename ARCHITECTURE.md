# GrembleVoice — Architecture

A reference for the design, module layout, and key technical decisions behind GrembleVoice. This document is intended for engineers integrating the package or contributing to it. For installation and usage, see [`README.md`](README.md).

## Contents

1. [Design principles](#design-principles)
2. [Module map](#module-map)
3. [Pipeline data flow](#pipeline-data-flow)
4. [Core protocols and types](#core-protocols-and-types)
5. [Text processing](#text-processing)
6. [Audio processing](#audio-processing)
7. [Context capture](#context-capture)
8. [ASR adapters](#asr-adapters)
9. [Refinement adapters](#refinement-adapters)
10. [Cloud adapters](#cloud-adapters)
11. [Audio capture](#audio-capture)
12. [Performance characteristics](#performance-characteristics)
13. [Testing](#testing)
14. [Dependency rationale](#dependency-rationale)

---

## Design principles

Five rules drive the structure of the package:

**1. Protocol-only core.** `GrembleVoiceCore` has zero external dependencies. It contains only protocols, value types, and pure-Swift utilities. The domain model can be understood, tested, and depended on without pulling in any ML framework.

**2. Adapter modules own heavy dependencies.** FluidAudio (~600 MB model), WhisperKit (~400 MB–1.6 GB), and MLX each live in their own target. An app that only needs Parakeet doesn't compile WhisperKit. An app that only needs cloud refinement doesn't compile MLX.

**3. Actors for stateful managers.** Any type that holds a loaded model, an active audio session, or mutable pipeline state is an `actor`. Models are large, loading is async, and concurrent loads of the same model would be a data race.

**4. `Sendable` value types for results.** Everything that crosses an actor boundary — `TranscriptionResult`, `StreamingTextUpdate`, `RefinementContext`, `DictionaryEntry` — is a `Sendable` value type. If it compiles under Swift 6 strict concurrency, the threading is correct.

**5. `AsyncStream<[Float]>` as the audio contract.** `AVAudioPCMBuffer` is not `Sendable`, and audio callbacks run on a real-time thread where async work is unsafe. Samples are extracted from the buffer inside the callback (synchronous, safe), then yielded to an `AsyncStream` of `[Float]` chunks.

```swift
inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
    guard let channelData = buffer.floatChannelData else { return }
    let samples = Array(UnsafeBufferPointer(
        start: channelData[0],
        count: Int(buffer.frameLength)
    ))
    continuation.yield(samples)  // yields Sendable [Float], not the buffer
}
```

---

## Module map

```
GrembleVoiceCore          (zero deps)
├── Protocols/            ASREngine, StreamingASREngine, TextRefiner, AudioSource
├── Types/                TranscriptionResult, StreamingTextUpdate, StreamingConfig,
│                         RefinementContext, DictionaryEntry, AudioSampleBuffer
├── TextProcessing/       ArtifactStripper, PhoneticMatcher, DictionaryProcessor,
│                         PreambleStripper, RefinementValidator, SensitiveDataFilter
├── Audio/                AudioDeviceManager, AudioResampler, AudioLevelMeter, WordDiff
└── Context/              ContextCapture, ContextAwarePromptBuilder

GrembleVoiceParakeet      (deps: FluidAudio)
├── ParakeetModelManager  model download + lifecycle
├── ParakeetEngine        batch ASR
├── ParakeetStreamingEngine  real-time streaming
├── VADProcessor          Silero VAD segmentation
└── DiarizationEngine     speaker diarization

GrembleVoiceWhisper       (deps: WhisperKit)
├── WhisperModelManager
├── WhisperEngine
└── WhisperStreamingEngine

GrembleVoiceRefinement    (deps: MLXLLM, MLXLMCommon, swift-transformers)
├── MLXRefiner            on-device LLM (Gemma 3 4B by default)
├── OllamaRefiner         local HTTP
├── OllamaManager         server status + model pull
└── SmartRouter           multi-backend fallback dispatcher

GrembleVoiceCloud         (zero external deps — URLSession only)
├── KeychainStore
├── Transcription/        OpenAITranscriber, GroqTranscriber, DeepgramTranscriber
└── Refinement/           ClaudeRefiner, OpenAIRefiner, GroqRefiner

GrembleVoiceAudio         (deps: AVFoundation, CoreAudio)
├── MicCaptureSource
└── AudioFileSource

GrembleVoiceEngine        (re-exports the modules above)
├── GrembleVoicePipeline  @Observable @MainActor pipeline coordinator
├── GrembleSession        complete record of one recording
├── PipelineConfig        ASR engine + refiner + dictionary configuration
├── PipelineLogger        structured event logging
└── TrainingTypes         (compiled only with -DTRAINING_FEATURES)
```

---

## Pipeline data flow

A typical dictation invocation, end to end:

```
hotkey pressed
    │
    ▼
MicCaptureSource.start()
    │  AsyncStream<[Float]>  (4096-sample chunks at 16 kHz mono)
    ▼
ParakeetStreamingEngine.addSamples()
    │  AudioSampleBuffer accumulates
    │  poll every 200 ms
    │  transcribe(buffer.peek()) → ArtifactStripper → WordDiff
    │  emit StreamingTextUpdate (confirmed + unconfirmed text)
    ▼
hotkey released → stopRecording()
    │
    ▼
ParakeetStreamingEngine.stopStreaming()
    │  transcribe(buffer.consume())  — full accumulated buffer
    │  → rawFinalText
    ▼
ArtifactStripper.strip(rawFinalText)
    │  → rawText
    ▼
DictionaryProcessor.process(rawText, entries, language: "en")
    │  pass 1: exact alias replacement
    │  pass 2: phonetic fuzzy matching
    │  → dictionaryText
    ▼
TextRefiner.refine(dictionaryText, context: ...)
    │  PreambleStripper + RefinementValidator
    │  → refinedText (or fallback to dictionaryText)
    ▼
GrembleSession {
    rawAsrOutput, rawTranscript, dictionaryProcessed, refinedText, events, ...
}
```

`stopRecording()` returns a fully populated `GrembleSession`. For dictation use cases that prefer to inject text immediately and refine in the background, `stopRecordingFast()` returns the dictionary-processed transcript along with a `RefinementInput` that can be fed to `runRefinement(_:)` from a detached task.

---

## Core protocols and types

### `ASREngine`

```swift
public protocol ASREngine: Actor, Sendable {
    var engineName: String { get }
    var isModelLoaded: Bool { get }
    func loadModel(progressHandler: @escaping @Sendable (Double) -> Void) async throws
    func unloadModel() async
    func transcribe(samples: [Float]) async throws -> TranscriptionResult
    func transcribe(audioURL: URL) async throws -> TranscriptionResult
}
```

The actor requirement is intentional: conforming types hold loaded models that must be accessed from one isolation domain at a time.

### `StreamingASREngine`

```swift
public protocol StreamingASREngine: ASREngine {
    func startStreaming(config: StreamingConfig) async throws
    func addSamples(_ samples: [Float]) async
    var textUpdates: AsyncStream<StreamingTextUpdate> { get async }
    func stopStreaming() async throws -> String
}
```

`stopStreaming()` returns the *final* transcript from the full accumulated buffer — not a concatenation of streaming partials. The partial updates during streaming are lower quality (short windows, less context). The final pass over the full buffer is the authoritative result.

### `TextRefiner`

```swift
public protocol TextRefiner: Sendable {
    func refine(text: String, context: RefinementContext?, customPrompt: String?) async throws -> String
}
```

`Sendable` rather than `Actor` because refiners are stateless from the caller's perspective — text in, text out. `MLXRefiner` is internally an actor but presents a `Sendable` interface.

### `AudioSource`

```swift
public protocol AudioSource: Actor, Sendable {
    var sourceName: String { get }
    var isCapturing: Bool { get }
    func start() async throws -> AsyncStream<[Float]>
    func stop() async
}
```

### Value types

| Type | Key fields | Notes |
|------|-----------|-------|
| `TranscriptionResult` | `text`, `language?`, `confidence?`, `processingTime` | Optional fields nullable so engines that don't report confidence still conform. |
| `StreamingTextUpdate` | `confirmedText`, `unconfirmedText` | Confirmed = stable across consecutive passes. Unconfirmed = current window tail. |
| `StreamingConfig` | `maxBufferSamples`, `pollingIntervalNs`, `minSamples` | `.dictation` = 80k / 200 ms / 2.4k. `.meeting` = 480k / 0 / 8k. |
| `RefinementContext` | `activeAppName`, `activeAppBundleID`, `selectedText`, `clipboardText`, `browserURL` | All optional. `isEmpty` for guard checks. |
| `DictionaryEntry` | `id`, `word`, `pronunciation?`, `aliases`, `language: String`, `isEnabled` | `language` is `String` to decouple `Codable` storage from the `SupportedLanguage` enum. |
| `AudioSampleBuffer` | actor | `append`, `peek`, `consume`, `trim(maxSamples:)`. |
| `SupportedLanguage` | 25 cases, `isLatinScript: Bool` | Used by `DictionaryProcessor` to decide whether the non-ASCII ratio check is meaningful. |

`SensitiveDataFilter.filter()` and `ContextCapture.captureSync()` take explicit Bool flags / blocklists rather than reading `UserDefaults` — the library never owns user preferences. The calling app passes its configuration in.

---

## Text processing

### `ArtifactStripper`

Removes content that ASR models hallucinate when given silence or non-speech audio:

- Strips `[Music]`, `(Applause)`, `[inaudible]` and other bracket-enclosed noise markers.
- Maintains a blocklist of known Whisper hallucinations: subtitle credits, attribution strings, "Thank you for watching" patterns, music notation artifacts.
- Non-ASCII ratio check: if more than 40% of characters are non-ASCII *and* the language is Latin-script, the output is likely hallucinated and returns `""`.
- Trims whitespace and collapses runs.

### `PhoneticMatcher`

Three-algorithm fuzzy word matching, applied cheapest first:

- **Soundex.** 4-character code (letter + 3 digits). O(n) comparison. Best for short English words.
- **Metaphone.** English-optimized phonetic encoding. Handles silent letters and digraphs (ph→f, ck→k) better than Soundex.
- **Levenshtein (normalized).** Edit distance ÷ max length. Match threshold ≥ 0.7. Used as a fallback when phonetic codes diverge.

Pre-checks before any algorithm: punctuation stripped from both words; matches rejected when length ratio < 80% (prevents "I" matching "infrastructure").

### `DictionaryProcessor`

Two-pass replacement over tokenized transcript text:

- **Pass 1 — exact alias matching.** Whole-word, case-insensitive replacement of any alias in any enabled `DictionaryEntry`. Uses word-boundary detection — won't replace `"swift"` inside `"swiftly"`.
- **Pass 2 — phonetic fuzzy matching.** For each word that didn't match in Pass 1, run `PhoneticMatcher` against every alias.

Only processes entries where `isEnabled == true` and `entry.language == targetLanguage`.

### `PreambleStripper`

Small LLMs frequently prefix their output with acknowledgment phrases even when instructed not to. This strips them:

- `"Here's the cleaned text:"`, `"Here is the refined version:"`, `"Certainly! Here..."` patterns.
- Triple-backtick code fences wrapping the entire output.
- Leading/trailing quotation-mark wrapping.

### `RefinementValidator`

Validates that LLM output is an acceptable refinement of the input. Two checks:

- **Length check.** `result.wordCount ≤ max(input.wordCount * 2 + 20, 30)`. LLMs should not double the length of a transcript. For code/notes contexts, the multiplier is 3.
- **Word overlap check.** For inputs with more than five meaningful words (filler words excluded), at least 50% of content words in the result must appear in the input. Catches cases where the model confidently rewrites the transcript into something the user didn't say.

The filler-word exclusion set (`um`, `uh`, `like`, `you know`, `sort of`, `kind of`, `basically`, `literally`, `actually`) is expected to disappear and is excluded from the overlap calculation.

Returns `.accept` or `.fallback(reason: String)`. On fallback, the pipeline returns the pre-refinement dictionary-processed text.

### `SensitiveDataFilter`

**Tier 1 — credentials, enabled by default:** AWS access keys, private key headers, GitHub/GitLab/Slack tokens, Anthropic and OpenAI API keys, generic `password=`/`secret=`/`api_key=`/`token=` patterns.

**Tier 2 — PII, opt-in:** SSNs, emails (RFC 5322 simplified), credit card numbers (Luhn-validated).

PII is opt-in by design: in a dictation context, stripping emails from "send this to john@company.com" is almost always wrong — the user said it intentionally. Credentials are different — they should never appear in dictated text at all.

---

## Audio processing

### `AudioResampler`

Converts any audio format to 16 kHz mono Float32 using `AVAudioConverter`:

```
input  : AVAudioFile (any sample rate, any channel count, any format)
output : [Float] at 16 000 Hz, 1 channel, 32-bit float, normalized [-1.0, 1.0]
```

The 16 kHz target matches the training format for all supported ASR models. Feeding a model audio at the wrong sample rate is the most common source of degraded accuracy in ASR integrations.

Handles stereo→mono (channel averaging), high-rate→16 kHz (sinc interpolation), and integer PCM → Float32 normalization. Accepts file URL or `AVAudioPCMBuffer` input.

### `AudioLevelMeter`

Uses `vDSP_rmsqv` (Accelerate, SIMD-vectorized) for RMS calculation:

```swift
var result: Float = 0
vDSP_rmsqv(samples, 1, &result, vDSP_Length(samples.count))
```

On Apple Silicon this runs on the AMX coprocessor. For a 4096-sample chunk at 16 kHz, the throughput improvement versus a scalar loop is ~8–12×. Level metering runs on every audio callback (~250 times per second), so this matters.

### `WordDiff`

Common-prefix word diffing for streaming UI updates:

```swift
func diff(previous: String, current: String) -> (confirmed: String, unconfirmed: String)
```

Tokenizes both strings, finds the longest common word prefix, returns the prefix as `confirmed` and the current's tail as `unconfirmed`. Normalization: lowercase + strip trailing punctuation before comparison, so `"Hello,"` and `"Hello"` are the same word for diff purposes.

### `AudioDeviceManager`

Pure CoreAudio device enumeration: `availableInputDevices()`, `defaultInputDeviceID()`, `deviceUID(for:)`. No AVFoundation, so it can live in `GrembleVoiceCore`.

---

## Context capture

### `ContextCapture`

Captures environmental context at the moment of transcription completion to provide formatting guidance to the LLM:

- **Active app.** `NSWorkspace.shared.frontmostApplication` → name + bundle ID.
- **Selected text.** `AXUIElement` accessibility API, truncated to 800 chars.
- **Clipboard.** `NSPasteboard.general.string(forType: .string)`, truncated to 400 chars.
- **Browser URL.** AppleScript queries to Safari, Chrome, Arc, Brave, and Vivaldi.

A sensitive-app blocklist (1Password, Keychain Access, banking sites, etc.) causes `ContextCapture` to return an empty context without reading selected text or clipboard. The browser URL fetch has a 500 ms timeout — if AppleScript stalls, capture completes without the URL rather than blocking the pipeline.

### `ContextAwarePromptBuilder`

Composes the system prompt for LLM refinement from:

1. **Base instruction set** — grammar, punctuation, filler removal.
2. **App-specific formatting rules** based on bundle ID category:
   - Messaging (iMessage, WhatsApp, Slack, Teams): short sentences, light punctuation.
   - Email (Mail, Gmail, Outlook): paragraph structure, preserve salutations.
   - Code editors (Xcode, VS Code, JetBrains): verbatim technical names, no prose rewriting.
   - Notes / docs (Notes, Notion, Obsidian): markdown when the content is list-like.
3. **Context block** — active app name, selected text excerpt, clipboard excerpt, browser URL.
4. **User custom prompt** appended last so it can override any rule above.

All user-controlled strings (app names, selected text, clipboard) are XML-escaped before insertion to prevent prompt injection via clipboard content.

---

## ASR adapters

### `ParakeetModelManager`

Manages the FluidAudio model lifecycle. The key design choice is that a single manager instance is **shared between `ParakeetEngine` and `ParakeetStreamingEngine`**:

```swift
let manager = ParakeetModelManager()
let batchEngine  = ParakeetEngine(modelManager: manager)
let streamEngine = ParakeetStreamingEngine(modelManager: manager)
// both share the same loaded model
```

Without this, two instances would each download and load the ~600 MB model, doubling memory use. The model is downloaded once, loaded once, and both engine types reference the same `AsrManager`.

Model files cache to `~/Library/Caches/ai.fluidinference.FluidAudio/`. Progress callbacks report 0.0 → 1.0 fractions.

### `ParakeetStreamingEngine`

Sliding-window streaming with a maximum buffer cap:

```
new samples → AudioSampleBuffer.append()
                         │
                  poll every 200 ms
                         │
            buffer.peek() → up to 80 000 samples (5 s at 16 kHz)
                         │
            AsrManager.transcribe(peeked samples)
                         │
            WordDiff.diff(previousResult, newResult)
                         │
            emit StreamingTextUpdate
```

The window is capped at five seconds — longer windows have diminishing accuracy returns in streaming mode and increase latency. The final `stopStreaming()` call passes `buffer.consume()` (the full accumulated recording) for the authoritative final transcript.

The engine pre-runs a dummy transcription with empty samples after model load. This forces CoreML to compile the model's compute graph and cache it; subsequent first calls are 2–3× faster.

### `VADProcessor`

Wraps FluidAudio's Silero VAD for continuous-recording scenarios (meeting transcription):

- Input chunk size: 4096 samples (256 ms at 16 kHz) — required by Silero VAD.
- Speech start/end events trigger segment collection.
- 30-second flush during continuous speech to bound memory.
- Aborts gracefully after more than 10 consecutive VAD errors.

### `DiarizationEngine`

Post-session speaker identification via FluidAudio's `OfflineDiarizerManager`. Downloads CoreML diarization bundles (~150 MB, cached). Returns `[Segment]` with `speakerId: String`, `startTimeSeconds`, `endTimeSeconds`. Speaker IDs are relative within a session (`"SPEAKER_0"`, `"SPEAKER_1"`), not identity.

### Whisper engines

`WhisperEngine`, `WhisperStreamingEngine`, and `WhisperModelManager` mirror the Parakeet adapter's structure but back onto WhisperKit. The streaming implementation uses the same sliding-window approach, with `WhisperKit.DecodingOptions` supplying language detection and vocabulary biasing.

---

## Refinement adapters

### `MLXRefiner`

On-device LLM via Apple's MLX framework:

- **Default model:** `mlx-community/gemma-3-4b-it-4bit` (Gemma 3 4B instruction-tuned, 4-bit).
- **Download:** HuggingFace Hub via `HubApi`, cached to `~/.cache/huggingface/`.
- **VRAM:** ~2.3 GB unified memory when loaded on Apple Silicon.
- **Tokenizer:** `AutoTokenizer` from `swift-transformers`, bridged to `MLXLMCommon.Tokenizer` via `TransformersTokenizerBridge`.
- **Generation:** `maxTokens: 800`, `temperature: 0.1`, Gemma chat template.

### `OllamaRefiner`

HTTP client for a locally-running Ollama server:

- Endpoint: `POST http://localhost:11434/api/chat`.
- Request: `{ model, messages: [{ role: "system", content }, { role: "user", content }] }`.
- Non-streaming: waits for `done: true` in response.
- Default model: `gemma3:4b`.
- No retries — fast-fail for UI responsiveness.

### `OllamaManager`

Server lifecycle helpers:

- **Status check.** `GET /api/tags` with a 3 s timeout → `.notRunning` or `.running([modelNames])`.
- **Model pull.** `POST /api/pull` → streaming NDJSON events with `status` and optional `completed` / `total` bytes.

Model availability uses prefix matching, so `"gemma3:4b"` matches `"gemma3:4b-instruct-q4_K_M"`.

### `SmartRouter`

Dispatcher with an optional fallback chain:

```swift
SmartRouter(
    primary:  .ollama(baseURL: localURL, model: "gemma3:4b"),
    fallback: .custom(ClaudeRefiner(apiKey: key))
)
```

If primary throws (network, timeout, model not loaded), falls back to secondary. Fallback is optional — without one, primary errors propagate.

---

## Cloud adapters

All cloud adapters use `URLSession` directly — no third-party HTTP libraries.

### Refiners

| Adapter | Endpoint | Default model | Auth header |
|---|---|---|---|
| `ClaudeRefiner` | `https://api.anthropic.com/v1/messages` | `claude-3-5-haiku-latest` | `x-api-key: {key}` + `anthropic-version: 2023-06-01` |
| `OpenAIRefiner` | `https://api.openai.com/v1/chat/completions` | `gpt-4o-mini` | `Authorization: Bearer {key}` |
| `GroqRefiner` | `https://api.groq.com/openai/v1/chat/completions` | `llama-3.1-70b-versatile` | `Authorization: Bearer {key}` |

`GroqRefiner` shares the `ChatCompletionRequest` / `ChatCompletionResponse` types with `OpenAIRefiner` because Groq's API is OpenAI-compatible.

### Transcribers

| Adapter | Endpoint | Model | Body |
|---|---|---|---|
| `OpenAITranscriber` | `/v1/audio/transcriptions` | `whisper-1` | multipart/form-data |
| `GroqTranscriber` | `/openai/v1/audio/transcriptions` | `whisper-large-v3` | multipart/form-data |
| `DeepgramTranscriber` | `/v1/listen` | `nova-3` | raw audio body |

Deepgram uses a raw body upload with `Content-Type: audio/wav`. Its response JSON is deeply nested at `results.channels[0].alternatives[0].transcript`.

### `KeychainStore`

Wrapper around `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete`:

```swift
let store = KeychainStore(service: "io.gremble.example")
store.save(key: "anthropic-api-key", value: apiKey)
let key = store.load(key: "anthropic-api-key")
```

Service namespacing prevents apps that use the same Keychain from sharing or overwriting each other's keys.

---

## Audio capture

### `MicCaptureSource`

`AVAudioEngine`-based microphone capture:

1. Permission request via `AVCaptureDevice.requestAccess(.audio)` (macOS) or `AVAudioSession.sharedInstance().requestRecordPermission()` (iOS).
2. Optional device routing via CoreAudio UID (`kAudioDevicePropertyDeviceUID`).
3. Input node tap at the device's native format (typically 48 kHz stereo).
4. `AVAudioConverter` on the audio render thread: 48 kHz stereo → 16 kHz mono Float32.
5. `continuation.yield(samples)` — sends 4096-sample chunks into the `AsyncStream`.

The 4096 buffer size balances low-latency level metering (~256 ms) against callback overhead.

### `AudioFileSource`

Reads an audio file via `AVAudioFile`, resamples to 16 kHz mono Float32, and yields chunks into an `AsyncStream` matching `MicCaptureSource`. Useful for testing the pipeline end-to-end without a microphone.

---

## Performance characteristics

### Streaming latency (debug app, M-series Mac)

| Stage | Time |
|---|---|
| Mic → first `AudioSampleBuffer` entry | ~5 ms (AVAudioEngine tap latency) |
| Streaming poll interval | 200 ms |
| Parakeet transcription (5 s window) | ~50–200 ms depending on content density |
| `DictionaryProcessor` (typical, < 50 entries) | < 1 ms |
| `OllamaRefiner` (Gemma 3 4B, ~100-word input) | ~800 ms – 2.5 s |
| Total stop → refined text | ~1–3 s on M2 or higher |

The bottleneck is LLM refinement, not ASR. The two-phase API (`stopRecordingFast()` + `runRefinement()`) exists to hide this latency behind text injection.

### Memory (approximate)

| Component | RAM |
|---|---|
| Parakeet TDT v3 loaded | ~1.2 GB unified memory |
| WhisperKit `base.en` loaded | ~200 MB |
| Gemma 3 4B (MLX, 4-bit) | ~2.3 GB GPU memory |
| Ollama server process | 2–4 GB (separate process) |
| `GrembleVoiceCore` | < 5 MB |

Parakeet + Gemma 3 4B simultaneously: ~3.5 GB. Comfortable on 16 GB systems, tight on 8 GB.

### Phonetic matching (100 words against a 50-entry dictionary)

| Algorithm | Time |
|---|---|
| Soundex | ~0.1 ms |
| Metaphone | ~0.2 ms |
| Levenshtein (worst case) | ~1 ms |
| Typical `DictionaryProcessor` pass | < 2 ms |

---

## Build flags

### `TRAINING_FEATURES`

Off by default. When enabled, `GrembleSession` gains fields for collecting training data: `correctedText`, `trainingDecision`, `scoreCard`, `captureMode`, and `scriptReference`. Supporting types (`TrainingDecision`, `CaptureMode`, `ScoreCard`, `TrainingPrompt`) are defined in `Sources/Engine/TrainingTypes.swift`.

Enable by passing the flag to the Swift compiler:

```bash
swift build -Xswiftc -DTRAINING_FEATURES
```

Or by adding `.define("TRAINING_FEATURES")` to the `swiftSettings` of the `GrembleVoiceEngine` target in `Package.swift`.

The `Codable` implementation on `GrembleSession` handles both variants — sessions serialized with the flag enabled decode safely in builds without it, and vice versa.

---

## Testing

Tests are partitioned by whether they require model downloads.

**Unit tests** — no network, no models. Run via `swift test`. These run in CI.

**Integration tests** — guarded by `GREMBLE_INTEGRATION=1`:

```swift
guard ProcessInfo.processInfo.environment["GREMBLE_INTEGRATION"] != nil else {
    throw XCTSkip("Set GREMBLE_INTEGRATION=1 to run integration tests")
}
```

Run locally with `GREMBLE_INTEGRATION=1 swift test --filter ParakeetTests`.

**Network mocking.** Cloud adapter tests use a custom `MockURLProtocol` that intercepts `URLSession` requests and returns pre-configured JSON responses without hitting the network:

```swift
let session = URLSession(configuration: {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return config
}())
```

| Test target | Coverage |
|---|---|
| `CoreTests` | `ArtifactStripper`, `PhoneticMatcher`, `DictionaryProcessor`, `RefinementValidator`, `WordDiff`, `AudioLevelMeter`, `AudioResampler` |
| `CloudTests` | All three cloud refiners (HTTP format, auth headers, response parsing), all three transcribers (multipart/raw, response parsing), `KeychainStore` round-trip |
| `RefinementTests` | `OllamaRefiner` HTTP, `MLXRefiner`, `SmartRouter` primary/fallback semantics |
| `AudioTests` | `AudioFileSource` chunk sizes and completion, `MicCaptureSource` lifecycle |
| `ParakeetTests` | Integration-only; requires `GREMBLE_INTEGRATION=1` and the model download |

---

## Dependency rationale

### FluidAudio (Parakeet)

- Parakeet TDT v3 achieves better English WER than Whisper Large v3 at ~40% the parameter count.
- ANE optimization tuned more aggressively than WhisperKit's; higher real-time factor on Apple Silicon.
- Bundles speaker diarization (`OfflineDiarizerManager`) and end-of-utterance detection — Whisper would need these added separately.
- Pinned to `≥ 0.13.0` for the ANE optimizations and the standalone CTC head used for vocabulary biasing in future work.

### WhisperKit

Kept as an alternative for wider multilingual coverage, broader user familiarity, and as a fallback for non-Apple-Silicon targets. `large-v3-turbo` reaches near-large accuracy at ~40% the size.

### MLX (refinement)

- Native Apple Silicon — uses Metal, AMX, and the Neural Engine appropriately.
- Active first-party development; performance improvements ship regularly.
- HuggingFace Hub integration for model download.
- 4-bit quantization of Gemma 3 4B fits comfortably in unified memory.

`llama.cpp` Swift bindings were considered and rejected — MLX integrates better with Apple's unified memory architecture and is actively maintained by Apple's ML team.

### No HTTP library

Cloud adapters use `URLSession` directly. The patterns are simple (JSON encode → POST → JSON decode); pulling in Alamofire for three call sites would add hundreds of kilobytes for no benefit.

### No persistence library

Persistence (dictionaries, sessions, snippets) is JSON via `JSONEncoder` / `JSONDecoder`. SQLite or Core Data would be over-engineering for record sets that won't exceed a few thousand entries.
