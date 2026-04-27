import SwiftUI
import GrembleVoiceRefinement

/// Onboarding sheet shown on first launch (or when Ollama isn't ready).
///
/// Walks the user through two steps:
///   1. Install + start Ollama
///   2. Pull the default model
///
/// Dismisses itself once both steps are complete.
struct OllamaSetupView: View {
    @Bindable var state: PipelineState
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ────────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("Set Up Local Refinement")
                    .font(.title2.bold())
                Text("GrembleVoice uses Ollama to refine transcriptions locally on your Mac. Your audio never leaves your device.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)

            Divider()

            // ── Steps ─────────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 20) {

                // Step 1 — Ollama running
                SetupStep(
                    number: "1",
                    title: "Install & start Ollama",
                    isComplete: state.ollamaServerRunning
                ) {
                    if state.ollamaServerRunning {
                        Text("Ollama is running.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Download and install Ollama, then start the server:")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            CodeBlock("brew install ollama && ollama serve")

                            Text("— or —")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .center)

                            Link("Download from ollama.com",
                                 destination: URL(string: "https://ollama.com/download")!)
                                .font(.callout)

                            Button("Check Again") { state.checkOllamaStatus() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }

                // Step 2 — Model available
                SetupStep(
                    number: "2",
                    title: "Download \(OllamaManager.defaultModel)",
                    isComplete: state.ollamaModelReady,
                    disabled: !state.ollamaServerRunning
                ) {
                    if state.ollamaModelReady {
                        Text("Model is ready.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else if state.ollamaServerRunning {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("~3 GB download. Stored locally, used for all future sessions.")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            if state.ollamaPullProgress > 0 || state.isPullingModel {
                                VStack(alignment: .leading, spacing: 4) {
                                    ProgressView(value: state.ollamaPullProgress)
                                        .progressViewStyle(.linear)
                                    Text(state.ollamaPullStatus)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Button("Download Now") { state.pullOllamaModel() }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                            }

                            if let error = state.ollamaPullError {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                        }
                    } else {
                        Text("Complete step 1 first.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(24)

            Divider()

            // ── Footer ────────────────────────────────────────────────────────
            HStack {
                Button("Skip for now") { onDismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Get Started") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.ollamaModelReady)
            }
            .padding(20)
        }
        .frame(width: 480)
        .onAppear { state.checkOllamaStatus() }
    }
}

// MARK: - SetupStep

private struct SetupStep<Content: View>: View {
    let number: String
    let title: String
    let isComplete: Bool
    var disabled: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Circle badge
            ZStack {
                Circle()
                    .fill(isComplete ? Color.green : (disabled ? Color.secondary.opacity(0.2) : Color.accentColor.opacity(0.15)))
                    .frame(width: 28, height: 28)
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                } else {
                    Text(number)
                        .font(.caption.bold())
                        .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(disabled ? .secondary : .primary)
                content()
            }
        }
        .opacity(disabled ? 0.5 : 1)
    }
}

// MARK: - CodeBlock

private struct CodeBlock: View {
    let code: String
    init(_ code: String) { self.code = code }

    var body: some View {
        Text(code)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
