import SwiftUI

struct ModelsView: View {
    @Bindable var state: PipelineState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // ── ASR Models ─────────────────────────────────────────────────
                GroupBox(label: Label("ASR Models", systemImage: "waveform.and.mic").font(.headline)) {
                    VStack(spacing: 12) {
                        ModelRow(
                            name: "Parakeet TDT v3",
                            detail: "FluidAudio · ~600 MB · multilingual",
                            status: state.parakeetStatus,
                            onLoad: { state.loadParakeet() },
                            onUnload: { state.unloadParakeet() }
                        )

                        Divider()

                        HStack {
                            ModelRow(
                                name: "Whisper",
                                detail: "WhisperKit · size depends on variant",
                                status: state.whisperStatus,
                                onLoad: { state.loadWhisper() },
                                onUnload: { state.unloadWhisper() }
                            )
                            Spacer()
                            TextField("Variant", text: $state.whisperVariant)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 140)
                                .disabled(state.whisperStatus.isLoaded || state.whisperStatus.isLoading)
                        }
                    }
                    .padding(.top, 4)
                }

                // ── Refinement Models ──────────────────────────────────────────
                GroupBox(label: Label("On-Device Refinement", systemImage: "cpu").font(.headline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            ModelRow(
                                name: "MLX Refiner",
                                detail: "Gemma 3 4B IT · ~3 GB · Apple Silicon",
                                status: state.mlxStatus,
                                onLoad: { state.loadMLX() },
                                onUnload: { state.unloadMLX() }
                            )
                            Spacer()
                            TextField("Model ID", text: $state.mlxModelID)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 280)
                                .disabled(state.mlxStatus.isLoaded || state.mlxStatus.isLoading)
                        }
                    }
                    .padding(.top, 4)
                }

                // ── Cloud API Keys ─────────────────────────────────────────────
                GroupBox(label: Label("Cloud API Keys", systemImage: "key.fill").font(.headline)) {
                    VStack(spacing: 10) {
                        APIKeyRow(label: "Ollama Base URL", isSecure: false, value: $state.ollamaBaseURL)
                        APIKeyRow(label: "Ollama Model", isSecure: false, value: $state.ollamaModel)
                        Divider()
                        APIKeyRow(label: "Claude API Key", isSecure: true, value: $state.claudeAPIKey)
                        APIKeyRow(label: "OpenAI API Key", isSecure: true, value: $state.openAIAPIKey)
                        APIKeyRow(label: "Groq API Key", isSecure: true, value: $state.groqAPIKey)
                    }
                    .padding(.top, 4)
                }

                Spacer()
            }
            .padding()
        }
    }
}

// MARK: - ModelRow

private struct ModelRow: View {
    let name: String
    let detail: String
    let status: LoadStatus
    let onLoad: () -> Void
    let onUnload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if let msg = status.errorMessage {
                    Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }

            Spacer()

            if let p = status.progress {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
            } else {
                StatusBadge(status: status)
            }

            if status.isLoaded {
                Button("Unload", action: onUnload)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if !status.isLoading {
                Button("Load", action: onLoad)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - StatusBadge

private struct StatusBadge: View {
    let status: LoadStatus

    var body: some View {
        switch status {
        case .loaded:
            Label("Loaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .unloaded:
            Text("Not loaded")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .failed:
            Label("Error", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case .loading:
            EmptyView()
        }
    }
}

// MARK: - APIKeyRow

private struct APIKeyRow: View {
    let label: String
    let isSecure: Bool
    @Binding var value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 140, alignment: .trailing)
                .foregroundStyle(.secondary)
            if isSecure {
                SecureField("", text: $value)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("", text: $value)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}
