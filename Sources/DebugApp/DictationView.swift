import SwiftUI

struct DictationView: View {
    @Bindable var state: PipelineState

    var body: some View {
        VStack(spacing: 0) {
            // ── Top bar: engine + refiner pickers ──────────────────────────────
            HStack(spacing: 20) {
                LabeledContent("ASR Engine") {
                    Picker("", selection: $state.selectedASR) {
                        ForEach(ASRChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 130)
                    .disabled(state.isRecording)
                }

                LabeledContent("Refiner") {
                    Picker("", selection: $state.selectedRefiner) {
                        ForEach(RefinerChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 130)
                    .disabled(state.isRecording)
                }

                Spacer()

                if let error = state.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(2)
                        .frame(maxWidth: 280)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            // ── Status area ─────────────────────────────────────────────────────
            VStack {
                if state.isRecording {
                    Label("Listening…", systemImage: "waveform")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                } else if !state.isRefining && state.rawFinalText.isEmpty {
                    Text("Press Record to start…")
                        .foregroundStyle(.tertiary)
                        .font(.title3)
                }
            }
            .frame(maxHeight: .infinity)
            .background(.background.secondary)

            Divider()

            // ── Record button + level meter ─────────────────────────────────────
            HStack(spacing: 16) {
                Button {
                    if state.isRecording { state.stopRecording() }
                    else { state.startRecording() }
                } label: {
                    Label(
                        state.isRecording ? "Stop" : "Record",
                        systemImage: state.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                    .frame(width: 100)
                }
                .buttonStyle(.borderedProminent)
                .tint(state.isRecording ? .red : .accentColor)
                .disabled(state.isRefining)
                .keyboardShortcut(.space, modifiers: [])

                ProgressView(value: Double(state.audioLevel))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 180)
                    .opacity(state.isRecording ? 1 : 0.3)

                Spacer()
            }
            .padding()

            // ── Results panel (shown after recording stops) ─────────────────────
            if !state.rawFinalText.isEmpty || state.isRefining {
                Divider()
                ResultsPanel(state: state)
                    .frame(height: 220)
            }
        }
    }
}

// MARK: - ResultsPanel

private struct ResultsPanel: View {
    let state: PipelineState
    @State private var showEditSheet = false

    var body: some View {
        HStack(alignment: .top, spacing: 1) {

            // ── Raw transcript ───────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Raw", systemImage: "text.quote")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !state.rawFinalText.isEmpty {
                        Button("Edit & Learn") { showEditSheet = true }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                }
                ScrollView {
                    Text(state.rawFinalText.isEmpty ? "—" : state.rawFinalText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding()
            .sheet(isPresented: $showEditSheet) {
                EditAndLearnSheet(originalText: state.rawFinalText, store: state.dictionary)
            }

            Divider()

            // ── Dictionary-processed ────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Label("Dictionary", systemImage: "character.book.closed")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ScrollView {
                    let text = state.dictionaryText
                    Text(text.isEmpty ? (state.rawFinalText.isEmpty ? "—" : state.rawFinalText) : text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding()

            Divider()

            // ── Refined ─────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Refined", systemImage: "sparkles")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if state.isRefining {
                        ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                    }
                }
                ScrollView {
                    if state.selectedRefiner == .none {
                        Text("Select a refiner above to enable")
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    } else {
                        Text(state.refinedText.isEmpty ? (state.isRefining ? "…" : "—") : state.refinedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                    }
                }
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding()
        }
    }
}

// MARK: - EditAndLearnSheet

private struct EditAndLearnSheet: View {
    let originalText: String
    let store: DictionaryStore
    @Environment(\.dismiss) private var dismiss
    @State private var editedText: String = ""
    @State private var corrections: [(alias: String, word: String)] = []
    @State private var selected: Set<Int> = []
    @State private var phase: Phase = .editing

    enum Phase { case editing, reviewing }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(phase == .editing ? "Edit Transcript" : "Learn Corrections")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            if phase == .editing {
                // ── Full-size text editor ────────────────────────────────
                TextEditor(text: $editedText)
                    .font(.body)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Find Changes") {
                        corrections = DictionaryStore.extractCorrections(
                            original: originalText,
                            edited: editedText
                        )
                        selected = Set(corrections.indices)
                        phase = .reviewing
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(editedText == originalText)
                }
                .padding()

            } else {
                // ── Review detected corrections ──────────────────────────
                if corrections.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No differences detected.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(Array(corrections.enumerated()), id: \.offset) { idx, pair in
                        HStack {
                            Image(systemName: selected.contains(idx)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(idx)
                                                 ? Color.accentColor : .secondary)
                            Text("\"\(pair.alias)\"")
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text("\"\(pair.word)\"")
                                .bold()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selected.contains(idx) { selected.remove(idx) }
                            else { selected.insert(idx) }
                        }
                    }
                }

                Divider()

                HStack {
                    Button("Back") { phase = .editing }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add \(selected.count) to Dictionary") {
                        for idx in selected {
                            let c = corrections[idx]
                            store.add(word: c.word, alias: c.alias)
                        }
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
                }
                .padding()
            }
        }
        .frame(width: 480, height: 400)
        .onAppear { editedText = originalText }
    }
}
